// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.29;

import { MockERC20 } from "./MockERC20.sol";
import { MockGohm } from "./MockGohm.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

interface IDistributor {
    function distribute() external;

    function retrieveBounty() external returns (uint256);
}

contract MockStaking {
    using SafeERC20 for IERC20;

    struct Epoch {
        uint256 length;
        uint256 number;
        uint256 end;
        uint256 distribute;
    }

    struct Claim {
        uint256 deposit; // if forfeiting
        uint256 gons; // staked balance
        uint256 expiry; // end of warmup period
        bool lock; // prevents malicious delays for claim
    }

    /// state
    MockERC20 public OHM;
    MockERC20 public sOHM;
    MockGohm public gOHM;

    Epoch public epoch;

    IDistributor public distributor;

    mapping(address => Claim) public warmupInfo;
    uint256 public warmupPeriod;
    uint256 private gonsInWarmup;

    /// constructor
    constructor(
        address ohm_,
        address sohm_,
        address gohm_,
        uint256 epochLength,
        uint256 firstEpochNumber_,
        uint256 firstEpochTime_
    ) {
        OHM = MockERC20(ohm_);
        sOHM = MockERC20(sohm_);
        gOHM = MockGohm(gohm_);

        epoch = Epoch({ length: epochLength, number: firstEpochNumber_, end: firstEpochTime_, distribute: 0 });
    }

    /// setters
    function setDistributor(address distributor_) external {
        distributor = IDistributor(distributor_);
    }

    /// functions
    function stake(address to_, uint256 amount_, bool rebasing_, bool claim_) external returns (uint256) {
        IERC20(address(OHM)).safeTransferFrom(msg.sender, address(this), amount_);
        amount_ = amount_ + rebase();
        if (claim_ && warmupPeriod == 0) {
            return _send(to_, amount_, rebasing_);
        } else {
            Claim memory info = warmupInfo[to_];
            if (!info.lock) {
                require(to_ == msg.sender, "External deposits for account are locked");
            }

            warmupInfo[to_] = Claim({
                deposit: info.deposit + amount_,
                gons: 0, // info.gons.add(sOHM.gonsForBalance(amount_)),
                expiry: epoch.number + warmupPeriod,
                lock: info.lock
            });

            // gonsInWarmup = gonsInWarmup.add(sOHM.gonsForBalance(amount_));
            return amount_;
        }
    }

    // TODO: check gonsInWarmup

    function claim(address _to, bool _rebasing) public returns (uint256) {
        Claim memory info = warmupInfo[_to];

        if (!info.lock) {
            require(_to == msg.sender, "External claims for account are locked");
        }

        if (epoch.number >= info.expiry && info.expiry != 0) {
            delete warmupInfo[_to];

            // gonsInWarmup = gonsInWarmup - info.gons;
            // return _send(_to, sOHM.balanceForGons(info.gons), _rebasing);
            return _send(_to, info.deposit, _rebasing);
        }
        return 0;
    }

    function unstake(address to_, uint256 amount_, bool trigger_, bool rebasing_) external returns (uint256 amount) {
        uint256 bounty;
        if (trigger_) bounty = rebase();

        if (rebasing_) {
            IERC20(address(sOHM)).safeTransferFrom(msg.sender, address(this), amount_);
            amount = amount_ + bounty;
        } else {
            gOHM.burnFrom(msg.sender, amount_);
            amount = gOHM.balanceFrom(amount_) + bounty;
        }

        IERC20(address(OHM)).safeTransfer(to_, amount);
    }

    function rebase() public pure returns (uint256) {
        uint256 bounty;
        // if (epoch.end <= block.timestamp) {
        //     epoch.end = epoch.end + epoch.length;
        //     distributor.distribute();
        //     bounty = distributor.retrieveBounty();
        // }

        return bounty;
    }

    function _send(address to_, uint256 amount_, bool rebasing_) internal returns (uint256) {
        if (rebasing_) {
            sOHM.mint(to_, amount_);
            return amount_;
        } else {
            gOHM.mint(to_, gOHM.balanceTo(amount_));
            return gOHM.balanceTo(amount_);
        }
    }

    function setWarmupPeriod(uint256 value) external {
        warmupPeriod = value;
    }

    function setEpochNumber(uint256 value) external {
        epoch.number = value;
    }

    /**
     * @notice forfeit stake and retrieve OHM
     * @return uint
     */
    function forfeit() external returns (uint256) {
        Claim memory info = warmupInfo[msg.sender];
        delete warmupInfo[msg.sender];

        // gonsInWarmup = gonsInWarmup.sub(info.gons);

        IERC20(address(OHM)).safeTransfer(msg.sender, info.deposit);

        return info.deposit;
    }
}
