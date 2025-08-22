// SPDX-License-Identifier: AGPL-3.0

pragma solidity ^0.8.4;

interface ICallistoHeart {
    // =========  EVENTS ========= //

    event Beat(uint256 indexed timestamp_);
    event RewardIssued(address indexed to_, uint256 indexed rewardAmount_);
    event RewardUpdated(uint256 indexed maxRewardAmount_, uint48 indexed auctionDuration_);
    event FrequencySet(uint48 indexed frequency);
    event VaultSet(address indexed vault);
    event PSMSet(address indexed psm);
    event Activated();
    event Deactivated();

    // =========  ERRORS ========= //

    error Heart_OutOfCycle();
    error Heart_BeatStopped();
    error Heart_InvalidParams();
    error Heart_BeatAvailable();
    error Heart_Active();

    // =========  CORE FUNCTIONS ========= //

    /**
     * @notice Beats the heart.
     *
     * Anyone who calls this function is rewarded with CALL tokens.
     *
     * Requires at least `frequency` seconds to have elapsed since the last `beat`.
     */
    function beat() external;

    // =========  ADMIN FUNCTIONS ========= //

    /**
     * @notice Resets the heartbeat timer.
     *
     * Requires the caller to have the role `HEART_ADMIN_ROLE`.
     *
     * @dev This function adjusts the cycle by setting the last beat to (Current timestamp - `frequency`), effectively
     * allowing a new beat to be called immediately. This is useful if the beat cycle needs to be restarted because of
     * `Heart_OutOfCycle`.
     */
    function resetBeat() external;

    /**
     * @notice Activates the heart and resets the heartbeat timer.
     *
     * Requires the caller to have the role `HEART_ADMIN_ROLE`.
     */
    function activate() external;

    /**
     * @notice Deactivates the heart.
     *
     * Requires the caller to have the role `HEART_ADMIN_ROLE`.
     *
     * @dev This function is intended for emergencies.
     */
    function deactivate() external;

    /**
     * @notice Sets the maximum reward amount and the auction duration.
     *
     * Requires the caller to have the role `HEART_ADMIN_ROLE`.
     *
     * @param maxReward_ The maximum reward amount to set (in terms of the CALL token).
     * @param auctionDuration_ The auction duration to set (in seconds).
     */
    function setRewardAuctionParams(uint256 maxReward_, uint48 auctionDuration_) external;

    /**
     * @notice Sets the Callisto vault address to `vault`.
     *
     * Requires the caller to have the role `HEART_ADMIN_ROLE`.
     */
    function setVault(address vault) external;

    /**
     * @notice Sets the address of the Callisto PSM to `psm`.
     *
     * Requires the caller to have the role `HEART_ADMIN_ROLE`.
     */
    function setPSM(address psm) external;

    /**
     * @notice Sets the heartbeat frequency to `freq` (in seconds).
     *
     * Requires the caller to have the role `HEART_ADMIN_ROLE`.
     */
    function setFrequency(uint48 freq) external;

    // =========  VIEW FUNCTIONS ========= //

    /// @notice Returns the heartbeat frequency (in seconds).
    function frequency() external view returns (uint48);

    /// @notice Returns the current reward amount based on the linear auction.
    function currentReward() external view returns (uint256);
}
