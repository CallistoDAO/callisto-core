// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

interface IStabilityPoolForPSM {
    function deposit(uint256 amount) external;
}

// TODO: ! replace before deploying to the main network.
contract PSMStrategy {
    IStabilityPoolForPSM public immutable STABILITY_POOL;

    // solhint-disable-next-line no-unused-vars
    constructor(address defaultAdmin, address stabilityPool, address collar, address auctioneer, address treasury_) {
        STABILITY_POOL = IStabilityPoolForPSM(stabilityPool);
    }

    // solhint-disable-next-line no-unused-vars
    function finalizeInitialization(address psm) external { }

    function deposit(uint256 amount) external {
        STABILITY_POOL.deposit(amount);
    }
}
