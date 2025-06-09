// SPDX-License-Identifier: AGPL-3.0-only

pragma solidity 0.8.30;

import { Kernel, Keycode, Permissions, Policy } from "../../Kernel.sol";
import { ICallistoVault } from "../../interfaces/ICallistoVault.sol";
import { IExecutableByHeart } from "../../interfaces/IExecutableByHeart.sol";
import { RolesConsumer } from "../../modules/ROLES/CallistoRoles.sol";
import { ROLESv1 } from "../../modules/ROLES/CallistoRoles.sol";
import { TRSRYv1 } from "../../modules/TRSRY/CallistoTreasury.sol";
import { CommonRoles } from "../common/CommonRoles.sol";
import { CallistoVaultLogic, IDLGTEv1 } from "./CallistoVaultLogic.sol";

contract CallistoVault is Policy, RolesConsumer, CallistoVaultLogic, ICallistoVault, IExecutableByHeart {
    // ___ CONSTANTS ___

    bytes32 public constant CDP_ROLE = "cdp";

    bytes32 public constant HEART_ROLE = "heart";

    // ___ STORAGE ___

    /// @notice The Callisto treasury.
    address public TRSRY;

    // ___ MODIFIERS ___

    modifier onlyAdminOrManager() {
        require(
            ROLES.hasRole(msg.sender, CommonRoles.ADMIN) || ROLES.hasRole(msg.sender, CommonRoles.MANAGER),
            CommonRoles.Unauthorized(msg.sender)
        );
        _;
    }

    // ___ INITIALIZATION AND KERNEL POLICY CONFIGURATION ___

    constructor(Kernel kernel_, InitialParameters memory p)
        Policy(kernel_)
        CallistoVaultLogic("Callisto OHM", "cOHM", p)
    {
        require(address(kernel_) != address(0), ZeroAddress());
    }

    /// @inheritdoc Policy
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

    /// @inheritdoc Policy
    function requestPermissions() external pure override returns (Permissions[] memory) { }

    // ___ RESTRICTED FUNCTIONALITY ___

    function execute() external onlyRole(HEART_ROLE) {
        _executeByHeart();
    }

    /// @inheritdoc ICallistoVault
    function applyDelegations(IDLGTEv1.DelegationRequest[] calldata requests)
        external
        returns (uint256 totalDelegated, uint256 totalUndelegated, uint256 undelegatedBalance)
    {
        require(
            ROLES.hasRole(msg.sender, CDP_ROLE) || ROLES.hasRole(msg.sender, CommonRoles.ADMIN),
            CommonRoles.Unauthorized(msg.sender)
        );
        return _applyDelegations(requests);
    }

    function sweepYield(uint256 yield) external onlyAdminOrManager {
        _sweepYield(yield);
    }

    function withdrawExcessGOHM(uint256 gOHMAmount, address to) external onlyAdminOrManager {
        _withdrawExcessGOHM(gOHMAmount, to);
    }

    function cancelOHMStake() external onlyAdminOrManager {
        _cancelOHMStake();
    }

    function sweepTokens(address token, address to, uint256 value) external onlyAdminOrManager {
        _sweepTokens(token, to, value);
    }

    function setPause(bool deposit, bool pause) external onlyAdminOrManager {
        _setPause(deposit, pause);
    }

    function setMinDeposit(uint256 minDeposit) external onlyAdminOrManager {
        _setMinDeposit(minDeposit);
    }

    function setOHMExchangeMode(OHMExchangeMode mode) external onlyRole(CommonRoles.ADMIN) {
        _setOHMExchangeMode(mode);
    }

    function setOHMSwapper(address swapper) external onlyRole(CommonRoles.ADMIN) {
        _setOHMSwapper(swapper);
    }

    // ___ VAULT LOGIC FOR MODULES ___

    function _treasuryAddress() internal view override returns (address) {
        return TRSRY;
    }
}
