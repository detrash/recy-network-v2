// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Script.sol";
import "forge-std/console2.sol";
import "../src/RecyReportFactory.sol";
import "../src/RecyReportAttributes.sol";
import "../src/RecyDistribution.sol";
import "../src/cRECYStaking.sol";
import "../src/TimeLock.sol";
import "../src/RecyCertificate.sol";

interface IERC20AndAccess {
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
}

contract TransferToDeployer is Script {
    // Existing Deployed Celo Sepolia Contracts (Unchanged)
    address constant RECY_REPORT_ATTRIBUTES = 0x610A260c35939D736C4149A275552cbd9ECcd90B;
    address constant RECY_REPORT_FACTORY    = 0xc9Fb52e7eDBA245aBeb9Cbee3e603aF10A44BBd0;
    address constant GENESIS_REPORT_PROXY   = 0xf2CA0F67557819ce67591a96AEcEE4964c61284a;
    address constant CRECY_TOKEN            = 0xAEdE51b3493037546fAC090dF99D897abdef9b65;
    address constant CRECY_STAKING          = 0x431D35FA8E41207Dfb8B13f1C7d67a61F70Aa2DD;
    address constant CRECY_LOCKING          = 0x316970350AcA45176040e687e391530ce922a339;
    address constant IMPACT_CERTIFICATE     = 0x5D978fce70Bc093d483e21ACB5F85333862dc7Fe;
    address constant RECY_DISTRIBUTION      = 0xe949248B8310780f2B2869deCE04C2d7C1a92B06;

    // Target Wallets (EIP-55 Checksummed)
    address constant DEPLOYER_WALLET = 0x656CaB5127F4067Af0E0b60b070604cDCC0B307c;
    address constant SECOND_RECYCLER = 0x6731a191bb817D6C7ef537ffE340FCAEcAb9D684;

    function run() external {
        vm.startBroadcast();

        // 1. Grant roles on GENESIS_REPORT_PROXY via RecyReportFactory, then transfer Factory ownership
        RecyReportFactory factory = RecyReportFactory(RECY_REPORT_FACTORY);
        if (factory.owner() == msg.sender) {
            factory.grantAdminRole(GENESIS_REPORT_PROXY, DEPLOYER_WALLET);
            factory.grantRecyclerRole(GENESIS_REPORT_PROXY, DEPLOYER_WALLET);
            factory.grantAuditorRole(GENESIS_REPORT_PROXY, DEPLOYER_WALLET);
            factory.grantEmergencyRole(GENESIS_REPORT_PROXY, DEPLOYER_WALLET);
            factory.grantRecyclerRole(GENESIS_REPORT_PROXY, SECOND_RECYCLER);

            factory.transferOwnership(DEPLOYER_WALLET);
            console2.log("Factory roles granted & ownership transferred to:", DEPLOYER_WALLET);
        }

        // 2. Seed RecyReportAttributes (if empty) & transfer ownership
        RecyReportAttributes attrs = RecyReportAttributes(RECY_REPORT_ATTRIBUTES);
        if (attrs.owner() == msg.sender) {
            if (attrs.getMaterials().length == 0) {
                attrs.addMaterial("Plastico (PET / PEAD / PP)", "<rect width='20' height='20' fill='#01a75b'/>");
                attrs.addMaterial("Aluminio e Metais Nao-Ferrosos", "<circle cx='10' cy='10' r='8' fill='#01a75b'/>");
                attrs.addMaterial("Papel e Papelao Ondulado", "<rect width='18' height='14' fill='#01a75b'/>");
                attrs.addMaterial("Vidro Limpo / Caco", "<polygon points='10,2 18,18 2,18' fill='#01a75b'/>");
                attrs.addMaterial("Residuo Organico Compostavel", "<circle cx='10' cy='10' r='9' fill='#01a75b'/>");
            }
            if (attrs.getRecycleTypes().length == 0) {
                attrs.addRecycleType("Reciclagem Mecanica / Extrusao");
                attrs.addRecycleType("Compostagem Termofilica");
                attrs.addRecycleType("Triagem, Prensagem e Enfardamento");
                attrs.addRecycleType("Logistica Reversa Industrial");
            }
            if (attrs.getRecycleShapes().length == 0) {
                attrs.addRecycleShape("Fardos Prensados (Alta Densidade)");
                attrs.addRecycleShape("Flakes Moidos e Lavados");
                attrs.addRecycleShape("Pellets / Granulos");
                attrs.addRecycleShape("Composto Organico Humificado");
            }
            if (attrs.getDisposalMethods().length == 0) {
                attrs.addDisposalMethod("Reinsercao na Cadeia Produtiva");
                attrs.addDisposalMethod("Desvio Verificado de Aterro Sanitario");
                attrs.addDisposalMethod("Recuperacao Agricola / Solo");
            }
            attrs.transferOwnership(DEPLOYER_WALLET);
            console2.log("RecyReportAttributes seeded & ownership transferred.");
        }

        // 3. Whitelist Genesis Proxy in RecyDistribution & transfer ownership
        RecyDistribution dist = RecyDistribution(RECY_DISTRIBUTION);
        if (dist.owner() == msg.sender) {
            try dist.whitelistReportContract(GENESIS_REPORT_PROXY) {} catch {}
            dist.transferOwnership(DEPLOYER_WALLET);
            console2.log("RecyDistribution ownership transferred.");
        }

        // 4. Grant Admin & Distributor roles on Staking, Locking, Certificate, and CRecy
        cRECYStaking staking = cRECYStaking(CRECY_STAKING);
        if (staking.hasRole(bytes32(0), msg.sender)) {
            staking.grantRole(bytes32(0), DEPLOYER_WALLET);
            staking.grantRole(staking.REWARD_DISTRIBUTOR_ROLE(), DEPLOYER_WALLET);
        }

        TimeLock locking = TimeLock(CRECY_LOCKING);
        if (locking.hasRole(bytes32(0), msg.sender)) {
            locking.grantRole(bytes32(0), DEPLOYER_WALLET);
        }

        RecyCertificate cert = RecyCertificate(IMPACT_CERTIFICATE);
        if (cert.hasRole(bytes32(0), msg.sender)) {
            cert.grantRole(bytes32(0), DEPLOYER_WALLET);
            cert.grantRole(cert.MINTER_ROLE(), DEPLOYER_WALLET);
        }

        // Grant admin/ownership on CRecy token (handles either Ownable or AccessControl)
        (bool ok1, ) = CRECY_TOKEN.call(abi.encodeWithSignature("grantRole(bytes32,address)", bytes32(0), DEPLOYER_WALLET));
        (bool ok2, ) = CRECY_TOKEN.call(abi.encodeWithSignature("transferOwnership(address)", DEPLOYER_WALLET));
        ok1; ok2;

        // 5. Transfer all cRECY tokens from recy-testnet-deployer to deployer (0x656CaB...307c)
        uint256 cRecyBal = IERC20AndAccess(CRECY_TOKEN).balanceOf(msg.sender);
        if (cRecyBal > 0) {
            IERC20AndAccess(CRECY_TOKEN).transfer(DEPLOYER_WALLET, cRecyBal);
            console2.log("Transferred cRECY balance to deployer:", cRecyBal / 1e18);
        }

        vm.stopBroadcast();
    }
}
