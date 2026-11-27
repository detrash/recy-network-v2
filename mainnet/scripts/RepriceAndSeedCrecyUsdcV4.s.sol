// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {PoolKey, UniswapV4Math} from "../../src/interfaces/IUniswapV4Minimal.sol";

interface IStateViewV4 {
    function getSlot0(bytes32 poolId)
        external
        view
        returns (uint160 sqrtPriceX96, int24 tick, uint24 protocolFee, uint24 lpFee);
    function getLiquidity(bytes32 poolId) external view returns (uint128 liquidity);
}

interface IPoolManagerV4Swap {
    struct SwapParams {
        bool zeroForOne;
        int256 amountSpecified;
        uint160 sqrtPriceLimitX96;
    }

    function unlock(bytes calldata data) external returns (bytes memory);
    function swap(PoolKey memory key, SwapParams memory params, bytes calldata hookData)
        external
        returns (int256 swapDelta);
}

interface IUnlockCallback {
    function unlockCallback(bytes calldata data) external returns (bytes memory);
}

interface IAllowanceTransfer {
    function approve(address token, address spender, uint160 amount, uint48 expiration) external;
}

interface IPositionManagerV4 {
    function modifyLiquidities(bytes calldata unlockData, uint256 deadline) external payable;
    function nextTokenId() external view returns (uint256);
}

/// @notice Single-caller atomic helper: shifts an empty V4 pool to targetSqrtPriceX96 (0 token delta)
///         and immediately mints the concentrated LP position in the same transaction.
contract RecyV4AtomicRepriceSeeder is IUnlockCallback {
    using SafeERC20 for IERC20;

    address public immutable AUTHORIZED;
    address public immutable POOL_MANAGER;
    address public immutable POSITION_MANAGER;
    address public immutable PERMIT2;
    address public immutable STATE_VIEW;

    uint8 internal constant ACTION_MINT_POSITION = 0x02;
    uint8 internal constant ACTION_SETTLE_PAIR = 0x0d;

    constructor(address authorized, address poolManager, address positionManager, address permit2, address stateView) {
        AUTHORIZED = authorized;
        POOL_MANAGER = poolManager;
        POSITION_MANAGER = positionManager;
        PERMIT2 = permit2;
        STATE_VIEW = stateView;
    }

    function repriceAndMint(
        PoolKey calldata key,
        uint160 targetSqrtPriceX96,
        int24 tickLower,
        int24 tickUpper,
        uint128 liquidity,
        uint128 amount0Max,
        uint128 amount1Max,
        address lpRecipient,
        uint256 deadline
    ) external returns (uint256 tokenId, uint256 spent0, uint256 spent1) {
        require(msg.sender == AUTHORIZED, "RecyV4AtomicRepriceSeeder: unauthorized");

        bytes32 poolId = keccak256(abi.encode(key));
        (uint160 currentSqrtPriceX96,,,) = IStateViewV4(STATE_VIEW).getSlot0(poolId);
        require(currentSqrtPriceX96 != 0, "RecyV4AtomicRepriceSeeder: pool not initialized");

        // 1. Shift empty pool spot price atomically to targetSqrtPriceX96 (enforces zero token delta)
        if (currentSqrtPriceX96 != targetSqrtPriceX96) {
            bool zeroForOne = currentSqrtPriceX96 > targetSqrtPriceX96;
            IPoolManagerV4Swap(POOL_MANAGER).unlock(abi.encode(key, zeroForOne, targetSqrtPriceX96));
        }

        (uint160 postSwapSqrtPriceX96,,,) = IStateViewV4(STATE_VIEW).getSlot0(poolId);
        require(postSwapSqrtPriceX96 == targetSqrtPriceX96, "RecyV4AtomicRepriceSeeder: price did not reach target");

        // 2. Pull deposit budgets from authorized caller
        IERC20(key.currency0).safeTransferFrom(msg.sender, address(this), amount0Max);
        IERC20(key.currency1).safeTransferFrom(msg.sender, address(this), amount1Max);

        // 3. Grant least-privilege Permit2 allowances to PositionManager
        IERC20(key.currency0).forceApprove(PERMIT2, amount0Max);
        IERC20(key.currency1).forceApprove(PERMIT2, amount1Max);

        uint48 permitExpiry = uint48(block.timestamp + 3600);
        IAllowanceTransfer(PERMIT2).approve(key.currency0, POSITION_MANAGER, uint160(amount0Max), permitExpiry);
        IAllowanceTransfer(PERMIT2).approve(key.currency1, POSITION_MANAGER, uint160(amount1Max), permitExpiry);

        // 4. Mint LP NFT in [tickLower, tickUpper] immediately after reprice
        tokenId = IPositionManagerV4(POSITION_MANAGER).nextTokenId();

        bytes memory actions = abi.encodePacked(ACTION_MINT_POSITION, ACTION_SETTLE_PAIR);
        bytes[] memory actionParams = new bytes[](2);
        actionParams[0] =
            abi.encode(key, tickLower, tickUpper, uint256(liquidity), amount0Max, amount1Max, lpRecipient, bytes(""));
        actionParams[1] = abi.encode(key.currency0, key.currency1);

        IPositionManagerV4(POSITION_MANAGER).modifyLiquidities(abi.encode(actions, actionParams), deadline);

        // 5. Clear ERC-20 Permit2 approvals and refund unspent dust to caller
        IERC20(key.currency0).forceApprove(PERMIT2, 0);
        IERC20(key.currency1).forceApprove(PERMIT2, 0);

        uint256 rem0 = IERC20(key.currency0).balanceOf(address(this));
        uint256 rem1 = IERC20(key.currency1).balanceOf(address(this));
        spent0 = uint256(amount0Max) - rem0;
        spent1 = uint256(amount1Max) - rem1;

        if (rem0 > 0) IERC20(key.currency0).safeTransfer(msg.sender, rem0);
        if (rem1 > 0) IERC20(key.currency1).safeTransfer(msg.sender, rem1);
    }

    function unlockCallback(bytes calldata data) external override returns (bytes memory) {
        require(msg.sender == POOL_MANAGER, "RecyV4AtomicRepriceSeeder: invalid callback caller");

        (PoolKey memory key, bool zeroForOne, uint160 targetSqrtPriceX96) = abi.decode(data, (PoolKey, bool, uint160));

        int256 swapDelta = IPoolManagerV4Swap(POOL_MANAGER)
            .swap(
                key,
                IPoolManagerV4Swap.SwapParams({
                    zeroForOne: zeroForOne, amountSpecified: -1, sqrtPriceLimitX96: targetSqrtPriceX96
                }),
                ""
            );

        // Guarantees the traversed range had zero liquidity and zero tokens are owed or taken
        require(swapDelta == 0, "RecyV4AtomicRepriceSeeder: pool has active liquidity in range");
        return "";
    }
}

