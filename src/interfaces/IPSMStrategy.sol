// SPDX-License-Identifier: MIT

pragma solidity ^0.8.30;

interface IPSMStrategy {
    // ========== EVENTS ========== //

    event Purchased(
        uint256 indexed auctionID,
        address indexed purchaser,
        address indexed recipient,
        uint256 collateralPurchased,
        uint256 collarPaid,
        uint256 collateralProfit
    );

    event AuctionClosed(uint256 indexed auctionID);

    event ProfitFromAuctionForUnsold(uint256 indexed auctionID, uint256 indexed collarProfit);

    // ========== ERRORS ========== //

    error ZeroAmount();

    error ZeroAddress();

    error NotActiveAuction(uint256 id);

    error PriceGreaterThanMax(uint256 current, uint256 maximum);

    error COLLARTargetOvershoot(uint256 target, uint256 raised);

    error NotEnoughCollateral(uint256 requested, uint256 remaining);

    error ArrayLenMismatch(uint256 auctionArrLen, uint256 paymentArrLen);

    error CollateralMismatch(address auctionCollateral, address passed);

    // ========== STRUCTS ========== //

    /**
     * @notice Auction state.
     * The `startPrice` is the price at the auction start which is the maximum price for purchasers. It is denominated
     * in units of COLLAR per `collateral` unit.
     */
    struct Auction {
        address collateral;
        uint48 startTime;
        uint48 endTime;
        uint256 capacity; // Collateral left.
        uint256 target; // COLLAR to raise.
        uint256 raised; // COLLAR raised so far.
        uint256 startPrice; // Maximum price for the purchaser.
        uint256 endPrice; // Minimum price for the purchaser.
    }

    // ========== PURCHASE FUNCTIONS ========== //

    /**
     * @notice Purchases a corresponding amount of the collateral token for the specified `collarPayment`
     * at the `auctionID` auction, transferring the collateral amount to the `recipient`.
     * Also, updates the treasury profit for the `auctionID` auction and re-deposits obtained COLLAR into the SP.
     *
     * @param maxPrice ... If zero, there is no price cap.
     */
    function purchase(uint256 auctionID, uint256 collarPayment, address recipient, uint256 maxPrice)
        external
        returns (uint256 collateralPurchased, uint256 collarPaid);

    /**
     * @param maxPrice ... If zero, there is no price cap.
     */
    function purchaseBatch(
        uint256[] calldata auctionIDs,
        uint256[] memory collarPayments,
        address recipient,
        address collateral,
        uint256 maxPrice
    ) external returns (uint256[] memory collateralAmounts, uint256[] memory collarPaid);

    // ========== QUERY FUNCTIONS ========== //

    function getAuctionStatus(uint256 id) external view returns (bool exists, bool active);

    /**
     * @notice Returns details and current price of the `id` auction. Reverts if the auction does not exist or is not
     * active.
     * @param id An auction ID.
     * @return A tuple of two elements:
     * 1. Values of all fields of the `Auction` object. See the `Auction` structure for details.
     * 2. The current price quoted as COLLAR per collateral for `id`.
     */
    function getActiveAuctionDetails(uint256 id) external view returns (Auction memory, uint256 price);

    function getActiveAuctionIDs(address collateral) external view returns (uint256[] memory);

    function getActiveAuctionNum(address collateral) external view returns (uint256);

    function getSPAssets() external view returns (address[] memory);

    function addAuction(
        uint256 collateralPosition,
        uint256 collateralAmount,
        uint256 collateralPrice,
        uint256 updatedSPDeposit
    ) external;

    function addSPAsset(address asset) external;
}
