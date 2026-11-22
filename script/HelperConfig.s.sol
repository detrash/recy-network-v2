// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script} from "forge-std/Script.sol";

contract HelperConfig is Script {
    struct NetworkConfig {
        address usdc;
        address weth;
        address uniswapV4PoolManager;
        address uniswapV4PositionManager;
        address permit2;
        address fallbackSwapRouter02; // V3 fallback for external payToken -> USDC swaps
        address protocolAdmin;
        address treasury;
        bool deployMocks;
    }

    uint256 public constant ETH_MAINNET_CHAIN_ID = 1;
    uint256 public constant CELO_MAINNET_CHAIN_ID = 42220;
    uint256 public constant CELO_SEPOLIA_CHAIN_ID = 11142220;

    function getActiveNetworkConfig() public view returns (NetworkConfig memory) {
        if (block.chainid == ETH_MAINNET_CHAIN_ID) return getEthMainnetConfig();
        if (block.chainid == CELO_MAINNET_CHAIN_ID) return getCeloMainnetConfig();
        if (block.chainid == CELO_SEPOLIA_CHAIN_ID) return getCeloSepoliaConfig();
        revert("Unsupported chainId: configure network in HelperConfig.s.sol");
    }

    function getEthMainnetConfig() public view returns (NetworkConfig memory) {
        return NetworkConfig({
            usdc: 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48,
            weth: 0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2,
            uniswapV4PoolManager: 0x000000000004444c5dc75cB358380D2e3dE08A90,
            uniswapV4PositionManager: 0xbD216513d74C8cf14cf4747E6AaA6420FF64ee9e,
            permit2: 0x000000000022D473030F116dDEE9F6B43aC78BA3,
            fallbackSwapRouter02: 0x68b3465833fb72A70ecDF485E0e4C7bD8665Fc45,
            protocolAdmin: vm.envOr("MAINNET_PROTOCOL_ADMIN", msg.sender),
            treasury: vm.envOr("MAINNET_TREASURY_SAFE", msg.sender),
            deployMocks: false
        });
    }

    function getCeloMainnetConfig() public view returns (NetworkConfig memory) {
        return NetworkConfig({
            usdc: 0xcebA9300f2b948710d2653dD7B07f33A8B32118C,
            weth: 0x471EcE3750Da237f93B8E339c536989b8978a438, // CELO ERC-20
            uniswapV4PoolManager: 0x288dc841A52FCA2707c6947B3A777c5E56cd87BC,
            uniswapV4PositionManager: 0xf7965f3981e4D5BC383BfBCb61501763e9068CA9,
            permit2: 0x000000000022D473030F116dDEE9F6B43aC78BA3,
            fallbackSwapRouter02: 0x5615CDAb10dc425a742d643d949a7F474C01abc4,
            protocolAdmin: vm.envOr("CELO_PROTOCOL_ADMIN", msg.sender),
            treasury: vm.envOr("CELO_TREASURY_SAFE", msg.sender),
            deployMocks: false
        });
    }

    function getCeloSepoliaConfig() public view returns (NetworkConfig memory) {
        return NetworkConfig({
            usdc: 0x01C5C0122039549AD1493B8220cABEdD739BC44E,
            weth: 0x471EcE3750Da237f93B8E339c536989b8978a438, // CELO ERC-20
            uniswapV4PoolManager: 0x2af85C83CFe7bC5182F81E5aE82661b4E9F15A1e,
            uniswapV4PositionManager: 0xB104b7c42DAB49d31fe3Ea91Dd80305348Cc37C1,
            permit2: 0x000000000022D473030F116dDEE9F6B43aC78BA3,
            fallbackSwapRouter02: address(0), // Uniswap V3 is not deployed on Celo Sepolia
            protocolAdmin: vm.envOr("TESTNET_ADMIN", msg.sender),
            treasury: vm.envOr("TESTNET_TREASURY", msg.sender),
            deployMocks: false
        });
    }
}
