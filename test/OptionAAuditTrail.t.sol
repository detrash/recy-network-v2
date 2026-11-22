// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";

import {CRecy} from "../src/CRecy.sol";
import {cRECYStaking} from "../src/cRECYStaking.sol";
import {RecyReportAttributes} from "../src/RecyReportAttributes.sol";
import {RecyReportSvg} from "../src/RecyReportSvg.sol";
import {RecyReportData} from "../src/RecyReportData.sol";
import {RecyReport} from "../src/RecyReport.sol";
import {RecyReportFactory} from "../src/RecyReportFactory.sol";
import {RecyTraceabilityCertificate} from "../src/RecyTraceabilityCertificate.sol";

contract OptionAMockUSDC is ERC20 {
    constructor() ERC20("USD Coin", "USDC") {
        _mint(msg.sender, 1_000_000 * 1e6);
    }

    function decimals() public pure override returns (uint8) {
        return 6;
    }
}

contract OptionAAuditTrailTest is Test {
    CRecy public crecy;
    OptionAMockUSDC public usdc;
    cRECYStaking public staking;
    RecyReportFactory public factory;
    RecyReport public report;
    RecyTraceabilityCertificate public cert;

    address public adminWallet = address(0xAD01);
    address public generator = address(0x1001);
    address public recycler1 = address(0x2001);
    address public recycler2 = address(0x2002);
    address public reportAuditor = address(0x3003);
    address public certAuditor = address(0x4004);

    function setUp() public {
        vm.warp(1_760_000_000);

        crecy = new CRecy(address(this), 2_138_428 * 1e18);
        usdc = new OptionAMockUSDC();
        staking = new cRECYStaking(address(crecy), address(this));

        RecyReportAttributes attrs = new RecyReportAttributes();
        RecyReportSvg svg = new RecyReportSvg();
        RecyReportData data = new RecyReportData(address(attrs), address(svg));
        RecyReport impl = new RecyReport();
        factory = new RecyReportFactory(address(impl), address(data));

        address proxyAddr = factory.deployProxy(
            "Genesis Cluster", "RECY-01", address(crecy), adminWallet, uint64(7 days), 60, 10, 20, 10
        );
        report = RecyReport(proxyAddr);
        factory.grantRecyclerRole(proxyAddr, recycler1);
        factory.grantRecyclerRole(proxyAddr, recycler2);
        factory.grantAuditorRole(proxyAddr, reportAuditor);

        RecyTraceabilityCertificate traceImpl = new RecyTraceabilityCertificate();
        bytes memory initData = abi.encodeCall(
            RecyTraceabilityCertificate.initialize,
            (
                address(this),
                address(factory),
                address(usdc),
                address(crecy),
                address(0), // no router -> queues buyback cleanly
                adminWallet,
                address(staking),
                3000,
                1, // Landfill = 1
                50 * 1e6,
                RecyTraceabilityCertificate.SplitConfig({adminBps: 3000, auditorBps: 2000, buybackBps: 5000})
            )
        );
        cert = RecyTraceabilityCertificate(address(new ERC1967Proxy(address(traceImpl), initData)));
        cert.grantRole(cert.AUDITOR_ROLE(), certAuditor);

        _mintAndValidate(recycler1, 1, 1_000_000_000, 3); // 1,000 kg Plastic Recycling
        _mintAndValidate(recycler2, 4, 500_000_000, 1);   // 500 kg Paper Landfill

        usdc.transfer(generator, 1_000 * 1e6);
    }

    function _mintAndValidate(address recWallet, uint32 matId, uint128 mgAmt, uint32 disposalId) internal {
        uint32[] memory mats = new uint32[](1);
        uint128[] memory amts = new uint128[](1);
        uint32[] memory rTypes = new uint32[](1);
        uint32[] memory rShapes = new uint32[](1);
        mats[0] = matId;
        amts[0] = mgAmt;
        rTypes[0] = 3;
        rShapes[0] = 1;

        uint256 nextId = report.nftNextId();
        vm.prank(recWallet);
        report.mintRecyReportResult(
            generator, uint64(vm.getBlockTimestamp() - 1 days), mgAmt, mats, amts, rTypes, rShapes, disposalId
        );
        vm.prank(reportAuditor);
        report.validateRecyReport(nextId);
    }

    function _contains(string memory haystack, string memory needle) internal pure returns (bool) {
        bytes memory h = bytes(haystack);
        bytes memory n = bytes(needle);
        if (n.length == 0 || n.length > h.length) return false;
        for (uint256 i = 0; i <= h.length - n.length; i++) {
            bool ok = true;
            for (uint256 j = 0; j < n.length; j++) {
                if (h[i + j] != n[j]) {
                    ok = false;
                    break;
                }
            }
            if (ok) return true;
        }
        return false;
    }

    function test_OptionA_PlaintextAuditTrailAndMetadata() public {
        RecyTraceabilityCertificate.ReportRef[] memory refs = new RecyTraceabilityCertificate.ReportRef[](2);
        refs[0] = RecyTraceabilityCertificate.ReportRef({reportProxy: address(report), reportId: 0});
        refs[1] = RecyTraceabilityCertificate.ReportRef({reportProxy: address(report), reportId: 1});

        uint64 endTs = uint64(vm.getBlockTimestamp());
        uint64 startTs = endTs - 2 days;

        vm.startPrank(generator);
        usdc.approve(address(cert), 50 * 1e6);
        uint256 certId = cert.mintCertificate(startTs, endTs, refs, address(usdc), 0, 0, 0);
        vm.stopPrank();

        // 1. Plaintext per-report audit records
        RecyTraceabilityCertificate.ConsolidatedReportRecord[] memory records = cert.getCertificateReports(certId);
        assertEq(records.length, 2);
        assertEq(records[0].generator, generator);
        assertEq(records[0].recycler, recycler1);
        assertEq(records[0].reportAuditor, reportAuditor);
        assertEq(records[1].recycler, recycler2);
        assertEq(records[1].treatmentType, 1);

        // 2. Deduplicated actor lists (1 generator, 2 recyclers, 1 report auditor)
        (
            address issuer,
            address[] memory generators,
            address[] memory recyclers,
            address[] memory reportAuditors,
            address validatedByBefore
        ) = cert.getCertificateActors(certId);

        assertEq(issuer, generator);
        assertEq(generators.length, 1);
        assertEq(recyclers.length, 2);
        assertEq(reportAuditors.length, 1);
        assertEq(validatedByBefore, address(0));

        // 3. Validate by independent auditor & verify landfill exclusion + JSON metadata
        vm.prank(certAuditor);
        cert.validateCertificate(certId);

        (,,, uint256 totalVol, uint256 sustainableVol,,,,) = cert.getCertificate(certId);
        assertEq(totalVol, 1_500_000);
        assertEq(sustainableVol, 1_000_000);

        string memory json = cert.tokenJson(certId);
        assertTrue(_contains(json, Strings.toHexString(uint160(generator), 20)));
        assertTrue(_contains(json, Strings.toHexString(uint160(recycler1), 20)));
        assertTrue(_contains(json, Strings.toHexString(uint160(recycler2), 20)));
        assertTrue(_contains(json, Strings.toHexString(uint160(reportAuditor), 20)));
        assertTrue(_contains(json, Strings.toHexString(uint160(certAuditor), 20)));
        assertGt(bytes(cert.tokenURI(certId)).length, 128);
    }
}
