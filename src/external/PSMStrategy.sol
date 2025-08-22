// SPDX-License-Identifier: MIT

pragma solidity 0.8.30;

import { AccessControl } from "../../dependencies/@openzeppelin-contracts-5.3.0/access/AccessControl.sol";
import { IERC20, SafeERC20 } from "../../dependencies/@openzeppelin-contracts-5.3.0/token/ERC20/utils/SafeERC20.sol";
import { Pausable } from "../../dependencies/@openzeppelin-contracts-5.3.0/utils/Pausable.sol";
import { ReentrancyGuardTransient } from
    "../../dependencies/@openzeppelin-contracts-5.3.0/utils/ReentrancyGuardTransient.sol";
import { Math } from "../../dependencies/@openzeppelin-contracts-5.3.0/utils/math/Math.sol";
import { EnumerableSet } from "../../dependencies/@openzeppelin-contracts-5.3.0/utils/structs/EnumerableSet.sol";
import { Time } from "../../dependencies/@openzeppelin-contracts-5.3.0/utils/types/Time.sol";
import { FixedPointMathLib as FPMath } from "../../dependencies/solady-0.1.19/src/utils/FixedPointMathLib.sol";
import { ICOLLAR } from "../interfaces/ICOLLAR.sol";
import { IPSMStrategy } from "../interfaces/IPSMStrategy.sol";
import { IStabilityPool } from "../interfaces/IStabilityPool.sol";
import { Constants } from "../libraries/Constants.sol";
import { CallistoPSM } from "./CallistoPSM.sol";

/**
 * @title The PSM strategy
 * @author Callisto Protocol
 * @notice The coordination layer between the Peg Stability Module and Stability Pool.
 */
