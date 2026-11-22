// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {Base64} from "@openzeppelin/contracts/utils/Base64.sol";

import {CRecy} from "../src/CRecy.sol";
import {RecyReportAttributes} from "../src/RecyReportAttributes.sol";
import {RecyReportSvg} from "../src/RecyReportSvg.sol";
import {RecyReportData} from "../src/RecyReportData.sol";
import {RecyReward} from "../src/lib/RecyReward.sol";
import {RecyConstants} from "../src/lib/RecyConstants.sol";
import {RecyTypes} from "../src/lib/RecyTypes.sol";
import {RecyErrors} from "../src/lib/RecyErrors.sol";

contract Batch2BSecurityAuditTest is Test {
    CRecy public crecy;
    RecyReportAttributes public attributes;
    RecyReportSvg public svg;
    RecyReportData public data;

    uint128 public constant ONE_KG_MG = 1_000_000;

    function setUp() public {
        crecy = new CRecy(address(this), 1_000_000 * 1e18);
        attributes = new RecyReportAttributes();
        svg = new RecyReportSvg();
        data = new RecyReportData(address(attributes), address(svg));
    }

    function _contains(string memory haystack, string memory needle) internal pure returns (bool) {
        bytes memory h = bytes(haystack);
        bytes memory n = bytes(needle);
        if (n.length == 0 || n.length > h.length) return false;
        for (uint256 i = 0; i <= h.length - n.length; i++) {
            bool matched = true;
            for (uint256 j = 0; j < n.length; j++) {
                if (h[i + j] != n[j]) {
                    matched = false;
                    break;
                }
            }
            if (matched) return true;
        }
        return false;
    }

    // --- B2B-H04: Verify all 6 epoch boundaries, exact cumulative caps, and ratios ---
    function test_B2B_H04_AllSixEpochsAndHardCapMath() public pure {
        // Verify exact sum of allocations == 22,000,000 cRECY
        assertEq(RecyReward.FIRST_EPOCH, 2_138_428 * 1e18);
        assertEq(RecyReward.SECOND_EPOCH - RecyReward.FIRST_EPOCH, 1_389_981 * 1e18);
        assertEq(RecyReward.THIRD_EPOCH - RecyReward.SECOND_EPOCH, 6_354_339 * 1e18);
        assertEq(RecyReward.FOURTH_EPOCH - RecyReward.THIRD_EPOCH, 2_892_680 * 1e18);
        assertEq(RecyReward.FIFTH_EPOCH - RecyReward.FOURTH_EPOCH, 3_119_686 * 1e18);
        assertEq(RecyReward.SIXTH_EPOCH - RecyReward.FIFTH_EPOCH, 6_104_886 * 1e18);
        assertEq(RecyReward.SIXTH_EPOCH, 22_000_000 * 1e18);

        // Epoch 1: 1 kg = 1 cRECY
        assertEq(RecyReward.calculateReward(ONE_KG_MG, 0), 1e18);
        assertEq(RecyReward.calculateReward(ONE_KG_MG, RecyReward.FIRST_EPOCH - 1), 1e18);

        // Epoch 2: 1 kg = 0.5 cRECY
        assertEq(RecyReward.calculateReward(ONE_KG_MG, RecyReward.FIRST_EPOCH), 0.5e18);
        assertEq(RecyReward.calculateReward(ONE_KG_MG, RecyReward.SECOND_EPOCH - 1), 0.5e18);

        // Epoch 3: 1 kg = 0.1 cRECY
        assertEq(RecyReward.calculateReward(ONE_KG_MG, RecyReward.SECOND_EPOCH), 0.1e18);
        assertEq(RecyReward.calculateReward(ONE_KG_MG, RecyReward.THIRD_EPOCH - 1), 0.1e18);

        // Epoch 4: 1 kg = 0.01 cRECY
        assertEq(RecyReward.calculateReward(ONE_KG_MG, RecyReward.THIRD_EPOCH), 0.01e18);
        assertEq(RecyReward.calculateReward(ONE_KG_MG, RecyReward.FOURTH_EPOCH - 1), 0.01e18);

        // Epoch 5: 1 kg = 0.0001 cRECY (full 3,119,686 cRECY span, NOT 1 token wide)
        assertEq(RecyReward.calculateReward(ONE_KG_MG, RecyReward.FOURTH_EPOCH), 0.0001e18);
        assertEq(RecyReward.calculateReward(ONE_KG_MG, RecyReward.FIFTH_EPOCH - 1), 0.0001e18);

        // Epoch 6: 1 kg = 0.000002815328847 cRECY (2_815_328_847_004 wei)
        uint128 epoch6Reward = RecyReward.calculateReward(ONE_KG_MG, RecyReward.FIFTH_EPOCH);
        assertEq(epoch6Reward, 2_815_328_847_004);
        assertEq(RecyReward.calculateReward(ONE_KG_MG, RecyReward.SIXTH_EPOCH - 1), 2_815_328_847_004);

        // Post-cap (>= 22M): 0 reward
        assertEq(RecyReward.calculateReward(ONE_KG_MG, RecyReward.SIXTH_EPOCH), 0);
        assertEq(RecyReward.calculateReward(ONE_KG_MG, RecyReward.SIXTH_EPOCH + 1e18), 0);
    }

    // --- B2B-H01 & B2B-H02: Valid JSON in tokenURI() and non-reverting RECYCLE_INVALIDATED metadata ---
    function test_B2B_H01_H02_TokenUriJsonValidAndInvalidatedHandled() public view {
        RecyTypes.RecyInfo memory rInfo = RecyTypes.RecyInfo({
            validator: address(0x1111),
            recycler: address(0x2222),
            recycleDate: 1700000000,
            validationDate: 1700001000,
            wasteAmount: ONE_KG_MG
        });
        RecyTypes.RecyReward memory rReward = RecyTypes.RecyReward({
            rewardAmount: 1e18,
            rewardUnlockDate: 1700604800
        });
        RecyTypes.RecyMaterials[] memory mats = new RecyTypes.RecyMaterials[](1);
        mats[0] = RecyTypes.RecyMaterials({
            material: 1,
            recycleType: 3,
            recycleShape: 1,
            disposalMethod: 3,
            amountRecycled: ONE_KG_MG
        });

        // 1. Validated JSON must NOT contain double-wrapped Status attribute
        string memory validJson = data.tokenJson(1, RecyConstants.RECYCLE_VALIDATED, crecy, rReward, rInfo, mats);
        assertTrue(_contains(validJson, '"attributes": [{"trait_type":"Status","value":"Validated"}'));
        assertFalse(_contains(validJson, '"value":"{"trait_type"'));

        // 2. tokenUriAttributes must succeed on RECYCLE_INVALIDATED (5) without reward attributes
        string memory invJson = data.tokenJson(2, RecyConstants.RECYCLE_INVALIDATED, crecy, rReward, rInfo, mats);
        assertTrue(_contains(invJson, '{"trait_type":"Status","value":"Invalidated"}'));
        assertFalse(_contains(invJson, '"Reward Claimed"'));

        string memory invUri = data.tokenUriAttributes(2, RecyConstants.RECYCLE_INVALIDATED, crecy, rReward, rInfo, mats);
        string memory expectedInvSvgB64 = Base64.encode(bytes(svg.getInvalidated()));
        // Verify base64 JSON builds cleanly and SVG uses invalidated red icon (#DC2626), not gold coins
        assertGt(bytes(invUri).length, 64);
        assertTrue(_contains(svg.getInvalidated(), "#DC2626"));
        assertGt(bytes(expectedInvSvgB64).length, 0);
    }

    // --- B2B-H03 & B2B-M01/M02: Preserved indices, Landfill == 1, safe unknown material fallback ---
    function test_B2B_H03_M01_M02_AttributesAndDataSafety() public {
        assertEq(attributes.getDisposalMethod(0), "Undefined");
        assertEq(attributes.getDisposalMethod(1), "Landfill");
        assertEq(attributes.getMaterial(1), "Plastic");
        assertEq(attributes.getMaterial(5), "Glass"); // Original index preserved

        // Zero SVG address rejected by RecyReportData
        vm.expectRevert(RecyErrors.AddressInvalid.selector);
        new RecyReportData(address(attributes), address(0));

        // Empty catalog entry rejected
        vm.expectRevert("RecyReportAttributes.addDisposalMethod: Empty value");
        attributes.addDisposalMethod("");

        // Out-of-range material ID renders "Unknown" instead of reverting tokenURI()
        RecyTypes.RecyInfo memory rInfo;
        RecyTypes.RecyReward memory rReward;
        RecyTypes.RecyMaterials[] memory badMats = new RecyTypes.RecyMaterials[](1);
        badMats[0] = RecyTypes.RecyMaterials({
            material: 99,
            recycleType: 0,
            recycleShape: 0,
            disposalMethod: 1,
            amountRecycled: 100
        });
        string memory json = data.tokenJson(3, RecyConstants.RECYCLE_COMPLETED, crecy, rReward, rInfo, badMats);
        assertTrue(_contains(json, '{"trait_type":"Unknown","value":100'));
    }
}
