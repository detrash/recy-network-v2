// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {CRecy} from "../src/CRecy.sol";
import {cRECYStaking} from "../src/cRECYStaking.sol";
import {RecyReportAttributes} from "../src/RecyReportAttributes.sol";
import {RecyReportSvg} from "../src/RecyReportSvg.sol";
import {RecyReportData} from "../src/RecyReportData.sol";
import {RecyReport} from "../src/RecyReport.sol";
import {RecyReportFactory} from "../src/RecyReportFactory.sol";
import {RecyV4SwapAdapter} from "../src/RecyV4SwapAdapter.sol";
import {RecyTraceabilityCertificate} from "../src/RecyTraceabilityCertificate.sol";
import {DetrashDirectOTC} from "../src/DetrashDirectOTC.sol";
import {IPoolManager, IUnlockCallback, PoolKey, SwapParams} from "../src/interfaces/IUniswapV4Minimal.sol";

contract Batch3MockERC20 is ERC20 {
    uint8 private immutable _dec;

    constructor(string memory n, string memory s, uint8 dec) ERC20(n, s) {
        _dec = dec;
        _mint(msg.sender, 100_000_000 * (10 ** dec));
    }

    function decimals() public view override returns (uint8) {
        return _dec;
    }
}

contract Batch3MockV4PoolManager is IPoolManager {
    address private _syncedCurrency;
    uint256 private _syncedBalance;
    uint256 private _expectedIn;
    address private _expectedInToken;

    address public immutable usdc;
    address public immutable crecy;
    bool public shouldRevertSwap;

    constructor(address _usdc, address _crecy) {
        usdc = _usdc;
        crecy = _crecy;
    }

    function setShouldRevertSwap(bool flag) external {
        shouldRevertSwap = flag;
    }

    function initialize(PoolKey memory, uint160) external pure override returns (int24) {
        return 0;
    }

    function unlock(bytes calldata data) external override returns (bytes memory res) {
        res = IUnlockCallback(msg.sender).unlockCallback(data);
        require(_expectedIn == 0, "CurrencyNotSettled");
    }

    function swap(PoolKey memory key, SwapParams memory params, bytes calldata)
        external
        override
        returns (int256 swapDelta)
    {
        require(!shouldRevertSwap, "MockPoolPaused");
        address tokenIn = params.zeroForOne ? key.currency0 : key.currency1;
        uint256 amtIn;
        uint256 amtOut;

        // 1 USDC (1e6) = 20 cRECY (20e18) => $0.05/cRECY
        if (params.amountSpecified < 0) {
            amtIn = uint256(-params.amountSpecified);
            amtOut = tokenIn == usdc ? amtIn * 20 * 1e12 : amtIn / (20 * 1e12);
        } else {
            amtOut = uint256(params.amountSpecified);
            amtIn = tokenIn == usdc ? amtOut / (20 * 1e12) : amtOut * 20 * 1e12;
        }

        _expectedIn = amtIn;
        _expectedInToken = tokenIn;

        int128 d0 = params.zeroForOne ? -int128(uint128(amtIn)) : int128(uint128(amtOut));
        int128 d1 = params.zeroForOne ? int128(uint128(amtOut)) : -int128(uint128(amtIn));

        assembly ("memory-safe") {
            swapDelta := or(shl(128, d0), and(sub(shl(128, 1), 1), d1))
        }
    }

    function sync(address currency) external override {
        _syncedCurrency = currency;
        _syncedBalance = IERC20(currency).balanceOf(address(this));
    }

    function settle() external payable override returns (uint256 paid) {
        require(_syncedCurrency == _expectedInToken, "Wrong settle currency");
        paid = IERC20(_syncedCurrency).balanceOf(address(this)) - _syncedBalance;
        require(paid == _expectedIn, "Insufficient settle");
        _expectedIn = 0;
    }

    function take(address currency, address to, uint256 amount) external override {
        require(IERC20(currency).transfer(to, amount), "Take failed");
    }
}

contract MaliciousPermitTarget {
    bool public permitCalled;

    function permit(address, address, uint256, uint256, uint8, bytes32, bytes32) external {
        permitCalled = true;
    }
}

