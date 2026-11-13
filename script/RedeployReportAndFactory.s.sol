// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "forge-std/console2.sol";
import "../src/RecyReport.sol";
import "../src/RecyReportFactory.sol";

interface IERC20Token {
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
}

contract RedeployReportAndFactory is Script {
    // Existing deployed contracts kept unchanged
    address constant RECY_REPORT_DATA = 0x64Fc6411cBc9477628cf19eb774BFa0589604DCb;
    address constant CRECY_TOKEN      = 0xAEdE51b3493037546fAC090dF99D897abdef9b65;

    // Wallets to authorize on the Genesis Proxy
    address constant BROWSER_WALLET   = 0x656CaB5127F4067Af0E0b60b070604cDCC0B307c;
    address constant SECOND_RECYCLER  = 0x6731a191bb817D6C7ef537ffE340FCAEcAb9D684;

    uint64 constant REPORT_UNLOCK_DELAY = uint64(7 days);
    uint8 constant SHARE_RECYCLER  = 60;
    uint8 constant SHARE_VALIDATOR = 10;
    uint8 constant SHARE_GENERATOR = 20;
    uint8 constant SHARE_PROTOCOL  = 10;

    function run() external {
        vm.startBroadcast();

        // 1. Deploy patched RecyReport Implementation
        RecyReport newImpl = new RecyReport();

        // 2. Deploy patched RecyReportFactory wired to existing RECY_REPORT_DATA
        RecyReportFactory newFactory = new RecyReportFactory(
            address(newImpl),
            RECY_REPORT_DATA
        );

        // 3. Deploy new Genesis Report Proxy via the Factory
        //    Grants DEFAULT_ADMIN_ROLE, RECYCLER_ROLE, AUDITOR_ROLE, EMERGENCY_ROLE to BROWSER_WALLET & msg.sender
        address newGenesisProxy = newFactory.deployProxy(
            "Recy Network Genesis Cluster",
            "RECY-REP-01",
            CRECY_TOKEN,
            BROWSER_WALLET,
            REPORT_UNLOCK_DELAY,
            SHARE_RECYCLER,
            SHARE_VALIDATOR,
            SHARE_GENERATOR,
            SHARE_PROTOCOL
        );

        // 4. Grant RECYCLER_ROLE to 0x6731...d684 on the new Genesis Proxy
        RecyReport(newGenesisProxy).grantRole(
            RecyReport(newGenesisProxy).RECYCLER_ROLE(),
            SECOND_RECYCLER
        );

        // 5. Fund the new Genesis Proxy with 100,000 cRECY reserve if broadcaster holds cRECY
        uint256 bal = IERC20Token(CRECY_TOKEN).balanceOf(msg.sender);
        if (bal >= 100_000 * 1e18) {
            IERC20Token(CRECY_TOKEN).transfer(newGenesisProxy, 100_000 * 1e18);
        }

        vm.stopBroadcast();

        console2.log("==================================================");
        console2.log("RECY_REPORT_IMPL:     ", address(newImpl));
        console2.log("RECY_REPORT_FACTORY:  ", address(newFactory));
        console2.log("GENESIS_REPORT_PROXY: ", newGenesisProxy);
        console2.log("==================================================");
    }
}