contract PSMStrategy is AccessControl, Pausable, ReentrancyGuardTransient, IPSMStrategy {
    using SafeERC20 for IERC20;
    using Math for uint256;
    using EnumerableSet for EnumerableSet.UintSet;

    // ========== STRUCTS ========== //

    /**
     * @notice Configuration for new auctions.
     * The fields:
     * 1. `startDiscount` is the discount utilized to calculate a start price. See `Auction` for details.
     *    `Constants.PERCENTAGE_PRECISION` is used as 100% (ex. `Constants.PERCENTAGE_PRECISION / 200` is 0.5%).
     *    A start price is calculated using the following formula:
     *        Start price = Current collateral market price * (100% - Start discount) / 100%.
     * 2. `duration` is the auction duration in seconds.
     */
    struct AuctionConfig {
        uint128 startDiscount;
        uint32 duration;
    }

    struct AuctionParams {
        uint256 collateralAmount;
        uint256 startPrice; // Maximum price for the purchaser.
        uint256 endPrice; // Minimum price for the purchaser.
        uint32 duration;
    }

    // ========== CONSTANTS & IMMUTABLES ========== //

    /// @dev Assumed to be the Callisto governance.
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");

    /// @dev Assumed to be the Callisto multisig.
    bytes32 public constant MANAGER_ROLE = keccak256("MANAGER_ROLE");

    /// @notice The stability pool of the Callisto CDP market.
    IStabilityPool public immutable STABILITY_POOL;

    // ========== STORAGE ========== //

    // ========== COLLAR DEPOSIT ========== //

    /// @notice The Callisto peg stability module.
    address public psm;

    /**
     * @notice The total amount of COLLAR deposited into the SP.
     *
     * @dev Used to compute how much of the strategy's SP deposit was consumed by liquidations before
     * adding a new auction via `addAuction`.
     * The formula: COLLAR value of collateral obtained from liquidation =
     *                  `collarInSP` - current compounded deposit.
     * The compounded deposit is the current SP deposit after liquidation-driven reductions.
     * The SP uses depositors' COLLAR to offset borrower debt and returns collateral with a premium for those
     * deposit losses.
     */
    uint256 public collarInSP;

    /**
     * @notice The total amount of COLLAR deposited by the PSM into this strategy.
     *
     * @dev It is only updated when the PSM deposits or withdraws COLLAR from this strategy.
     */
    uint256 public collarFromPSM;

    // ========== ASSETS ========== //

    /**
     * @notice The array of assets.
     * The `_spAssets[0]` is `COLLAR`. The SP accrues interest in COLLAR for its depositors.
     * All other assets of `_spAssets` are collateral assets for which gains are claimed and auctions are created.
     * @dev It should match the asset array of the stability pool.
     */
    address[] private _spAssets;

    /**
     * @dev Position is the index of the address in the `_spAssets` array plus 1.
     * Position 0 is used to mean an address is not in the `_spAssets` array.
     */
    mapping(address spAsset => uint256) public spAssetPosition;

    // ========== AUCTION ========== //

    /**
     * @notice The amount of COLLAR consumed by liquidations in the SP, pending replenishment.
     *
     * @dev When liquidations occur in the CDP market, the SP uses depositors' COLLAR to offset debt and provides
     * collateral (with profit) in return for those deposit losses.
     */
    uint256 public collarPendingReplenishment;

    uint256 public collarDeficit;

    uint256 public nextAuctionID;

    /// @dev Auction configuration by `collateral`.
    mapping(address collateral => AuctionConfig) public newAuctionConfig;

    mapping(uint256 auctionID => Auction) private _auction;

    mapping(address collateral => EnumerableSet.UintSet auctionIDs) private _activeAuctions;

    /**
     * @notice Collateral collected from unsold auctions.
     * It is waiting to be re-auctioned with specified parameters using `addAuctionForUnsold`.
     * Unsold auctions increase `collarDeficit`, which should be reduced by re-auctioning unsold collateral and
     * `donateCOLLARToReduceDeficit`.
     */
    mapping(address collateral => uint256) public unsoldCollateral;

    mapping(address collateral => bool) public purchasePaused;

    // ========== TREASURY PROFIT FROM AUCTIONS ==========

    /// @notice The Callisto treasury for profit sweeping.
    address public treasury;

    /**
     * @notice Accumulated profit for `token` ready to be transferred to the Callisto treasury using `sweepProfit`.
     *
     * Profit can be transferred to the Callisto treasury using `sweepProfit`.
     *
     * Two kinds of profit:
     * 1. The SP accrues interest in COLLAR (`_spAssets[0]`) for its depositors.
     * 2. Collateral (`_spAssets[1...]`) gains from liquidations in the CDP market.
     */
    mapping(address spAsset => uint256) public treasuryProfit;

    // ========== EVENTS ========== //

    event Deposited(uint256 indexed deposited);

    event AuctionAdded(uint256 indexed auctionID);

    event ProfitSwept(address indexed token, uint256 indexed amount);

    event UnsoldAuctionClosed(
        uint256 indexed auctionID, uint256 indexed unsoldCollateral, uint256 indexed collarDeficit
    );

    event AuctionAddedForUnsold(uint256 indexed auctionID);

    event TooHighStartPrice(
        address indexed collateral,
        uint256 indexed collateralAmount,
        uint256 indexed depositPendingReplenishment,
        uint256 startPrice,
        uint256 endPrice
    );

    event AuctionClosedManually(uint256 indexed id, uint256 indexed remainingCollateral, uint256 indexed collarDeficit);

    event SPAssetAdded(address indexed token);

    event NewAuctionConfigSet(address indexed collateral);

    event TreasurySet(address indexed newTreasury);

    event PurchasePaused(address indexed caller, address indexed collateral);

    event PurchaseUnpaused(address indexed caller, address indexed collateral);

    event Migrated(address indexed oldStrategy, address indexed newStrategy);

    event COLLARBurnedInEmergency(uint256 indexed burned);

    // ========== ERRORS ========== //

    error AlreadyInitialized();

    error NoSPAssets();

    error SPAssetAlreadyAdded();

    error OnlyPSM(address caller, address psm);

    error OnlySP();

    error Unauthorized(address account);

    error ZeroDuration();

    error ZeroPrice();

    error ZeroMaxNumber();

    error ZeroProfit();

    error UnknownCollateral(address addr);

    error AmountGreaterThanSPDeposit(uint256 requested, uint256 available);

    error AmountGreaterThanDeficit(uint256 collarAmount, uint256 deficit);

    error NotEnoughUnsoldCollateral(uint256 requested, uint256 available);

    error StartPriceLessThanEnd(uint256 maximum, uint256 minimum);

    error TooHighDiscount(uint256 discount, uint256 maximum);

    error ActiveAuctionsExist(address collateral);

    // ========== MODIFIERS ========== //

    modifier nonzeroAmount(uint256 amount) {
        require(amount != 0, ZeroAmount());
        _;
    }

    modifier nonzeroAddress(address a) {
        require(a != address(0), ZeroAddress());
        _;
    }

    modifier nonzeroDuration(uint32 duration) {
        require(duration != 0, ZeroDuration());
        _;
    }

    modifier onlyPSM() {
        if (msg.sender != psm) revert OnlyPSM(msg.sender, psm);
        _;
    }

    modifier onlyAdminOrManager() {
        require(hasRole(MANAGER_ROLE, msg.sender) || hasRole(ADMIN_ROLE, msg.sender), Unauthorized(msg.sender));
        _;
    }

    // ========== INITIALIZATION & SETUP ========== //

    constructor(address defaultAdmin, address stabilityPool, address treasury_)
        nonzeroAddress(defaultAdmin)
        nonzeroAddress(stabilityPool)
    {
        _setTreasury(treasury_);

        _grantRole(DEFAULT_ADMIN_ROLE, defaultAdmin);

        IStabilityPool sp = IStabilityPool(stabilityPool);
        STABILITY_POOL = sp;

        // Add the current asset addresses from the SP.
        address[] memory spAssets = sp.getAssets();
        uint256 assetNum = spAssets.length;
        require(assetNum != 0, NoSPAssets());
        address[] storage rAssets = _spAssets;
        // The address is stored at length-1, but 1 is added to all indexes, because 0 is used as a sentinel value.
        uint256 assetPosition = rAssets.length + 1;
        address asset;
        for (uint256 i = 0; i < assetNum; ++i) {
            /* Ensured by the SP:
             * - require(asset != address(0), ZeroAddress());
             * - require(spAssetPosition[asset] == 0, SPAssetAlreadyAdded());
             */
            asset = spAssets[i];
            _addSPAsset(asset, assetPosition, rAssets);
            unchecked {
                ++assetPosition;
            }
        }

        // Pre-approve the SP for unlimited COLLAR transfers.
        IERC20(spAssets[0]).approve(stabilityPool, type(uint256).max);
    }

    function finalizeInitialization(address psm_) external onlyRole(ADMIN_ROLE) nonzeroAddress(psm_) {
        require(psm == address(0), AlreadyInitialized());
        psm = psm_;
    }

    // ========== AUCTION COLLATERAL PURCHASING ========== //

    /// @inheritdoc IPSMStrategy
    // TODO: test rounding issues between `collarPayment` and `collateralAmount`.
    function purchase(uint256 auctionID, uint256 collarPayment, address recipient, uint256 maxPrice)
        external
        nonzeroAmount(collarPayment)
        nonzeroAddress(recipient)
        nonReentrant
        returns (uint256, uint256)
    {
        Auction storage rAuction = _auction[auctionID];
        Auction memory a = rAuction; // Cache the auction.
        EnumerableSet.UintSet storage rActiveAuctions = _activeAuctions[a.collateral];

        // Validate that purchases for `collateral` are not paused and the auction is active.
        _validatePurchaseNotPaused(a.collateral);
        _validateActiveAuction(auctionID, rActiveAuctions);

        // Calculate and validate the current auction price (in units of COLLAR per `a.collateral` unit).
        uint256 collarPerCollateral = _calcCurrentPrice(a);
        if (maxPrice != 0) require(collarPerCollateral <= maxPrice, PriceGreaterThanMax(collarPerCollateral, maxPrice));

        // Handle the auction and update its state.
        address collar = _spAssets[0];
        (uint256 collateralAmount, uint256 collateralProfit, uint256 actualPayment, uint256 collarPaymentWoProfit) =
            _purchase(auctionID, collarPayment, recipient, collarPerCollateral, collar, a, rAuction, rActiveAuctions);

        _updateTreasuryCollateralProfit(a.collateral, collateralProfit);

        // Transfer COLLAR from the purchaser and collateral to the `recipient`, re-deposit COLLAR into the SP.
        _settleTransfersAndRedepositToSP(
            collar, collarPayment, collarPaymentWoProfit, a.collateral, collateralAmount, recipient
        );

        return (collateralAmount, actualPayment);
    }

    /// @inheritdoc IPSMStrategy
    // solhint-disable-next-line gas-calldata-parameters
    function purchaseBatch(
        uint256[] calldata auctionIDs,
        uint256[] memory collarPayments,
        address recipient,
        address collateral,
        uint256 maxPrice
    ) external nonzeroAddress(recipient) nonReentrant returns (uint256[] memory, uint256[] memory) {
        uint256 auctionNum = auctionIDs.length;
        require(auctionNum == collarPayments.length, ArrayLenMismatch(auctionNum, collarPayments.length));
        _validatePurchaseNotPaused(collateral);

        // Calculate and validate prices; handle auctions and update their states.
        address collar = _spAssets[0];
        EnumerableSet.UintSet storage rActiveAuctions = _activeAuctions[collateral];
        Auction storage rAuction;
        Auction memory a;
        uint256 price;
        uint256 collateralProfit;
        uint256 collarPaymentWoProfit;
        uint256[] memory collateralAmounts = new uint256[](auctionNum);
        uint256 totalCollateralAmount = 0;
        uint256 totalCollateralProfit = 0;
        uint256 totalCOLLARPayment = 0;
        uint256 totalCOLLARToSP = 0;
        for (uint256 i = 0; i < auctionNum; ++i) {
            require(collarPayments[i] != 0, ZeroAmount());
            _validateActiveAuction(auctionIDs[i], rActiveAuctions);
            rAuction = _auction[auctionIDs[i]];
            a = rAuction; // Cache the auction.
            require(a.collateral == collateral, CollateralMismatch(a.collateral, collateral));

            // Calculate and validate the current auction price (in units of COLLAR per `collateral` unit).
            price = _calcCurrentPrice(a);
            if (maxPrice != 0) require(price <= maxPrice, PriceGreaterThanMax(price, maxPrice));
            // Handle the auction and update its state.
            (collateralAmounts[i], collateralProfit, collarPayments[i], collarPaymentWoProfit) =
                _purchase(auctionIDs[i], collarPayments[i], recipient, price, collar, a, rAuction, rActiveAuctions);

            totalCollateralAmount += collateralAmounts[i];
            totalCollateralProfit += collateralProfit;
            totalCOLLARPayment += collarPayments[i];
            totalCOLLARToSP += collarPaymentWoProfit;
        }

        _updateTreasuryCollateralProfit(collateral, totalCollateralProfit);

        // Transfer COLLAR from the purchaser and collateral to the `recipient`, re-deposit COLLAR into the SP.
        _settleTransfersAndRedepositToSP(
            collar, totalCOLLARPayment, totalCOLLARToSP, collateral, totalCollateralAmount, recipient
        );

        return (collateralAmounts, collarPayments);
    }

    /* Handles the `auctionID` auction, updates its state and returns:
     * - The collateral amount obtained for the `collarPayment`.
     * - The collateral treasury profit to be recorded.
     * - The reduced `collarPayment` without profit to be deposited into the SP.
     */
    function _purchase(
        uint256 auctionID,
        uint256 collarPayment,
        address recipient,
        uint256 collarPerCollateral,
        address collar,
        Auction memory a,
        Auction storage rAuction,
        EnumerableSet.UintSet storage rActiveAuctions
    ) private returns (uint256 collateralAmount, uint256 collateralProfit, uint256, uint256 collarPaymentWoProfit) {
        collarPaymentWoProfit = collarPayment;
        if (a.target != 0) {
            // If the auction has the COLLAR `a.target`, i.e. it is created using `addAuction` and makes a profit.

            if (collarPayment != type(uint256).max) {
                a.raised += collarPayment;
                require(a.raised <= a.target, COLLARTargetOvershoot(a.target, a.raised));

                collateralAmount = _calcCollateralAmount(collarPayment, collarPerCollateral);

                if (a.raised != a.target) {
                    /* Profit = Maximum collateral expected to be spent for `collarPayment` - actual spent,
             * where maximum expected = `collarPayment` / minimum price for the purchaser.
             */
                    collateralProfit = _calcCollateralAmount(collarPayment, a.endPrice) - collateralAmount;

                    a.capacity -= collateralAmount + collateralProfit;
                } else {
                    collateralProfit = a.capacity - collateralAmount;
                    a.capacity = 0;
                    a.raised = a.target;
                }
            } else {
                /* If `collarPayment == type(uint256).max`, purchase all remaining collateral prior to
                 * the `COLLAR` target.
                 */

                collarPayment = _calcRemainingCOLLAR(a.target, a.raised);
                a.raised = a.target;

                collateralAmount = _calcCollateralAmount(collarPayment, collarPerCollateral);

                collateralProfit = a.capacity - collateralAmount;
                a.capacity = 0;
            }

            if (a.raised == a.target) _closeAuction(auctionID, rActiveAuctions);

            treasuryProfit[a.collateral] += collateralProfit;
        } else {
            /* If the auction has no COLLAR `a.target`, i.e. it is created using `addAuctionForUnsold` and aims to sell
             * the entire collateral capacity without making a profit.
             */

            if (collarPayment != type(uint256).max) {
                collateralAmount = _calcCollateralAmount(collarPayment, collarPerCollateral);
                require(collateralAmount <= a.capacity, NotEnoughCollateral(collateralAmount, a.capacity));
            } else {
                // If `collarPayment == type(uint256).max`, purchase all remaining collateral.

                collateralAmount = a.capacity;
                collarPayment =
                    collateralAmount.mulDiv(collarPerCollateral, Constants.ORACLE_PRICE_SCALE, Math.Rounding.Ceil);
            }

            a.raised += collarPayment;
            a.capacity -= collateralAmount;

            if (a.capacity == 0) _closeAuction(auctionID, rActiveAuctions);

            // collateralProfit = 0; // Default value.

            // Reduce the COLLAR deficit.
            uint256 deficit = collarDeficit;
            if (deficit >= collarPayment) {
                collarDeficit = FPMath.rawSub(deficit, collarPayment);
            } else {
                /* If someone reduced the COLLAR deficit so much by `donateCOLLARToReduceDeficit` that
                 * the auction for unsold collateral raised more COLLAR than there was in
                 * the deficit, then the excess is counted as profit.
                 */
                uint256 collarProfit = FPMath.rawSub(collarPayment, deficit);
                collarPaymentWoProfit = deficit;
                delete collarDeficit;
                treasuryProfit[collar] += collarProfit;
                emit ProfitFromAuctionForUnsold(auctionID, collarProfit);
            }
        }

        // Update the auction state.
        rAuction.raised = a.raised;
        rAuction.capacity = a.capacity;

        emit Purchased(auctionID, msg.sender, recipient, collateralAmount, collarPayment, collateralProfit);
        return (collateralAmount, collateralProfit, collarPayment, collarPaymentWoProfit);
    }

    function _closeAuction(uint256 id, EnumerableSet.UintSet storage rActiveAuctions) private {
        // slither-disable-next-line unused-return
        rActiveAuctions.remove(id);
        emit AuctionClosed(id);
    }

    function _updateTreasuryCollateralProfit(address collateral, uint256 profit) private {
        if (profit != 0) treasuryProfit[collateral] += profit;
    }

    function _settleTransfersAndRedepositToSP(
        address collar,
        uint256 collarPayment,
        uint256 collarToSP,
        address collateral,
        uint256 collateralAmount,
        address recipient
    ) private {
        // Reduce the amount of COLLAR pending replenishment in the SP.
        collarPendingReplenishment -= collarToSP;

        // Transfer COLLAR from the purchaser.
        IERC20(collar).safeTransferFrom(msg.sender, address(this), collarPayment);
        // Re-deposit obtained COLLAR into the SP.
        STABILITY_POOL.deposit(collarToSP);
        // Transfer the collateral to the `recipient`.
        IERC20(collateral).safeTransfer(recipient, collateralAmount);
    }

    function _validateActiveAuction(uint256 id, EnumerableSet.UintSet storage rActiveAuctions) private view {
        require(rActiveAuctions.contains(id), NotActiveAuction(id));
    }

    // ========== AUCTION PRICE CALCULATIONS ========== //

    /* Returns the current price with a linear decrease from Maximum price to Minimum price in the interval
     * [Start time, End time].
     *
     * Current price is denominated in units of COLLAR per unit of the collateral
     * (the same as `maxPrice` and `minPrice`).
     *
     * The formula:
     *     Current price = Maximum price - Price decay,
     * where
     *     Price decay = Delta * Elapsed / Duration,
     *     Delta       = Maximum price - Minimum price,
     *     Elapsed     = Current time  - Start time,
     *     Duration    = End time      - Start time.
     */
    function _calcCurrentPrice(Auction memory a) private view returns (uint256) {
        // Ensured by the preceding logic:
        // if (capacity == 0) return 0;
        // if (currentTime <= startTime) return maxPrice;

        uint48 currentTime = Time.timestamp();
        if (currentTime >= a.endTime) return a.endPrice;

        return a.startPrice - ((a.startPrice - a.endPrice) * (currentTime - a.startTime) / (a.endTime - a.startTime));
    }

    function _calcCollateralAmount(uint256 collarPayment, uint256 collarPerCollateral) private pure returns (uint256) {
        return collarPayment.mulDiv(Constants.ORACLE_PRICE_SCALE, collarPerCollateral);
    }

    // ========== AUCTION QUERY FUNCTIONS ========== //

    /// @inheritdoc IPSMStrategy
    function getAuctionStatus(uint256 id) external view returns (bool exists, bool active) {
        address collateral = _auction[id].collateral;
        exists = collateral != address(0);
        active = _activeAuctions[collateral].contains(id);
        return (exists, active);
    }

    /// @inheritdoc IPSMStrategy
    function getActiveAuctionDetails(uint256 id) external view returns (Auction memory, uint256) {
        Auction memory a = _auction[id];
        _validateActiveAuction(id, _activeAuctions[a.collateral]);

        return (a, _calcCurrentPrice(a));
    }

    /// @inheritdoc IPSMStrategy
    function getActiveAuctionIDs(address collateral) external view returns (uint256[] memory) {
        return _activeAuctions[collateral].values();
    }

    /// @inheritdoc IPSMStrategy
    function getActiveAuctionNum(address collateral) external view returns (uint256) {
        return _activeAuctions[collateral].length();
    }

    // ========== SP ASSET MANAGEMENT ========== //

    /**
     * @dev Adds the `asset` to the `_spAssets` used to claim gains from the Callisto SP and create auctions.
     * The `asset` is assumed to be an asset of the Callisto stability pool.
     * Warning. SP assets should be added in the same order as in the SP. Removal of SP assets is not envisaged.
     */
    function addSPAsset(address asset) external override nonzeroAddress(asset) {
        require(msg.sender == address(STABILITY_POOL) || hasRole(ADMIN_ROLE, msg.sender), Unauthorized(msg.sender));
        require(spAssetPosition[asset] == 0, SPAssetAlreadyAdded());

        address[] storage rAssets = _spAssets;
        // The address is stored at length-1, but 1 is added to all indexes, because 0 is used as a sentinel value.
        _addSPAsset(asset, rAssets.length + 1, rAssets);
    }

    function getSPAssets() external view returns (address[] memory) {
        return _spAssets;
    }

    function _addSPAsset(address asset, uint256 position, address[] storage rAssets) private {
        spAssetPosition[asset] = position;
        rAssets.push(asset);
        emit SPAssetAdded(asset);
    }

    function _validateExistingCollateral(address collateral) private view {
        // COLLAR is at position 1 and not a collateral.
        require(spAssetPosition[collateral] > 1, UnknownCollateral(collateral));
    }

    // ========== PSM COLLAR DEPOSIT & BURNING OPERATIONS ========== //

    /// @notice Deposits `amount` COLLAR from a PSM `swapIn` operation into the stability pool.
    function deposit(uint256 amount) external onlyPSM nonzeroAmount(amount) {
        /* Warning. `amount` of COLLAR is externally transferred by the PSM to this contract before calling this
         * function.
         */

        /* When increasing the deposit, it is re-calculated with the compounded deposit, but here `amount` is added
         * instead of replacing `collarInSP` with the current deposit, because it is used and properly
         * updated when launching new auctions.
         */
        collarInSP += amount;
        collarFromPSM += amount;

        // Deposit COLLAR into the SP. Pre-approved at the contract initialization.
        // slither-disable-next-line unused-return
        STABILITY_POOL.deposit(amount);
        emit Deposited(amount);
    }

    function burnCOLLAR(uint256 amount) external onlyPSM {
        // Ensured by the PSM: _requireNotExceedingSPDeposit(amount, sp);

        unchecked {
            // The PSM ensures that `amount <= spDeposit`.
            collarInSP -= amount;
            collarFromPSM -= amount;
        }

        STABILITY_POOL.withdraw(amount);
        ICOLLAR(_spAssets[0]).burn(address(this), amount);
    }

    /**
     * @notice Withdraws and burns `amount` of COLLAR from the SP in emergency.
     */
    function burnCOLLARInEmergency(uint256 amount) external onlyRole(ADMIN_ROLE) nonzeroAmount(amount) {
        IStabilityPool sp = STABILITY_POOL;
        uint256 spDeposit = sp.calcCompoundedDeposit(address(this));
        require(amount <= spDeposit, AmountGreaterThanSPDeposit(amount, spDeposit));

        collarInSP -= amount;
        collarFromPSM -= amount;
        sp.withdraw(amount);
        ICOLLAR(_spAssets[0]).burn(address(this), amount);
        emit COLLARBurnedInEmergency(amount);
    }

    function burnableCOLLAR() external view returns (uint256) {
        return STABILITY_POOL.calcCompoundedDeposit(address(this));
    }

    // ========== AUCTION CONFIGURATION ==========

    /**
     * @notice Sets the configuration for new `collateral` auctions to `c`.
     *
     * See the `AuctionConfig` comment for more details.
     */
    function setNewAuctionConfig(address collateral, AuctionConfig calldata c)
        external
        onlyAdminOrManager
        nonzeroDuration(c.duration)
    {
        _validateExistingCollateral(collateral);
        require(
            c.startDiscount <= Constants.PERCENTAGE_PRECISION,
            TooHighDiscount(c.startDiscount, Constants.PERCENTAGE_PRECISION)
        );

        newAuctionConfig[collateral] = c;
        emit NewAuctionConfigSet(collateral);
    }

    // ========== AUCTION LIFECYCLE MANAGEMENT ========== //

    /**
     * @dev Creates an auction of the `collateralAmount` using the current market price (`collarPerCollateral`),
     * updates the current SP deposit, and records the deposited COLLAR consumed by liquidation.
     *
     * `collateralAmount`, `collarPerCollateral` and `updatedSPDeposit` should use 18 decimals.
     *
     * It should only be called by the SP during liquidation after claiming the collateral gain for
     * the PSM strategy.
     */
    function addAuction(
        uint256 collateralPosition,
        uint256 collateralAmount,
        uint256 collarPerCollateral,
        uint256 updatedSPDeposit
    ) external override {
        require(msg.sender == address(STABILITY_POOL), OnlySP());

        if (paused()) return; // TODO: add to `unsoldCollateral`, emit an event.

        /* Should be ensured by the SP and the CDP market liquidation logic:
         * - require(collateralPosition != 0 && collateralPosition < _spAssets.length);
         * - require(collateralAmount != 0);
         * - require(updatedSPDeposit <= collarInSP);
         * - `collateralPosition` corresponds to `collateralAmount` transferred to this strategy by the SP.
        * - The COLLAR value of the `collateralAmount` is less than or equal to the `depositPendingReplenishment`.
         */

        // Calculate COLLAR consumed by the liquidation and update the SP deposit state.
        uint256 depositPendingReplenishment = collarInSP - updatedSPDeposit; // COLLAR consumed by the liquidation.
        collarPendingReplenishment += depositPendingReplenishment; // Track total COLLAR pending replenishment.
        collarInSP = updatedSPDeposit; // Reset `collarInSP` to the current deposit in the SP.

        // Calculate the discounted prices.
        address collateral = _spAssets[collateralPosition];
        AuctionConfig storage rConf = newAuctionConfig[collateral];
        /* Calculate the price at the auction start (the maximum price for purchasers).
         * The formula: Start price = Current `collateral` market price * (100% - Start discount) / 100%.
         */
        uint256 startPrice = collarPerCollateral.mulDiv(
            Constants.PERCENTAGE_PRECISION - rConf.startDiscount, Constants.PERCENTAGE_PRECISION, Math.Rounding.Ceil
        );
        // Calculate the price at the auction end (the minimum price for purchasers).
        uint256 endPrice =
            depositPendingReplenishment.mulDiv(Constants.ORACLE_PRICE_SCALE, collateralAmount, Math.Rounding.Ceil);

        if (startPrice < endPrice) {
            /* This is an emergency when:
             * - The `startPrice` calculated with the specified `startDiscount` relative to
              *   the `collateral` market price (`collarPerCollateral`) is less than the minimum price that
              *   would not lead to a COLLAR deficit for this auction.
             *   This may happen if the specified `startDiscount` is too large.
            * - The `depositPendingReplenishment` is greater than the COLLAR value of the `collateralAmount`
              *   (the collateral value is calculated in the CDP market and should be approximately equal to
              *     `collateralAmount` * `collarPerCollateral` / `Constants.ORACLE_PRICE_SCALE`).
             *
             * This function is called during each liquidation in the CDP market if the PSM strategy is set,
             * so it should not revert.
              * Therefore, the COLLAR deficit is increased by `depositPendingReplenishment`,
              * the `collateralAmount` is recorded to `unsoldCollateral`, and the event is emitted.
             *
              * Possible solution: update the auction configuration using `setNewAuctionConfig`, and
              * recreate the auction manually with `addAuctionForUnsold`.
             */
            collarDeficit += depositPendingReplenishment;
            unsoldCollateral[collateral] += collateralAmount;
            emit TooHighStartPrice(collateral, collateralAmount, depositPendingReplenishment, startPrice, endPrice);
            return;
        }

        // slither-disable-next-line unused-return
        _addAuction({
            collateral: collateral,
            collateralAmount: collateralAmount,
            collarTarget: depositPendingReplenishment,
            startPrice: startPrice,
            endPrice: endPrice,
            duration: rConf.duration
        });
    }

    /**
     * @notice Adds an auction for unsold `collateral` with specified parameters.
     * @param collateral The collateral address for which to create the auction
     * @param p The auction parameters
     * @dev The caller should have either the role `ADMIN_ROLE` or the role `MANAGER_ROLE`.
     *      All amounts and prices should use 18 decimals.
     */
    function addAuctionForUnsold(address collateral, AuctionParams calldata p)
        external
        onlyAdminOrManager
        nonzeroAmount(p.collateralAmount)
        nonzeroDuration(p.duration)
    {
        _validateExistingCollateral(collateral);
        require(p.startPrice >= p.endPrice, StartPriceLessThanEnd(p.startPrice, p.endPrice));
        require(p.endPrice != 0, ZeroPrice());
        uint256 unsold = unsoldCollateral[collateral];
        require(p.collateralAmount <= unsold, NotEnoughUnsoldCollateral(p.collateralAmount, unsold));

        uint256 auctionID = _addAuction({
            collateral: collateral,
            collateralAmount: p.collateralAmount,
            collarTarget: 0,
            startPrice: p.startPrice,
            endPrice: p.endPrice,
            duration: p.duration
        });
        // No underflow thanks to `p.collateralAmount <= unsold`.
        unsoldCollateral[collateral] = FPMath.rawSub(unsold, p.collateralAmount);
        emit AuctionAddedForUnsold(auctionID);
    }

    /**
     * @notice Closes expired auctions by removing them from the active set, adding remaining `collateral`
     * capacity to `unsoldCollateral`, and increasing `collarDeficit`.
     *
     * @param maxNum The maximum number of auctions to close. Used to bound gas usage.
     *
     * @dev The next step could be to add an auction for unsold collateral using `addAuctionForUnsold` and
     * reduce the COLLAR shortfall using `donateCOLLARToReduceDeficit`.
     */
    function closeUnsoldAuctions(address collateral, uint256 maxNum) external onlyAdminOrManager {
        require(maxNum != 0, ZeroMaxNumber());

        EnumerableSet.UintSet storage rActiveAuctions = _activeAuctions[collateral];
        uint48 currentTime = Time.timestamp();
        Auction storage rAuction;
        uint256 auctionID;
        uint256 remainingCollateral;
        uint256 deficit;
        uint256 totalDeficit = 0;
        uint256 closedNum = 0;
        uint256 len = rActiveAuctions.length();
        uint256 i = 0;
        while (i < len) {
            if (closedNum == maxNum) break;

            auctionID = rActiveAuctions.at(i);
            rAuction = _auction[auctionID];

            if (currentTime >= rAuction.endTime) {
                // If the auction is closed.

                remainingCollateral = rAuction.capacity;
                deficit = _calcRemainingCOLLAR(rAuction.target, rAuction.raised);

                unsoldCollateral[collateral] += remainingCollateral;
                delete rAuction.capacity;
                totalDeficit += deficit;

                // slither-disable-next-line unused-return
                rActiveAuctions.remove(auctionID);
                emit UnsoldAuctionClosed(auctionID, remainingCollateral, deficit);

                unchecked {
                    ++closedNum;
                    --len;
                }
            } else {
                // If the auction is not closed.

                unchecked {
                    ++i;
                }
            }
        }

        // Update collarDeficit once after the loop
        if (totalDeficit > 0) {
            collarDeficit += totalDeficit;
        }
    }

    /**
     * @notice Manually closes an active auction and moves remaining collateral to unsold.
     * @param id The auction ID to close
     * @dev Only callable by `ADMIN_ROLE` or `MANAGER_ROLE`.
     */
    function closeAuction(uint256 id) external onlyAdminOrManager {
        Auction storage rAuction = _auction[id];
        address collateral = rAuction.collateral;
        EnumerableSet.UintSet storage rActiveAuctions = _activeAuctions[collateral];
        _validateActiveAuction(id, rActiveAuctions);

        // Update the COLLAR deficit if the auction is created using `addAuction`.
        uint256 collarTarget = rAuction.target;
        uint256 deficit = 0;
        if (collarTarget != 0) {
            uint256 collarRaised = rAuction.raised;
            deficit = _calcRemainingCOLLAR(collarTarget, collarRaised);
            collarDeficit += deficit;
        }

        uint256 remainingCollateral = rAuction.capacity;
        unsoldCollateral[collateral] += remainingCollateral;
        delete rAuction.capacity;

        // slither-disable-next-line unused-return
        rActiveAuctions.remove(id);
        emit AuctionClosedManually(id, remainingCollateral, deficit);
    }

    /**
     * @notice Donates COLLAR to reduce the strategy's COLLAR deficit.
     * @param collarAmount The amount of `COLLAR` to donate
     * @dev The caller transfers `COLLAR` tokens and the contract re-deposits them into the stability pool.
     */
    function donateCOLLARToReduceDeficit(uint256 collarAmount) external nonzeroAmount(collarAmount) {
        uint256 deficit = collarDeficit;
        require(collarAmount <= deficit, AmountGreaterThanDeficit(collarAmount, deficit));

        collarDeficit = deficit - collarAmount;
        collarPendingReplenishment -= collarAmount;

        // Transfer COLLAR from the caller.
        IERC20(_spAssets[0]).safeTransferFrom(msg.sender, address(this), collarAmount);
        // Re-deposit the `collarAmount` into the SP.
        STABILITY_POOL.deposit(collarAmount);
    }

    function _addAuction(
        address collateral,
        uint256 collateralAmount,
        uint256 collarTarget,
        uint256 startPrice,
        uint256 endPrice,
        uint32 duration
    ) private returns (uint256) {
        uint256 auctionID = nextAuctionID;
        ++nextAuctionID;
        // Use post-increment to maintain auction IDs starting from 0
        // slither-disable-next-line unused-return
        _activeAuctions[collateral].add(auctionID);

        uint48 startTime = Time.timestamp();
        _auction[auctionID] = Auction({
            collateral: collateral,
            capacity: collateralAmount,
            target: collarTarget,
            raised: 0,
            startTime: startTime,
            endTime: startTime + duration,
            startPrice: startPrice,
            endPrice: endPrice
        });
        emit AuctionAdded(auctionID);
        return auctionID;
    }

    function _calcRemainingCOLLAR(uint256 target, uint256 raised) private pure returns (uint256) {
        // Underflow excluded: when `purchase`, an auction is closed when `raised` reaches `target`.
        return FPMath.rawSub(target, raised);
    }

    // ========== PROFIT MANAGEMENT ========== //

    /**
     * @notice Transfers accumulated profit of a specific token to the Callisto treasury.
     * @param token The token address for which to sweep profit
     * @param amount The amount of profit to transfer (capped at available profit)
     * @dev If the token is COLLAR, claims interest from the stability pool first.
     */
    function sweepProfit(address token, uint256 amount)
        external
        onlyAdminOrManager
        nonzeroAddress(token)
        nonzeroAmount(amount)
    {
        uint256 profit = treasuryProfit[token];
        IERC20 tkn = IERC20(token);

        // If the `token` is COLLAR, then claim COLLAR interest from the SP.
        if (token == _spAssets[0]) {
            uint256 bal = tkn.balanceOf(address(this));
            uint256[] memory positions = new uint256[](1); // The COLLAR's position is 0.
            STABILITY_POOL.claimGains({ receiver: address(this), assetPositions: positions });
            profit += tkn.balanceOf(address(this)) - bal;
            treasuryProfit[token] = profit;
        }

        require(profit != 0, ZeroProfit());

        amount = Math.min(amount, profit);
        treasuryProfit[token] -= amount;
        tkn.safeTransfer(treasury, amount);
        emit ProfitSwept(token, amount);
    }

    /// @notice Sets the treasury address for profit sweeping.
    /// @param t The new treasury address
    /// @dev Only callable by `ADMIN_ROLE`.
    function setTreasury(address t) external onlyRole(ADMIN_ROLE) {
        _setTreasury(t);
    }

    function _setTreasury(address t) private nonzeroAddress(t) {
        treasury = t;
        emit TreasurySet(t);
    }

    // ========== PAUSE FUNCTIONS ========== //

    /**
     * @notice Pauses purchases for a specific collateral type.
     * @param collateral The collateral address for which to pause purchases
     * @dev Only callable by `ADMIN_ROLE` or `MANAGER_ROLE`.
     */
    function pausePurchase(address collateral) external onlyAdminOrManager {
        _validatePurchaseNotPaused(collateral);
        _validateExistingCollateral(collateral);

        purchasePaused[collateral] = true;
        emit PurchasePaused(msg.sender, collateral);
    }

    /**
     * @notice Unpauses purchases for a specific collateral type.
     * @param collateral The collateral address for which to unpause purchases
     * @dev Only callable by `ADMIN_ROLE` or `MANAGER_ROLE`.
     */
    function unpausePurchase(address collateral) external onlyAdminOrManager {
        _validatePurchasePaused(collateral);
        _validateExistingCollateral(collateral);

        purchasePaused[collateral] = false;
        emit PurchaseUnpaused(msg.sender, collateral);
    }

    /**
     * @notice Pauses the addition of new auctions globally.
     * @dev Only callable by `ADMIN_ROLE` or `MANAGER_ROLE`.
     */
    function pauseAuctionAdding() external onlyAdminOrManager {
        _pause();
    }

    /**
     * @notice Unpauses the addition of new auctions globally.
     * @dev Only callable by `ADMIN_ROLE` or `MANAGER_ROLE`.
     */
    function unpauseAuctionAdding() external onlyAdminOrManager {
        _unpause();
    }

    function _validatePurchaseNotPaused(address collateral) private view {
        require(!purchasePaused[collateral], EnforcedPause());
    }

    function _validatePurchasePaused(address collateral) private view {
        require(purchasePaused[collateral], ExpectedPause());
    }

    // ========== STRATEGY MIGRATION ========== //

    // TODO: complete the migration flow for the correct PSM and SP behavior.

    function migrate(address newStrategy) external onlyRole(ADMIN_ROLE) {
        // Withdraw COLLAR from the SP and transfer to the new strategy.
        address[] storage rAssets = _spAssets;
        address collar = rAssets[0];
        IStabilityPool sp = STABILITY_POOL;
        uint256 collarAmount = sp.calcCompoundedDeposit(address(this));
        sp.withdraw(collarAmount);
        IERC20(collar).safeTransfer(newStrategy, collarAmount);

        // Transfer all unsold collateral to the new strategy.
        uint256 assetNum = rAssets.length;
        address collateral;
        uint256 unsold;
        for (uint256 i = 1; i < assetNum; ++i) {
            collateral = rAssets[i];
            require(_activeAuctions[collateral].length() == 0, ActiveAuctionsExist(collateral));

            unsold = unsoldCollateral[collateral];
            if (unsold > 0) {
                unsoldCollateral[collateral] = 0;
                IERC20(collateral).safeTransfer(newStrategy, unsold);
            }
        }

        // Replace the strategy in the contracts.
        CallistoPSM(psm).migrateToNewStrategy(newStrategy);
        sp.setPSMStrategy(newStrategy);
        emit Migrated(address(this), newStrategy);
    }
}
