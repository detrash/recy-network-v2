// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC1967Proxy} from "@openzeppelin/contracts/proxy/ERC1967/ERC1967Proxy.sol";

import {RecyReportAttributes} from "../../src/RecyReportAttributes.sol";
import {RecyReportSvg} from "../../src/RecyReportSvg.sol";
import {RecyReportData} from "../../src/RecyReportData.sol";
import {RecyReport} from "../../src/RecyReport.sol";
import {RecyReportFactory} from "../../src/RecyReportFactory.sol";
import {CRecy} from "../../src/CRecy.sol";
import {cRECYStaking} from "../../src/cRECYStaking.sol";
import {TimeLock} from "../../src/TimeLock.sol";
import {RecyCertificate} from "../../src/RecyCertificate.sol";
import {RecyDistribution} from "../../src/RecyDistribution.sol";
import {RecyTraceabilityCertificate} from "../../src/RecyTraceabilityCertificate.sol";
import {DetrashDirectOTC} from "../../src/DetrashDirectOTC.sol";
import {RecyV4SwapAdapter} from "../../src/RecyV4SwapAdapter.sol";
import {IPoolManager, PoolKey, UniswapV4Math} from "../../src/interfaces/IUniswapV4Minimal.sol";

contract DeployRecyMainnet is Script {
    // =========================================================================
    // EXTERNAL ETHEREUM MAINNET PROTOCOL CONTRACTS (NOT DETRASH WALLETS)
    // Immutable third-party infrastructure: Circle USDC & Uniswap V4/V3.
    // =========================================================================
    uint256 public constant ETH_MAINNET_CHAIN_ID = 1;
    address public constant ETH_MAINNET_USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address public constant ETH_MAINNET_V4_POOL_MANAGER = 0x000000000004444c5dc75cB358380D2e3dE08A90;
    address public constant ETH_MAINNET_V4_POSITION_MANAGER = 0xbD216513d74C8cf14cf4747E6AaA6420FF64ee9e;
    address public constant ETH_MAINNET_PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    address public constant ETH_MAINNET_V3_FALLBACK_ROUTER = 0x68b3465833fb72A70ecDF485E0e4C7bD8665Fc45;

    // Foundry built-in dummy sender (rejected so Detrash never loses contract access)
    address public constant FOUNDRY_DEFAULT_SENDER = 0x1804c8AB1F12E6bbf3894d4083f33e07309d1f38;

    // Exact Genesis Supply Cap: 484,891.69691 cRECY (new cRECY minted only after report validation)
    uint256 public constant GENESIS_SUPPLY_CAP = 484_891_696_910_000_000_000_000;
    uint256 public constant MIN_COMPLIANCE_LOCK = 1_000 * 1e18;

    // Emission Split (sums to 100): Treatment Agents 60% | Auditors 10% | Generators 20% | Protocol 10%
    uint64 public constant REPORT_UNLOCK_DELAY = uint64(7 days);
    uint8 public constant SHARE_RECYCLER = 60;
    uint8 public constant SHARE_VALIDATOR = 10;
    uint8 public constant SHARE_GENERATOR = 20;
    uint8 public constant SHARE_PROTOCOL = 10;

    // Uniswap V4 cRECY/USDC Pool Parameters
    uint24 public constant USDC_CRECY_POOL_FEE = 3000; // 0.30%
    int24 public constant USDC_CRECY_TICK_SPACING = 60;
    uint256 public constant DEFAULT_INITIAL_PRICE_MICRO_USDC = 50_000; // $0.05 per cRECY

    // Traceability Certificate Parameters (disposalMethod[1] == "Landfill")
    uint8 public constant LANDFILL_TREATMENT_ID = 1;
    uint256 public constant INITIAL_CERT_PRICE_USDC = 50 * 1e6;

    // Detrash Direct OTC Mainnet Parameters
    uint256 public constant OTC_MIN_PAYMENT_USDC = 50 * 1e6;
    uint256 public constant OTC_MIN_PRICE_PER_CRECY = 50_000; // $0.05 floor per whole cRECY
    uint256 public constant OTC_MAX_CRECY_PER_PROPOSAL = 100_000 * 1e18;

    struct DeployConfig {
        // Detrash-controlled wallets (all default to the broadcaster EOA)
        address deployer;
        address protocolWallet;
        address adminWallet;
        address detrashTreasury;
        address treasuryOperator;
        // Optional Uniswap V4 hook contract (address(0) = hookless standard V4 pool)
        address v4Hook;
        uint256 initialMint;
        uint256 genesisReportSeed;
        uint256 stakingRewardSeed;
        uint256 otcInitialAllowance;
        uint256 initialPriceMicroUsdc;
        bool initializeV4Pool;
    }

    struct DeployedAddresses {
        address attributes;
        address svg;
        address data;
        address reportImpl;
        address factory;
        address crecy;
        address staking;
        address locking;
        address certificate;
        address distribution;
        address genesisReportProxy;
        address v4Adapter;
        address traceImpl;
        address traceProxy;
        address otc;
        bytes32 v4PoolId;
        uint160 v4InitSqrtPriceX96;
        int24 v4InitTick;
    }

    function run() external {
        require(
            block.chainid == ETH_MAINNET_CHAIN_ID, "DeployRecyMainnet: must run against Ethereum Mainnet (chainId 1)"
        );

        vm.startBroadcast();
        (, address deployer,) = vm.readCallers();

        DeployConfig memory cfg = DeployConfig({
            deployer: deployer,
            protocolWallet: vm.envOr("MAINNET_PROTOCOL_WALLET", deployer),
            adminWallet: vm.envOr("MAINNET_ADMIN_WALLET", deployer),
            detrashTreasury: vm.envOr("DETRASH_TREASURY_ADDRESS", deployer),
            treasuryOperator: vm.envOr("TREASURY_OPERATOR_ADDRESS", deployer),
            v4Hook: vm.envOr("MAINNET_V4_HOOK", address(0)),
            initialMint: vm.envOr("INITIAL_MAINNET_MINT", GENESIS_SUPPLY_CAP),
            genesisReportSeed: vm.envOr("GENESIS_REPORT_SEED", uint256(0)),
            stakingRewardSeed: vm.envOr("STAKING_REWARD_SEED", uint256(0)),
            otcInitialAllowance: vm.envOr("OTC_INITIAL_ALLOWANCE", uint256(0)),
            initialPriceMicroUsdc: vm.envOr("INITIAL_CRECY_PRICE_MICRO_USDC", DEFAULT_INITIAL_PRICE_MICRO_USDC),
            initializeV4Pool: vm.envOr("INITIALIZE_V4_POOL", true)
        });

        _validateDetrashWallets(cfg);

        require(
            cfg.initialMint <= GENESIS_SUPPLY_CAP, "DeployRecyMainnet: initialMint cannot exceed 484,891.69691 cRECY"
        );
        require(
            cfg.genesisReportSeed + cfg.stakingRewardSeed <= cfg.initialMint,
            "DeployRecyMainnet: seed allocations exceed initialMint"
        );
        require(
            cfg.otcInitialAllowance <= cfg.initialMint, "DeployRecyMainnet: otcInitialAllowance exceeds initialMint"
        );

        DeployedAddresses memory deployed = _deployCoreSuite(cfg);
        _deployV4AdapterAndPool(cfg, deployed);
        _deployTraceabilityCertificate(cfg, deployed);
        _deployDetrashOtc(cfg, deployed);

        require(
            IERC20(deployed.crecy).totalSupply() == cfg.initialMint, "DeployRecyMainnet: totalSupply invariant violated"
        );

        vm.stopBroadcast();

        _logAndWriteManifest(cfg, deployed);
    }

    function _validateDetrashWallets(DeployConfig memory cfg) internal pure {
        _requireDetrashWallet(cfg.deployer, "deployer");
        _requireDetrashWallet(cfg.protocolWallet, "protocolWallet");
        _requireDetrashWallet(cfg.adminWallet, "adminWallet");
        _requireDetrashWallet(cfg.detrashTreasury, "detrashTreasury");
        _requireDetrashWallet(cfg.treasuryOperator, "treasuryOperator");
    }

    function _requireDetrashWallet(address wallet, string memory label) internal pure {
        require(
            wallet != address(0) && wallet != FOUNDRY_DEFAULT_SENDER,
            string.concat("DeployRecyMainnet: invalid Detrash wallet for ", label)
        );
    }

    function _deployCoreSuite(DeployConfig memory cfg) internal returns (DeployedAddresses memory d) {
        RecyReportAttributes attributes = new RecyReportAttributes();
        RecyReportSvg svg = new RecyReportSvg();
        RecyReportData data = new RecyReportData(address(attributes), address(svg));
        RecyReport reportImpl = new RecyReport();
        RecyReportFactory factory = new RecyReportFactory(address(reportImpl), address(data));

        CRecy crecy = new CRecy(cfg.deployer, cfg.initialMint);
        cRECYStaking staking = new cRECYStaking(address(crecy), cfg.deployer);
        RecyCertificate certificate = new RecyCertificate(cfg.deployer, address(crecy));
        TimeLock locking = new TimeLock(address(crecy), address(certificate), cfg.deployer, MIN_COMPLIANCE_LOCK);
        RecyDistribution distribution = new RecyDistribution(address(crecy));

        // Only RecyDistribution may mint new cRECY (strictly after verified reports)
        crecy.setMinter(address(distribution), true);
        crecy.setMinter(cfg.deployer, false);

        certificate.setLockingContract(address(locking));

        address genesisReportProxy = factory.deployProxy(
            "Recy Network Genesis Cluster",
            "RECY-REP-01",
            address(crecy),
            cfg.protocolWallet,
            REPORT_UNLOCK_DELAY,
            SHARE_RECYCLER,
            SHARE_VALIDATOR,
            SHARE_GENERATOR,
            SHARE_PROTOCOL
        );

        distribution.whitelistReportContract(genesisReportProxy);

        if (cfg.genesisReportSeed > 0) {
            crecy.transfer(genesisReportProxy, cfg.genesisReportSeed);
        }
        if (cfg.stakingRewardSeed > 0) {
            crecy.approve(address(staking), cfg.stakingRewardSeed);
            staking.notifyRewardAmount(cfg.stakingRewardSeed);
        }

        d.attributes = address(attributes);
        d.svg = address(svg);
        d.data = address(data);
        d.reportImpl = address(reportImpl);
        d.factory = address(factory);
        d.crecy = address(crecy);
        d.staking = address(staking);
        d.locking = address(locking);
        d.certificate = address(certificate);
        d.distribution = address(distribution);
        d.genesisReportProxy = genesisReportProxy;
    }

    function _deployV4AdapterAndPool(DeployConfig memory cfg, DeployedAddresses memory d) internal {
        RecyV4SwapAdapter adapter =
            new RecyV4SwapAdapter(ETH_MAINNET_V4_POOL_MANAGER, ETH_MAINNET_V3_FALLBACK_ROUTER, cfg.deployer);

        bytes32 poolId =
            adapter.registerV4Pool(d.crecy, ETH_MAINNET_USDC, USDC_CRECY_POOL_FEE, USDC_CRECY_TICK_SPACING, cfg.v4Hook);

        d.v4Adapter = address(adapter);
        d.v4PoolId = poolId;

        if (cfg.initializeV4Pool) {
            (address c0, address c1) = UniswapV4Math.sortCurrencies(d.crecy, ETH_MAINNET_USDC);
            PoolKey memory key = PoolKey({
                currency0: c0,
                currency1: c1,
                fee: USDC_CRECY_POOL_FEE,
                tickSpacing: USDC_CRECY_TICK_SPACING,
                hooks: cfg.v4Hook
            });

            uint160 sqrtPriceX96 =
                UniswapV4Math.computeCrecyUsdcSqrtPriceX96(d.crecy, ETH_MAINNET_USDC, cfg.initialPriceMicroUsdc);

            d.v4InitSqrtPriceX96 = sqrtPriceX96;
            d.v4InitTick = IPoolManager(ETH_MAINNET_V4_POOL_MANAGER).initialize(key, sqrtPriceX96);
        }
    }

    function _deployTraceabilityCertificate(DeployConfig memory cfg, DeployedAddresses memory d) internal {
        RecyTraceabilityCertificate traceImpl = new RecyTraceabilityCertificate();

        RecyTraceabilityCertificate.SplitConfig memory initialSplit =
            RecyTraceabilityCertificate.SplitConfig({adminBps: 3000, auditorBps: 2000, buybackBps: 5000});

        bytes memory initData = abi.encodeCall(
            RecyTraceabilityCertificate.initialize,
            (
                cfg.deployer,
                d.factory,
                ETH_MAINNET_USDC,
                d.crecy,
                d.v4Adapter,
                cfg.adminWallet,
                d.staking,
                USDC_CRECY_POOL_FEE,
                LANDFILL_TREATMENT_ID,
                INITIAL_CERT_PRICE_USDC,
                initialSplit
            )
        );

        ERC1967Proxy traceProxy = new ERC1967Proxy(address(traceImpl), initData);
        d.traceImpl = address(traceImpl);
        d.traceProxy = address(traceProxy);
    }

    function _deployDetrashOtc(DeployConfig memory cfg, DeployedAddresses memory d) internal {
        bytes32 initialTermsHash =
            keccak256(abi.encodePacked("TERMO_DE_AQUISICAO_MERCANTIL_ATIVO_UTILIDADE_CRECY_V1_DETRASH_LTDA"));

        DetrashDirectOTC otc =
            new DetrashDirectOTC(d.crecy, cfg.detrashTreasury, cfg.treasuryOperator, initialTermsHash);

        otc.configurePaymentToken(ETH_MAINNET_USDC, true, OTC_MIN_PAYMENT_USDC, OTC_MIN_PRICE_PER_CRECY);
        otc.setMaxCrecyPerProposal(OTC_MAX_CRECY_PER_PROPOSAL);

        if (cfg.deployer == cfg.detrashTreasury && cfg.otcInitialAllowance > 0) {
            IERC20(d.crecy).approve(address(otc), cfg.otcInitialAllowance);
        }

        d.otc = address(otc);
    }

    function _logAndWriteManifest(DeployConfig memory cfg, DeployedAddresses memory d) internal {
        console2.log("=== Recy Network Unified Ethereum Mainnet Deployment (Uniswap V4) ===");
        console2.log("Chain ID                     :", block.chainid);
        console2.log("--- Detrash-Controlled Wallets ---");
        console2.log("Deployer / Initial Admin     :", cfg.deployer);
        console2.log("Protocol Fee Wallet          :", cfg.protocolWallet);
        console2.log("Certificate Admin Wallet     :", cfg.adminWallet);
        console2.log("Detrash OTC Treasury         :", cfg.detrashTreasury);
        console2.log("Detrash OTC Operator         :", cfg.treasuryOperator);
        console2.log("--- Supply & Deployed Contracts ---");
        console2.log("Genesis Total Supply (wei)   :", IERC20(d.crecy).totalSupply());
        console2.log("Deployer cRECY Balance (wei) :", IERC20(d.crecy).balanceOf(cfg.deployer));
        console2.log("6_cRECYToken                 :", d.crecy);
        console2.log("7_cRECYStaking               :", d.staking);
        console2.log("10_RecyDistribution          :", d.distribution);
        console2.log("GenesisRecyReportProxy       :", d.genesisReportProxy);
        console2.log("RecyV4SwapAdapter            :", d.v4Adapter);
        console2.log("TraceabilityCertProxy        :", d.traceProxy);
        console2.log("DetrashDirectOTC             :", d.otc);
        console2.log("UniswapV4PoolId              :", vm.toString(d.v4PoolId));
        console2.log("UniswapV4InitSqrtPriceX96    :", d.v4InitSqrtPriceX96);
        console2.log("UniswapV4InitTick            :", d.v4InitTick);

        string memory obj = "recy_eth_mainnet_v4";
        vm.serializeUint(obj, "chainId", block.chainid);
        vm.serializeAddress(obj, "deployer", cfg.deployer);
        vm.serializeAddress(obj, "protocolWallet", cfg.protocolWallet);
        vm.serializeAddress(obj, "adminWallet", cfg.adminWallet);
        vm.serializeAddress(obj, "detrashTreasury", cfg.detrashTreasury);
        vm.serializeAddress(obj, "treasuryOperator", cfg.treasuryOperator);
        vm.serializeUint(obj, "genesisTotalSupplyWei", IERC20(d.crecy).totalSupply());
        vm.serializeAddress(obj, "usdc", ETH_MAINNET_USDC);
        vm.serializeAddress(obj, "uniswapV4PoolManager", ETH_MAINNET_V4_POOL_MANAGER);
        vm.serializeAddress(obj, "uniswapV4PositionManager", ETH_MAINNET_V4_POSITION_MANAGER);
        vm.serializeAddress(obj, "permit2", ETH_MAINNET_PERMIT2);
        vm.serializeAddress(obj, "1_RecyReportAttributes", d.attributes);
        vm.serializeAddress(obj, "2_RecyReportSvg", d.svg);
        vm.serializeAddress(obj, "3_RecyReportData", d.data);
        vm.serializeAddress(obj, "4_RecyReportImplementation", d.reportImpl);
        vm.serializeAddress(obj, "5_RecyReportFactory", d.factory);
        vm.serializeAddress(obj, "6_cRECYToken", d.crecy);
        vm.serializeAddress(obj, "7_cRECYStaking", d.staking);
        vm.serializeAddress(obj, "8_cRECYLocking", d.locking);
        vm.serializeAddress(obj, "9_ImpactInvestmentCertificate", d.certificate);
        vm.serializeAddress(obj, "10_RecyDistribution", d.distribution);
        vm.serializeAddress(obj, "GenesisRecyReportProxy", d.genesisReportProxy);
        vm.serializeAddress(obj, "RecyV4SwapAdapter", d.v4Adapter);
        vm.serializeAddress(obj, "TraceabilityCertImpl", d.traceImpl);
        vm.serializeAddress(obj, "TraceabilityCertProxy", d.traceProxy);
        vm.serializeAddress(obj, "DetrashDirectOTC", d.otc);
        string memory finalJson = vm.serializeBytes32(obj, "UniswapV4PoolId", d.v4PoolId);

        vm.writeJson(finalJson, "./mainnet/deployments/recy-eth-mainnet-1.json");
    }
}
