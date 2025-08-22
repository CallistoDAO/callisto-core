// SPDX-License-Identifier: MIT

pragma solidity 0.8.30;

import {
    AccessControl, IAccessControl
} from "../../dependencies/@openzeppelin-contracts-5.3.0/access/AccessControl.sol";
import { IERC20Metadata } from "../../dependencies/@openzeppelin-contracts-5.3.0/interfaces/IERC20Metadata.sol";
import { IERC20, IERC4626 } from "../../dependencies/@openzeppelin-contracts-5.3.0/interfaces/IERC4626.sol";
import { SafeERC20 } from "../../dependencies/@openzeppelin-contracts-5.3.0/token/ERC20/utils/SafeERC20.sol";
import { Math } from "../../dependencies/@openzeppelin-contracts-5.3.0/utils/math/Math.sol";
import { CallistoVault } from "../../src/policies/CallistoVault.sol";
import { ICOLLAR } from "../interfaces/ICOLLAR.sol";
import { IExecutableByHeart } from "../interfaces/IExecutableByHeart.sol";
import { DebtTokenMigrator } from "./DebtTokenMigrator.sol";
import { PSMStrategy } from "./PSMStrategy.sol";
import { VaultStrategy } from "./VaultStrategy.sol";

/**
 * @title Callisto Peg Stability Module (PSM) for COLLAR
 * @notice Swaps a stablecoin asset and COLLAR at a 1:1 rate, deposits assets into a yield vault,
 * and mints/burns COLLAR as needed.
 *
 * @dev Initially uses USDS as the asset and sUSDS as the yield vault. The liquidity provider is the Callisto
 * vault's strategy contract. Asset and yield vault can be migrated if Olympus Cooler V2 changes its debt token.
 */
