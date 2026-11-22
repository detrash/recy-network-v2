// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title cRECYStaking (OpenZeppelin v5 Compatible — Strict Per-Deposit Tranches)
 * @notice Whitepaper Section 3.1 & 5.1: 15.0% Liquid Base Yield + 7.0% Milestone Bonus (+1.75% per 90 days) = 22.0% Max APY.
 * @dev Each stake() creates an independent tranche with its own 90-day milestone clock, preventing top-up timing exploits.
 */
contract cRECYStaking is AccessControl, ReentrancyGuard {
    using SafeERC20 for IERC20;

    bytes32 public constant REWARD_DISTRIBUTOR_ROLE = keccak256("REWARD_DISTRIBUTOR_ROLE");

    uint256 public constant MILESTONE_PERIOD = 90 days;
    uint256 public constant QUARTERLY_BONUS_BPS = 175; // +1.75% flat per completed 90-day quarter
    uint256 public constant MAX_TRANCHES_PER_USER = 50;

    struct StakeTranche {
        uint256 amount;
        uint256 depositTime;
        uint256 lastBaseSettleTime;
        uint256 lastMilestoneTimestamp;
    }

    IERC20 public immutable crecyToken;
    uint256 public totalStaked;
    uint256 public rewardReserve;

    uint256 public baseYieldRate = 1500; // 15.00% APY (basis points)

    mapping(address => uint256) public stakedBalanceOf;
    mapping(address => uint256) public accruedRewards;
    mapping(address => StakeTranche[]) private _userTranches;

    event Staked(address indexed account, uint256 indexed trancheIndex, uint256 amount, uint256 timestamp);
    event Unstaked(address indexed account, uint256 amount, uint256 remainingStaked);
    event RewardsClaimed(address indexed account, uint256 paidAmount, uint256 remainingAccrued);
    event RewardNotified(address indexed distributor, uint256 amount, uint256 newRewardReserve);
    event RewardReserveSynced(uint256 syncedAmount, uint256 newRewardReserve);

    constructor(address _crecyToken, address initialAdmin) {
        require(_crecyToken != address(0) && initialAdmin != address(0), "Zero address");
        crecyToken = IERC20(_crecyToken);
        _grantRole(DEFAULT_ADMIN_ROLE, initialAdmin);
        _grantRole(REWARD_DISTRIBUTOR_ROLE, initialAdmin);
    }

    /**
     * @notice Credits any cRECY sent directly to this contract (e.g., Uniswap V4 buybacks)
     *         into rewardReserve without touching user principal (totalStaked).
     */
    function syncRewardReserve() public returns (uint256 synced) {
        uint256 actualBalance = crecyToken.balanceOf(address(this));
        uint256 accounted = totalStaked + rewardReserve;
        if (actualBalance > accounted) {
            synced = actualBalance - accounted;
            rewardReserve += synced;
            emit RewardReserveSynced(synced, rewardReserve);
        }
    }

    function _tranchePendingYield(StakeTranche memory tranche) internal view returns (uint256 liquidYield, uint256 milestoneYield, uint256 completedQuarters) {
        if (tranche.amount == 0) return (0, 0, 0);

        uint256 elapsedBase = block.timestamp - tranche.lastBaseSettleTime;
        liquidYield = (tranche.amount * baseYieldRate * elapsedBase) / (10_000 * 365 days);

        completedQuarters = (block.timestamp - tranche.lastMilestoneTimestamp) / MILESTONE_PERIOD;
        if (completedQuarters > 0) {
            // Discrete 90-day milestone payout per Whitepaper Section 5.1 (not pro-rated)
            // forge-lint: disable-next-line(divide-before-multiply)
            milestoneYield = (tranche.amount * QUARTERLY_BONUS_BPS * completedQuarters) / 10_000;
        }
    }

    function _settleTranche(address account, StakeTranche storage tranche) internal {
        (uint256 liquidYield, uint256 milestoneYield, uint256 completedQuarters) = _tranchePendingYield(tranche);
        if (liquidYield + milestoneYield > 0) {
            accruedRewards[account] += liquidYield + milestoneYield;
        }
        tranche.lastBaseSettleTime = block.timestamp;
        if (completedQuarters > 0) {
            // Advance strictly by whole completed quarters to preserve remainder toward the next quarter
            // forge-lint: disable-next-line(divide-before-multiply)
            tranche.lastMilestoneTimestamp += completedQuarters * MILESTONE_PERIOD;
        }
    }

    function _settleAll(address account) internal {
        StakeTranche[] storage tranches = _userTranches[account];
        uint256 len = tranches.length;
        for (uint256 i = 0; i < len; i++) {
            _settleTranche(account, tranches[i]);
        }
    }

    function pendingRewards(address account) public view returns (uint256 totalPending) {
        totalPending = accruedRewards[account];
        StakeTranche[] storage tranches = _userTranches[account];
        uint256 len = tranches.length;
        for (uint256 i = 0; i < len; i++) {
            (uint256 liquidYield, uint256 milestoneYield,) = _tranchePendingYield(tranches[i]);
            totalPending += liquidYield + milestoneYield;
        }
    }

    function stake(uint256 amount) external nonReentrant {
        require(amount > 0, "Zero amount");
        StakeTranche[] storage tranches = _userTranches[msg.sender];
        require(tranches.length < MAX_TRANCHES_PER_USER, "Max tranches reached");

        uint256 trancheIndex = tranches.length;
        tranches.push(
            StakeTranche({
                amount: amount,
                depositTime: block.timestamp,
                lastBaseSettleTime: block.timestamp,
                lastMilestoneTimestamp: block.timestamp
            })
        );
        stakedBalanceOf[msg.sender] += amount;
        totalStaked += amount;

        emit Staked(msg.sender, trancheIndex, amount, block.timestamp);
        crecyToken.safeTransferFrom(msg.sender, address(this), amount);
    }

    /**
     * @notice Unstakes `amount` using LIFO order (newest tranches first) so older tranches
     *         preserve their accrued progress toward the next 90-day milestone bonus.
     */
    function unstake(uint256 amount) external nonReentrant {
        require(amount > 0 && stakedBalanceOf[msg.sender] >= amount, "Insufficient stake");

        StakeTranche[] storage tranches = _userTranches[msg.sender];
        uint256 remaining = amount;

        while (remaining > 0 && tranches.length > 0) {
            uint256 lastIdx = tranches.length - 1;
            StakeTranche storage tranche = tranches[lastIdx];

            _settleTranche(msg.sender, tranche);

            if (tranche.amount <= remaining) {
                remaining -= tranche.amount;
                tranches.pop();
            } else {
                tranche.amount -= remaining;
                remaining = 0;
            }
        }

        require(remaining == 0, "Accounting mismatch");
        stakedBalanceOf[msg.sender] -= amount;
        totalStaked -= amount;

        emit Unstaked(msg.sender, amount, stakedBalanceOf[msg.sender]);
        crecyToken.safeTransfer(msg.sender, amount);
    }

    /**
     * @notice Unstakes a specific tranche by index (useful for targeted liquidity management).
     */
    function unstakeTranche(uint256 trancheIndex, uint256 amount) external nonReentrant {
        StakeTranche[] storage tranches = _userTranches[msg.sender];
        require(trancheIndex < tranches.length, "Invalid tranche");

        StakeTranche storage tranche = tranches[trancheIndex];
        require(amount > 0 && tranche.amount >= amount, "Insufficient tranche stake");

        _settleTranche(msg.sender, tranche);

        if (tranche.amount == amount) {
            uint256 lastIdx = tranches.length - 1;
            if (trancheIndex != lastIdx) {
                tranches[trancheIndex] = tranches[lastIdx];
            }
            tranches.pop();
        } else {
            tranche.amount -= amount;
        }

        stakedBalanceOf[msg.sender] -= amount;
        totalStaked -= amount;

        emit Unstaked(msg.sender, amount, stakedBalanceOf[msg.sender]);
        crecyToken.safeTransfer(msg.sender, amount);
    }

    function claimRewards() external nonReentrant {
        syncRewardReserve();
        _settleAll(msg.sender);

        uint256 available = accruedRewards[msg.sender];
        require(available > 0, "No rewards");
        require(rewardReserve > 0, "Empty reward reserve");

        uint256 payout = available > rewardReserve ? rewardReserve : available;
        accruedRewards[msg.sender] = available - payout;
        rewardReserve -= payout;

        emit RewardsClaimed(msg.sender, payout, accruedRewards[msg.sender]);
        crecyToken.safeTransfer(msg.sender, payout);
    }

    function notifyRewardAmount(uint256 reward) external nonReentrant onlyRole(REWARD_DISTRIBUTOR_ROLE) {
        require(reward > 0, "Zero reward");
        rewardReserve += reward;
        emit RewardNotified(msg.sender, reward, rewardReserve);
        crecyToken.safeTransferFrom(msg.sender, address(this), reward);
    }

    // --- View Helpers & Backwards-Compatible Getters ---

    function getUserTranches(address account) external view returns (StakeTranche[] memory) {
        return _userTranches[account];
    }

    function getUserTrancheCount(address account) external view returns (uint256) {
        return _userTranches[account].length;
    }

    /// @notice Backwards-compatible getter returning the most recent deposit timestamp.
    function userStakeTime(address account) external view returns (uint256 latestDeposit) {
        StakeTranche[] storage tranches = _userTranches[account];
        for (uint256 i = 0; i < tranches.length; i++) {
            if (tranches[i].depositTime > latestDeposit) {
                latestDeposit = tranches[i].depositTime;
            }
        }
    }

    /// @notice Backwards-compatible getter returning the earliest active milestone clock.
    function lastMilestoneTimestamp(address account) external view returns (uint256 earliestClock) {
        StakeTranche[] storage tranches = _userTranches[account];
        if (tranches.length == 0) return 0;
        earliestClock = tranches[0].lastMilestoneTimestamp;
        for (uint256 i = 1; i < tranches.length; i++) {
            if (tranches[i].lastMilestoneTimestamp < earliestClock) {
                earliestClock = tranches[i].lastMilestoneTimestamp;
            }
        }
    }
}
