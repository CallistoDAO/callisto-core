// SPDX-License-Identifier: AGPL-3.0-only

pragma solidity 0.8.30;

import { Kernel, Keycode, Permissions, Policy } from "../Kernel.sol";
import { DebtTokenMigrator } from "../external/DebtTokenMigrator.sol";
import { VaultStrategy } from "../external/VaultStrategy.sol";
import { ICallistoVault } from "../interfaces/ICallistoVault.sol";
import { IConverterToWadDebt } from "../interfaces/IConverterToWadDebt.sol";
import { ICoolerTreasuryBorrower } from "../interfaces/ICoolerTreasuryBorrower.sol";
import { IDLGTEv1 } from "../interfaces/IDLGTEv1.sol";
import { IExecutableByHeart } from "../interfaces/IExecutableByHeart.sol";
import { IGOHM } from "../interfaces/IGOHM.sol";
import { IMonoCooler } from "../interfaces/IMonoCooler.sol";
import { IOHMSwapper } from "../interfaces/IOHMSwapper.sol";
import { IOlympusStaking } from "../interfaces/IOlympusStaking.sol";
import { CallistoConstants } from "../libraries/CallistoConstants.sol";
import { CommonRoles } from "../libraries/CommonRoles.sol";
import { RolesConsumer } from "../modules/ROLES/CallistoRoles.sol";
import { ROLESv1 } from "../modules/ROLES/CallistoRoles.sol";
import { TRSRYv1 } from "../modules/TRSRY/CallistoTreasury.sol";
import { IERC20 } from "@openzeppelin/contracts/interfaces/IERC20.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/interfaces/IERC20Metadata.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { ERC20Permit } from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import { ERC4626 } from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { ReentrancyGuardTransient } from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { SafeCast } from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import { FixedPointMathLib } from "@solady/src/utils/FixedPointMathLib.sol";

/**
 * @title CallistoVault
 * @author Callisto Protocol
 * @notice ERC4626-compliant vault that wraps OHM into cOHM, converts it to gOHM, opens a loan in Olympus Cooler v2,
 * and uses the debt token in sophisticated DeFi strategies.
 *
 * - 1 OHM (1e9) = 1 cOHM share (1e18)
 * - OHM → gOHM → Cooler V2 → USDS → Vault Strategy
 * - Strategy yield covers Cooler V2 interest, surplus flows to treasury
 */
