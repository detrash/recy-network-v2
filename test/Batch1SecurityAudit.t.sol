// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";

import {CRecy} from "../src/CRecy.sol";
import {cRECYStaking} from "../src/cRECYStaking.sol";
import {TimeLock} from "../src/TimeLock.sol";
import {RecyCertificate} from "../src/RecyCertificate.sol";
import {RecyDistribution} from "../src/RecyDistribution.sol";

contract MockReportContract {
    uint256 public rewardTotal;
    uint256 public rewardClaimed;

    function setRewards(uint256 total, uint256 claimed) external {
        rewardTotal = total;
        rewardClaimed = claimed;
    }
}

contract ReentrantCertReceiver is IERC721Receiver {
    TimeLock public immutable timeLock;
    RecyCertificate public immutable cert;

    bool public observedCompliantDuringCallback;
    uint256 public observedLockAmountDuringCallback;
    uint256 public observedCertIdInLockDuringCallback;
    string public observedTokenUriDuringCallback;
    uint256 public observedCertLockedAmountDuringCallback;
    bool public reentrantLockReverted;

    constructor(TimeLock _timeLock, RecyCertificate _cert) {
        timeLock = _timeLock;
        cert = _cert;
    }

    function executeLockForCert(uint256 amount, string calldata uri) external {
        timeLock.lockForCertificate(amount, uri);
    }

    function onERC721Received(
        address,
        address,
        uint256 tokenId,
        bytes calldata
    ) external override returns (bytes4) {
        // Verify read-only state is 100% populated during callback (B1-H02)
        observedCompliantDuringCallback = timeLock.isCompliant(address(this));
        (uint256 amt,, uint256 certId,) = timeLock.getLockPosition(address(this), 0);
        observedLockAmountDuringCallback = amt;
        observedCertIdInLockDuringCallback = certId;
        observedTokenUriDuringCallback = cert.tokenURI(tokenId);
        (, uint256 certAmt,,) = cert.certificateDetails(tokenId);
        observedCertLockedAmountDuringCallback = certAmt;

        // Verify reentrant call back into TimeLock is blocked
        try timeLock.lock(1 ether, 30 days) {
            reentrantLockReverted = false;
        } catch {
            reentrantLockReverted = true;
        }

        return IERC721Receiver.onERC721Received.selector;
    }
}

