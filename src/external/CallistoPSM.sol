// SPDX-License-Identifier: MIT

pragma solidity 0.8.30;

import { AccessControl } from "../../dependencies/@openzeppelin-contracts-5.3.0/access/AccessControl.sol";
import { IERC20Metadata } from "../../dependencies/@openzeppelin-contracts-5.3.0/interfaces/IERC20Metadata.sol";
import { IERC20, IERC4626 } from "../../dependencies/@openzeppelin-contracts-5.3.0/interfaces/IERC4626.sol";
import { SafeERC20 } from "../../dependencies/@openzeppelin-contracts-5.3.0/token/ERC20/utils/SafeERC20.sol";
import { Math } from "../../dependencies/@openzeppelin-contracts-5.3.0/utils/math/Math.sol";
import { ICOLLAR } from "../interfaces/ICOLLAR.sol";

/**
 * @title Callisto Peg Stability Module (PSM) for COLLAR
 * @notice Swaps a stablecoin asset and COLLAR at a 1:1 rate, deposits assets into a yield vault,
 * and mints/burns COLLAR as needed.
 *
 * @dev Initially uses USDS as the asset and sUSDS as the yield vault. The liquidity provider is the Callisto
 * vault's strategy contract. Asset and yield vault can be migrated if Olympus Cooler V2 changes its debt token.
 */
