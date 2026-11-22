// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

interface IRecyReportRewardView {
    function rewardTotal() external view returns (uint256);
    function rewardClaimed() external view returns (uint256);
}

interface ICRecyMintable {
    function balanceOf(address account) external view returns (uint256);
    function totalSupply() external view returns (uint256);
    function MAX_SUPPLY() external view returns (uint256);
    function mint(address to, uint256 amount) external;
}

contract RecyDistribution is Ownable2Step, ReentrancyGuard {
    ICRecyMintable public immutable token;

    /// @notice Array to track all registered report contracts
    address[] public reportContracts;

    /// @notice O(1) membership registry replacing linear scans
    mapping(address => bool) public isRegisteredReport;

    /// @notice Mapping to track total tokens minted to each report contract
    mapping(address => uint256) public totalMintedToReport;

    /// @notice Mapping to track blacklisted report contracts
    mapping(address => bool) public blacklistedReports;

    event TokensMinted(address indexed reportContract, uint256 amount);
    event ReportContractAdded(address indexed reportContract);
    event ReportContractBlacklisted(address indexed reportContract);
    event ReportContractWhitelisted(address indexed reportContract);

    constructor(address _token) Ownable(msg.sender) {
        require(_token != address(0) && _token.code.length > 0, "Invalid token contract");
        token = ICRecyMintable(_token);
    }

    function whitelistReportContract(address _reportContract) external onlyOwner {
        require(_reportContract != address(0) && _reportContract.code.length > 0, "Invalid report contract");

        if (!isRegisteredReport[_reportContract]) {
            isRegisteredReport[_reportContract] = true;
            reportContracts.push(_reportContract);
            emit ReportContractAdded(_reportContract);
        } else {
            blacklistedReports[_reportContract] = false;
        }

        emit ReportContractWhitelisted(_reportContract);
    }

    function blacklistReportContract(address _reportContract) external onlyOwner {
        require(_reportContract != address(0), "Zero address not allowed");
        require(isRegisteredReport[_reportContract], "Report contract not found");
        require(!blacklistedReports[_reportContract], "Report contract already blacklisted");

        blacklistedReports[_reportContract] = true;
        emit ReportContractBlacklisted(_reportContract);
    }

    function _remainingMintableSupply() internal view returns (uint256) {
        uint256 maxSup = token.MAX_SUPPLY();
        uint256 curSup = token.totalSupply();
        return maxSup > curSup ? maxSup - curSup : 0;
    }

    function _computeShortfall(address _reportContract) internal view returns (uint256) {
        IRecyReportRewardView report = IRecyReportRewardView(_reportContract);
        uint256 totalRewards = report.rewardTotal();
        uint256 claimedRewards = report.rewardClaimed();
        uint256 shouldHave = totalRewards > claimedRewards ? totalRewards - claimedRewards : 0;
        uint256 contractBalance = token.balanceOf(_reportContract);
        return shouldHave > contractBalance ? shouldHave - contractBalance : 0;
    }

    function calculateTokensToMint(address _reportContract) public view returns (uint256 tokensToMint) {
        require(isRegisteredReport[_reportContract], "Report contract not found");
        require(!blacklistedReports[_reportContract], "Report contract is blacklisted");

        uint256 shortfall = _computeShortfall(_reportContract);
        uint256 remaining = _remainingMintableSupply();
        tokensToMint = shortfall > remaining ? remaining : shortfall;
    }

    function mintTokensToReport(address _reportContract) external nonReentrant onlyOwner {
        uint256 tokensToMint = calculateTokensToMint(_reportContract);
        require(tokensToMint > 0, "No tokens need to be minted");

        // Effects first (CEI)
        totalMintedToReport[_reportContract] += tokensToMint;
        emit TokensMinted(_reportContract, tokensToMint);

        token.mint(_reportContract, tokensToMint);
    }

    function mintTokensToAllReports() external nonReentrant onlyOwner {
        _mintRange(0, reportContracts.length);
    }

    /**
     * @notice Paginated batch minting to keep gas strictly below Ethereum Mainnet EIP-7825 cap.
     */
    function mintTokensToReportsRange(uint256 startIndex, uint256 limit) external nonReentrant onlyOwner {
        require(startIndex < reportContracts.length, "Start out of bounds");
        uint256 endIndex = startIndex + limit;
        if (endIndex > reportContracts.length) {
            endIndex = reportContracts.length;
        }
        _mintRange(startIndex, endIndex);
    }

    function _mintRange(uint256 startIndex, uint256 endIndex) internal {
        uint256 totalMinted = 0;
        uint256 remaining = _remainingMintableSupply();

        for (uint256 i = startIndex; i < endIndex && remaining > 0; i++) {
            address reportContract = reportContracts[i];
            if (blacklistedReports[reportContract]) {
                continue;
            }

            uint256 shortfall = _computeShortfall(reportContract);
            uint256 tokensToMint = shortfall > remaining ? remaining : shortfall;

            if (tokensToMint > 0) {
                remaining -= tokensToMint;
                totalMintedToReport[reportContract] += tokensToMint;
                totalMinted += tokensToMint;
                emit TokensMinted(reportContract, tokensToMint);

                token.mint(reportContract, tokensToMint);
            }
        }

        require(totalMinted > 0, "No tokens needed to be minted");
    }

    function getAllReportContracts() external view returns (address[] memory) {
        return reportContracts;
    }

    function getActiveReportContracts() external view returns (address[] memory) {
        uint256 activeCount = 0;
        uint256 len = reportContracts.length;
        for (uint256 i = 0; i < len; i++) {
            if (!blacklistedReports[reportContracts[i]]) {
                activeCount++;
            }
        }

        address[] memory activeContracts = new address[](activeCount);
        uint256 index = 0;
        for (uint256 i = 0; i < len; i++) {
            if (!blacklistedReports[reportContracts[i]]) {
                activeContracts[index] = reportContracts[i];
                index++;
            }
        }
        return activeContracts;
    }

    function getReportContractCount() external view returns (uint256) {
        return reportContracts.length;
    }

    function getActiveReportContractCount() external view returns (uint256) {
        uint256 activeCount = 0;
        uint256 len = reportContracts.length;
        for (uint256 i = 0; i < len; i++) {
            if (!blacklistedReports[reportContracts[i]]) {
                activeCount++;
            }
        }
        return activeCount;
    }
}
