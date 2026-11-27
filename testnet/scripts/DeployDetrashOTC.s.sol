// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {DetrashDirectOTC} from "../../src/DetrashDirectOTC.sol";

/**
 * @dev Mock USDC de 6 casas decimais exclusivo para Celo Sepolia Testnet caso USDC_TOKEN_ADDRESS não seja informado.
 */
contract TestnetMockUSDC is ERC20 {
    constructor(address initialHolder) ERC20("USD Coin (Recy Testnet)", "USDC") {
        _mint(initialHolder, 100_000 * 1e6); // 100.000 USDC para testes
    }

    function decimals() public pure override returns (uint8) {
        return 6;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

contract DeployDetrashOTC is Script {
    // Chain IDs Oficiais
    uint256 constant CELO_MAINNET_CHAIN_ID = 42220;
    uint256 constant CELO_SEPOLIA_CHAIN_ID = 11142220;

    // Endereços Canônicos Celo Mainnet
    address constant MAINNET_CRECY = 0x34C11A932853Ae24E845Ad4B633E3cEf91afE583;
    address constant MAINNET_USDC = 0xcebA9300f2b948710d2653dD7B07f33A8B32118C;

    // Endereço Oficial do cRECY na Celo Sepolia Testnet
    address constant TESTNET_CRECY = 0xAEdE51b3493037546fAC090dF99D897abdef9b65;

    function run() external {
        bool isMainnet = (block.chainid == CELO_MAINNET_CHAIN_ID);

        // 1. Resolve endereço do cRECY automaticamente (Mainnet ou Sepolia)
        address crecyAddress =
            isMainnet ? vm.envOr("CRECY_TOKEN_ADDRESS", MAINNET_CRECY) : vm.envOr("CRECY_TOKEN_ADDRESS", TESTNET_CRECY);

        // 2. Hash canônico do Termo de Aquisição de Ativo de Utilidade cRECY
        bytes32 initialTermsHash =
            keccak256(abi.encodePacked("TERMO_DE_AQUISICAO_MERCANTIL_ATIVO_UTILIDADE_CRECY_V1_DETRASH_LTDA"));

        // 3. Inicia o broadcast usando a carteira desbloqueada pelo --account do Keystore
        uint256 envPk = vm.envOr("PRIVATE_KEY", uint256(0));
        if (envPk != 0) {
            vm.startBroadcast(envPk);
        } else {
            vm.startBroadcast();
        }

        // Obtém automaticamente o endereço público da carteira do Keystore ativa no broadcast
        (, address deployer,) = vm.readCallers();

        address detrashTreasury = vm.envOr("DETRASH_TREASURY_ADDRESS", deployer);
        address treasuryOperator = vm.envOr("TREASURY_OPERATOR_ADDRESS", deployer);

        // 4. Resolve ou implanta USDC na Testnet
        address usdcAddress;
        if (isMainnet) {
            usdcAddress = vm.envOr("USDC_TOKEN_ADDRESS", MAINNET_USDC);
        } else {
            address envUsdc = vm.envOr("USDC_TOKEN_ADDRESS", address(0));
            if (envUsdc != address(0)) {
                usdcAddress = envUsdc;
            } else {
                TestnetMockUSDC mockUsdc = new TestnetMockUSDC(deployer);
                usdcAddress = address(mockUsdc);
                console2.log("TestnetMockUSDC deployed & 100,000 USDC minted to:", deployer);
            }
        }

        // 5. Deploy do contrato DetrashDirectOTC
        DetrashDirectOTC otc = new DetrashDirectOTC(crecyAddress, detrashTreasury, treasuryOperator, initialTermsHash);

        // 6. Configura parâmetros de pagamento (Testnet: mín 1 USDC | Mainnet: mín 50 USDC)
        uint256 minPaymentAmount = isMainnet ? (50 * 1e6) : (1 * 1e6);
        uint256 minPricePerCrecy = isMainnet ? 50_000 : 1_000;

        otc.configurePaymentToken(usdcAddress, true, minPaymentAmount, minPricePerCrecy);

        // 7. Aprova automaticamente o lote de cRECY da Tesouraria para o contrato OTC
        if (deployer == detrashTreasury) {
            IERC20(crecyAddress).approve(address(otc), type(uint256).max);
            console2.log("Auto-approved cRECY allowance from Detrash Treasury to OTC contract.");
        }

        vm.stopBroadcast();

        console2.log("==========================================");
        console2.log("DEPLOYER / KEYSTORE WALLET:", deployer);
        console2.log("NETWORK CHAIN ID:", block.chainid);
        console2.log("ENVIRONMENT:", isMainnet ? "CELO MAINNET" : "CELO SEPOLIA TESTNET");
        console2.log("VITE_DETRASH_OTC_ADDRESS=", address(otc));
        console2.log("VITE_CELO_USDC_ADDRESS=", usdcAddress);
        console2.log("CRECY_TOKEN_ADDRESS=", crecyAddress);
        console2.log("DETRASH_TREASURY=", detrashTreasury);
        console2.log("COMMERCIAL_TERMS_HASH=", vm.toString(initialTermsHash));
        console2.log("==========================================");
    }
}