contract CallistoPSM is AccessControl {
    using SafeERC20 for IERC20;
    using SafeERC20 for IERC4626;
    using SafeERC20 for ICOLLAR;

    // ___ CONSTANTS & IMMUTABLES

    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");

    bytes32 public constant KEEPER_ROLE = keccak256("KEEPER_ROLE");

    bytes32 public constant FEE_EXEMPT_ROLE = keccak256("FEE_EXEMPT_ROLE");

    uint256 public constant ONE_HUNDRED_PERCENT = 1e18;

    uint256 private constant _PAUSE_VALUE = type(uint256).max;

    /// @notice The Callisto stablecoin.
    ICOLLAR public immutable COLLAR;

    address public immutable DEBT_TOKEN_MIGRATOR;

    // ___ STORAGE

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

    IERC4626 public callistoStabilityPool;

    uint256 public depositedToStabilityPool;

    // ___ EVENTS

    event LiquidityAdded(uint256 shares, uint256 newLPBalance);

    event LiquidityRemoved(uint256 shares, uint256 newLPBalance);

    event COLLARBought(address indexed account, uint256 assetsIn, uint256 collarOut, uint256 fee);

    event COLLARSold(address indexed account, uint256 collarIn, uint256 assetsOut, uint256 fee);

    event COLLARBurned(uint256 amount);

    event FeeInSet(uint256 value);

    event FeeOutSet(uint256 value);

    event LPSet(address lp);

    event CallistoStabilityPoolInitialized(address pool);

    event AssetMigrated(
        address indexed newAsset,
        address indexed newYieldVault,
        address indexed receiver,
        uint256 assets,
        uint256 suppliedByLPConverted
    );

    // ___ ERRORS

    error ZeroAmount();

    error Paused();

    error OnlyLP();

    error InvalidParameter();

    error AlreadyFeeExempt(address account);

    error NotFeeExempt(address account);

    error AlreadyInitialized();

    error OnlyDebtTokenMigrator(address migrator);

    // ___ MODIFIERS

    modifier onlyLP() {
        require(msg.sender == liquidityProvider, OnlyLP());
        _;
    }

    modifier nonzeroAmount(uint256 amount) {
        require(amount != 0, ZeroAmount());
        _;
    }

    // ___ INITIALIZATION

    /**
     * @dev Use `setLiquidityProvider` and `initCallistoStabilityPool` after deployment. Optionally set fees with
     * `setFee`.
     */
    constructor(address defaultAdmin, address asset_, address collar, address yieldVault_, address debtTokenMigrator) {
        require(
            defaultAdmin != address(0) && asset_ != address(0) && collar != address(0) && yieldVault_ != address(0)
                && debtTokenMigrator != address(0),
            InvalidParameter()
        );

        _grantRole(DEFAULT_ADMIN_ROLE, defaultAdmin);

        COLLAR = ICOLLAR(collar);
        asset = IERC20(asset_);
        to18DecimalsMultiplier = 10 ** (18 - IERC20Metadata(asset_).decimals());
        yieldVault = IERC4626(yieldVault_);
        emit FeeInSet(0);
        emit FeeOutSet(0);
        DEBT_TOKEN_MIGRATOR = debtTokenMigrator;
    }

    function initCallistoStabilityPool(address pool) external onlyRole(ADMIN_ROLE) {
        require(address(callistoStabilityPool) == address(0), AlreadyInitialized());
        require(pool != address(0), InvalidParameter());
        callistoStabilityPool = IERC4626(pool);
        emit CallistoStabilityPoolInitialized(pool);
    }

    // ___ SWAP BETWEEN ASSETS & COLLAR

    // Note: COLLAR and the asset swap at a 1:1 ratio.

    // TODO: consider whether we need to add `from` methods.

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
     * @notice Redeems COLLAR for `assets`, withdraws `assets` from `yieldVault`, and deposits COLLAR to Stability Pool.
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

    function _sellAssets(
        address to,
        uint256 assets,
        uint256 fee // Percentage.
    ) private nonzeroAmount(assets) returns (uint256 collarOut) {
        // Calculate the COLLAR amount to mint.
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
        // TODO: check whether COLLAR reverts if `to` is the zero address.
        COLLAR.mintFromWhitelistedContract(to, collarOut);

        emit COLLARBought(to, collarOut, assets, fee);
        return collarOut;
    }

    // TODO: clarify when COLLAR should be withdrawn from the CDP after cOHM have been exchanged for COLLAR in the CDP.

    function _buyAssets(
        address to,
        uint256 assets,
        uint256 fee // Percentage.
    ) private nonzeroAmount(assets) returns (uint256 collarIn) {
        // Calculate the COLLAR amount to transfer from the caller.
        (collarIn, fee) = _calcCOLLARIn(assets, fee);

        // Transfer `collarIn` from the caller.
        ICOLLAR collar = COLLAR;
        collar.safeTransferFrom(msg.sender, address(this), collarIn);
        // Transfer `collarIn` to `stabilityPool`.
        IERC4626 stabilityPool = callistoStabilityPool;
        // slither-disable-next-line unused-return
        collar.approve(address(stabilityPool), collarIn);
        // slither-disable-next-line unused-return
        stabilityPool.deposit(collarIn, address(this));
        depositedToStabilityPool += collarIn;
        // TODO: clarify whether to deposit an accumulated value through an external function.
        // TODO: clarify whether to track the total value deposited into the CDP.
        // TODO: handle `stabilityPool`'s shares.

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

    // ___ LIQUIDITY PROVIDER FUNCTIONS TO TRACK THE TOTAL SUPPLY

    /// @notice Supplies `yieldVault` shares as liquidity (LP only).
    function addLiquidity(uint256 shares) external onlyLP {
        suppliedByLP += shares;
        yieldVault.safeTransferFrom(msg.sender, address(this), shares);
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

    /* TODO: ensure that the LP does not need a method for withdrawing shares in excess of the liquidity provided
     * in some cases.
     */

    // ___ ADMINISTRATIVE FUNCTIONS

    // TODO: update based on inflation decision.
    /// @notice Burns up to `amount` of COLLAR accumulated from asset purchases.
    function burnCOLLAR(uint256 amount) external {
        require(hasRole(KEEPER_ROLE, msg.sender) || hasRole(ADMIN_ROLE, msg.sender), AccessControlBadConfirmation());
        if (amount != 0) {
            ICOLLAR collar = COLLAR;
            uint256 balance = collar.balanceOf(address(this));
            if (amount > balance) amount = balance;
            collar.burnFromWhitelistedContract(amount);
            emit COLLARBurned(amount);
        }
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

    /// @notice Sets the liquidity provider address (admin only).
    function setLP(address lp) external onlyRole(ADMIN_ROLE) {
        require(lp != address(0), InvalidParameter());
        liquidityProvider = lp;
        emit LPSet(lp);
    }

    /// @notice Transfers unexpected tokens (not managed by PSM) to a recipient (callable by admin only).
    function transferUnexpectedTokens(address token, address to, uint256 value) external onlyRole(ADMIN_ROLE) {
        if (token != address(yieldVault) && token != address(callistoStabilityPool) && token != address(COLLAR)) {
            IERC20(token).safeTransfer(to, value);
        }
    }

    // ___ ASSET MIGRATION LOGIC

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
        require(msg.sender == DEBT_TOKEN_MIGRATOR, OnlyDebtTokenMigrator(DEBT_TOKEN_MIGRATOR));
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
}
