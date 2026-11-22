// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {IERC721Receiver} from "@openzeppelin/contracts/token/ERC721/IERC721Receiver.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {CRecy} from "../src/CRecy.sol";
import {RecyReportAttributes} from "../src/RecyReportAttributes.sol";
import {RecyReportSvg} from "../src/RecyReportSvg.sol";
import {RecyReportData} from "../src/RecyReportData.sol";
import {RecyReport} from "../src/RecyReport.sol";
import {RecyReportFactory} from "../src/RecyReportFactory.sol";
import {RecyConstants} from "../src/lib/RecyConstants.sol";
import {RecyErrors} from "../src/lib/RecyErrors.sol";

contract ReentrantReportReceiver is IERC721Receiver {
    RecyReport public immutable report;

    uint128 public observedNextId;
    uint8 public observedStatus;
    address public observedGenerator;
    bool public reentrantMintReverted;

    constructor(RecyReport _report) {
        report = _report;
    }

    function onERC721Received(
        address,
        address,
        uint256 tokenId,
        bytes calldata
    ) external override returns (bytes4) {
        observedNextId = report.nftNextId();
        observedStatus = report.status(tokenId);
        observedGenerator = report.reportGenerator(tokenId);

        try report.mintRecyReport() {
            reentrantMintReverted = false;
        } catch {
            reentrantMintReverted = true;
        }

        return IERC721Receiver.onERC721Received.selector;
    }
}