contract CallistoVault is
    Policy,
    RolesConsumer,
    ERC4626,
    ERC20Permit,
    ReentrancyGuardTransient,
    ICallistoVault,
    IExecutableByHeart
{
    using Math for *;
    using SafeCast for *;
    using SafeERC20 for IERC20;

    bytes32 public constant CDP_ROLE = "cdp";
    bytes32 public constant HEART_ROLE = "heart";

    uint256 private constant _TO_18_DECIMALS_FACTOR = 1e9;

    IGOHM public immutable GOHM;

    uint128 private immutable _GOHM_PRECISION;

    /**
     * @notice Olympus Staking contract for OHM-gOHM conversion.
     *
     * Reference: `https://docs.olympusdao.finance/main/contracts-old/staking/#ohm-staking`.
     */
    IOlympusStaking public immutable OLYMPUS_STAKING;

    /// @notice Olympus Cooler V2 contract.
    IMonoCooler public immutable OLYMPUS_COOLER;

    VaultStrategy public immutable STRATEGY;

    /// @notice The Callisto treasury.
    address public TRSRY;

    // The amount of total assets (OHM) deposited into the vault.
    uint256 private _totalAssets;

    IERC20 public debtToken;

    /// @dev Converter from wad to debt token decimals for borrowing operations.
    ICoolerTreasuryBorrower private _debtConverterFromWad;

    /// @dev Converter from debt token decimals to wad for repayment calculations.
    IConverterToWadDebt public debtConverterToWad;

    uint256 public minDeposit;

    /// @notice OHM deposits awaiting to be deposited into the strategy.
    uint256 public pendingOHMDeposits;

    /**
     * @notice The amount of OHM staked to `OLYMPUS_STAKING`. It is only used when the
     * `OHMToGOHMMode.ZeroWarmup`
     * mode is active because of the non-zero warm-up period. See `OHMToGOHMMode` for details.
     */
    uint256 public pendingOHMWarmupStaking;

    ICallistoVault.OHMToGOHMMode public ohmToGOHMMode;

    uint256 public totalReimbursementClaim;

    /**
     * @notice A reimbursement claim for `account` in wad terms of Olympus for `debtToken`.
     *
     * Sets when an `account` repays the vault's debt in Olympus Cooler V2 using `repayCoolerDebt`, to prevent
     * the vault's position from being liquidated. Represents a claim the account can later redeem when enough
     * `debtTokens` in the strategy.
     */
    mapping(address account => uint256) public reimbursementClaims;

    /// @dev OHM swapper used when the `OHMToGOHMMode.Swap` mode is active.
    IOHMSwapper public ohmSwapper;

    bool public depositPaused;

    bool public withdrawalPaused;

    /// @notice The contract address authorized to migrate the debt token.
    address public debtTokenMigrator;

    modifier onlyAdminOrManager() {
        ROLESv1 roles = ROLES;
        require(
            roles.hasRole(msg.sender, CommonRoles.ADMIN) || roles.hasRole(msg.sender, CommonRoles.MANAGER),
            CommonRoles.Unauthorized(msg.sender)
        );
        _;
    }

    modifier nonzeroValue(uint256 v) {
        require(v != 0, ZeroValue());
        _;
    }

    modifier whenWithdrawalNotPaused() {
        require(!withdrawalPaused, WithdrawalsPaused());
        _;
    }

    struct InitialParameters {
        address asset;
        address olympusStaking;
        address olympusCooler;
        address strategy;
        address debtConverterToWad;
        uint256 minDeposit;
    }

    /**
     * @notice Initializes the Callisto Vault with required dependencies and configuration.
     * @dev Sets up the ERC4626 vault with OHM as the underlying asset and cOHM as shares.
     *      Configures integrations with Olympus staking, Cooler V2, and vault strategy.
     *
     * @param kernel The Olympus Kernel instance for policy management
     * @param p Initialization parameters containing:
     *          - asset: OHM token address (must have 9 decimals)
     *          - olympusStaking: Olympus staking contract for OHM<->gOHM conversion
     *          - olympusCooler: Olympus Cooler V2 contract for collateralized borrowing
     *          - strategy: Vault strategy contract for yield generation
     *          - debtConverterToWad: Converter for debt token to wad format
     *          - minDeposit: Minimum deposit amount (must be >= cooler's minDebtRequired)
     *
     * Requirements:
     * - All addresses must be non-zero
     * - Asset must be OHM with 9 decimals
     * - Strategy must accept the same debt token as Cooler V2
     * - minDeposit must meet minimum bounds for consistent mint/redeem operations
     */
    constructor(Kernel kernel, InitialParameters memory p)
        Policy(kernel)
        ERC20("Callisto OHM", "cOHM")
        ERC20Permit("Callisto OHM")
        ERC4626(IERC20(p.asset))
    {
        _requireNonzeroAddress(address(kernel));
        require(IERC20Metadata(p.asset).decimals() == 9, OHMExpected());
        _requireNonzeroAddress(p.olympusStaking);
        _requireNonzeroAddress(p.olympusCooler);
        _requireNonzeroAddress(p.strategy);
        _requireNonzeroAddress(p.debtConverterToWad);

        // we need to bound minimum to big enough amount to prevent mint/redeem big inconsistencies
        _setMinDeposit(p.minDeposit);

        OLYMPUS_COOLER = IMonoCooler(p.olympusCooler);
        IERC20 debtToken_ = OLYMPUS_COOLER.treasuryBorrower().debtToken();
        address debtTokenAddr = address(debtToken_);
        STRATEGY = VaultStrategy(p.strategy);
        require(address(STRATEGY.asset()) == debtTokenAddr, DebtTokenExpected(debtTokenAddr));

        GOHM = IGOHM(address(OLYMPUS_COOLER.collateralToken()));
        _GOHM_PRECISION = uint128(10 ** GOHM.decimals());
        OLYMPUS_STAKING = IOlympusStaking(p.olympusStaking);
        debtTokenMigrator = address(0);
        _updateDebtTokenConfiguration(debtTokenAddr, p.debtConverterToWad);
        _setOHMExchangeMode(ICallistoVault.OHMToGOHMMode.ZeroWarmup, address(0));

        // Sets the permanent allowance of the vault strategy over this vault's debt tokens borrowed from
        // Olympus Cooler V2.
        // slither-disable-next-line unused-return
        debtToken_.approve(p.strategy, type(uint256).max);
    }

    /**
     * @notice Configures dependencies on Olympus kernel modules.
     * @dev Sets up connections to ROLES and TRSRY modules with version validation.
     *      This function is called by the kernel during policy installation.
     *
     * @return dependencies Array of module keycodes this policy depends on
     *
     * Requirements:
     * - Only callable by the kernel
     * - ROLES module must be version 1.x
     * - TRSRY module must be version 1.x
     */
    function configureDependencies() external override onlyKernel returns (Keycode[] memory) {
        Keycode[] memory dependencies = new Keycode[](2);
        dependencies[0] = Keycode.wrap(0x524f4c4553); // toKeycode("ROLES");
        dependencies[1] = Keycode.wrap(0x5452535259); // toKeycode("TRSRY");

        ROLESv1 roles = ROLESv1(getModuleAddress(dependencies[0]));
        address treasury = getModuleAddress(dependencies[1]);

        // Check the module versions. Modules should be sorted in alphabetical order.
        (uint8 major,) = roles.VERSION();
        if (major != 1) revert Policy_WrongModuleVersion(abi.encode([1, 1]));
        (major,) = TRSRYv1(treasury).VERSION();
        if (major != 1) revert Policy_WrongModuleVersion(abi.encode([1, 1]));

        (ROLES, TRSRY) = (roles, treasury);

        return dependencies;
    }

    /**
     * @notice Returns the permissions this policy requires from kernel modules.
     * @dev Currently returns empty array as this policy doesn't require specific module permissions.
     * @return Empty permissions array
     */
    function requestPermissions() external pure override returns (Permissions[] memory) { }

    /// @inheritdoc ICallistoVault
    function execute() external override(ICallistoVault, IExecutableByHeart) onlyRole(HEART_ROLE) {
        uint256 ohmAmount = pendingOHMDeposits;
        if (ohmAmount == 0) return;
        ICallistoVault.OHMToGOHMMode mode = ohmToGOHMMode;
        if (mode == ICallistoVault.OHMToGOHMMode.ZeroWarmup) {
            _processPendingDepositsZeroWarmup(ohmAmount);
        }
    }

    /// @inheritdoc ICallistoVault
    function applyDelegations(IDLGTEv1.DelegationRequest[] calldata requests)
        external
        override
        returns (uint256 totalDelegated, uint256 totalUndelegated, uint256 undelegatedBalance)
    {
        ROLESv1 roles = ROLES;
        require(
            roles.hasRole(msg.sender, CDP_ROLE) || roles.hasRole(msg.sender, CommonRoles.ADMIN),
            CommonRoles.Unauthorized(msg.sender)
        );
        return OLYMPUS_COOLER.applyDelegations({ delegationRequests: requests, onBehalfOf: address(this) });
    }

    /// @inheritdoc ICallistoVault
    function sweepProfit(uint256 amount) external override nonzeroValue(amount) onlyAdminOrManager {
        uint256 totalProfit_ = totalProfit();

        if (amount == type(uint256).max) amount = totalProfit_;
        else if (amount > totalProfit_) revert ProfitWithdrawalExceedsTotalProfit(totalProfit_);

        STRATEGY.divest(amount, address(this));
        debtToken.safeTransfer(TRSRY, amount);
        emit TreasuryProfitWithdrawn(amount);
    }

    /// @inheritdoc ICallistoVault
    function withdrawExcessGOHM(uint256 gOHMAmount, address to) external override onlyAdminOrManager {
        // Calculate and require excess GOHM.
        uint256 excessGOHM_ = excessGOHM();
        require(excessGOHM_ != 0, NoExcessGOHM());
        if (gOHMAmount > excessGOHM_) revert NotEnoughGOHM(gOHMAmount - excessGOHM_);

        // Calculate the debt amount required to repay a debt in `OLYMPUS_COOLER` to withdraw `gOHMAmount`.
        (uint128 wadDebtToRepay, uint256 debtToRepay) = _calcDebtToRepay(gOHMAmount);

        if (debtToRepay != 0) {
            /* If `_processPendingDeposits` is called before this function, then the borrowed amount in
             * Olympus Cooler V2 is maximized.
             * In this case, `debtToRepay` should be repaid to withdraw excess gOHM.
             */

            // Withdraw `debtToRepay` from the strategy.
            STRATEGY.divest(debtToRepay, address(this)); // Reverts, if not enough debt tokens are available.

            // Repay the debt in Olympus Cooler V2 to withdraw gOHM.
            // slither-disable-next-line unused-return
            debtToken.approve(address(OLYMPUS_COOLER), debtToRepay);
            // slither-disable-next-line unused-return
            OLYMPUS_COOLER.repay({ repayAmountInWad: wadDebtToRepay, onBehalfOf: address(this) });
        }

        // Withdraw excess gOHM from Olympus Cooler V2.
        // slither-disable-next-line unused-return
        OLYMPUS_COOLER.withdrawCollateral({
            collateralAmount: gOHMAmount.toUint128(),
            onBehalfOf: address(this),
            recipient: to,
            delegationRequests: new IDLGTEv1.DelegationRequest[](0)
        });
        emit GOHMExcessWithdrawn(to, gOHMAmount);
    }

    /// @inheritdoc ICallistoVault
    function cancelOHMStake() external override onlyAdminOrManager {
        uint256 stakedAmount = pendingOHMWarmupStaking;
        require(stakedAmount != 0, ZeroValue());
        _deletePendingOHMWarmupStaking(stakedAmount);
        uint256 ohmAmount = OLYMPUS_STAKING.forfeit();
        pendingOHMDeposits += ohmAmount;
        emit PendingOHMDepositsChanged(int256(ohmAmount), pendingOHMDeposits);
        emit OHMStakeCancelled(ohmAmount);
    }

    /// @inheritdoc ICallistoVault
    function sweepTokens(address token, address to, uint256 value) external override onlyAdminOrManager {
        if (token == asset()) {
            IERC20 tokenContract = IERC20(token);
            uint256 available = tokenContract.balanceOf(address(this)) - pendingOHMDeposits;
            uint256 transferAmount = Math.min(available, value);
            if (transferAmount > 0) tokenContract.safeTransfer(to, transferAmount);
        } else {
            IERC20(token).safeTransfer(to, value);
        }
    }

    /// @inheritdoc ICallistoVault
    function setDepositsPause(bool pause) external override onlyAdminOrManager {
        require(depositPaused != pause, PauseStatusUnchanged());
        depositPaused = pause;
        emit DepositPauseStatusChanged(pause);
    }

    /// @inheritdoc ICallistoVault
    function setWithdrawalsPause(bool pause) external override onlyAdminOrManager {
        require(withdrawalPaused != pause, PauseStatusUnchanged());
        withdrawalPaused = pause;
        emit WithdrawalPauseStatusChanged(pause);
    }

    function _setMinDeposit(uint256 minOhmAmount) internal {
        // we need to bound minimum to big enough amount to prevent mint/redeem big inconsistencies
        require(
            minOhmAmount >= CallistoConstants.MIN_OHM_DEPOSIT_BOUND,
            AmountLessThanMinDeposit(minOhmAmount, CallistoConstants.MIN_OHM_DEPOSIT_BOUND)
        );
        minDeposit = minOhmAmount;
        emit MinDepositSet(minOhmAmount);
    }

    /// @inheritdoc ICallistoVault
    function setMinDeposit(uint256 minOhmAmount) external override onlyAdminOrManager {
        _setMinDeposit(minOhmAmount);
    }

    /// @notice Sets the debt token migrator address.
    /// @param newMigrator The new debt token migrator address (can be address(0) to disable migrations)
    function setDebtTokenMigrator(address newMigrator) external onlyRole(CommonRoles.ADMIN) {
        if (newMigrator != address(0)) {
            require(
                address(DebtTokenMigrator(newMigrator).OLYMPUS_COOLER()) == address(OLYMPUS_COOLER),
                MismatchedCoolerAddress()
            );
        }
        address oldMigrator = debtTokenMigrator;
        debtTokenMigrator = newMigrator;
        emit DebtTokenMigratorSet(oldMigrator, newMigrator);
    }

    function _requireNonzeroAddress(address a) private pure {
        require(a != address(0), ZeroAddress());
    }

    function _requireModeChange(ICallistoVault.OHMToGOHMMode newMode) private view {
        require(newMode != ohmToGOHMMode, OHMToGOHMModeUnchanged());
    }

    function _requireNoPendingWarmupStaking() private view {
        require(pendingOHMWarmupStaking == 0, PendingWarmupStakingExists());
    }

    function _requireZeroWarmupPeriod() private view {
        uint256 period = OLYMPUS_STAKING.warmupPeriod();
        require(period == 0, InvalidWarmupPeriod(period));
    }

    function _requireNonZeroWarmupPeriod() private view {
        uint256 period = OLYMPUS_STAKING.warmupPeriod();
        require(period != 0, InvalidWarmupPeriod(period));
    }

    function _setOHMExchangeMode(ICallistoVault.OHMToGOHMMode mode, address swapper) internal {
        ohmToGOHMMode = mode;
        ohmSwapper = IOHMSwapper(swapper);
        emit OHMExchangeModeSet(mode, swapper);
    }

    /// @inheritdoc ICallistoVault
    function setZeroWarmupMode() external override onlyRole(CommonRoles.ADMIN) {
        _requireModeChange(ICallistoVault.OHMToGOHMMode.ZeroWarmup);
        _requireZeroWarmupPeriod();
        _requireNoPendingWarmupStaking();
        _setOHMExchangeMode(ICallistoVault.OHMToGOHMMode.ZeroWarmup, address(0));
    }

    /// @inheritdoc ICallistoVault
    function setActiveWarmupMode() external override onlyRole(CommonRoles.ADMIN) {
        _requireModeChange(ICallistoVault.OHMToGOHMMode.ActiveWarmup);
        _requireNonZeroWarmupPeriod();
        _setOHMExchangeMode(ICallistoVault.OHMToGOHMMode.ActiveWarmup, address(0));
    }

    /// @inheritdoc ICallistoVault
    function setSwapMode(address swapper) external override onlyRole(CommonRoles.ADMIN) {
        _requireNonzeroAddress(swapper);
        require(
            ICallistoVault.OHMToGOHMMode.Swap != ohmToGOHMMode || swapper != address(ohmSwapper),
            OHMToGOHMModeUnchanged()
        );
        _requireNonZeroWarmupPeriod();
        _requireNoPendingWarmupStaking();
        _setOHMExchangeMode(ICallistoVault.OHMToGOHMMode.Swap, swapper);
    }

    // Note. The asset-to-share ratio is 1-to-1. The asset has 9 decimals, shares have 18 decimals.

    /// @inheritdoc ICallistoVault
    function deposit(uint256 assets, address receiver) public override(ERC4626, ICallistoVault) returns (uint256) {
        uint256 shares = previewDeposit(assets);
        _deposit(msg.sender, receiver, assets, shares);
        return shares;
    }

    /// @inheritdoc ICallistoVault
    function mint(uint256 shares, address receiver) public override(ERC4626, ICallistoVault) returns (uint256) {
        uint256 assets = previewMint(shares);
        _deposit(msg.sender, receiver, assets, shares);
        return assets;
    }

    /// @inheritdoc ICallistoVault
    function withdraw(uint256 assets, address receiver, address owner)
        public
        override(ERC4626, ICallistoVault)
        nonReentrant
        returns (uint256)
    {
        uint256 maxWithdraw = maxWithdraw(owner);
        if (assets > maxWithdraw) revert ERC4626ExceededMaxWithdraw(owner, assets, maxWithdraw);
        uint256 shares = previewWithdraw(assets);
        _withdraw(msg.sender, receiver, owner, assets, shares);
        return shares;
    }

    /// @inheritdoc ICallistoVault
    function redeem(uint256 shares, address receiver, address owner)
        public
        override(ERC4626, ICallistoVault)
        nonReentrant
        returns (uint256)
    {
        uint256 maxRedeem = maxRedeem(owner);
        if (shares > maxRedeem) revert ERC4626ExceededMaxRedeem(owner, shares, maxRedeem);
        uint256 assets = previewRedeem(shares);
        require(assets != 0, ZeroOHM()); // Check for rounding error since we round down in `previewRedeem`.
        _withdraw(msg.sender, receiver, owner, assets, shares);
        return assets;
    }

    /// @inheritdoc ICallistoVault
    function emergencyRedeem(uint256 shares)
        external
        override
        whenWithdrawalNotPaused
        nonzeroValue(shares)
        returns (uint256 debtAmount)
    {
        uint256 debtTokensDeposited = STRATEGY.totalAssetsInvested();
        if (_isVaultPositionLiquidated(debtTokensDeposited)) {
            /* In an emergency where the vault's position has been liquidated in Olympus Cooler V2 and there are
             * funds in the strategy.
             */
            // Amount to redeem = cOHM amount * Total funds in the strategy / Total cOHM.
            debtAmount = Math.mulDiv(shares, debtTokensDeposited, totalSupply());
            _burn(msg.sender, shares);
            STRATEGY.divest(debtAmount, msg.sender);
            emit EmergencyRedeemed(msg.sender, debtAmount);
        }
        return debtAmount;
    }

    /* Deposits `assets` of OHM into the vault, minting corresponding amount of cOHM (shares).
     *
     * The deposited OHM is added to `pendingOHMDeposits` and awaits processing by the keeper
     * through periodic calls to `_processPendingDeposits()`.
     */
    function _deposit(address caller, address receiver, uint256 assets, uint256 shares) internal override {
        require(!depositPaused, DepositsPaused());
        require(assets >= minDeposit, AmountLessThanMinDeposit(assets, minDeposit));
        // Transfers `assets` of OHM from `msg.sender` and mints `shares` of cOHM to `receiver`.
        _totalAssets += assets;
        pendingOHMDeposits += assets;
        emit PendingOHMDepositsChanged(int256(assets), pendingOHMDeposits);
        super._deposit(caller, receiver, assets, shares);
    }

    /* Withdraws `assets` worth of OHM from the vault to `receiver`, burning the equivalent amount of cOHM (shares)
     * from `owner`.
     *
     * Withdrawal Process
     *
     * 0. Direct OHM Withdrawal
     * - If sufficient OHM exists in `pendingOHMDeposits`, transfer directly to `receiver`
     * - If vault position is liquidated in Olympus Cooler V2, transfer remaining OHM balance
     *
     * Otherwise, the withdrawal process consists of the following steps:
     * 1. Calculate the amounts needed for the withdrawal:
     *    - The lacking OHM amount.
     *    - The gOHM amount required to obtain the lacking OHM.
     *    - The amount of `debtToken` to be repaid to obtain the required gOHM.
     * 2. Withdraw the required amount of `debtToken` from the strategy if available.
     *    If not enough debt tokens are in the strategy, attempt to transfer the lacking debt tokens from
     *    the caller. In this case, the caller can redeem the amount using `claimReimbursement` when
     *    enough debt tokens are available in the strategy.
     * 3. Repay the debt and withdraw gOHM from Olympus Cooler Loans V2.
     * 4. Unwrap gOHM to OHM using Olympus Staking.
     * 5. Transfer OHM to `receiver` and burn cOHM from `owner`.
     *
     * Yield generated by the strategy is first used to repay debt in Olympus Cooler Loans V2.
     * Any excess yield may be swept to the protocol treasury via `_sweepProfit`, which is expected to be
     * called by the Callisto keeper or governance.
     *
     * Warning. The last depositor should withdraw an amount such that at least `minDeposit` is left
     * in the vault, otherwise the function reverts due to the minimum debt requirement in `OLYMPUS_COOLER`.
     * For the same reason, if there are a number of last cOHM holders who have about `minDeposit` in total,
     * they cannot withdraw. (This can occur if cOHM are received through direct transfers).
     */
    function _withdraw(address caller, address receiver, address owner, uint256 assets, uint256 shares)
        internal
        override
        whenWithdrawalNotPaused
        nonzeroValue(assets)
    {
        _totalAssets -= assets;

        // 0.1 Check if sufficient OHM exists in pending deposits for direct withdrawal
        // This avoids the complex strategy withdrawal and debt repayment process
        uint256 ohmBalance = pendingOHMDeposits;
        if (assets <= ohmBalance) {
            uint256 newPending = FixedPointMathLib.rawSub(ohmBalance, assets);
            pendingOHMDeposits = newPending;
            emit PendingOHMDepositsChanged(-int256(assets), newPending);
            // Transfers `assets` of OHM to `receiver` and burns `shares` of cOHM from `owner`.
            super._withdraw(caller, receiver, owner, assets, shares);
            return;
        }

        // Insufficient OHM in pending deposits - must obtain lacking amount via strategy withdrawal
        // and debt repayment process

        // Reset pending OHM, because the entire amount is involved in the withdrawal process.
        emit PendingOHMDepositsChanged(-int256(ohmBalance), 0);
        delete pendingOHMDeposits;

        // Get the total gOHM amount available in Olympus Cooler V2.
        uint256 totalCollateral = uint256(OLYMPUS_COOLER.accountCollateral(address(this)));

        // 0.2: Handle emergency liquidation scenario
        // If vault position is liquidated (`totalCollateral` == 0), transfer remaining OHM directly
        // Note: Users should call `repayCoolerDebt` before liquidation to prevent this situation
        // For liquidated positions with strategy funds, use `emergencyRedeem` instead
        if (totalCollateral == 0) {
            // Transfers `assets` of OHM to `receiver` and burns `shares` of cOHM from `owner`.
            super._withdraw(caller, receiver, owner, assets, shares);
            return;
        }

        // 1. Calculate the amount needed for the withdrawal request:
        // 1.1. Lacking OHM amount after using pending deposits.
        // 1.2. gOHM amount needed to obtain `lackingOHM`.
        // 1.3. Debt token amount to repay for gOHM withdrawal.
        // Also handle insufficient amounts at each step.
        // 1. 1. Calculate the lacking amount of OHM required to cover the withdrawal request.
        uint256 lackingOHM = FixedPointMathLib.rawSub(assets, ohmBalance);

        // 1. 2. Calculate the gOHM amount required to obtain `lackingOHM`.
        uint256 gOHMAmountRequired = _convertOHMToGOHM(lackingOHM);

        // Determine how much gOHM to withdraw from Olympus Cooler V2, and handle the case where rounding leaves a
        // shortfall.
        uint256 gOHMAmountToWithdraw;
        if (gOHMAmountRequired <= totalCollateral) {
            // Enough gOHM is available in Olympus Cooler V2.
            gOHMAmountToWithdraw = gOHMAmountRequired;
        } else {
            /* If not enough gOHM in Olympus Cooler V2.
             *
             * This occurs for the last depositor because of rounding in the `GOHM` contract.
             * In this case, it is assumed to use the gOHM directly transferred to the vault.
             * If not enough gOHM in the vault, revert.
             */
            uint256 shortfall = FixedPointMathLib.rawSub(gOHMAmountRequired, totalCollateral);
            require(GOHM.balanceOf(address(this)) >= shortfall, NotEnoughGOHM(shortfall));
            gOHMAmountToWithdraw = totalCollateral;
        }

        /* 1. 3. Calculate the debt amount required to repay a debt in `OLYMPUS_COOLER` to withdraw
         * `gOHMAmountToWithdraw`.
         */
        (uint128 wadDebt, uint256 debtToRepay) = _calcDebtToRepay(gOHMAmountToWithdraw);

        /* 2. Withdraw the required amount of `debtToken` from the strategy to repay the debt.
         *
         * If an emergency case where not enough are available in the strategy, attempting to obtain
         * the lacking amount of `debtToken` from the caller, and record a reimbursement to be claimed by
         * the caller using `claimReimbursement` when there are enough funds in the strategy.
         * If a caller would not like to pay the lacking amount, then, alternatively, the caller can withdraw
         * the part, for which the available funds are sufficient instead of the entire amount.
         *
         * Note. This also occurs if the yield generated by the strategy is not enough to repay the debt in
         * Olympus Cooler Loans V2. For example, if the first depositor attempts to immediately withdraw
         * the entire initial deposit. So, the strategy has not time to accumulate yield.
         */
        IERC20 debtToken_ = debtToken;
        _withdrawStrategyOrCallerFunds(debtToRepay, debtToken_);

        // 3. Repay the debt in Olympus Cooler V2 to withdraw gOHM.
        if (debtToRepay != 0) {
            // slither-disable-next-line unused-return
            debtToken_.approve(address(OLYMPUS_COOLER), debtToRepay);
            // slither-disable-next-line unused-return
            OLYMPUS_COOLER.repay({ repayAmountInWad: wadDebt, onBehalfOf: address(this) });
        }
        // Withdraw gOHM (the collateral) from Olympus Cooler V2.
        // slither-disable-next-line unused-return
        OLYMPUS_COOLER.withdrawCollateral({
            collateralAmount: gOHMAmountToWithdraw.toUint128(),
            onBehalfOf: address(this),
            recipient: address(this),
            delegationRequests: new IDLGTEv1.DelegationRequest[](0)
        });

        // 4. Exchange gOHM for OHM. (Note. Olympus Staking does not have a warm-up period for OHM redemption).
        // slither-disable-next-line unused-return
        GOHM.approve(address(OLYMPUS_STAKING), gOHMAmountRequired);
        // slither-disable-next-line unused-return
        OLYMPUS_STAKING.unstake({ to: address(this), amount: gOHMAmountRequired, trigger: false, rebasing: false });

        // 5. Transfer `assets` of OHM to `receiver` and burn `shares` of cOHM from `owner`.
        super._withdraw(caller, receiver, owner, assets, shares);
    }

    /* Withdraws funds from the strategy (up to available), transfers the rest from the caller, and records
     * a reimbursement for the caller.
     */
    function _withdrawStrategyOrCallerFunds(uint256 debtToRepay, IERC20 debtToken_) private {
        // Get the total amount available in the strategy.
        uint256 strategyBalance = STRATEGY.totalAssetsAvailable();

        // If the strategy covers the entire debt, withdraw the required amount of `debtToken`.
        if (debtToRepay <= strategyBalance) {
            STRATEGY.divest(debtToRepay, address(this));
            return;
        }

        // Otherwise, the caller pays the difference, and a reimbursement is recorded for them.
        uint256 callerContribution = FixedPointMathLib.rawSub(debtToRepay, strategyBalance);
        debtToken_.safeTransferFrom(msg.sender, address(this), callerContribution);
        uint256 reimbursementClaim = debtConverterToWad.toWad(callerContribution);
        reimbursementClaims[msg.sender] += reimbursementClaim;
        emit ReimbursementClaimAdded(msg.sender, reimbursementClaim, callerContribution);
        totalReimbursementClaim += reimbursementClaim;

        // Withdraw the available amount of `debtToken` from the strategy.
        if (strategyBalance != 0) STRATEGY.divest(strategyBalance, address(this));
    }

    /**
     * @notice Converts OHM amount to equivalent gOHM amount using the current gOHM index.
     * @dev This function calculates the minimum gOHM needed to obtain at least `value` OHM when unstaking.
     *
     * The conversion formula is: gOHM = (OHM * 10^gOHM_decimals) / gOHM_index
     *
     * To ensure sufficient gOHM for the desired OHM amount, this function rounds UP when there's a remainder.
     * This prevents situations where rounding down would result in insufficient OHM after unstaking.
     *
     * Implementation notes:
     * - Uses integer division with remainder check instead of `mulDivUp()` for consistency with gOHM contract
     * - Matches the behavior of
     * [balanceTo()](https://github.com/OlympusDAO/olympus-contracts/blob/main/contracts/governance/gOHM.sol#L125)
     * function in the gOHM contract
     * - Prevents precision loss that could leave users with less OHM than expected
     *
     * @param ohmAmount The OHM amount (9 decimals) to convert to gOHM
     * @return gOHMAmount The equivalent gOHM amount (18 decimals), rounded up if necessary
     */
    function _convertOHMToGOHM(uint256 ohmAmount) internal view returns (uint256 gOHMAmount) {
        uint256 gOHMIndex = GOHM.index();
        // Calculate base gOHM amount: floor(value * 10^decimals / index)
        uint256 base = (ohmAmount * _GOHM_PRECISION) / gOHMIndex;
        // Check if there's a remainder: (value * 10^decimals) % index > 0
        bool hasRemainder = mulmod(ohmAmount, _GOHM_PRECISION, gOHMIndex) > 0;
        // Round up by adding 1 if there's a remainder to ensure sufficient gOHM
        return base + SafeCast.toUint(hasRemainder);
    }

    /// @inheritdoc ICallistoVault
    function repayCoolerDebt(uint256 amount) external override {
        // Calculate the amount required to repay a debt in `OLYMPUS_COOLER` to return to the origination LTV.
        (uint128 wadDebtToRepay, uint256 debtToRepay) = _calcDebtToRepay(0);
        if (debtToRepay == 0) return;

        if (amount != 0) {
            if (amount > debtToRepay) revert RepaymentAmountExceedsDebt(amount - debtToRepay);

            if (amount < debtToRepay) {
                debtToRepay = amount;
                wadDebtToRepay = debtConverterToWad.toWad(debtToRepay);
            }
        }

        /* Withdraw an available amount from the strategy to repay the debt. If the amount is not enough, then
         * transfer the rest from the caller and record a reimbursement for the caller.
         */
        IERC20 debtToken_ = debtToken;
        _withdrawStrategyOrCallerFunds(debtToRepay, debtToken_);

        // Repay the debt in Olympus Cooler V2 to return the position LTV to the origination LTV.
        // slither-disable-next-line unused-return
        debtToken_.approve(address(OLYMPUS_COOLER), debtToRepay);
        // slither-disable-next-line unused-return
        OLYMPUS_COOLER.repay({ repayAmountInWad: wadDebtToRepay, onBehalfOf: address(this) });
        emit CoolerDebtRepaid(msg.sender, debtToRepay);
    }

    /**
     * @notice Internal function to process reimbursement claims by transferring debt tokens and updating claims
     * @param account The account claiming reimbursement
     * @param debt The amount of debt tokens to transfer
     * @param cachedClaim The cache of claim amount
     */
    function _claimReimbursement(address account, uint256 debt, uint256 cachedClaim) private {
        uint256 strategyBalance = STRATEGY.totalAssetsAvailable();
        if (debt <= strategyBalance) {
            // If enough debt tokens in the strategy to reimburse.
            STRATEGY.divest(debt, account);
        } else {
            // If not enough debt tokens in the strategy.
            debtToken.safeTransfer(account, FixedPointMathLib.rawSub(debt, strategyBalance));
            if (strategyBalance != 0) STRATEGY.divest(strategyBalance, account);
        }

        // Convert amount to wad and subtract from reimbursement claims
        uint256 amountInWad = debtConverterToWad.toWad(debt);

        if (amountInWad >= cachedClaim) {
            // If the amount in wad is equal or greater than remaining claims, clear the claim
            reimbursementClaims[account] = 0;
            emit ReimbursementClaimRemoved(account, cachedClaim, debt);
            unchecked {
                totalReimbursementClaim -= cachedClaim;
            }
        } else {
            reimbursementClaims[account] -= amountInWad;
            emit ReimbursementClaimRemoved(account, amountInWad, debt);
            unchecked {
                totalReimbursementClaim -= amountInWad;
            }
        }
    }

    /// @inheritdoc ICallistoVault
    function claimReimbursement(address account) external override {
        uint256 cachedClaim = reimbursementClaims[account];
        (, uint256 debt) = _debtConverterFromWad.convertToDebtTokenAmount(cachedClaim);
        require(debt != 0, NoReimbursementFor(account));

        _claimReimbursement(account, debt, cachedClaim);
    }

    /// @inheritdoc ICallistoVault
    function claimReimbursementPartial(address account, uint256 partialAmount) external override {
        uint256 cachedClaim = reimbursementClaims[account];
        (, uint256 totalDebt) = _debtConverterFromWad.convertToDebtTokenAmount(cachedClaim);
        require(partialAmount <= totalDebt, PartialAmountExceedsAvailableClaim(partialAmount, totalDebt));

        _claimReimbursement(account, partialAmount, cachedClaim);
    }

    /// @inheritdoc ICallistoVault
    function calcDebtToRepay() external view override returns (uint128 wadDebt, uint256 debtAmount) {
        return _calcDebtToRepay(0);
    }

    // Returns the debt amount required to be repaid in `OLYMPUS_COOLER` to withdraw `gOHMAmount`.
    function _calcDebtToRepay(uint256 gOHMAmount) private view returns (uint128, uint256) {
        int128 debtDelta = OLYMPUS_COOLER.debtDeltaForMaxOriginationLtv({
            account: address(this),
            collateralDelta: -(gOHMAmount.toInt256().toInt128())
        });
        if (debtDelta >= 0) return (0, 0);
        uint128 wadDebt = uint128(-debtDelta);
        (, uint256 debt) = _debtConverterFromWad.convertToDebtTokenAmount(wadDebt);
        return (wadDebt, debt);
    }

    /// @inheritdoc ICallistoVault
    function totalProfit() public view override returns (uint256) {
        /* Total profit = Strategy funds - Vault's debt to Olympus Cooler V2 - Total reimbursment to users.
         * If the vault is liquidated, profit is 0.
         */
        uint256 totalDeposited = STRATEGY.totalAssetsInvested();
        uint256 totalReimbursement = totalReimbursementClaim;
        if (totalDeposited < totalReimbursement) return 0;
        if (_isVaultPositionLiquidated(totalDeposited)) return 0;

        (, uint256 debt) = _debtConverterFromWad.convertToDebtTokenAmount(OLYMPUS_COOLER.accountDebt(address(this)));
        unchecked {
            totalDeposited -= totalReimbursement;
        }
        return totalDeposited < debt ? 0 : FixedPointMathLib.rawSub(totalDeposited, debt);
    }

    /// @inheritdoc ICallistoVault
    function excessGOHM() public view override returns (uint256) {
        uint256 gOHMIndex = GOHM.index();
        /* Total OHM that can be obtained for all available GOHM = gOHM.balanceFrom( Total GOHM ).
         *
         * Not use `gOHM.balanceFrom()` to optimize gas.
         */
        uint256 collateral = OLYMPUS_COOLER.accountCollateral(address(this));
        uint256 ohmAvailable = collateral * gOHMIndex / _GOHM_PRECISION;
        uint256 ohmRequired = totalAssets();
        if (ohmAvailable <= ohmRequired) return 0;

        // Convert the excess OHM amount back to gOHM to determine how much gOHM can be withdrawn.
        // This is equivalent to gOHM.balanceTo(ohmAvailable - ohmRequired) but optimized for gas.
        // Formula: excessOHM * gOHMPrecision / gOHMIndex
        // Reference: https://github.com/OlympusDAO/olympus-contracts/blob/main/contracts/governance/gOHM.sol#L125
        uint256 excessOHM = FixedPointMathLib.rawSub(ohmAvailable, ohmRequired);
        return excessOHM * _GOHM_PRECISION / gOHMIndex;
    }

    // Returns `true` in an emergency where the vault's position has been liquidated in Olympus Cooler Loans V2.
    function _isVaultPositionLiquidated(uint256 totalDeposited) private view returns (bool) {
        /* The condition `totalDeposited > 1` is used instead of `!= 0` because, in an extremely rare case,
         * 1 token unit may remain on the strategy's balance after withdrawing all OHM deposits.
         * When migrating to a debt token with lower decimals, the division rounds up to ensure
         * the Callisto vault receives exactly enough tokens to cover its debt.
         * See `DebtTokenMigrator.migrateDebtToken()` for details.
         * Any remaining token unit after withdrawing all deposits is considered as an empty balance.
         * The minimum debt requirement of Olympus Cooler Loans V2 should prevent passing this condition when
         * not liquidated.
         */
        return totalDeposited > 1 && OLYMPUS_COOLER.accountCollateral(address(this)) == 0;
    }

    function _validateAndUpdatePendingDeposits(uint256 ohmAmount) private {
        uint256 pendingOHM = pendingOHMDeposits;
        require(ohmAmount <= pendingOHM, AmountGreaterThanPendingOHMDeposits(ohmAmount, pendingOHM));

        unchecked {
            pendingOHM -= ohmAmount;
        }
        pendingOHMDeposits = pendingOHM;
        emit PendingOHMDepositsChanged(-int256(ohmAmount), pendingOHM);
    }

    /// @inheritdoc ICallistoVault
    function processPendingDeposits(uint256 ohmAmount, bytes[] calldata swapperData)
        external
        override
        nonzeroValue(ohmAmount)
    {
        _processPendingDeposits(ohmAmount, ohmToGOHMMode, swapperData);
    }

    /* Processes OHM deposits by depositing `ohmAmount` of OHM to Olympus Cooler Loans V2 obtaining `debtToken` and then
     * depositing them into the strategy.
     *
     * This process consists of the following steps:
    * 1. Exchanging OHM for gOHM using Olympus Staking or another approach (see `OHMToGOHMMode` for more details).
     * 2. Borrowing `debtToken` for gOHM using Olympus Cooler Loans V2.
     * 3. Depositing `debtToken` into the strategy.
     */
    function _processPendingDeposits(
        uint256 ohmAmount,
        ICallistoVault.OHMToGOHMMode exchangeMode,
        bytes[] calldata swapperData
    ) private {
        // 1. Exchange OHM for gOHM.
        if (exchangeMode == ICallistoVault.OHMToGOHMMode.ZeroWarmup) {
            _processPendingDepositsZeroWarmup(ohmAmount);
        } else if (exchangeMode == ICallistoVault.OHMToGOHMMode.Swap) {
            // If obtaining gOHM using `ohmSwapper` because of the non-zero warm-up period in `OLYMPUS_STAKING`.
            _validateAndUpdatePendingDeposits(ohmAmount);

            IOHMSwapper swapper = ohmSwapper;
            // slither-disable-next-line unused-return
            IERC20(asset()).approve(address(swapper), ohmAmount);
            uint256 gOHMAmount = swapper.swap(ohmAmount, swapperData);
            _handleDepositsToStrategy(gOHMAmount, ohmAmount);
        } else {
            // If `exchangeMode == OHMToGOHMMode.ActiveWarmup`.
            uint256 stakedAmount = pendingOHMWarmupStaking;
            if (stakedAmount == 0) {
                _validateAndUpdatePendingDeposits(ohmAmount);
                pendingOHMWarmupStaking += ohmAmount;
                emit PendingOHMWarmupStakingChanged(int256(ohmAmount));
                // slither-disable-next-line unused-return
                IERC20(asset()).approve(address(OLYMPUS_STAKING), ohmAmount);
                // slither-disable-next-line unused-return
                OLYMPUS_STAKING.stake({ to: address(this), amount: ohmAmount, rebasing: false, claim: false });
                // `_processPendingDeposits` should be called again after the warm-up period has elapsed.
            } else {
                _deletePendingOHMWarmupStaking(stakedAmount);
                uint256 gOHMAmount = OLYMPUS_STAKING.claim({ to: address(this), rebasing: false });
                require(gOHMAmount != 0, ZeroValue());
                _handleDepositsToStrategy(gOHMAmount, stakedAmount);
            }
        }
    }

    function _processPendingDepositsZeroWarmup(uint256 ohmAmount) private {
        _validateAndUpdatePendingDeposits(ohmAmount);

        _requireZeroWarmupPeriod();

        // Deposit `ohmAmount` of pending OHM (assets) to `OLYMPUS_STAKING` to get gOHM.
        // slither-disable-next-line unused-return
        IERC20(asset()).approve(address(OLYMPUS_STAKING), ohmAmount);
        uint256 gOHMAmount =
            OLYMPUS_STAKING.stake({ to: address(this), amount: ohmAmount, rebasing: false, claim: true });
        _handleDepositsToStrategy(gOHMAmount, ohmAmount);
    }

    function _deletePendingOHMWarmupStaking(uint256 stakedAmount) private {
        delete pendingOHMWarmupStaking;
        emit PendingOHMWarmupStakingChanged(-int256(stakedAmount));
    }

    function _handleDepositsToStrategy(uint256 gOHMAmount, uint256 ohmAmount) private {
        // 2. Borrow `debtToken` from Olympus Cooler Loans V2.
        // slither-disable-next-line unused-return
        GOHM.approve(address(OLYMPUS_COOLER), gOHMAmount);
        OLYMPUS_COOLER.addCollateral({
            collateralAmount: gOHMAmount.toUint128(),
            onBehalfOf: address(this),
            delegationRequests: new IDLGTEv1.DelegationRequest[](0)
        });
        // Returns `debtToken` amount (USDS) and STRATEGY owns them
        uint256 debtTokenAmount = OLYMPUS_COOLER.borrow({
            borrowAmountInWad: type(uint128).max, // Borrow up to `_globalStateRW().maxOriginationLtv` of Cooler V2.
            onBehalfOf: address(this),
            recipient: address(STRATEGY)
        });

        // 3. Trigger STRATEGY to invest borrowed `debtToken`.
        STRATEGY.invest(debtTokenAmount);

        emit DepositsHandled(ohmAmount);
    }

    /**
     * @dev Updates the debt token configuration and emits the corresponding event.
     * @param newDebtToken The address of the new debt token
     * @param newConverterToWadDebt The address of the new converter to wad debt
     */
    function _updateDebtTokenConfiguration(address newDebtToken, address newConverterToWadDebt) private {
        debtToken = IERC20(newDebtToken);
        ICoolerTreasuryBorrower newDebtConverterFromWad = OLYMPUS_COOLER.treasuryBorrower();
        _debtConverterFromWad = newDebtConverterFromWad;
        debtConverterToWad = IConverterToWadDebt(newConverterToWadDebt);

        emit DebtTokenUpdated(newDebtToken, address(newDebtConverterFromWad), address(newConverterToWadDebt));
    }

    function migrateDebtToken(address newDebtToken, address newConverterToWadDebt) external {
        address migrator = debtTokenMigrator;
        require(msg.sender == migrator, OnlyDebtTokenMigrator(migrator));
        require(newDebtToken == address(OLYMPUS_COOLER.treasuryBorrower().debtToken()), MismatchedDebtTokenAddress());

        // slither-disable-next-line unused-return
        debtToken.approve(address(STRATEGY), 0);
        _updateDebtTokenConfiguration(newDebtToken, newConverterToWadDebt);

        /* Set the permanent allowance of the vault strategy over this vault's debt tokens borrowed from
         * Olympus Cooler V2.
         */
        // slither-disable-next-line unused-return
        IERC20(newDebtToken).approve(address(STRATEGY), type(uint256).max);
    }

    /// @inheritdoc ICallistoVault
    function totalAssets() public view override(ERC4626, ICallistoVault) returns (uint256) {
        return _totalAssets;
    }

    function _convertToShares(uint256 assets, Math.Rounding) internal pure override returns (uint256) {
        return assets * _TO_18_DECIMALS_FACTOR;
    }

    function _convertToAssets(uint256 shares, Math.Rounding rounding) internal pure override returns (uint256) {
        if (rounding == Math.Rounding.Ceil || rounding == Math.Rounding.Expand) {
            return shares.ceilDiv(_TO_18_DECIMALS_FACTOR);
        }
        return shares / _TO_18_DECIMALS_FACTOR;
    }

    function _decimalsOffset() internal view virtual override returns (uint8) {
        return 9;
    }

    function decimals() public view virtual override(ERC20, ERC4626) returns (uint8) {
        return ERC4626.decimals();
    }
}
