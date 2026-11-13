// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title cRECYStaking (OpenZeppelin v5 Compatible)
 * @notice Whitepaper Section 3.1 & 5.1: 15.0% Liquid Base Yield + 7.0% Milestone Bonus (+1.75% per 90 days) = 22.0% Max APY.
 */
contract cRECYStaking is Ownable, AccessControl, ReentrancyGuard {
    using SafeERC20 for IERC20;

    bytes32 public constant REWARD_DISTRIBUTOR_ROLE = keccak256("REWARD_DISTRIBUTOR_ROLE");

    IERC20 public immutable crecyToken;
    uint256 public totalStaked;
    uint256 public rewardReserve;

    uint256 public baseYieldRate = 1500;              // 15.00% APY
    uint256 public milestoneBonusRate = 700;          // 7.00% APY equivalent
    uint256 public constant MILESTONE_PERIOD = 90 days;
    uint256 public constant QUARTERLY_BONUS_BPS = 175; // +1.75% flat per 90 days

    mapping(address => uint256) public stakedBalanceOf;
    mapping(address => uint256) public userStakeTime;
    mapping(address => uint256) public lastMilestoneTimestamp;
    mapping(address => uint256) public accruedRewards;

    constructor(address _crecyToken, address initialAdmin) Ownable(initialAdmin) {
        require(_crecyToken != address(0) && initialAdmin != address(0), "Zero address");
        crecyToken = IERC20(_crecyToken);
        _grantRole(DEFAULT_ADMIN_ROLE, initialAdmin);
        _grantRole(REWARD_DISTRIBUTOR_ROLE, initialAdmin);
    }

    function pendingRewards(address account) public view returns (uint256) {
        uint256 staked = stakedBalanceOf[account];
        if (staked == 0) return accruedRewards[account];

        uint256 elapsedBase = block.timestamp - userStakeTime[account];
        uint256 liquidYield = (staked * baseYieldRate * elapsedBase) / (10_000 * 365 days);

        uint256 completedQuarters = (block.timestamp - lastMilestoneTimestamp[account]) / MILESTONE_PERIOD;
        uint256 milestoneYield = (staked * QUARTERLY_BONUS_BPS * completedQuarters) / 10_000;

        return accruedRewards[account] + liquidYield + milestoneYield;
    }

    function _settle(address account) internal {
        uint256 staked = stakedBalanceOf[account];
        if (staked > 0) {
            uint256 elapsedBase = block.timestamp - userStakeTime[account];
            uint256 liquidYield = (staked * baseYieldRate * elapsedBase) / (10_000 * 365 days);
            uint256 completedQuarters = (block.timestamp - lastMilestoneTimestamp[account]) / MILESTONE_PERIOD;
            uint256 milestoneYield = (staked * QUARTERLY_BONUS_BPS * completedQuarters) / 10_000;
            accruedRewards[account] += liquidYield + milestoneYield;
            if (completedQuarters > 0) {
                lastMilestoneTimestamp[account] += completedQuarters * MILESTONE_PERIOD;
            }
        } else {
            lastMilestoneTimestamp[account] = block.timestamp;
        }
        userStakeTime[account] = block.timestamp;
    }

    function stake(uint256 amount) external nonReentrant {
        require(amount > 0, "Zero amount");
        _settle(msg.sender);
        stakedBalanceOf[msg.sender] += amount;
        totalStaked += amount;
        crecyToken.safeTransferFrom(msg.sender, address(this), amount);
    }

    function unstake(uint256 amount) external nonReentrant {
        require(amount > 0 && stakedBalanceOf[msg.sender] >= amount, "Insufficient stake");
        _settle(msg.sender);
        lastMilestoneTimestamp[msg.sender] = block.timestamp;
        stakedBalanceOf[msg.sender] -= amount;
        totalStaked -= amount;
        crecyToken.safeTransfer(msg.sender, amount);
    }

    function claimRewards() external nonReentrant {
        _settle(msg.sender);
        uint256 reward = accruedRewards[msg.sender];
        require(reward > 0 && rewardReserve >= reward, "Insufficient reward");
        accruedRewards[msg.sender] = 0;
        rewardReserve -= reward;
        crecyToken.safeTransfer(msg.sender, reward);
    }

    function notifyRewardAmount(uint256 reward) external onlyRole(REWARD_DISTRIBUTOR_ROLE) {
        require(reward > 0, "Zero reward");
        rewardReserve += reward;
        crecyToken.safeTransferFrom(msg.sender, address(this), reward);
    }
}