contract Batch3SecurityAuditTest is Test {
    CRecy public crecy;
    Batch3MockERC20 public usdc;
    cRECYStaking public staking;
    RecyReportFactory public factory;
    RecyReport public report;
    Batch3MockV4PoolManager public poolManager;
    RecyV4SwapAdapter public v4Adapter;
    RecyTraceabilityCertificate public cert;
    DetrashDirectOTC public otc;

    address public admin = address(this);
    address public adminWallet = address(0xAD01);
    address public generator = address(0x1001);
    address public recycler = address(0x2002);
    address public reportAuditor = address(0x3003);
    address public independentAuditor = address(0x4004);
    address public buyer = address(0x5005);
    address public treasuryOperator = address(0x6006);

    bytes32 public constant TERMS_HASH = keccak256("RECY_OTC_TERMS_V1");

    function setUp() public {
        vm.warp(1_760_000_000);

        crecy = new CRecy(admin, 5_000_000 * 1e18);
        usdc = new Batch3MockERC20("USD Coin", "USDC", 6);
        staking = new cRECYStaking(address(crecy), admin);

        RecyReportAttributes attributes = new RecyReportAttributes();
        RecyReportSvg svg = new RecyReportSvg();
        RecyReportData data = new RecyReportData(address(attributes), address(svg));
        RecyReport impl = new RecyReport();
        factory = new RecyReportFactory(address(impl), address(data));

        address proxyAddr = factory.deployProxy(
            "Genesis Cluster", "RECY-01", address(crecy), adminWallet, uint64(7 days), 60, 10, 20, 10
        );
        report = RecyReport(proxyAddr);
        factory.grantRecyclerRole(proxyAddr, recycler);
        factory.grantAuditorRole(proxyAddr, reportAuditor);

        // Uniswap V4 PoolManager & Adapter
        poolManager = new Batch3MockV4PoolManager(address(usdc), address(crecy));
        usdc.transfer(address(poolManager), 1_000_000 * 1e6);
        crecy.transfer(address(poolManager), 2_000_000 * 1e18);

        v4Adapter = new RecyV4SwapAdapter(address(poolManager), address(0), admin);
        v4Adapter.registerV4Pool(address(crecy), address(usdc), 3000, 60, address(0));

        // Traceability Certificate Proxy
        RecyTraceabilityCertificate traceImpl = new RecyTraceabilityCertificate();
        bytes memory initData = abi.encodeCall(
            RecyTraceabilityCertificate.initialize,
            (
                admin,
                address(factory),
                address(usdc),
                address(crecy),
                address(v4Adapter),
                adminWallet,
                address(staking),
                3000,
                1, // Landfill = 1
                50 * 1e6, // 50 USDC flat
                RecyTraceabilityCertificate.SplitConfig({adminBps: 3000, auditorBps: 2000, buybackBps: 5000})
            )
        );
        cert = RecyTraceabilityCertificate(address(new ERC1967Proxy(address(traceImpl), initData)));

        // Grant AUDITOR_ROLE to generator, recycler, reportAuditor (to test conflict blocks), and independentAuditor
        cert.grantRole(cert.AUDITOR_ROLE(), generator);
        cert.grantRole(cert.AUDITOR_ROLE(), recycler);
        cert.grantRole(cert.AUDITOR_ROLE(), reportAuditor);
        cert.grantRole(cert.AUDITOR_ROLE(), independentAuditor);

        // Create & validate 1 report (1,000 kg recycled plastic)
        uint32[] memory mats = new uint32[](1);
        uint128[] memory amts = new uint128[](1);
        uint32[] memory rTypes = new uint32[](1);
        uint32[] memory rShapes = new uint32[](1);
        mats[0] = 1;
        amts[0] = 1_000_000_000; // 1,000 kg in mg
        rTypes[0] = 3;
        rShapes[0] = 1;

        vm.prank(recycler);
        report.mintRecyReportResult(
            generator, uint64(vm.getBlockTimestamp() - 1 days), 1_000_000_000, mats, amts, rTypes, rShapes, 3
        );
        vm.prank(reportAuditor);
        report.validateRecyReport(0);

        // Fund generator & buyer with USDC
        usdc.transfer(generator, 50_000 * 1e6);
        usdc.transfer(buyer, 50_000 * 1e6);

        // Deploy DetrashDirectOTC
        otc = new DetrashDirectOTC(address(crecy), admin, treasuryOperator, TERMS_HASH);
        otc.configurePaymentToken(address(usdc), true, 50 * 1e6, 50_000); // min 50 USDC, floor $0.05/cRECY
        crecy.approve(address(otc), 500_000 * 1e18);
    }

    function _singleReportRef() internal view returns (RecyTraceabilityCertificate.ReportRef[] memory refs) {
        refs = new RecyTraceabilityCertificate.ReportRef[](1);
        refs[0] = RecyTraceabilityCertificate.ReportRef({reportProxy: address(report), reportId: 0});
    }

    // --- B3-C01: minCRecyOut == 0 queues buyback USDC safely instead of swapping unprotected or trapping in staking ---
    function test_B3_C01_ZeroMinOutQueuesBuybackAndExecutesViaV4Adapter() public {
        RecyTraceabilityCertificate.ReportRef[] memory refs = _singleReportRef();
        uint64 endTs = uint64(vm.getBlockTimestamp());
        uint64 startTs = endTs - 2 days;

        vm.startPrank(generator);
        usdc.approve(address(cert), 50 * 1e6);
        cert.mintCertificate(startTs, endTs, refs, address(usdc), 0, 0, 0); // minCRecyOut == 0
        vm.stopPrank();

        // 50% of 50 USDC = 25 USDC must be queued in pendingBuybackUsdc, NOT sent to cRECYStaking
        assertEq(usdc.balanceOf(address(staking)), 0, "USDC trapped in cRECYStaking!");
        assertEq(cert.pendingBuybackUsdc(address(usdc)), 25 * 1e6);
        assertEq(usdc.balanceOf(adminWallet), 15 * 1e6);

        // Admin executes queued buyback through RecyV4SwapAdapter with strict slippage guard
        uint256 crecyOut = cert.executePendingBuyback(address(usdc), 25 * 1e6, 500 * 1e18);
        assertEq(crecyOut, 500 * 1e18);
        assertEq(cert.pendingBuybackUsdc(address(usdc)), 0);
        assertEq(usdc.allowance(address(cert), address(v4Adapter)), 0);

        // Sync directly into cRECYStaking rewardReserve
        uint256 synced = staking.syncRewardReserve();
        assertEq(synced, 500 * 1e18);
    }

    // --- B3-C01: Failed V4 buyback queues USDC cleanly; admin can sweep if needed ---
    function test_B3_C01_FailedBuybackQueuesInsteadOfTrappingInStaking() public {
        RecyTraceabilityCertificate.ReportRef[] memory refs = _singleReportRef();
        uint64 endTs = uint64(vm.getBlockTimestamp());
        uint64 startTs = endTs - 2 days;

        vm.startPrank(generator);
        usdc.approve(address(cert), 50 * 1e6);
        // Attacker passes impossible minCRecyOut to force catch branch
        cert.mintCertificate(startTs, endTs, refs, address(usdc), 0, 0, type(uint256).max);
        vm.stopPrank();

        assertEq(usdc.balanceOf(address(staking)), 0, "Failed buyback burned USDC in staking!");
        assertEq(cert.pendingBuybackUsdc(address(usdc)), 25 * 1e6);
        assertEq(usdc.allowance(address(cert), address(v4Adapter)), 0);

        // Escape hatch sweeps safely to adminWallet
        uint256 adminBefore = usdc.balanceOf(adminWallet);
        cert.sweepPendingBuybackToAdmin(address(usdc), 25 * 1e6);
        assertEq(usdc.balanceOf(adminWallet) - adminBefore, 25 * 1e6);
        assertEq(cert.pendingBuybackUsdc(address(usdc)), 0);
    }

    // --- Soulbound Enforcement: Certificates cannot be transferred away from cert.issuer ---
    function test_B3_Soulbound_TransferReverts() public {
        RecyTraceabilityCertificate.ReportRef[] memory refs = _singleReportRef();
        uint64 endTs = uint64(vm.getBlockTimestamp());
        uint64 startTs = endTs - 2 days;

        vm.startPrank(generator);
        usdc.approve(address(cert), 50 * 1e6);
        uint256 certId = cert.mintCertificate(startTs, endTs, refs, address(usdc), 0, 0, 500 * 1e18);

        vm.expectRevert(RecyTraceabilityCertificate.CertificateIsSoulbound.selector);
        cert.transferFrom(generator, buyer, certId);

        vm.expectRevert(RecyTraceabilityCertificate.CertificateIsSoulbound.selector);
        cert.safeTransferFrom(generator, buyer, certId);
        vm.stopPrank();

        assertEq(cert.ownerOf(certId), generator);
    }

    // --- B3-H01: Generator, Recycler, and Report Auditor are all blocked from validating the certificate ---
    function test_B3_H01_AllInvolvedReportActorsBlockedFromValidation() public {
        RecyTraceabilityCertificate.ReportRef[] memory refs = _singleReportRef();
        uint64 endTs = uint64(vm.getBlockTimestamp());
        uint64 startTs = endTs - 2 days;

        vm.startPrank(generator);
        usdc.approve(address(cert), 50 * 1e6);
        uint256 certId = cert.mintCertificate(startTs, endTs, refs, address(usdc), 0, 0, 500 * 1e18);
        vm.stopPrank();

        vm.prank(generator);
        vm.expectRevert(
            abi.encodeWithSelector(RecyTraceabilityCertificate.ConflictOfInterestAuditor.selector, certId, generator)
        );
        cert.validateCertificate(certId);

        vm.prank(recycler);
        vm.expectRevert(
            abi.encodeWithSelector(RecyTraceabilityCertificate.ConflictOfInterestAuditor.selector, certId, recycler)
        );
        cert.validateCertificate(certId);

        vm.prank(reportAuditor);
        vm.expectRevert(
            abi.encodeWithSelector(
                RecyTraceabilityCertificate.ConflictOfInterestAuditor.selector, certId, reportAuditor
            )
        );
        cert.validateCertificate(certId);

        // Independent 4th auditor succeeds and receives 20% escrow (10 USDC)
        vm.prank(independentAuditor);
        cert.validateCertificate(certId);
        assertEq(usdc.balanceOf(independentAuditor), 10 * 1e6);
    }

    // --- B3-H03: OTC createProposalWithPermit blocks unsupported token BEFORE calling permit() ---
    function test_B3_H03_OtcPermitBlocksUnsupportedTokenBeforeExternalCall() public {
        MaliciousPermitTarget target = new MaliciousPermitTarget();
        uint64 exp = uint64(vm.getBlockTimestamp() + 1 days);

        vm.prank(buyer);
        vm.expectRevert(DetrashDirectOTC.UnsupportedPaymentToken.selector);
        otc.createProposalWithPermit(
            address(target), 100 * 1e6, 1_000 * 1e18, exp, TERMS_HASH, bytes32(0), exp, 27, bytes32(0), bytes32(0)
        );

        assertFalse(target.permitCalled(), "Arbitrary external permit() was executed!");
    }

    // --- B3-H04 & B3-M01: Disabled token blocked on acceptProposal; floor rounds up; maxCrecy cap enforced ---
    function test_B3_H04_M01_OtcDisabledTokenCeilingFloorAndMaxCap() public {
        uint64 exp = uint64(vm.getBlockTimestamp() + 1 days);

        // 1. Floor price ceiling check: 1,000.00001 cRECY at 50_000 micro-USDC/cRECY requires 50_000_001 (ceil)
        uint256 slightlyOver1000 = 1_000 * 1e18 + 1e13;
        vm.startPrank(buyer);
        usdc.approve(address(otc), 500 * 1e6);
        vm.expectRevert(
            abi.encodeWithSelector(DetrashDirectOTC.BelowMinimumFloorPrice.selector, 50_000_000, 50_000_001)
        );
        otc.createProposal(address(usdc), 50_000_000, slightlyOver1000, exp, TERMS_HASH, bytes32(0));

        // 2. Valid proposal created while USDC is supported
        uint256 pid = otc.createProposal(address(usdc), 100 * 1e6, 2_000 * 1e18, exp, TERMS_HASH, bytes32(0));
        vm.stopPrank();

        // 3. Disabling USDC blocks settlement of previously pending proposal
        otc.configurePaymentToken(address(usdc), false, 50 * 1e6, 50_000);
        vm.prank(treasuryOperator);
        vm.expectRevert(DetrashDirectOTC.UnsupportedPaymentToken.selector);
        otc.acceptProposal(pid);

        // 4. Re-enable USDC, enforce maxCrecyPerProposal = 1,000 cRECY -> blocks oversized settlement
        otc.configurePaymentToken(address(usdc), true, 50 * 1e6, 50_000);
        otc.setMaxCrecyPerProposal(1_000 * 1e18);

        vm.prank(treasuryOperator);
        vm.expectRevert(
            abi.encodeWithSelector(DetrashDirectOTC.ExceedsMaxCrecyPerProposal.selector, 2_000 * 1e18, 1_000 * 1e18)
        );
        otc.acceptProposal(pid);

        // 5. Raise cap to 10,000 cRECY -> atomic DvP succeeds with 0 resting contract balance
        otc.setMaxCrecyPerProposal(10_000 * 1e18);
        vm.prank(treasuryOperator);
        otc.acceptProposal(pid);

        assertEq(crecy.balanceOf(buyer), 2_000 * 1e18);
        assertEq(usdc.balanceOf(address(otc)), 0);
        assertEq(crecy.balanceOf(address(otc)), 0);
    }
}
