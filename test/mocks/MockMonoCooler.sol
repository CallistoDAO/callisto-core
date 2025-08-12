// SPDX-License-Identifier: AGPL-3.0-only

pragma solidity ^0.8.29;

import { ERC20 } from "../../dependencies/@openzeppelin-contracts-5.3.0/token/ERC20/ERC20.sol";

import { ERC4626 } from "../../dependencies/@openzeppelin-contracts-5.3.0/token/ERC20/extensions/ERC4626.sol";
import { IERC20, SafeERC20 } from "../../dependencies/@openzeppelin-contracts-5.3.0/token/ERC20/utils/SafeERC20.sol";
import { SafeCast } from "../../dependencies/@openzeppelin-contracts-5.3.0/utils/math/SafeCast.sol";
import { ICoolerTreasuryBorrower } from "../../src/interfaces/ICoolerTreasuryBorrower.sol";
import { IDLGTEv1 } from "../../src/interfaces/IDLGTEv1.sol";
import { IGOHM } from "../../src/interfaces/IGOHM.sol";

contract MockMonoCooler is ERC4626 {
    using SafeCast for *;
    using SafeERC20 for IGOHM;
    using SafeERC20 for IERC20;

    uint128 public constant PRICE_DENOMINATOR = 100;

    IGOHM public immutable GOHM;

    IERC20 public USDS;

    uint128 public immutable GOHM_USD_PRICE;

    uint128 public borrowingAmount;

    uint128 public repaymentAmount;

    ICoolerTreasuryBorrower public treasuryBorrower;

    int128 public debtDelta;

    mapping(address account => uint128) public accountCollateral;

    constructor(IGOHM gOHM, address usds, uint128 usdPriceOfGOHM, address treasuryBorrower_)
        ERC4626(ERC20(address(gOHM)))
        ERC20("MockMonoCooler", "mMC")
    {
        GOHM = gOHM;
        USDS = IERC20(usds);
        GOHM_USD_PRICE = usdPriceOfGOHM;
        treasuryBorrower = ICoolerTreasuryBorrower(treasuryBorrower_);
    }

    function setBorrowingAmount(uint128 amount) external {
        borrowingAmount = amount;
    }

    function setAccountDebt(uint128 amount) external {
        repaymentAmount = amount;
    }

    function setRepaymentAmount(uint128 amount) external {
        repaymentAmount = amount;
    }

    function setDebtDelta(int128 debtDelta_) external {
        debtDelta = debtDelta_;
    }

    function addCollateral(uint128 collateralAmount, address onBehalfOf, IDLGTEv1.DelegationRequest[] calldata)
        external
    {
        accountCollateral[onBehalfOf] += collateralAmount;
        GOHM.safeTransferFrom(msg.sender, address(this), collateralAmount);
    }

    function borrow(uint128, address, address) external returns (uint128 amountBorrowedInWad) {
        USDS.safeTransfer(msg.sender, borrowingAmount);
        return borrowingAmount;
    }

    function repay(uint128, address) external returns (uint128 amountRepaidInWad) {
        USDS.safeTransferFrom(msg.sender, address(this), repaymentAmount);
        return repaymentAmount;
    }

    function withdrawCollateral(
        uint128 collateralAmount,
        address onBehalfOf,
        address,
        IDLGTEv1.DelegationRequest[] calldata
    ) external returns (uint128 collateralWithdrawn) {
        accountCollateral[onBehalfOf] -= collateralAmount;
        GOHM.safeTransfer(msg.sender, collateralAmount);
        return collateralAmount;
    }

    function debtDeltaForMaxOriginationLtv(address, int128) external view returns (int128 debtDeltaInWad) {
        return debtDelta;
    }

    function collateralToken() external view returns (IERC20) {
        return IERC20(address(GOHM));
    }

    function debtToken() external view returns (IERC20) {
        return USDS;
    }

    function accountDebt(address) external view returns (uint128) {
        return borrowingAmount;
    }

    function toUSDS(uint128 gOHMAmount) public view returns (uint128) {
        return (gOHMAmount * GOHM_USD_PRICE) / PRICE_DENOMINATOR;
    }

    function applyDelegations(
        IDLGTEv1.DelegationRequest[] calldata, // delegationRequests,
        address // onBehalfOf
    ) external pure returns (uint256 totalDelegated, uint256 totalUndelegated, uint256 undelegatedBalance) {
        return (0, 0, 0);
    }

    function prepareDelegationRequest(address to, uint256 amount)
        internal
        pure
        returns (IDLGTEv1.DelegationRequest[] memory delegationRequests)
    {
        delegationRequests = new IDLGTEv1.DelegationRequest[](1);
        delegationRequests[0] = IDLGTEv1.DelegationRequest({ delegate: to, amount: int256(amount) });
    }

    function setNewUsdsToken(address newUDSD) external {
        USDS = IERC20(newUDSD);
    }

    function setNewTreasuryBorrower(address treasuryBorrower_) external {
        treasuryBorrower = ICoolerTreasuryBorrower(treasuryBorrower_);
    }
}
