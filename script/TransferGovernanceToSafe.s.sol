// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";

interface IAccessControlMinimal {
    function DEFAULT_ADMIN_ROLE() external view returns (bytes32);
    function hasRole(bytes32 role, address account) external view returns (bool);
    function grantRole(bytes32 role, address account) external;
    function renounceRole(bytes32 role, address callerConfirmation) external;
}

interface IOwnable2StepMinimal {
    function owner() external view returns (address);
    function transferOwnership(address newOwner) external;
}

/**
 * @title TransferGovernanceToSafe
 * @notice Idempotently transfers every Recy Network AccessControl role and Ownable2Step ownership
 *         from the deployer EOA to a deployed Gnosis Safe multisig.
 * @dev Required env vars:
 *      - MAINNET_SAFE_MULTISIG: Deployed Safe contract address (must have code.length > 0)
 *      - DEPLOYMENT_MANIFEST (optional): defaults to "./deployments/recy-eth-mainnet-1.json"
 */
contract TransferGovernanceToSafe is Script {
    bytes32 private constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    bytes32 private constant MINTER_ROLE = keccak256("MINTER_ROLE");
    bytes32 private constant REWARD_DISTRIBUTOR_ROLE = keccak256("REWARD_DISTRIBUTOR_ROLE");
    bytes32 private constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 private constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");
    bytes32 private constant AUDITOR_ROLE = keccak256("AUDITOR_ROLE");
    bytes32 private constant RECYCLER_ROLE = keccak256("RECYCLER_ROLE");
    bytes32 private constant EMERGENCY_ROLE = keccak256("EMERGENCY_ROLE");

    function run() external {
        address safe = vm.envAddress("MAINNET_SAFE_MULTISIG");
        require(safe != address(0) && safe.code.length > 0, "MAINNET_SAFE_MULTISIG must be a deployed contract");

        string memory manifestPath = vm.envOr("DEPLOYMENT_MANIFEST", string("./deployments/recy-eth-mainnet-1.json"));
        string memory json = vm.readFile(manifestPath);

        address attributes = vm.parseJsonAddress(json, ".1_RecyReportAttributes");
        address factory = vm.parseJsonAddress(json, ".5_RecyReportFactory");
        address crecy = vm.parseJsonAddress(json, ".6_cRECYToken");
        address staking = vm.parseJsonAddress(json, ".7_cRECYStaking");
        address locking = vm.parseJsonAddress(json, ".8_cRECYLocking");
        address certificate = vm.parseJsonAddress(json, ".9_ImpactInvestmentCertificate");
        address distribution = vm.parseJsonAddress(json, ".10_RecyDistribution");
        address genesisReport = vm.parseJsonAddress(json, ".GenesisRecyReportProxy");
        address v4Adapter = vm.parseJsonAddress(json, ".RecyV4SwapAdapter");
        address traceProxy = vm.parseJsonAddress(json, ".TraceabilityCertProxy");
        address otc = vm.parseJsonAddress(json, ".DetrashDirectOTC");

        vm.startBroadcast();
        (, address deployer,) = vm.readCallers();
        require(deployer != safe, "Deployer cannot equal Safe");

        // --- 1. AccessControl Contracts (grant Safe first, then renounce deployer) ---
        _handoverCRecy(crecy, deployer, safe);
        _handoverStaking(staking, deployer, safe);
        _handoverRecyCertificate(certificate, deployer, safe);
        _handoverDefaultAdminOnly(locking, deployer, safe);
        _handoverTraceabilityCert(traceProxy, deployer, safe);
        _handoverGenesisReport(genesisReport, deployer, safe);

        // --- 2. Ownable2Step Contracts (Safe must execute acceptOwnership() on each) ---
        _initiateTwoStepTransfer(attributes, deployer, safe);
        _initiateTwoStepTransfer(factory, deployer, safe);
        _initiateTwoStepTransfer(distribution, deployer, safe);
        _initiateTwoStepTransfer(v4Adapter, deployer, safe);
        _initiateTwoStepTransfer(otc, deployer, safe);

        vm.stopBroadcast();

        console2.log("=== Governance Handover Broadcast Complete ===");
        console2.log("Target Safe Multisig :", safe);
        console2.log("ACTION REQUIRED IN SAFE TRANSACTION BUILDER: call acceptOwnership() on:");
        console2.log("  1. RecyReportAttributes :", attributes);
        console2.log("  2. RecyReportFactory    :", factory);
        console2.log("  3. RecyDistribution     :", distribution);
        console2.log("  4. RecyV4SwapAdapter    :", v4Adapter);
        console2.log("  5. DetrashDirectOTC     :", otc);
    }

    function _handoverCRecy(address target, address deployer, address safe) internal {
        IAccessControlMinimal ac = IAccessControlMinimal(target);
        bytes32 adminRole = ac.DEFAULT_ADMIN_ROLE();
        _grantIfMissing(ac, adminRole, safe);
        _grantIfMissing(ac, PAUSER_ROLE, safe);
        // Deployer must never retain MINTER_ROLE or PAUSER_ROLE on Mainnet
        _renounceIfHeld(ac, MINTER_ROLE, deployer);
        _renounceIfHeld(ac, PAUSER_ROLE, deployer);
        _renounceIfHeld(ac, adminRole, deployer);
    }

    function _handoverStaking(address target, address deployer, address safe) internal {
        IAccessControlMinimal ac = IAccessControlMinimal(target);
        bytes32 adminRole = ac.DEFAULT_ADMIN_ROLE();
        _grantIfMissing(ac, adminRole, safe);
        _grantIfMissing(ac, REWARD_DISTRIBUTOR_ROLE, safe);
        _renounceIfHeld(ac, REWARD_DISTRIBUTOR_ROLE, deployer);
        _renounceIfHeld(ac, adminRole, deployer);
    }

    function _handoverRecyCertificate(address target, address deployer, address safe) internal {
        IAccessControlMinimal ac = IAccessControlMinimal(target);
        bytes32 adminRole = ac.DEFAULT_ADMIN_ROLE();
        _grantIfMissing(ac, adminRole, safe);
        _grantIfMissing(ac, MINTER_ROLE, safe);
        _renounceIfHeld(ac, MINTER_ROLE, deployer);
        _renounceIfHeld(ac, adminRole, deployer);
    }

    function _handoverDefaultAdminOnly(address target, address deployer, address safe) internal {
        IAccessControlMinimal ac = IAccessControlMinimal(target);
        bytes32 adminRole = ac.DEFAULT_ADMIN_ROLE();
        _grantIfMissing(ac, adminRole, safe);
        _renounceIfHeld(ac, adminRole, deployer);
    }

    function _handoverTraceabilityCert(address target, address deployer, address safe) internal {
        IAccessControlMinimal ac = IAccessControlMinimal(target);
        bytes32 adminRole = ac.DEFAULT_ADMIN_ROLE();
        _grantIfMissing(ac, adminRole, safe);
        _grantIfMissing(ac, ADMIN_ROLE, safe);
        _grantIfMissing(ac, UPGRADER_ROLE, safe);
        _renounceIfHeld(ac, UPGRADER_ROLE, deployer);
        _renounceIfHeld(ac, ADMIN_ROLE, deployer);
        _renounceIfHeld(ac, adminRole, deployer);
    }

    function _handoverGenesisReport(address target, address deployer, address safe) internal {
        IAccessControlMinimal ac = IAccessControlMinimal(target);
        bytes32 adminRole = ac.DEFAULT_ADMIN_ROLE();
        _grantIfMissing(ac, adminRole, safe);
        _grantIfMissing(ac, EMERGENCY_ROLE, safe);
        _renounceIfHeld(ac, AUDITOR_ROLE, deployer);
        _renounceIfHeld(ac, RECYCLER_ROLE, deployer);
        _renounceIfHeld(ac, EMERGENCY_ROLE, deployer);
        _renounceIfHeld(ac, adminRole, deployer);
    }

    function _grantIfMissing(IAccessControlMinimal ac, bytes32 role, address account) internal {
        if (!ac.hasRole(role, account)) {
            ac.grantRole(role, account);
        }
    }

    function _renounceIfHeld(IAccessControlMinimal ac, bytes32 role, address account) internal {
        if (ac.hasRole(role, account)) {
            ac.renounceRole(role, account);
        }
    }

    function _initiateTwoStepTransfer(address target, address deployer, address safe) internal {
        IOwnable2StepMinimal ownable = IOwnable2StepMinimal(target);
        if (ownable.owner() == deployer) {
            ownable.transferOwnership(safe);
        }
    }
}