contract RepriceAndSeedCrecyUsdcV4 is Script {
    using SafeERC20 for IERC20;

    // Canonical Ethereum Mainnet (Chain ID 1) Uniswap V4 & Circle USDC
    uint256 public constant ETH_MAINNET_CHAIN_ID = 1;
    address public constant ETH_MAINNET_USDC = 0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48;
    address public constant ETH_MAINNET_V4_POOL_MANAGER = 0x000000000004444c5dc75cB358380D2e3dE08A90;
    address public constant ETH_MAINNET_V4_POSITION_MANAGER = 0xbD216513d74C8cf14cf4747E6AaA6420FF64ee9e;
    address public constant ETH_MAINNET_PERMIT2 = 0x000000000022D473030F116dDEE9F6B43aC78BA3;
    address public constant ETH_MAINNET_V4_STATE_VIEW = 0x7fFE42C4a5DEeA5b0feC41C94C136Cf115597227;

    uint256 internal constant Q96 = 0x1000000000000000000000000;

    // Existing cRECY/USDC PoolKey parameters from DeployRecyMainnet.s.sol
    uint24 public constant LP_FEE = 3000; // 0.30%
    int24 public constant TICK_SPACING = 60;

    // Target Price & Range: $0.88 current price, $0.77912 floor (-278820), no upper limit (887220)
    uint256 public constant TARGET_PRICE_MICRO_USDC = 880_000; // $0.88 USDC per cRECY
    int24 public constant TICK_LOWER = -278_820; // $0.77912 USDC per cRECY (multiple of 60)
    int24 public constant TICK_UPPER = 887_220; // Max valid tick for tickSpacing 60 (no upper cap)

    function run() external {
        require(
            block.chainid == ETH_MAINNET_CHAIN_ID, "RepriceAndSeedCrecyUsdcV4: must run on Ethereum Mainnet (chainId 1)"
        );

        string memory manifestPath =
            vm.envOr("DEPLOYMENT_MANIFEST", string("./mainnet/deployments/recy-eth-mainnet-1.json"));
        string memory rawManifest = vm.readFile(manifestPath);
        address crecy = vm.parseJsonAddress(rawManifest, "$['6_cRECYToken']");

        require(
            crecy != address(0) && uint160(crecy) < uint160(ETH_MAINNET_USDC),
            "RepriceAndSeedCrecyUsdcV4: expected cRECY < USDC address order"
        );

        uint256 crecyAmount = vm.envUint("LP_CRECY_AMOUNT_WEI");
        uint256 usdcAmount = vm.envUint("LP_USDT_OR_USDC_AMOUNT_UNITS");
        require(crecyAmount > 0 && usdcAmount > 0, "RepriceAndSeedCrecyUsdcV4: deposit amounts must be > 0");
        require(
            crecyAmount <= type(uint128).max && usdcAmount <= type(uint128).max,
            "RepriceAndSeedCrecyUsdcV4: deposit exceeds uint128"
        );

        PoolKey memory key = PoolKey({
            currency0: crecy, currency1: ETH_MAINNET_USDC, fee: LP_FEE, tickSpacing: TICK_SPACING, hooks: address(0)
        });
        bytes32 poolId = keccak256(abi.encode(key));

        require(
            IStateViewV4(ETH_MAINNET_V4_STATE_VIEW).getLiquidity(poolId) == 0,
            "RepriceAndSeedCrecyUsdcV4: pool already has active liquidity"
        );

        uint160 targetSqrtPriceX96 =
            UniswapV4Math.computeCrecyUsdcSqrtPriceX96(crecy, ETH_MAINNET_USDC, TARGET_PRICE_MICRO_USDC);
        uint160 sqrtPriceLowerX96 = _getSqrtPriceAtTick(TICK_LOWER);
        uint160 sqrtPriceUpperX96 = _getSqrtPriceAtTick(TICK_UPPER);

        require(
            targetSqrtPriceX96 > sqrtPriceLowerX96 && targetSqrtPriceX96 < sqrtPriceUpperX96,
            "RepriceAndSeedCrecyUsdcV4: target price outside tick range"
        );

        uint128 rawLiquidity =
            _getLiquidityForAmounts(targetSqrtPriceX96, sqrtPriceLowerX96, sqrtPriceUpperX96, crecyAmount, usdcAmount);
        // 1 bps rounding cushion so PoolManager ceiling math stays within exact deposit cap
        uint128 liquidity = uint128((uint256(rawLiquidity) * 9999) / 10000);
        require(liquidity > 0, "RepriceAndSeedCrecyUsdcV4: computed liquidity is zero");

        vm.startBroadcast();
        (, address sender,) = vm.readCallers();

        address lpRecipient = vm.envOr("LP_NFT_RECIPIENT", sender);
        require(lpRecipient != address(0), "RepriceAndSeedCrecyUsdcV4: zero LP recipient");
        require(IERC20(crecy).balanceOf(sender) >= crecyAmount, "RepriceAndSeedCrecyUsdcV4: insufficient cRECY");
        require(
            IERC20(ETH_MAINNET_USDC).balanceOf(sender) >= usdcAmount, "RepriceAndSeedCrecyUsdcV4: insufficient USDC"
        );

        RecyV4AtomicRepriceSeeder seeder = new RecyV4AtomicRepriceSeeder(
            sender,
            ETH_MAINNET_V4_POOL_MANAGER,
            ETH_MAINNET_V4_POSITION_MANAGER,
            ETH_MAINNET_PERMIT2,
            ETH_MAINNET_V4_STATE_VIEW
        );

        IERC20(crecy).forceApprove(address(seeder), crecyAmount);
        IERC20(ETH_MAINNET_USDC).forceApprove(address(seeder), usdcAmount);

        (uint256 tokenId, uint256 spentCrecy, uint256 spentUsdc) = seeder.repriceAndMint(
            key,
            targetSqrtPriceX96,
            TICK_LOWER,
            TICK_UPPER,
            liquidity,
            uint128(crecyAmount),
            uint128(usdcAmount),
            lpRecipient,
            block.timestamp + 1200
        );

        vm.stopBroadcast();

        (uint160 finalSqrtPriceX96, int24 finalTick,,) = IStateViewV4(ETH_MAINNET_V4_STATE_VIEW).getSlot0(poolId);
        uint128 finalLiquidity = IStateViewV4(ETH_MAINNET_V4_STATE_VIEW).getLiquidity(poolId);

        console2.log("=== Existing cRECY/USDC (0.30%) Pool Repriced & Seeded ===");
        console2.log("PoolId                   :", vm.toString(poolId));
        console2.log("Atomic Seeder Contract   :", address(seeder));
        console2.log("Final sqrtPriceX96       :", finalSqrtPriceX96);
        console2.log("Final Tick ($0.88)       :", finalTick);
        console2.log("Tick Lower ($0.77912)    :", int256(TICK_LOWER));
        console2.log("Tick Upper (Uncapped)    :", int256(TICK_UPPER));
        console2.log("Active Pool Liquidity    :", finalLiquidity);
        console2.log("LP NFT Token ID          :", tokenId);
        console2.log("LP NFT Recipient         :", lpRecipient);
        console2.log("Actual cRECY Deposited   :", spentCrecy);
        console2.log("Actual USDC Deposited    :", spentUsdc);
    }

    function _getLiquidityForAmounts(
        uint160 sqrtRatioX96,
        uint160 sqrtRatioAX96,
        uint160 sqrtRatioBX96,
        uint256 amount0,
        uint256 amount1
    ) internal pure returns (uint128 liquidity) {
        uint256 intermediate = Math.mulDiv(sqrtRatioX96, sqrtRatioBX96, Q96);
        uint256 liq0 = Math.mulDiv(amount0, intermediate, uint256(sqrtRatioBX96) - uint256(sqrtRatioX96));
        uint256 liq1 = Math.mulDiv(amount1, Q96, uint256(sqrtRatioX96) - uint256(sqrtRatioAX96));
        uint256 minLiq = liq0 < liq1 ? liq0 : liq1;
        require(minLiq <= type(uint128).max, "RepriceAndSeedCrecyUsdcV4: liquidity overflow");
        liquidity = uint128(minLiq);
    }

    /// @dev Verbatim Uniswap v4-core TickMath.getSqrtPriceAtTick
    function _getSqrtPriceAtTick(int24 tick) internal pure returns (uint160 sqrtPriceX96) {
        uint256 absTick = tick < 0 ? uint256(-int256(tick)) : uint256(int256(tick));
        require(absTick <= 887272, "RepriceAndSeedCrecyUsdcV4: tick out of bounds");

        uint256 ratio = absTick & 0x1 != 0 ? 0xfffcb933bd6fad37aa2d162d1a594001 : 0x100000000000000000000000000000000;
        if (absTick & 0x2 != 0) ratio = (ratio * 0xfff97272373d413259a46990580e213a) >> 128;
        if (absTick & 0x4 != 0) ratio = (ratio * 0xfff2e50f5f656932ef12357cf3c7fdcc) >> 128;
        if (absTick & 0x8 != 0) ratio = (ratio * 0xffe5caca7e10e4e61c3624eaa0941cd0) >> 128;
        if (absTick & 0x10 != 0) ratio = (ratio * 0xffcb9843d60f6159c9db58835c926644) >> 128;
        if (absTick & 0x20 != 0) ratio = (ratio * 0xff973b41fa98c081472e6896dfb254c0) >> 128;
        if (absTick & 0x40 != 0) ratio = (ratio * 0xff2ea16466c96a3843ec78b326b52861) >> 128;
        if (absTick & 0x80 != 0) ratio = (ratio * 0xfe5dee046a99a2a811c461f1969c3053) >> 128;
        if (absTick & 0x100 != 0) ratio = (ratio * 0xfcbe86c7900a88aedcffc83b479aa3a4) >> 128;
        if (absTick & 0x200 != 0) ratio = (ratio * 0xf987a7253ac413176f2b074cf7815e54) >> 128;
        if (absTick & 0x400 != 0) ratio = (ratio * 0xf3392b0822b70005940c7a398e4b70f3) >> 128;
        if (absTick & 0x800 != 0) ratio = (ratio * 0xe7159475a2c29b7443b29c7fa6e889d9) >> 128;
        if (absTick & 0x1000 != 0) ratio = (ratio * 0xd097f3bdfd2022b8845ad8f792aa5825) >> 128;
        if (absTick & 0x2000 != 0) ratio = (ratio * 0xa9f746462d870fdf8a65dc1f90e061e5) >> 128;
        if (absTick & 0x4000 != 0) ratio = (ratio * 0x70d869a156d2a1b890bb3df62baf32f7) >> 128;
        if (absTick & 0x8000 != 0) ratio = (ratio * 0x31be135f97d08fd981231505542fcfa6) >> 128;
        if (absTick & 0x10000 != 0) ratio = (ratio * 0x9aa508b5b7a84e1c677de54f3e99bc9) >> 128;
        if (absTick & 0x20000 != 0) ratio = (ratio * 0x5d6af8dedb81196699c329225ee604) >> 128;
        if (absTick & 0x40000 != 0) ratio = (ratio * 0x2216e584f5fa1ea926041bedfe98) >> 128;
        if (absTick & 0x80000 != 0) ratio = (ratio * 0x48a170391f7dc42444e8fa2) >> 128;

        if (tick > 0) ratio = type(uint256).max / ratio;
        sqrtPriceX96 = uint160((ratio >> 32) + (ratio % (1 << 32) == 0 ? 0 : 1));
    }
}
