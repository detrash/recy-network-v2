// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console2} from "forge-std/Script.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";
import {RecyTraceabilityCertificate} from "../src/RecyTraceabilityCertificate.sol";

contract DeployTraceabilityCertificate is Script {
    // Deployed Recy Network Celo Sepolia Addresses
    address constant RECY_REPORT_FACTORY = 0xc9Fb52e7eDBA245aBeb9Cbee3e603aF10A44BBd0;
    address constant CRECY_TOKEN         = 0xAEdE51b3493037546fAC090dF99D897abdef9b65;
    address constant CRECY_STAKING       = 0x431D35FA8E41207Dfb8B13f1C7d67a61F70Aa2DD;

    // Circle Testnet USDC on Celo Sepolia (6 decimals)
    // (For Celo Mainnet, use Circle USDC: 0xcebA9300f2b948710d2653dD7B07f33A8B32118C)
    address constant USDC_SEPOLIA        = 0x01C5C0122039549AD1493B8220cABEdD739BC44E;

    // Uniswap V3 SwapRouter02 on Celo (0x5615CDAb10dc425a742d643d949a7F474C01abc4 on Mainnet)
    address constant SWAP_ROUTER_SEPOLIA = 0x5615CDAb10dc425a742d643d949a7F474C01abc4;
    uint24  constant USDC_CRECY_POOL_FEE = 3000; // 0.3% fee tier for USDC/cRECY

    // Treatment ID corresponding to Landfill in RecyReportAttributes
    uint8   constant LANDFILL_TREATMENT_ID = 1;

    // Initial Certificate Price: 50 USDC (6 decimals)
    uint256 constant INITIAL_PRICE_USDC = 50 * 1e6;

    function run() external {
        address deployer = msg.sender;
        address adminWallet = vm.envOr("ADMIN_WALLET", deployer);

        RecyTraceabilityCertificate.SplitConfig memory initialSplit = RecyTraceabilityCertificate
            .SplitConfig({
                adminBps: 3000,
                auditorBps: 2000,
                buybackBps: 5000
            });

        vm.startBroadcast();

        RecyTraceabilityCertificate implementation = new RecyTraceabilityCertificate();

        bytes memory initData = abi.encodeCall(
            RecyTraceabilityCertificate.initialize,
            (
                deployer,
                RECY_REPORT_FACTORY,
                USDC_SEPOLIA,
                CRECY_TOKEN,
                SWAP_ROUTER_SEPOLIA,
                adminWallet,
                CRECY_STAKING,
                USDC_CRECY_POOL_FEE,
                LANDFILL_TREATMENT_ID,
                INITIAL_PRICE_USDC,
                initialSplit
            )
        );

        ERC1967Proxy proxy = new ERC1967Proxy(address(implementation), initData);

        vm.stopBroadcast();

        console2.log("=== RecyTraceabilityCertificate Deployed on Celo Sepolia ===");
        console2.log("Deployer / Admin       :", deployer);
        console2.log("Implementation Address :", address(implementation));
        console2.log("Proxy Address (Active) :", address(proxy));
        console2.log("Factory Wired          :", RECY_REPORT_FACTORY);
        console2.log("Base Settlement (USDC) :", USDC_SEPOLIA);
        console2.log("Buyback Target (cRECY) :", CRECY_TOKEN);
        console2.log("Buyback Recipient      :", CRECY_STAKING);
    }
}
