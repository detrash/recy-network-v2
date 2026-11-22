// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {RecyReport} from "./RecyReport.sol";

/**
 * @title RecyReportFactory
 * @notice Owner-governed factory for deploying and administering official RecyReport UUPS proxy clusters.
 */
contract RecyReportFactory is Ownable2Step, ReentrancyGuard {
    /// @notice Active RecyReport implementation contract used for new proxy deployments
    address public implementation;

    /// @notice The RecyReportData contract address
    address public immutable dataContract;

    /// @notice Array of all deployed proxy addresses
    address[] public deployedProxies;

    /// @notice O(1) registry verifying whether a proxy was deployed by this factory
    mapping(address => bool) public isDeployedProxy;

    /// @notice Mapping from proxy name to proxy address
    mapping(string => address) public proxyByName;

    /// @notice Mapping from proxy address to proxy name
    mapping(address => string) public nameByProxy;

    /// @notice Array of all proxy names for enumeration
    string[] public proxyNames;

    /// @notice Events
    event ProxyDeployed(address indexed proxy, address indexed deployer, string indexed proxyName);
    event ImplementationUpdated(address indexed previousImplementation, address indexed newImplementation);
    event ProxyUpgraded(address indexed proxy, address indexed newImplementation, address indexed upgradedBy);
    event AuditorRoleGranted(address indexed proxy, address indexed auditor, address indexed grantedBy);
    event AuditorRoleRevoked(address indexed proxy, address indexed auditor, address indexed revokedBy);
    event RecyclerRoleGranted(address indexed proxy, address indexed recycler, address indexed grantedBy);
    event RecyclerRoleRevoked(address indexed proxy, address indexed recycler, address indexed revokedBy);
    event AdminRoleGranted(address indexed proxy, address indexed admin, address indexed grantedBy);
    event AdminRoleRevoked(address indexed proxy, address indexed admin, address indexed revokedBy);
    event EmergencyRoleGranted(address indexed proxy, address indexed emergency, address indexed grantedBy);
    event EmergencyRoleRevoked(address indexed proxy, address indexed emergency, address indexed revokedBy);
    event RecyclerFundUpdated(address indexed proxy, address indexed recycler, address indexed fundWallet);
    event AuditorFundUpdated(address indexed proxy, address indexed auditor, address indexed fundWallet);

    /// @notice Errors
    error InvalidImplementation();
    error InvalidDataContract();
    error InvalidTokenAddress();
    error InvalidProtocolAddress();
    error ProxyNameAlreadyExists();
    error InvalidProxyName();
    error ProxyNotFound();

    constructor(address _implementation, address _dataContract) Ownable(msg.sender) {
        if (_implementation == address(0) || _implementation.code.length == 0) revert InvalidImplementation();
        if (_dataContract == address(0) || _dataContract.code.length == 0) revert InvalidDataContract();

        implementation = _implementation;
        dataContract = _dataContract;
    }

    /**
     * @notice Updates the default implementation used for future deployProxy() calls.
     */
    function setImplementation(address _newImplementation) external onlyOwner {
        if (_newImplementation == address(0) || _newImplementation.code.length == 0) {
            revert InvalidImplementation();
        }
        address previous = implementation;
        implementation = _newImplementation;
        emit ImplementationUpdated(previous, _newImplementation);
    }

    /**
     * @notice Deploy a new official RecyReport proxy cluster (owner-only).
     */
    function deployProxy(
        string memory name,
        string memory symbol,
        address tokenAddress,
        address protocolAddress,
        uint64 unlockDelay,
        uint8 shareRecycler,
        uint8 shareValidator,
        uint8 shareGenerator,
        uint8 shareProtocol
    ) public nonReentrant onlyOwner returns (address proxy) {
        if (bytes(name).length == 0) revert InvalidProxyName();
        if (proxyByName[name] != address(0)) revert ProxyNameAlreadyExists();
        if (tokenAddress == address(0)) revert InvalidTokenAddress();
        if (protocolAddress == address(0)) revert InvalidProtocolAddress();

        bytes memory initializeCall = abi.encodeWithSelector(
            RecyReport.initialize.selector,
            name,
            symbol,
            tokenAddress,
            dataContract,
            protocolAddress,
            unlockDelay,
            shareRecycler,
            shareValidator,
            shareGenerator,
            shareProtocol
        );

        ERC1967Proxy newProxy = new ERC1967Proxy(implementation, initializeCall);
        proxy = address(newProxy);

        // Effects first (CEI): record registry state before external role grants
        deployedProxies.push(proxy);
        isDeployedProxy[proxy] = true;
        proxyByName[name] = proxy;
        nameByProxy[proxy] = name;
        proxyNames.push(name);

        emit ProxyDeployed(proxy, msg.sender, name);

        // Interactions: grant admin and operational roles to the deploying owner
        RecyReport report = RecyReport(proxy);
        report.grantRole(report.DEFAULT_ADMIN_ROLE(), msg.sender);
        report.grantRole(report.AUDITOR_ROLE(), msg.sender);
        report.grantRole(report.RECYCLER_ROLE(), msg.sender);
        report.grantRole(report.EMERGENCY_ROLE(), msg.sender);

        return proxy;
    }

    function getDeployedProxiesCount() external view returns (uint256 count) {
        return deployedProxies.length;
    }

    function getAllDeployedProxies() external view returns (address[] memory proxies) {
        return deployedProxies;
    }

    function getDeployedProxiesPaginated(uint256 offset, uint256 limit)
        external
        view
        returns (address[] memory proxies, uint256 total)
    {
        total = deployedProxies.length;

        if (offset >= total) {
            return (new address[](0), total);
        }

        uint256 end = offset + limit;
        if (end > total) {
            end = total;
        }

        uint256 length = end - offset;
        proxies = new address[](length);

        for (uint256 i = 0; i < length; i++) {
            proxies[i] = deployedProxies[offset + i];
        }

        return (proxies, total);
    }

    function getProxyByName(string memory proxyName) external view returns (address proxy) {
        proxy = proxyByName[proxyName];
        if (proxy == address(0)) revert ProxyNotFound();
        return proxy;
    }

    function getNameByProxy(address proxy) external view returns (string memory proxyName) {
        proxyName = nameByProxy[proxy];
        if (bytes(proxyName).length == 0) revert ProxyNotFound();
        return proxyName;
    }

    function proxyNameExists(string memory proxyName) external view returns (bool exists) {
        return proxyByName[proxyName] != address(0);
    }

    function getAllProxyNames() external view returns (string[] memory names) {
        return proxyNames;
    }

    function getProxyNamesCount() external view returns (uint256 count) {
        return proxyNames.length;
    }

    function grantAuditorRole(address proxy, address auditor) external onlyOwner {
        require(proxy != address(0), "Invalid proxy address");
        require(auditor != address(0), "Invalid auditor address");
        require(isDeployedProxy[proxy], "Proxy not deployed by factory");

        emit AuditorRoleGranted(proxy, auditor, msg.sender);
        RecyReport recyReport = RecyReport(proxy);
        recyReport.grantRole(recyReport.AUDITOR_ROLE(), auditor);
    }

    function revokeAuditorRole(address proxy, address auditor) external onlyOwner {
        require(proxy != address(0), "Invalid proxy address");
        require(auditor != address(0), "Invalid auditor address");
        require(isDeployedProxy[proxy], "Proxy not deployed by factory");

        emit AuditorRoleRevoked(proxy, auditor, msg.sender);
        RecyReport recyReport = RecyReport(proxy);
        recyReport.revokeRole(recyReport.AUDITOR_ROLE(), auditor);
    }

    function grantRecyclerRole(address proxy, address recycler) external onlyOwner {
        require(proxy != address(0), "Invalid proxy address");
        require(recycler != address(0), "Invalid recycler address");
        require(isDeployedProxy[proxy], "Proxy not deployed by factory");

        emit RecyclerRoleGranted(proxy, recycler, msg.sender);
        RecyReport recyReport = RecyReport(proxy);
        recyReport.grantRole(recyReport.RECYCLER_ROLE(), recycler);
    }

    function revokeRecyclerRole(address proxy, address recycler) external onlyOwner {
        require(proxy != address(0), "Invalid proxy address");
        require(recycler != address(0), "Invalid recycler address");
        require(isDeployedProxy[proxy], "Proxy not deployed by factory");

        emit RecyclerRoleRevoked(proxy, recycler, msg.sender);
        RecyReport recyReport = RecyReport(proxy);
        recyReport.revokeRole(recyReport.RECYCLER_ROLE(), recycler);
    }

    function grantAdminRole(address proxy, address admin) external onlyOwner {
        require(proxy != address(0), "Invalid proxy address");
        require(admin != address(0), "Invalid admin address");
        require(isDeployedProxy[proxy], "Proxy not deployed by factory");

        emit AdminRoleGranted(proxy, admin, msg.sender);
        RecyReport recyReport = RecyReport(proxy);
        recyReport.grantRole(recyReport.DEFAULT_ADMIN_ROLE(), admin);
    }

    function revokeAdminRole(address proxy, address admin) external onlyOwner {
        require(proxy != address(0), "Invalid proxy address");
        require(admin != address(0), "Invalid admin address");
        require(isDeployedProxy[proxy], "Proxy not deployed by factory");

        emit AdminRoleRevoked(proxy, admin, msg.sender);
        RecyReport recyReport = RecyReport(proxy);
        recyReport.revokeRole(recyReport.DEFAULT_ADMIN_ROLE(), admin);
    }

    function grantEmergencyRole(address proxy, address emergency) external onlyOwner {
        require(proxy != address(0), "Invalid proxy address");
        require(emergency != address(0), "Invalid emergency address");
        require(isDeployedProxy[proxy], "Proxy not deployed by factory");

        emit EmergencyRoleGranted(proxy, emergency, msg.sender);
        RecyReport recyReport = RecyReport(proxy);
        recyReport.grantRole(recyReport.EMERGENCY_ROLE(), emergency);
    }

    function revokeEmergencyRole(address proxy, address emergency) external onlyOwner {
        require(proxy != address(0), "Invalid proxy address");
        require(emergency != address(0), "Invalid emergency address");
        require(isDeployedProxy[proxy], "Proxy not deployed by factory");

        emit EmergencyRoleRevoked(proxy, emergency, msg.sender);
        RecyReport recyReport = RecyReport(proxy);
        recyReport.revokeRole(recyReport.EMERGENCY_ROLE(), emergency);
    }

    function hasAuditorRole(address proxy, address auditor) external view returns (bool hasRole) {
        require(proxy != address(0), "Invalid proxy address");
        require(isDeployedProxy[proxy], "Proxy not deployed by factory");

        RecyReport recyReport = RecyReport(proxy);
        return recyReport.hasRole(recyReport.AUDITOR_ROLE(), auditor);
    }

    function hasRecyclerRole(address proxy, address recycler) external view returns (bool hasRole) {
        require(proxy != address(0), "Invalid proxy address");
        require(isDeployedProxy[proxy], "Proxy not deployed by factory");

        RecyReport recyReport = RecyReport(proxy);
        return recyReport.hasRole(recyReport.RECYCLER_ROLE(), recycler);
    }

    function hasAdminRole(address proxy, address admin) external view returns (bool hasRole) {
        require(proxy != address(0), "Invalid proxy address");
        require(isDeployedProxy[proxy], "Proxy not deployed by factory");

        RecyReport recyReport = RecyReport(proxy);
        return recyReport.hasRole(recyReport.DEFAULT_ADMIN_ROLE(), admin);
    }

    function hasEmergencyRole(address proxy, address emergency) external view returns (bool hasRole) {
        require(proxy != address(0), "Invalid proxy address");
        require(isDeployedProxy[proxy], "Proxy not deployed by factory");

        RecyReport recyReport = RecyReport(proxy);
        return recyReport.hasRole(recyReport.EMERGENCY_ROLE(), emergency);
    }

    function upgradeProxy(address proxy, address newImplementation) external onlyOwner {
        require(isDeployedProxy[proxy], "Proxy not deployed by factory");
        if (newImplementation == address(0) || newImplementation.code.length == 0) {
            revert InvalidImplementation();
        }

        emit ProxyUpgraded(proxy, newImplementation, msg.sender);
        RecyReport(proxy).upgradeToAndCall(newImplementation, "");
    }

    function setRecyclerFund(address proxy, address recycler, address fundWallet) external onlyOwner {
        require(proxy != address(0), "Invalid proxy address");
        require(recycler != address(0), "Invalid recycler address");
        require(isDeployedProxy[proxy], "Proxy not deployed by factory");

        emit RecyclerFundUpdated(proxy, recycler, fundWallet);
        RecyReport(proxy).setFundsWallet(recycler, fundWallet);
    }

    function setAuditorFund(address proxy, address auditor, address fundWallet) external onlyOwner {
        require(proxy != address(0), "Invalid proxy address");
        require(auditor != address(0), "Invalid auditor address");
        require(isDeployedProxy[proxy], "Proxy not deployed by factory");

        emit AuditorFundUpdated(proxy, auditor, fundWallet);
        RecyReport(proxy).setFundsWallet(auditor, fundWallet);
    }
}
