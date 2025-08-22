// SPDX-License-Identifier: AGPL-3.0

pragma solidity 0.8.30;

import { Kernel, Keycode, Permissions, Policy } from "../Kernel.sol";
import { ICallistoHeart } from "../interfaces/ICallistoHeart.sol";
import { IExecutableByHeart } from "../interfaces/IExecutableByHeart.sol";
import { MINTRv1 } from "../modules/MINTR/MINTR.v1.sol";
import { ROLESv1, RolesConsumer } from "../modules/ROLES/CallistoRoles.sol";
import { ReentrancyGuard } from "solmate-6.8.0/utils/ReentrancyGuard.sol";

/**
 * @title Callisto Heart
 * @notice This contract provides keepers with a reward for calling the `beat` function.
 * It features an auction-style reward system where rewards increase linearly up to a maximum reward.
 * Rewards are released in CALL.
 */
contract CallistoHeart is ICallistoHeart, Policy, RolesConsumer, ReentrancyGuard {
    // ========== CONSTANTS ========== //

    bytes32 public constant HEART_ADMIN_ROLE = "heart_admin";

    // ========== STORAGE ========== //

    /// @notice The status of the Heart. If `true`, then beating.
    bool public active;

    /// @inheritdoc ICallistoHeart
    uint48 public frequency;

    /// @notice The timestamp of the last beat in seconds.
    uint48 public lastBeat;

    /// @notice The duration of the reward auction in seconds.
    uint48 public auctionDuration;

    /// @notice The maximum reward for beating the Heart (in reward token decimals)
    uint256 public maxReward;

    /// @notice The Callisto minter module to mint CALL as a reward for calling `beat`.
    MINTRv1 public MINTR;

    /// @notice The Callisto vault.
    IExecutableByHeart public vault;

    /// @notice The Callisto PSM.
    IExecutableByHeart public psm;

    // ========== MODIFIERS ========== //

    modifier onlyActive() {
        require(active, Heart_BeatStopped());
        _;
    }

    // ========== INITIALIZATION AND KERNEL POLICY CONFIGURATION ========== //

    /// @notice `auctionDuration_` should be less than or equal to `frequency_`.
    constructor(
        Kernel kernel_,
        address vault_,
        address psm_,
        uint48 frequency_,
        uint48 auctionDuration_,
        uint256 maxReward_
    ) Policy(kernel_) {
        require(address(kernel_) != address(0), Heart_InvalidParams());
        require(auctionDuration_ <= frequency_, Heart_InvalidParams());

        _setFrequency(frequency_);
        _setVault(vault_);
        _setPSM(psm_);
        auctionDuration = auctionDuration_;
        maxReward = maxReward_;
        emit RewardUpdated(maxReward_, auctionDuration_);
        active = true;
        emit Activated();
    }

    /// @inheritdoc Policy
    function configureDependencies() external override onlyKernel returns (Keycode[] memory) {
        Keycode[] memory dependencies = new Keycode[](2);
        dependencies[0] = Keycode.wrap(0x4d494e5452); // toKeycode("MINTR");
        dependencies[1] = Keycode.wrap(0x524f4c4553); // toKeycode("ROLES");

        MINTRv1 minter = MINTRv1(getModuleAddress(dependencies[0]));
        ROLESv1 roles = ROLESv1(getModuleAddress(dependencies[1]));

        // Check the module versions. Modules should be sorted in alphabetical order.
        (uint8 major,) = minter.VERSION();
        if (major != 1) revert Policy_WrongModuleVersion(abi.encode([1, 1]));
        (major,) = roles.VERSION();
        if (major != 1) revert Policy_WrongModuleVersion(abi.encode([1, 1]));

        (MINTR, ROLES) = (minter, roles);

        return dependencies;
    }

    /// @inheritdoc Policy
    function requestPermissions() external pure override returns (Permissions[] memory) {
        Permissions[] memory permissions = new Permissions[](2);
        Keycode kc = Keycode.wrap(0x4d494e5452); // toKeycode("MINTR");
        permissions[0] = Permissions(kc, MINTRv1.increaseMintApproval.selector);
        permissions[1] = Permissions(kc, MINTRv1.mintCALL.selector);
        return permissions;
    }

    /**
     * @notice Returns the version of the policy.
     * @return   [major, minor].
     */
    function VERSION() external pure returns (uint8, uint8) {
        return (1, 0);
    }

    // ___ HEARTBEAT ___

    /// @inheritdoc ICallistoHeart
    function beat() external onlyActive nonReentrant {
        uint48 currentTime = uint48(block.timestamp);
        uint48 lastBeatTime = lastBeat;
        uint48 freq = frequency;
        require(currentTime >= lastBeatTime + freq, Heart_OutOfCycle());

        /* Update the timestamp of the last beat.
         * Ensure that the update `frequency` does not change, but prevent multiple beats if one is missed.
        */
        // slither-disable-next-line weak-prng
        lastBeat = currentTime - ((currentTime - lastBeatTime) % freq);

        // Handle pending OHM deposits in the Callisto vault.
        IExecutableByHeart executable = vault;
        if (address(executable) != address(0)) executable.execute();

        // Handle excess COLLAR burning in the Callisto PSM.
        executable = psm;
        if (address(executable) != address(0)) executable.execute();

        // Calculate and issue the reward for the keeper.
        uint256 reward = currentReward(); // 0 <= `reward` <= `maxReward`.
        if (reward > 0) {
            MINTRv1 minter = MINTR;
            minter.increaseMintApproval(address(this), reward);
            minter.mintCALL(msg.sender, reward);
            emit RewardIssued(msg.sender, reward);
        }

        emit Beat(block.timestamp);
    }

    // ========== REWARD CALCULATION ========== //

    /// @inheritdoc ICallistoHeart
    function currentReward() public view returns (uint256) {
        /* If `beat` is not available yet, returns 0 (no reward).
        * Otherwise, calculates the reward from a linearly increasing auction bounded by `maxReward` and the heart
         * balance.
         */

        uint48 freq = frequency;
        uint48 nextBeat = lastBeat + freq;
        uint48 currentTime = uint48(block.timestamp);
        if (currentTime <= nextBeat) return 0;

        uint48 duration = auctionDuration > freq ? freq : auctionDuration;
        uint48 elapsed = currentTime - nextBeat;
        return elapsed < duration ? (elapsed * maxReward) / duration : maxReward;
    }

    // ========== ADMINISTRATIVE FUNCTIONALITY ========== //

    /// @inheritdoc ICallistoHeart
    function setRewardAuctionParams(uint256 maxReward_, uint48 auctionDuration_) external onlyRole(HEART_ADMIN_ROLE) {
        // Check that a beat is available to avoid front-running a keeper.
        uint48 freq = frequency;
        require(uint48(block.timestamp) < lastBeat + freq, Heart_BeatAvailable());
        // `auctionDuration_` should be less than or equal to `frequency`, otherwise `frequency` is used.
        require(auctionDuration_ <= freq, Heart_InvalidParams());

        auctionDuration = auctionDuration_;
        maxReward = maxReward_;
        emit RewardUpdated(maxReward_, auctionDuration_);
    }

    /// @inheritdoc ICallistoHeart
    function setFrequency(uint48 freq) external onlyRole(HEART_ADMIN_ROLE) {
        _setFrequency(freq);
    }

    /// @inheritdoc ICallistoHeart
    function resetBeat() external onlyRole(HEART_ADMIN_ROLE) {
        _resetBeat();
    }

    /// @inheritdoc ICallistoHeart
    function deactivate() external onlyRole(HEART_ADMIN_ROLE) onlyActive {
        active = false;
        emit Deactivated();
    }

    /// @inheritdoc ICallistoHeart
    function activate() external onlyRole(HEART_ADMIN_ROLE) {
        require(!active, Heart_Active());
        active = true;
        _resetBeat();
        emit Activated();
    }

    /// @inheritdoc ICallistoHeart
    function setVault(address v) external onlyRole(HEART_ADMIN_ROLE) {
        _setVault(v);
    }

    /// @inheritdoc ICallistoHeart
    function setPSM(address psm_) external onlyRole(HEART_ADMIN_ROLE) {
        _setPSM(psm_);
    }

    function _setFrequency(uint48 freq) private {
        require(freq != 0, Heart_InvalidParams());
        frequency = freq;
        emit FrequencySet(freq);
    }

    function _setVault(address v) private {
        vault = IExecutableByHeart(v);
        emit VaultSet(v);
    }

    function _setPSM(address psm_) private {
        psm = IExecutableByHeart(psm_);
        emit PSMSet(psm_);
    }

    function _resetBeat() private {
        lastBeat = uint48(block.timestamp) - frequency;
    }
}
