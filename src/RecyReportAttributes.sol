// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";

contract RecyReportAttributes is Ownable2Step {
    string private constant DEFAULT_MATERIAL_SVG =
        "M264.4 95.01c-35.6-.06-80.2 11.19-124.2 34.09C96.27 152 61.45 182 41.01 211.3c-20.45 ";

    // Preserved original indices (0..10) for frontend/API compatibility
    string[] public material = [
        "Undefined",
        "Plastic",
        "Glass",
        "Metal",
        "Paper",
        "Glass",
        "E-Waste",
        "Organic",
        "Textile",
        "Hazardous",
        "Chemical"
    ];

    // Stores custom SVGs only for newly added or overridden material indices (saves >1M deploy gas)
    mapping(uint256 => string) private _customMaterialSvg;

    string[] public recycleType = [
        "Undefined",
        "Composting",
        "Incineration",
        "Mechanical Recycling",
        "Pyrolysis",
        "Refuse-Derived Fuel",
        "Thermal Recycling"
    ];

    string[] public recycleShape = ["Undefined", "Pellets", "Bricks"];

    string[] public disposalMethod = [
        "Undefined",
        "Landfill",
        "Incineration",
        "Recycling",
        "Composting",
        "Anaerobic Digestion",
        "Waste-to-Energy",
        "Plasma Gasification"
    ];

    event MaterialAdded(uint256 indexed index, string name);
    event RecycleTypeAdded(uint256 indexed index, string name);
    event DisposalMethodAdded(uint256 indexed index, string name);
    event RecycleShapeAdded(uint256 indexed index, string name);

    constructor() Ownable(msg.sender) {}

    function materialCount() external view returns (uint256) {
        return material.length;
    }

    function disposalMethodCount() external view returns (uint256) {
        return disposalMethod.length;
    }

    function getMaterial(uint256 index) public view returns (string memory) {
        require(index < material.length, "RecyReportAttributes.getMaterial: Invalid index");
        return material[index];
    }

    /// @notice ABI-compatible getter replacing the redundant storage array.
    function materialSvg(uint256 index) public view returns (string memory) {
        return getMaterialSvg(index);
    }

    function getMaterialSvg(uint256 index) public view returns (string memory) {
        require(index < material.length, "RecyReportAttributes.getMaterialSvg: Invalid index");
        string memory custom = _customMaterialSvg[index];
        return bytes(custom).length > 0 ? custom : DEFAULT_MATERIAL_SVG;
    }

    function getRecycleType(uint256 index) public view returns (string memory) {
        require(index < recycleType.length, "RecyReportAttributes.getRecycleType: Invalid index");
        return recycleType[index];
    }

    function getDisposalMethod(uint256 index) public view returns (string memory) {
        require(index < disposalMethod.length, "RecyReportAttributes.getDisposalMethod: Invalid index");
        return disposalMethod[index];
    }

    function getRecycleShape(uint256 index) public view returns (string memory) {
        require(index < recycleShape.length, "RecyReportAttributes.getRecycleShape: Invalid index");
        return recycleShape[index];
    }

    function getMaterials() public view returns (string[] memory) {
        return material;
    }

    function getMaterialSvgs() public view returns (string[] memory svgs) {
        uint256 len = material.length;
        svgs = new string[](len);
        for (uint256 i = 0; i < len; i++) {
            string memory custom = _customMaterialSvg[i];
            svgs[i] = bytes(custom).length > 0 ? custom : DEFAULT_MATERIAL_SVG;
        }
    }

    function getRecycleTypes() public view returns (string[] memory) {
        return recycleType;
    }

    function getDisposalMethods() public view returns (string[] memory) {
        return disposalMethod;
    }

    function getRecycleShapes() public view returns (string[] memory) {
        return recycleShape;
    }

    function addMaterial(string calldata newMaterial, string calldata newMaterialSvg) external onlyOwner {
        require(bytes(newMaterial).length > 0, "RecyReportAttributes.addMaterial: Material name cannot be empty");
        require(bytes(newMaterialSvg).length > 0, "RecyReportAttributes.addMaterial: Material SVG cannot be empty");
        uint256 idx = material.length;
        material.push(newMaterial);
        _customMaterialSvg[idx] = newMaterialSvg;
        emit MaterialAdded(idx, newMaterial);
    }

    function addRecycleType(string calldata newRecycleType) external onlyOwner {
        require(bytes(newRecycleType).length > 0, "RecyReportAttributes.addRecycleType: Empty value");
        uint256 idx = recycleType.length;
        recycleType.push(newRecycleType);
        emit RecycleTypeAdded(idx, newRecycleType);
    }

    function addDisposalMethod(string calldata newDisposalMethod) external onlyOwner {
        require(bytes(newDisposalMethod).length > 0, "RecyReportAttributes.addDisposalMethod: Empty value");
        uint256 idx = disposalMethod.length;
        disposalMethod.push(newDisposalMethod);
        emit DisposalMethodAdded(idx, newDisposalMethod);
    }

    function addRecycleShape(string calldata newRecycleShape) external onlyOwner {
        require(bytes(newRecycleShape).length > 0, "RecyReportAttributes.addRecycleShape: Empty value");
        uint256 idx = recycleShape.length;
        recycleShape.push(newRecycleShape);
        emit RecycleShapeAdded(idx, newRecycleShape);
    }
}