contract CallistoPSM is AccessControl, IExecutableByHeart {
    using SafeERC20 for IERC20;
    using SafeERC20 for IERC4626;

    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");

    bytes32 public constant MANAGER_ROLE = keccak256("MANAGER_ROLE");

    bytes32 public constant KEEPER_ROLE = keccak256("KEEPER_ROLE");

    bytes32 public constant FEE_EXEMPT_ROLE = keccak256("FEE_EXEMPT_ROLE");

    uint256 public constant ONE_HUNDRED_PERCENT = 1e18;

    uint256 private constant _PAUSE_VALUE = type(uint256).max;

    /// @notice The Callisto stablecoin.
    IERC20 public immutable COLLAR;

    /**
     * @notice The underlying stablecoin (initially USDS).
     *
     * Not planned, but theoretically it could be replaced. See the contract description for details.
     */
    IERC20 public asset;

    uint256 public to18DecimalsMultiplier;

    /**
     * @notice ERC4626 vault for the asset (initially sUSDS).
     *
     * Not planned, but theoretically it could be replaced. See the contract description for details.
     */
    IERC4626 public yieldVault;

    /// @notice Fee (in 1e18) for minting COLLAR when selling the asset.
    uint256 public feeIn;

    /// @notice Fee (in 1e18) for redeeming COLLAR when buying the asset.
    uint256 public feeOut;

    /// @notice Liquidity provider (Callisto vault's strategy contract).
    address public liquidityProvider;

    /// @notice Total yield vault shares (initially sUSDS) supplied by the liquidity provider.
    uint256 public suppliedByLP;

    /// @notice The amount of COLLAR which is minted by this contract and should be burned with `swapIn` operations.
    uint256 public excessCOLLAR;

    /// @notice The amount of COLLAR waiting to be burned using `execute` when it is greater than `minBurningAmount`.
    uint256 public collarPendingBurning;

    uint256 public minBurningAmount;

    /**
     * @notice The PSM strategy in which incoming COLLAR is deposited, when there is no `excessCOLLAR`,
     * to earn a profit for the Callisto treasury.
     */
    PSMStrategy public strategy;

    /// @notice The contract address authorized to migrate the debt token.
    address public debtTokenMigrator;

    event LiquidityAdded(uint256 indexed shares, uint256 indexed newLPBalance);

    event LiquidityRemoved(uint256 indexed shares, uint256 indexed newLPBalance);

    event COLLARBought(address indexed account, uint256 indexed collarOut, uint256 indexed assetsIn, uint256 fee);

    event COLLARSold(address indexed account, uint256 indexed collarIn, uint256 indexed assetsOut, uint256 fee);

    event FeeInSet(uint256 indexed value);

    event FeeOutSet(uint256 indexed value);

    event LPSet(address indexed lp);

    event MinBurningAmountSet(uint256 indexed amount);

    event AssetMigrated(
        address indexed newAsset,
        address indexed newYieldVault,
        address indexed receiver,
        uint256 assets,
        uint256 suppliedByLPConverted
    );

    /**
     * @notice Emitted when the debt token migrator address is updated
     * @param oldMigrator The previous migrator address
     * @param newMigrator The new migrator address
     */
    event DebtTokenMigratorSet(address indexed oldMigrator, address indexed newMigrator);

    event MigratedToNewStrategy(address indexed oldStrategy, address indexed newStrategy);

    error ZeroAmount();

    error Paused();

    error OnlyLP();

    error InvalidParameter();

    error AlreadyFeeExempt(address account);

    error NotFeeExempt(address account);

    error AlreadyInitialized();

    error OnlyDebtTokenMigrator(address migrator);

    error MigratorNotSet();

    error MismatchedCoolerAddress();

    error OnlyStrategy();

    error MismatchedDebtTokenAddress();

    modifier onlyLP() {
        require(msg.sender == liquidityProvider, OnlyLP());
        _;
    }

    modifier onlyAdminOrManager() {
        require(
            hasRole(MANAGER_ROLE, msg.sender) || hasRole(ADMIN_ROLE, msg.sender),
            IAccessControl.AccessControlBadConfirmation()
        );
        _;
    }

    modifier nonzeroAmount(uint256 amount) {
        require(amount != 0, ZeroAmount());
        _;
    }

    /**
     * @dev Use `finalizeInitialization` after deployment. Optionally set fees with `setFee` and
     * the minimum COLLAR burning amount with `setMinBurningAmount`.
     */
    constructor(address defaultAdmin, address asset_, address collar, address yieldVault_, address psmStrategy) {
        require(
            defaultAdmin != address(0) && asset_ != address(0) && collar != address(0) && yieldVault_ != address(0)
                && psmStrategy != address(0),
            InvalidParameter()
        );

        _grantRole(DEFAULT_ADMIN_ROLE, defaultAdmin);

        COLLAR = IERC20(collar);
        asset = IERC20(asset_);
        to18DecimalsMultiplier = 10 ** (18 - IERC20Metadata(asset_).decimals());
        yieldVault = IERC4626(yieldVault_);
        strategy = PSMStrategy(psmStrategy);
        emit FeeInSet(0);
        emit FeeOutSet(0);
        debtTokenMigrator = address(0);
    }

    /// @notice Finalizes the contract initialization by setting the liquidity provider.
    function finalizeInitialization(address lp) external onlyRole(ADMIN_ROLE) {
        require(liquidityProvider == address(0), AlreadyInitialized());
        require(lp != address(0), InvalidParameter());
        liquidityProvider = lp;
        emit LPSet(lp);
    }

    // Note: COLLAR and the asset swap at a 1:1 ratio.

    /// @notice Sells `assets` for COLLAR, mints COLLAR to recipient, and deposits `assets` to yield vault.
    function swapOut(address to, uint256 assets) external returns (uint256) {
        uint256 feeIn_ = feeIn;
        require(feeIn_ != _PAUSE_VALUE, Paused());
        return _sellAssets(to, assets, feeIn_);
    }

    /// @notice Sells `assets` for COLLAR with no fee (fee-exempt role only).
    function swapOutNoFee(address to, uint256 assets) external onlyRole(FEE_EXEMPT_ROLE) returns (uint256) {
        require(feeIn != _PAUSE_VALUE, Paused());
        return _sellAssets(to, assets, 0);
    }

    /**
     * TODO: add another method to withdraw COLLAR for the CDP's stability pool.
     * @notice Redeems COLLAR for `assets`, withdraws `assets` from `yieldVault`, and deposits COLLAR into the strategy.
     */
    function swapIn(address to, uint256 assets) external returns (uint256) {
        uint256 feeOut_ = feeOut;
        require(feeOut_ != _PAUSE_VALUE, Paused());
        return _buyAssets(to, assets, feeOut_);
    }

    /// @notice Redeems COLLAR for `assets` with no fee (fee-exempt role only).
    function swapInNoFee(address to, uint256 assets) external onlyRole(FEE_EXEMPT_ROLE) returns (uint256) {
        require(feeOut != _PAUSE_VALUE, Paused());
        return _buyAssets(to, assets, 0);
    }

    /// @notice Returns COLLAR amount to mint for a given `assets` amount.
    function calcCOLLAROut(uint256 assets) external view returns (uint256, uint256) {
        return _calcCOLLAROut(assets, feeIn);
    }

    /// @notice Returns COLLAR amount needed to buy a given `assets` amount.
    function calcCOLLARIn(uint256 assets) external view returns (uint256, uint256) {
        return _calcCOLLARIn(assets, feeOut);
    }

    // TODO: add `fee` receiver, `sweepFee()`.

    function _sellAssets(
        address to,
        uint256 assets,
        uint256 fee // Percentage.
    ) private nonzeroAmount(assets) returns (uint256 collarOut) {
        // Calculate the COLLAR amount, including fee, to mint.
        (collarOut, fee) = _calcCOLLAROut(assets, fee);

        // Transfer `assets` from the caller.
        IERC20 asset_ = asset;
        asset_.safeTransferFrom(msg.sender, address(this), assets);

        // Deposit `assets` to `yieldVault` to earn yield.
        IERC4626 yieldVault_ = yieldVault;
        // slither-disable-next-line unused-return
        asset_.approve(address(yieldVault_), assets);
        // slither-disable-next-line unused-return
        yieldVault_.deposit(assets, address(this));

        // Mint COLLAR to `to`.
        ICOLLAR(address(COLLAR)).mintByPSM(to, collarOut);
        excessCOLLAR += collarOut;

        emit COLLARBought(to, collarOut, assets, fee);
        return collarOut;
    }

    function _buyAssets(
        address to,
        uint256 assets,
        uint256 fee // Percentage.
    ) private nonzeroAmount(assets) returns (uint256 collarIn) {
        // Calculate the COLLAR amount, including fee, to transfer from the caller.
        (collarIn, fee) = _calcCOLLARIn(assets, fee);

        /* Calculate the COLLAR amount to be deposited into the strategy and
         * the amount to be burned if excess COLLAR exists.
         */
        uint256 collarToStrategy = 0;
        uint256 excess = excessCOLLAR - collarPendingBurning;
        if (excess < collarIn) {
            collarToStrategy = collarIn - excess;
            if (excess != 0) collarPendingBurning += excess;
        } else {
            // collarToStrategy = 0;
            collarPendingBurning += collarIn;
        }

        // Transfer `collarIn` from the caller.
        COLLAR.safeTransferFrom(msg.sender, address(this), collarIn);

        // Transfer COLLAR to the strategy if no excess COLLAR.
        if (collarToStrategy != 0) {
            PSMStrategy strategy_ = strategy;
            // Instead of `approve` to reduce gas consumption.
            COLLAR.safeTransfer(address(strategy_), collarToStrategy);
            strategy_.deposit(collarToStrategy);
        }

        // Withdraw `assets` and transfer to `to`.
        // slither-disable-next-line unused-return
        yieldVault.withdraw({ assets: assets, receiver: to, owner: address(this) });

        emit COLLARSold(to, collarIn, assets, fee);
        return collarIn;
    }

    /// @notice Returns COLLAR amount to be minted for `assets`.
    function _calcCOLLAROut(uint256 assets, uint256 feeIn_) private view returns (uint256 collarOut, uint256 fee) {
        collarOut = assets * to18DecimalsMultiplier; // 1-to-1 ratio.
        fee = feeIn_;
        if (fee != 0) {
            fee = Math.mulDiv(collarOut, fee, ONE_HUNDRED_PERCENT);
            collarOut -= fee;
        }
        return (collarOut, fee);
    }

    function _calcCOLLARIn(uint256 assets, uint256 feeOut_) private view returns (uint256 collarIn, uint256 fee) {
        collarIn = assets * to18DecimalsMultiplier; // 1-to-1 ratio.
        fee = feeOut_;
        if (fee != 0) {
            fee = Math.mulDiv(collarIn, fee, ONE_HUNDRED_PERCENT);
            collarIn += fee;
        }
        return (collarIn, fee);
    }

    /// @notice Supplies `yieldVault` shares as liquidity (LP only).
    function addLiquidity(uint256 shares) external onlyLP {
        suppliedByLP += shares;
        emit LiquidityAdded(shares, suppliedByLP);
    }

    /// @notice Withdraws `yieldVault` shares as liquidity (LP only).
    function removeLiquidity(uint256 shares, address to) external onlyLP {
        suppliedByLP -= shares;
        yieldVault.safeTransfer(to, shares);
        emit LiquidityRemoved(shares, suppliedByLP);
    }

    /// @notice Withdraws `assets` as liquidity (LP only).
    function removeLiquidityAsAssets(uint256 assets, address to) external onlyLP returns (uint256) {
        uint256 shares = yieldVault.withdraw({ assets: assets, receiver: to, owner: address(this) });
        suppliedByLP -= shares;
        emit LiquidityRemoved(shares, suppliedByLP);
        return shares;
    }

    /**
     * @inheritdoc IExecutableByHeart
     * @notice Burns excess COLLAR, as far as possible.
     */
    function execute() external override onlyRole(KEEPER_ROLE) {
        burnExcessCOLLAR();
    }

    function burnExcessCOLLAR() public {
        uint256 excess = excessCOLLAR;
        if (excess < minBurningAmount) return;

        bool burned = false;

        // Burn excess COLLAR, as far as possible.
        // Burn all COLLAR pending burning in the PSM.
        uint256 toBurn = collarPendingBurning;
        if (toBurn != 0) {
            burned = true;
            excess -= toBurn;
            delete collarPendingBurning;
            ICOLLAR(address(COLLAR)).burn(address(this), toBurn);
        }
        /* If excess remains, check burnable COLLAR in the strategy and
         * burn as much as necessary, or everything available.
         */
        if (excess != 0) {
            PSMStrategy strategy_ = strategy;
            toBurn = strategy_.burnableCOLLAR(); // Burnable.
            if (toBurn != 0) {
                burned = true;
                if (excess <= toBurn) toBurn = excess; // Burn only the excess amount.
                excess -= toBurn;
                strategy_.burnCOLLAR(toBurn);
            }
        }

        // Update `excessCOLLAR` if any amount is burned.
        if (burned) excessCOLLAR = excess;
    }

    /// @notice Adds or removes fee exemption for an account.
    function setFeeExempt(address account, bool add) external onlyRole(ADMIN_ROLE) {
        if (add) {
            if (!_grantRole(FEE_EXEMPT_ROLE, account)) revert AlreadyFeeExempt(account);
        } else if (!_revokeRole(FEE_EXEMPT_ROLE, account)) {
            revert NotFeeExempt(account);
        }
    }

    /// @notice Sets `swapIn` or `swapOut` fee (admin only).
    function setFee(uint256 value, bool setFeeIn) external onlyRole(ADMIN_ROLE) {
        require(value <= ONE_HUNDRED_PERCENT || value == _PAUSE_VALUE, InvalidParameter());
        if (setFeeIn) {
            feeIn = value;
            emit FeeInSet(value);
        } else {
            feeOut = value;
            emit FeeOutSet(value);
        }
    }

    function setMinBurningAmount(uint256 collarAmount) external onlyAdminOrManager {
        minBurningAmount = collarAmount;
        emit MinBurningAmountSet(collarAmount);
    }

    /// @notice Sets the debt token migrator address (admin only).
    /// @param newMigrator The new debt token migrator address (can be address(0) to disable migrations)
    function setDebtTokenMigrator(address newMigrator) external onlyRole(ADMIN_ROLE) {
        if (newMigrator != address(0)) {
            require(
                address(DebtTokenMigrator(newMigrator).OLYMPUS_COOLER())
                    == address(CallistoVault(VaultStrategy(liquidityProvider).vault()).OLYMPUS_COOLER()),
                MismatchedCoolerAddress()
            );
        }
        address oldMigrator = debtTokenMigrator;
        debtTokenMigrator = newMigrator;
        emit DebtTokenMigratorSet(oldMigrator, newMigrator);
    }

    /// @notice Transfers `value` of tokens, transferred directly to the PSM, to `to`.
    function transferUnexpectedTokens(address token, address to, uint256 value) external onlyAdminOrManager {
        if (token == address(yieldVault)) return;

        if (token != address(COLLAR)) {
            IERC20(token).safeTransfer(to, value);
        } else {
            IERC20 collar = IERC20(token);
            if (collar.balanceOf(address(this)) - collarPendingBurning >= value) {
                collar.safeTransfer(to, value);
            }
        }
    }

    /**
     * @notice Migrates to a `newAsset` and `yieldVault`. Only callable by the debt token migrator.
     * @param newAsset New asset address.
     * @param newYieldVault New yield vault address.
     * @param receiver Address to receive withdrawn assets.
     * @param assets Amount of asset to withdraw.
     * @param suppliedByLPConverted New LP share balance after migration.
     * @dev `newAsset` should have 18 or less decimals. Otherwise, reverts because of overflow.
     */
    function migrateAsset(
        address newAsset,
        address newYieldVault,
        address receiver,
        uint256 assets,
        uint256 suppliedByLPConverted
    ) external {
        address migrator = debtTokenMigrator;
        require(migrator != address(0), MigratorNotSet());
        require(msg.sender == migrator, OnlyDebtTokenMigrator(migrator));
        require(
            newAsset
                == address(
                    CallistoVault(VaultStrategy(liquidityProvider).vault()).OLYMPUS_COOLER().treasuryBorrower().debtToken()
                ),
            MismatchedDebtTokenAddress()
        );

        IERC20 asset_ = asset;
        IERC4626 newVault = IERC4626(newYieldVault);
        require(newAsset != address(asset_) && newVault.asset() == newAsset, InvalidParameter());

        // slither-disable-next-line unused-return
        yieldVault.withdraw({ assets: assets, receiver: receiver, owner: address(this) });

        asset = IERC20(newAsset);
        to18DecimalsMultiplier = 10 ** (18 - IERC20Metadata(newAsset).decimals());
        yieldVault = newVault;
        suppliedByLP = suppliedByLPConverted;
        emit AssetMigrated(newAsset, newYieldVault, receiver, assets, suppliedByLPConverted);
    }

    function migrateToNewStrategy(address newStrategy) external {
        address oldStrategy = address(strategy);
        require(msg.sender == oldStrategy, OnlyStrategy());

        strategy = PSMStrategy(newStrategy);
        emit MigratedToNewStrategy(oldStrategy, newStrategy);
    }
}