contract Batch1SecurityAuditTest is Test {
    CRecy public crecy;
    cRECYStaking public staking;
    RecyCertificate public cert;
    TimeLock public timeLock;
    RecyDistribution public dist;

    address public admin = address(this);
    address public attacker = address(0xA11CE);
    address public alice = address(0xB0B);

    function setUp() public {
        crecy = new CRecy(admin, 12_000_000 * 1e18);
        staking = new cRECYStaking(address(crecy), admin);
        cert = new RecyCertificate(admin, address(crecy));
        timeLock = new TimeLock(address(crecy), address(cert), admin, 1_000 * 1e18);
        dist = new RecyDistribution(address(crecy));

        crecy.setMinter(address(dist), true);
        cert.setLockingContract(address(timeLock));

        // Seed 500,000 cRECY reward reserve in staking
        crecy.approve(address(staking), 500_000 * 1e18);
        staking.notifyRewardAmount(500_000 * 1e18);
    }

    // --- B1-C01: Option B Per-Deposit Tranches defeats 1-wei milestone drain ---
    function test_B1_C01_OneWeiMilestoneDrainBlocked() public {
        crecy.transfer(attacker, 10_000_000 * 1e18 + 1);

        vm.startPrank(attacker);
        crecy.approve(address(staking), type(uint256).max);

        // Day 0: attacker stakes 1 wei
        staking.stake(1);

        // Day 90 minus 12 seconds: attacker deposits 10,000,000 cRECY
        vm.warp(vm.getBlockTimestamp() + 90 days - 12);
        staking.stake(10_000_000 * 1e18);

        // 1 block (12s) later: attacker tries to claim 1.75% (175,000 cRECY) on 10M
        vm.warp(vm.getBlockTimestamp() + 12);
        uint256 pending = staking.pendingRewards(attacker);
        vm.stopPrank();

        // Expected: only 12 seconds of 15% APY on 10M (~0.57 cRECY), NOT 175,000 cRECY!
        assertLt(pending, 1 * 1e18, "Attacker extracted illegitimate milestone bonus");
    }

    // --- B1-M03: LIFO unstake preserves older tranche's 90-day milestone ---
    function test_B1_M03_LifoUnstakePreservesOldMilestone() public {
        crecy.transfer(alice, 20_000 * 1e18);
        vm.startPrank(alice);
        crecy.approve(address(staking), type(uint256).max);

        // Day 0: Tranche 0 (10,000 cRECY)
        staking.stake(10_000 * 1e18);

        // Day 60: Tranche 1 (10,000 cRECY)
        vm.warp(vm.getBlockTimestamp() + 60 days);
        staking.stake(10_000 * 1e18);

        // Day 70: Alice unstakes 10,000 (removes Tranche 1 LIFO; Tranche 0 untouched)
        vm.warp(vm.getBlockTimestamp() + 10 days);
        staking.unstake(10_000 * 1e18);
        assertEq(staking.getUserTrancheCount(alice), 1);

        // Day 90: Tranche 0 completes 90 days and earns full 175 cRECY milestone bonus
        vm.warp(vm.getBlockTimestamp() + 20 days);
        uint256 pending = staking.pendingRewards(alice);
        vm.stopPrank();

        // 90d liquid on 10k (~369.86) + 10d liquid on 10k (~41.09) + 175 milestone = ~585.95 cRECY
        assertGt(pending, 580 * 1e18, "Older tranche lost its 90-day milestone bonus");
    }

    // --- B1-H01: Direct Uniswap V4 buyback transfer is synced and claimable ---
    function test_B1_H01_DirectV4BuybackSyncsToRewardReserve() public {
        uint256 reserveBefore = staking.rewardReserve();
        // Simulate Uniswap V4 swap transferring 25,000 cRECY directly to staking contract
        crecy.transfer(address(staking), 25_000 * 1e18);

        uint256 synced = staking.syncRewardReserve();
        assertEq(synced, 25_000 * 1e18);
        assertEq(staking.rewardReserve(), reserveBefore + 25_000 * 1e18);
    }

    // --- B1-H02: Read-only reentrancy eliminated during TimeLock + RecyCertificate mint ---
    function test_B1_H02_TimeLockAndCertificateStateFinalizedBeforeCallback() public {
        ReentrantCertReceiver receiver = new ReentrantCertReceiver(timeLock, cert);
        crecy.transfer(address(receiver), 5_000 * 1e18);

        vm.prank(address(receiver));
        crecy.approve(address(timeLock), 5_000 * 1e18);

        receiver.executeLockForCert(2_000 * 1e18, "ipfs://QmTestCert");

        assertTrue(receiver.observedCompliantDuringCallback(), "Not compliant during callback");
        assertEq(receiver.observedLockAmountDuringCallback(), 2_000 * 1e18);
        assertEq(receiver.observedCertIdInLockDuringCallback(), 1);
        assertEq(receiver.observedTokenUriDuringCallback(), "ipfs://QmTestCert");
        assertEq(receiver.observedCertLockedAmountDuringCallback(), 2_000 * 1e18);
        assertTrue(receiver.reentrantLockReverted(), "Reentrant lock did not revert");
    }

    // --- B1-M02: Rotating lockingContract revokes previous MINTER_ROLE ---
    function test_B1_M02_SetLockingContractRevokesOldMinter() public {
        address newLocking = address(0x9999);
        assertTrue(cert.hasRole(cert.MINTER_ROLE(), address(timeLock)));

        cert.setLockingContract(newLocking);
        assertFalse(cert.hasRole(cert.MINTER_ROLE(), address(timeLock)));
        assertTrue(cert.hasRole(cert.MINTER_ROLE(), newLocking));
    }

    // --- B1-M04: Unbounded lock duration rejected ---
    function test_B1_M04_ExcessiveLockDurationReverts() public {
        crecy.approve(address(timeLock), 1_000 * 1e18);
        vm.expectRevert("Invalid lock");
        timeLock.lock(1_000 * 1e18, 11 * 365 days);
    }

    // --- B1-H03: RecyDistribution O(1) lookup, pagination, and 22M cap clamping ---
    function test_B1_H03_DistributionPaginationAndCapClamping() public {
        MockReportContract r1 = new MockReportContract();
        MockReportContract r2 = new MockReportContract();
        dist.whitelistReportContract(address(r1));
        dist.whitelistReportContract(address(r2));

        // Request 15M total across r1 & r2, while only 10M remains under 22M hard cap
        r1.setRewards(6_000_000 * 1e18, 0);
        r2.setRewards(9_000_000 * 1e18, 0);

        dist.mintTokensToReportsRange(0, 2);

        assertEq(crecy.balanceOf(address(r1)), 6_000_000 * 1e18);
        assertEq(crecy.balanceOf(address(r2)), 4_000_000 * 1e18); // clamped cleanly at 22M cap
        assertEq(crecy.totalSupply(), crecy.MAX_SUPPLY());
    }
}
