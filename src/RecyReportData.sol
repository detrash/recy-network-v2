// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {Base64} from "@openzeppelin/contracts/utils/Base64.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {RecyReportAttributes} from "./RecyReportAttributes.sol";
import {RecyReportSvg} from "./RecyReportSvg.sol";
import {RecyConstants} from "./lib/RecyConstants.sol";
import {RecyTypes} from "./lib/RecyTypes.sol";
import {RecyErrors} from "./lib/RecyErrors.sol";

/**
 * @title RecyReportData
 * @notice Generates valid JSON metadata and dynamic SVG images for RecyReport NFTs.
 */
contract RecyReportData {
    RecyReportAttributes public immutable attributes;
    RecyReportSvg public immutable svg;

    constructor(address _attributesAddress, address _svgAddress) {
        if (
            _attributesAddress == address(0) || _attributesAddress.code.length == 0 || _svgAddress == address(0)
                || _svgAddress.code.length == 0
        ) {
            revert RecyErrors.AddressInvalid();
        }
        attributes = RecyReportAttributes(_attributesAddress);
        svg = RecyReportSvg(_svgAddress);
    }

    function tokenUriAttributes(
        uint256 _tokenId,
        uint8 _status,
        ERC20 _token,
        RecyTypes.RecyReward memory _reward,
        RecyTypes.RecyInfo memory _info,
        RecyTypes.RecyMaterials[] memory _materials
    ) external view returns (string memory) {
        string memory image = string.concat("data:image/svg+xml;base64,", Base64.encode(bytes(generateSvg(_status))));

        return string.concat(
            "data:application/json;base64,",
            Base64.encode(
                bytes(
                    string.concat(
                        '{"name":"RecyReport #',
                        Strings.toString(_tokenId),
                        '", "description":"This is a Recycle Report NFT that was obtained by recycling materials.","image":"',
                        image,
                        '","attributes": [',
                        generateStatusText(_status),
                        generateWasteAmountText(_info.wasteAmount),
                        generateRecycleDateText(_info.recycleDate),
                        generateValidationDateText(_info.validationDate),
                        generateRewardText(_status, _reward, _token),
                        generateMaterialsText(_materials),
                        "]}"
                    )
                )
            )
        );
    }

    function tokenJson(
        uint256 _tokenId,
        uint8 _status,
        ERC20 _token,
        RecyTypes.RecyReward memory _reward,
        RecyTypes.RecyInfo memory _info,
        RecyTypes.RecyMaterials[] memory _materials
    ) external view returns (string memory) {
        return string.concat(
            '{"name":"RecyReport #',
            Strings.toString(_tokenId),
            '", "description":"This is a Recycle Report NFT that was obtained by recycling materials.","attributes": [',
            generateStatusText(_status),
            generateWasteAmountText(_info.wasteAmount),
            generateRecycleDateText(_info.recycleDate),
            generateValidationDateText(_info.validationDate),
            generateRewardText(_status, _reward, _token),
            generateMaterialsText(_materials),
            "]}"
        );
    }

    function generateSvg(uint8 _status) internal view returns (string memory) {
        if (_status == RecyConstants.RECYCLE_CREATED) {
            return svg.getTrashcan();
        } else if (_status == RecyConstants.RECYCLE_COMPLETED) {
            return svg.getRecycle();
        } else if (_status == RecyConstants.RECYCLE_INVALIDATED) {
            return svg.getInvalidated();
        } else if (_status == RecyConstants.RECYCLE_VALIDATED || _status == RecyConstants.RECYCLE_REWARDED) {
            return svg.getCoins(_status);
        } else {
            revert RecyErrors.RecyReportInvalidStatus();
        }
    }

    function generateMaterialsText(RecyTypes.RecyMaterials[] memory _materials)
        internal
        view
        returns (string memory materials)
    {
        uint256 count = attributes.materialCount();
        for (uint256 i = 0; i < _materials.length; i++) {
            uint256 matIdx = _materials[i].material;
            string memory matName = matIdx < count ? attributes.getMaterial(matIdx) : "Unknown";
            materials = string.concat(
                materials,
                ',{"trait_type":"',
                matName,
                '","value":',
                Strings.toString(_materials[i].amountRecycled),
                ',"max_value":',
                Strings.toString(_materials[i].amountRecycled),
                "}"
            );
        }
    }

    function generateValidationDateText(uint256 _validationDate) internal pure returns (string memory validationDate) {
        if (_validationDate > 0) {
            validationDate = string.concat(
                ',{"display_type":"date","trait_type":"Validation Date","value":',
                Strings.toString(_validationDate),
                "}"
            );
        }
    }

    function generateRecycleDateText(uint256 _recycleDate) internal pure returns (string memory recycleDate) {
        if (_recycleDate > 0) {
            recycleDate = string.concat(
                ',{"display_type":"date","trait_type":"Recycle Date","value":', Strings.toString(_recycleDate), "}"
            );
        }
    }

    function generateWasteAmountText(uint256 _wasteAmount) internal pure returns (string memory wasteAmount) {
        if (_wasteAmount > 0) {
            wasteAmount =
                string.concat(',{"trait_type":"Waste Amount (mg)","value":', Strings.toString(_wasteAmount), "}");
        }
    }

    function generateRewardText(uint8 _status, RecyTypes.RecyReward memory _reward, ERC20 _token)
        internal
        view
        returns (string memory reward)
    {
        if (_status == RecyConstants.RECYCLE_VALIDATED || _status == RecyConstants.RECYCLE_REWARDED) {
            uint256 rewardPaid = _status == RecyConstants.RECYCLE_REWARDED ? _reward.rewardAmount : 0;
            reward = string.concat(
                ',{"trait_type":"Reward Claimed","value":',
                Strings.toString(rewardPaid / RecyConstants.ONE_E18),
                ',"max_value":',
                Strings.toString(_reward.rewardAmount / RecyConstants.ONE_E18),
                '},{"trait_type":"Reward Token","value":"',
                _token.symbol(),
                '"},{"display_type":"date","trait_type":"Reward Unlock Date","value":',
                Strings.toString(_reward.rewardUnlockDate),
                "}"
            );
        }
    }

    function generateStatusText(uint8 _status) internal pure returns (string memory status) {
        status = string.concat('{"trait_type":"Status","value":"', getStatus(_status), '"}');
    }

    function getStatus(uint8 _status) internal pure returns (string memory) {
        if (_status == RecyConstants.RECYCLE_CREATED) {
            return "Created";
        } else if (_status == RecyConstants.RECYCLE_COMPLETED) {
            return "Completed";
        } else if (_status == RecyConstants.RECYCLE_VALIDATED) {
            return "Validated";
        } else if (_status == RecyConstants.RECYCLE_REWARDED) {
            return "Rewarded";
        } else if (_status == RecyConstants.RECYCLE_INVALIDATED) {
            return "Invalidated";
        } else {
            revert RecyErrors.RecyReportInvalidStatus();
        }
    }
}