contract Batch2ASecurityAuditTest is Test {
    CRecy public crecy;
    RecyReportAttributes public attributes;
    RecyReportSvg public svg;
    RecyReportData public data;
    RecyReport public impl;
    RecyReportFactory public factory;
    RecyReport public report;

    address public admin = address(this);
    address public protocolWallet = address(0x9001);
    address public generator = address(0x1001);
    address public recycler = address(0x2002);
    address public auditor = address(0x3003);
    address public attacker = address(0xA11CE);
    address public buyer = address(0x4004);

    function setUp() public {
        crecy = new CRecy(admin, 2_138_428 * 1e18);
        attributes = new RecyReportAttributes();
        svg = new RecyReportSvg();
        data = new RecyReportData(address(attributes), address(svg));
        impl = new RecyReport();
        factory = new RecyReportFactory(address(impl), address(data));

        address proxyAddr = factory.deployProxy(
            "Genesis Cluster",
            "RECY-01",
            address(crecy),
            protocolWallet,
            uint64(7 days),
            60,
            10,
            20,
            10
        );
        report = RecyReport(proxyAddr);

        factory.grantRecyclerRole(proxyAddr, recycler);
        factory.grantAuditorRole(proxyAddr, auditor);

        crecy.transfer(proxyAddr, 100_000 * 1e18);
    }

    function _singleMaterialArrays(uint32 matId, uint128 amt)
        internal
        pure
        returns (
            uint32[] memory mats,
            uint128[] memory amts,
            uint32[] memory rTypes,
            uint32[] memory rShapes
        )
    {
        mats = new uint32[](1);
        amts = new uint128[](1);
        rTypes = new uint32[](1);
        rShapes = new uint32[](1);
        mats[0] = matId;
        amts[0] = amt;
        rTypes[0] = 0;
        rShapes[0] = 0;
    }

    // --- B2A-C01: Unauthorized wallet cannot deploy factory-registered proxy ---
    function test_B2A_C01_UnauthorizedDeployProxyReverts() public {
        vm.prank(attacker);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, attacker));
        factory.deployProxy(
            "Fake Cluster",
            "FAKE",
            address(crecy),
            attacker,
            uint64(1 days),
            60,
            10,
            20,
            10
        );
    }

    // --- B2A-C02: setRecyReportResult blocks unminted IDs and overwrites after completion/validation/reward ---
    function test_B2A_C02_SetRecyReportResultCannotOverwriteOrUseUnminted() public {
        (uint32[] memory mats, uint128[] memory amts, uint32[] memory rTypes, uint32[] memory rShapes) =
            _singleMaterialArrays(1, 1_000_000_000);

        // 1. Unminted token ID reverts
        vm.prank(recycler);
        vm.expectRevert(RecyErrors.NftNotExists.selector);
        report.setRecyReportResult(999, uint64(vm.getBlockTimestamp()), 1_000_000_000, mats, amts, rTypes, rShapes, 1);

        // 2. Valid mint + populate + validate
        vm.prank(generator);
        report.mintRecyReport();

        vm.prank(recycler);
        report.setRecyReportResult(0, uint64(vm.getBlockTimestamp()), 1_000_000_000, mats, amts, rTypes, rShapes, 1);

        // 3. Cannot overwrite already-completed report
        vm.prank(recycler);
        vm.expectRevert(RecyReport.InvalidReportStatus.selector);
        report.setRecyReportResult(0, uint64(vm.getBlockTimestamp()), 1_000_000_000, mats, amts, rTypes, rShapes, 1);

        // 4. Cannot overwrite invalidated report
        vm.prank(auditor);
        report.invalidateRecyReport(0);

        vm.prank(recycler);
        vm.expectRevert(RecyReport.InvalidReportStatus.selector);
        report.setRecyReportResult(0, uint64(vm.getBlockTimestamp()), 1_000_000_000, mats, amts, rTypes, rShapes, 1);
    }

    // --- B2A-C03: _safeMint callback sees finalized state & cannot reenter ---
    function test_B2A_C03_SafeMintCallbackSeesFinalizedState() public {
        ReentrantReportReceiver receiver = new ReentrantReportReceiver(report);
        (uint32[] memory mats, uint128[] memory amts, uint32[] memory rTypes, uint32[] memory rShapes) =
            _singleMaterialArrays(1, 500_000_000);

        vm.prank(recycler);
        report.mintRecyReportResult(
            address(receiver),
            uint64(vm.getBlockTimestamp()),
            500_000_000,
            mats,
            amts,
            rTypes,
            rShapes,
            1
        );

        assertEq(receiver.observedNextId(), 1);
        assertEq(receiver.observedStatus(), RecyConstants.RECYCLE_COMPLETED);
        assertEq(receiver.observedGenerator(), address(receiver));
        assertTrue(receiver.reentrantMintReverted(), "Reentrant mint was not blocked");
    }

    // --- B2A-H01: Zero protocol address rejected; claim conserves 100% of reward (0 wei dust) ---
    function test_B2A_H01_ZeroProtocolAddressRejectedAndZeroDustLeak() public {
        vm.expectRevert(RecyReportFactory.InvalidProtocolAddress.selector);
        factory.deployProxy(
            "Zero Protocol",
            "ZPRO",
            address(crecy),
            address(0),
            uint64(7 days),
            60,
            10,
            20,
            10
        );

        // Mint, validate, warp past unlock delay, claim, verify exact balance conservation
        (uint32[] memory mats, uint128[] memory amts, uint32[] memory rTypes, uint32[] memory rShapes) =
            _singleMaterialArrays(1, 1_000_000_000);

        vm.prank(recycler);
        report.mintRecyReportResult(
            generator,
            uint64(vm.getBlockTimestamp()),
            1_000_000_000,
            mats,
            amts,
            rTypes,
            rShapes,
            1
        );

        vm.prank(auditor);
        report.validateRecyReport(0);

        uint256 proxyBalBefore = crecy.balanceOf(address(report));
        vm.warp(vm.getBlockTimestamp() + 7 days + 1);

        vm.prank(generator);
        report.claimRecyReportReward(0);

        uint256 paidTotal = crecy.balanceOf(generator)
            + crecy.balanceOf(recycler)
            + crecy.balanceOf(auditor)
            + crecy.balanceOf(protocolWallet);

        assertGt(paidTotal, 0, "Expected non-zero reward");
        assertEq(proxyBalBefore - crecy.balanceOf(address(report)), paidTotal, "Dust leaked in proxy");
        assertEq(report.rewardClaimed(), paidTotal, "rewardClaimed mismatch");
    }

    // --- B2A-H02: Separation of duties prevents self-validation ---
    function test_B2A_H02_SelfValidationBlocked() public {
        // Grant auditor role to recycler and generator to attempt self-validation
        factory.grantAuditorRole(address(report), recycler);
        factory.grantAuditorRole(address(report), generator);

        (uint32[] memory mats, uint128[] memory amts, uint32[] memory rTypes, uint32[] memory rShapes) =
            _singleMaterialArrays(1, 1_000_000_000);

        vm.prank(recycler);
        report.mintRecyReportResult(
            generator,
            uint64(vm.getBlockTimestamp()),
            1_000_000_000,
            mats,
            amts,
            rTypes,
            rShapes,
            1
        );

        vm.prank(recycler);
        vm.expectRevert(RecyReport.AuditorCannotBeRecycler.selector);
        report.validateRecyReport(0);

        vm.prank(generator);
        vm.expectRevert(RecyReport.AuditorCannotBeGenerator.selector);
        report.validateRecyReport(0);

        // Protocol fee wallet must NOT have admin or operational roles automatically
        assertFalse(report.hasRole(report.DEFAULT_ADMIN_ROLE(), protocolWallet));
        assertFalse(report.hasRole(report.AUDITOR_ROLE(), protocolWallet));
    }

    // --- B2A-H03: Waste amount mismatch and uint8 attribute overflow rejected ---
    function test_B2A_H03_WasteAmountMismatchAndOverflowRejected() public {
        (uint32[] memory mats, uint128[] memory amts, uint32[] memory rTypes, uint32[] memory rShapes) =
            _singleMaterialArrays(1, 500_000_000);

        // Mismatch: wasteAmount 1_000_000_000 vs sum(materialAmounts) 500_000_000
        vm.prank(recycler);
        vm.expectRevert(RecyReport.WasteAmountMismatch.selector);
        report.mintRecyReportResult(
            generator,
            uint64(vm.getBlockTimestamp()),
            1_000_000_000,
            mats,
            amts,
            rTypes,
            rShapes,
            1
        );

        // Attribute ID >= 256 (would silently truncate to 0 = Landfill)
        (uint32[] memory badMats, uint128[] memory badAmts, uint32[] memory bTypes, uint32[] memory bShapes) =
            _singleMaterialArrays(256, 500_000_000);

        vm.prank(recycler);
        vm.expectRevert(RecyReport.InvalidAttributeId.selector);
        report.mintRecyReportResult(
            generator,
            uint64(vm.getBlockTimestamp()),
            500_000_000,
            badMats,
            badAmts,
            bTypes,
            bShapes,
            1
        );
    }

    // --- B2A-M01: Transferring NFT does not hijack generator rewards or ESG attribution ---
    function test_B2A_M01_NftTransferPreservesOriginalGenerator() public {
        (uint32[] memory mats, uint128[] memory amts, uint32[] memory rTypes, uint32[] memory rShapes) =
            _singleMaterialArrays(1, 1_000_000_000);

        vm.prank(recycler);
        report.mintRecyReportResult(
            generator,
            uint64(vm.getBlockTimestamp()),
            1_000_000_000,
            mats,
            amts,
            rTypes,
            rShapes,
            1
        );

        vm.prank(auditor);
        report.validateRecyReport(0);

        // Generator transfers NFT to buyer
        vm.prank(generator);
        report.transferFrom(generator, buyer, 0);
        assertEq(report.ownerOf(0), buyer);

        // ESG attribution still points to original generator
        (address reportedGen,,,,,,,) = report.getReportDetails(0);
        assertEq(reportedGen, generator);

        // Reward payout still goes to original generator, not buyer
        vm.warp(vm.getBlockTimestamp() + 7 days + 1);
        vm.prank(buyer);
        report.claimRecyReportReward(0);

        assertGt(crecy.balanceOf(generator), 0);
        assertEq(crecy.balanceOf(buyer), 0);
    }

    // --- B2A-M02: Factory mutable implementation + Ownable2Step ---
    function test_B2A_M02_FactoryImplementationUpdateAndTwoStepOwnership() public {
        RecyReport implV2 = new RecyReport();
        factory.setImplementation(address(implV2));
        assertEq(factory.implementation(), address(implV2));

        address newSafe = address(0x5AFE);
        factory.transferOwnership(newSafe);
        assertEq(factory.owner(), admin); // Not transferred until accepted

        vm.prank(newSafe);
        factory.acceptOwnership();
        assertEq(factory.owner(), newSafe);
    }
}
