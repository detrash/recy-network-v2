// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {RecyCertificate} from "./RecyCertificate.sol";

/**
 * @title TimeLock / cRECYLocking (OpenZeppelin v5 Compatible)
 * @notice Whitepaper Section 3.1: Locks cRECY for 30-day compliance or 730-day (24-month) Certificate issuance.
 */
contract TimeLock is AccessControl, ReentrancyGuard {
    using SafeERC20 for IERC20;

    struct LockPosition {
        uint256 amount;
        uint256 unlockTimestamp;
        uint256 certificateTokenId;
        bool unlocked;
    }

    IERC20 public immutable crecyToken;
    RecyCertificate public immutable certificateContract;

    uint256 public minimumComplianceThreshold;
    uint256 public constant MINIMUM_COMPLIANCE_DURATION = 30 days;
    uint256 public constant CERTIFICATE_LOCK_DURATION = 730 days; // 24 months
    uint256 public constant MAX_LOCK_DURATION = 10 * 365 days;

    mapping(address => uint256) public lockedBalanceOf;
    mapping(address => LockPosition[]) private _userLocks;

    event Locked(
        address indexed account,
        uint256 indexed lockId,
        uint256 amount,
        uint256 unlockTimestamp,
        uint256 certificateTokenId
    );
    event Unlocked(address indexed account, uint256 indexed lockId, uint256 amount);
    event MinimumComplianceThresholdUpdated(uint256 previousThreshold, uint256 newThreshold);

    constructor(
        address _crecyToken,
        address _certificateContract,
        address initialAdmin,
        uint256 _minimumComplianceThreshold
    ) {
        require(
            _crecyToken != address(0) &&
            _certificateContract != address(0) &&
            initialAdmin != address(0),
            "Zero address"
        );
        crecyToken = IERC20(_crecyToken);
        certificateContract = RecyCertificate(_certificateContract);
        minimumComplianceThreshold = _minimumComplianceThreshold;
        _grantRole(DEFAULT_ADMIN_ROLE, initialAdmin);
    }

    function setMinimumComplianceThreshold(uint256 newThreshold) external onlyRole(DEFAULT_ADMIN_ROLE) {
        uint256 previous = minimumComplianceThreshold;
        minimumComplianceThreshold = newThreshold;
        emit MinimumComplianceThresholdUpdated(previous, newThreshold);
    }

    function lock(uint256 amount, uint256 durationSeconds) external nonReentrant returns (uint256 lockId) {
        require(
            amount > 0 &&
            durationSeconds >= MINIMUM_COMPLIANCE_DURATION &&
            durationSeconds <= MAX_LOCK_DURATION,
            "Invalid lock"
        );
        uint256 unlockTimestamp = block.timestamp + durationSeconds;
        lockId = _userLocks[msg.sender].length;

        // Effects first (CEI)
        _userLocks[msg.sender].push(
            LockPosition({
                amount: amount,
                unlockTimestamp: unlockTimestamp,
                certificateTokenId: 0,
                unlocked: false
            })
        );
        lockedBalanceOf[msg.sender] += amount;

        emit Locked(msg.sender, lockId, amount, unlockTimestamp, 0);

        crecyToken.safeTransferFrom(msg.sender, address(this), amount);
    }

    function lockForCertificate(uint256 amount, string calldata metadataUri)
        external
        nonReentrant
        returns (uint256 lockId, uint256 certificateTokenId)
    {
        require(amount >= minimumComplianceThreshold, "Below threshold");
        require(bytes(metadataUri).length > 0, "Empty URI");

        uint256 unlockTimestamp = block.timestamp + CERTIFICATE_LOCK_DURATION;
        lockId = _userLocks[msg.sender].length;
        uint256 expectedTokenId = certificateContract.nextTokenId();

        // Effects first (CEI): commit lock state before external transfer and ERC-721 safeMint callback
        _userLocks[msg.sender].push(
            LockPosition({
                amount: amount,
                unlockTimestamp: unlockTimestamp,
                certificateTokenId: expectedTokenId,
                unlocked: false
            })
        );
        lockedBalanceOf[msg.sender] += amount;

        emit Locked(msg.sender, lockId, amount, unlockTimestamp, expectedTokenId);

        crecyToken.safeTransferFrom(msg.sender, address(this), amount);

        certificateTokenId = certificateContract.safeMintFromLock(
            msg.sender,
            lockId,
            amount,
            unlockTimestamp,
            metadataUri
        );
        require(certificateTokenId == expectedTokenId, "Certificate ID mismatch");
    }

    function unlock(uint256 lockId) external nonReentrant {
        require(lockId < _userLocks[msg.sender].length, "Invalid lockId");
        LockPosition storage pos = _userLocks[msg.sender][lockId];
        require(!pos.unlocked && block.timestamp >= pos.unlockTimestamp, "Lock active");

        uint256 amount = pos.amount;
        pos.unlocked = true;
        lockedBalanceOf[msg.sender] -= amount;

        emit Unlocked(msg.sender, lockId, amount);

        crecyToken.safeTransfer(msg.sender, amount);
    }

    function getLockPosition(address account, uint256 lockId)
        external
        view
        returns (uint256 amount, uint256 unlockTimestamp, uint256 certificateTokenId, bool unlocked)
    {
        LockPosition memory pos = _userLocks[account][lockId];
        return (pos.amount, pos.unlockTimestamp, pos.certificateTokenId, pos.unlocked);
    }

    function getUserLockCount(address account) external view returns (uint256) {
        return _userLocks[account].length;
    }

    function isCompliant(address account) external view returns (bool) {
        return lockedBalanceOf[account] >= minimumComplianceThreshold;
    }
}
