// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "forge-std/console2.sol";
import "../src/RecyReportAttributes.sol";
import "../src/RecyReportSvg.sol";
import "../src/RecyReportData.sol";
import "../src/RecyReport.sol";
import "../src/RecyReportFactory.sol";
import "../src/CRecy.sol";
import "../src/cRECYStaking.sol";
import "../src/TimeLock.sol";
import "../src/RecyCertificate.sol";
import "../src/RecyDistribution.sol";

contract DeployRecyTestnet is Script {
    // Whitepaper Section 3.2: First difficulty epoch supply (2,138,428 cRECY)
    uint256 public constant INITIAL_TESTNET_MINT = 2_138_428 * 1e18;
    // Whitepaper Section 6.1: Asymptotic Treasury Protection Loop reserve (100,000 cRECY)
    uint256 public constant INITIAL_RESERVE_POOL = 100_000 * 1e18;
    uint256 public constant MIN_COMPLIANCE_LOCK = 1_000 * 1e18;

    // Whitepaper Section 3.3 Emission Split (Must sum to 100 in RecyReport.initialize):
    // Treatment Agents: 60% | Auditors: 10% | Waste Generators: 20% | Detrash Protocol: 10%
    uint64 public constant REPORT_UNLOCK_DELAY = uint64(7 days);
    uint8 public constant SHARE_RECYCLER  = 60;
    uint8 public constant SHARE_VALIDATOR = 10;
    uint8 public constant SHARE_GENERATOR = 20;
    uint8 public constant SHARE_PROTOCOL  = 10;

    function run() external {
        address deployer = msg.sender;
        console2.log("Deployer:", deployer);
        console2.log("Chain ID:", block.chainid);

        vm.startBroadcast();

        // 1. Report Attributes Contract (#1)
        RecyReportAttributes attributes = new RecyReportAttributes();

        // 2. Recy Report Svg Contract (#2)
        RecyReportSvg svg = new RecyReportSvg();

        // 3. Recy Report Data Contract (#3)
        RecyReportData data = new RecyReportData(address(attributes), address(svg));

        // 4. Recy Report Implementation Contract (#4)
        RecyReport implementation = new RecyReport();

        // 5. Recy Report Factory Contract (#5)
        RecyReportFactory factory = new RecyReportFactory(address(implementation), address(data));

        // 6. cRECY Token Contract (#6)
        CRecy crecy = new CRecy(deployer, INITIAL_TESTNET_MINT);

        // 7. cRECY Staking Contract (#7)
        cRECYStaking staking = new cRECYStaking(address(crecy), deployer);

        // 9. Impact Investment Certificate Contract (#9)
        RecyCertificate certificate = new RecyCertificate(deployer, address(crecy));

        // 8. cRECY Locking Contract / TimeLock (#8)
        TimeLock locking = new TimeLock(
            address(crecy),
            address(certificate),
            deployer,
            MIN_COMPLIANCE_LOCK
        );

        // 10. RecyDistribution Contract (#10)
        RecyDistribution distribution = new RecyDistribution(address(crecy));

        // Wire permissions & Genesis Report Proxy
        crecy.setMinter(address(distribution), true);
        certificate.setLockingContract(address(locking));

        address genesisReportProxy = factory.deployProxy(
            "Recy Network Genesis Cluster",
            "RECY-REP-01",
            address(crecy),
            deployer,
            REPORT_UNLOCK_DELAY,
            SHARE_RECYCLER,
            SHARE_VALIDATOR,
            SHARE_GENERATOR,
            SHARE_PROTOCOL
        );

        crecy.transfer(genesisReportProxy, INITIAL_RESERVE_POOL);
        crecy.approve(address(staking), INITIAL_RESERVE_POOL);
        staking.notifyRewardAmount(INITIAL_RESERVE_POOL);

        vm.stopBroadcast();

        string memory obj = "recy_testnet_10_contracts";
        vm.serializeUint(obj, "chainId", block.chainid);
        vm.serializeAddress(obj, "deployer", deployer);
        vm.serializeAddress(obj, "1_RecyReportAttributes", address(attributes));
        vm.serializeAddress(obj, "2_RecyReportSvg", address(svg));
        vm.serializeAddress(obj, "3_RecyReportData", address(data));
        vm.serializeAddress(obj, "4_RecyReportImplementation", address(implementation));
        vm.serializeAddress(obj, "5_RecyReportFactory", address(factory));
        vm.serializeAddress(obj, "6_cRECYToken", address(crecy));
        vm.serializeAddress(obj, "7_cRECYStaking", address(staking));
        vm.serializeAddress(obj, "8_cRECYLocking", address(locking));
        vm.serializeAddress(obj, "9_ImpactInvestmentCertificate", address(certificate));
        vm.serializeAddress(obj, "10_RecyDistribution", address(distribution));
        string memory finalJson = vm.serializeAddress(obj, "GenesisRecyReportProxy", genesisReportProxy);

        string memory outputPath = string.concat(
            "./deployments/recy-",
            vm.toString(block.chainid),
            ".json"
        );
        vm.writeJson(finalJson, outputPath);
    }
}
