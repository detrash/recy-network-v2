// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {Base64} from "@openzeppelin/contracts/utils/Base64.sol";

/**
 * @title RecyTraceabilityMetadata
 * @notice External linked library rendering plaintext JSON & base64 tokenURI for RecyTraceabilityCertificate.
 * @dev Offloads Strings/Base64 serialization to keep RecyTraceabilityCertificate well below EIP-170 (24,576 B).
 */
library RecyTraceabilityMetadata {
    using Strings for uint256;

    struct MetadataInput {
        uint256 certId;
        address issuer;
        uint64 periodStart;
        uint64 periodEnd;
        uint256 totalVolumeGrams;
        uint256 totalSustainableVolumeGrams;
        uint256 reportCount;
        bool isValidated;
        uint64 validatedAt;
        address validatedBy;
        address[] generators;
        address[] recyclers;
        address[] reportAuditors;
    }

    function buildTokenJson(MetadataInput memory m) public pure returns (string memory) {
        return string.concat(
            '{"name":"Recy Waste Traceability Certificate #',
            m.certId.toString(),
            '","description":"Soulbound on-chain waste traceability certificate issued by Recy Network.","attributes":[',
            _buildActorAttributesJson(m),
            ",",
            _buildMetricAttributesJson(m),
            "]}"
        );
    }

    function buildTokenUri(MetadataInput memory m) public pure returns (string memory) {
        return string.concat("data:application/json;base64,", Base64.encode(bytes(buildTokenJson(m))));
    }

    function _buildActorAttributesJson(MetadataInput memory m) private pure returns (string memory) {
        string memory certAuditor =
            m.validatedBy == address(0) ? "Pending" : Strings.toHexString(uint160(m.validatedBy), 20);

        return string.concat(
            '{"trait_type":"Issuer","value":"',
            Strings.toHexString(uint160(m.issuer), 20),
            '"},{"trait_type":"Generators","value":"',
            _formatAddressList(m.generators),
            '"},{"trait_type":"Recyclers","value":"',
            _formatAddressList(m.recyclers),
            '"},{"trait_type":"Report Auditors","value":"',
            _formatAddressList(m.reportAuditors),
            '"},{"trait_type":"Certificate Auditor","value":"',
            certAuditor,
            '"}'
        );
    }

    function _buildMetricAttributesJson(MetadataInput memory m) private pure returns (string memory) {
        string memory validationStatus = m.isValidated ? "Validated" : "Pending Independent Audit";
        return string.concat(
            '{"display_type":"date","trait_type":"Period Start","value":',
            uint256(m.periodStart).toString(),
            '},{"display_type":"date","trait_type":"Period End","value":',
            uint256(m.periodEnd).toString(),
            '},{"display_type":"number","trait_type":"Total Volume (g)","value":',
            m.totalVolumeGrams.toString(),
            '},{"display_type":"number","trait_type":"Sustainable Volume Ex-Landfill (g)","value":',
            m.totalSustainableVolumeGrams.toString(),
            '},{"display_type":"number","trait_type":"Consolidated Reports","value":',
            m.reportCount.toString(),
            '},{"trait_type":"Status","value":"',
            validationStatus,
            '"},{"display_type":"date","trait_type":"Validated At","value":',
            uint256(m.validatedAt).toString(),
            "}"
        );
    }

    function _formatAddressList(address[] memory list) private pure returns (string memory out) {
        uint256 len = list.length;
        for (uint256 i = 0; i < len;) {
            string memory hexAddr = Strings.toHexString(uint160(list[i]), 20);
            out = i == 0 ? hexAddr : string.concat(out, ",", hexAddr);
            unchecked {
                ++i;
            }
        }
    }
}
