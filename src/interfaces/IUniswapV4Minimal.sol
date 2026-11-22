// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

/// @notice ABI-exact Uniswap v4 PoolKey (Currency and IHooks ABI-encode as address)
struct PoolKey {
    address currency0;
    address currency1;
    uint24 fee;
    int24 tickSpacing;
    address hooks;
}

/// @notice ABI-exact Uniswap v4 SwapParams (amountSpecified < 0 = exactInput; > 0 = exactOutput)
struct SwapParams {
    bool zeroForOne;
    int256 amountSpecified;
    uint160 sqrtPriceLimitX96;
}

interface IPoolManager {
    function initialize(PoolKey memory key, uint160 sqrtPriceX96) external returns (int24 tick);
    function unlock(bytes calldata data) external returns (bytes memory);
    function swap(PoolKey memory key, SwapParams memory params, bytes calldata hookData)
        external
        returns (int256 swapDelta);
    function sync(address currency) external;
    function settle() external payable returns (uint256 paid);
    function take(address currency, address to, uint256 amount) external;
}

interface IUnlockCallback {
    function unlockCallback(bytes calldata data) external returns (bytes memory);
}

library UniswapV4Math {
    // TickMath.MIN_SQRT_PRICE + 1 and TickMath.MAX_SQRT_PRICE - 1 from @uniswap/v4-core
    uint160 internal constant MIN_PRICE_LIMIT = 4295128740;
    uint160 internal constant MAX_PRICE_LIMIT = 1461446703485210103287273052203988822378723970341;

    error InvalidTokenPair();
    error InvalidInitialPrice();
    error PriceOutOfBounds();

    function sortCurrencies(address tokenA, address tokenB)
        internal
        pure
        returns (address currency0, address currency1)
    {
        if (tokenA == address(0) || tokenB == address(0) || tokenA == tokenB) {
            revert InvalidTokenPair();
        }
        return tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
    }

    function computePoolId(PoolKey memory key) internal pure returns (bytes32) {
        return keccak256(abi.encode(key));
    }

    /// @notice Decodes Uniswap v4 BalanceDelta (upper 128 bits = amount0, lower 128 bits = amount1)
    function decodeDelta(int256 delta) internal pure returns (int128 amount0, int128 amount1) {
        assembly ("memory-safe") {
            amount0 := sar(128, delta)
            amount1 := signextend(15, delta)
        }
    }

    /**
     * @notice Computes Q64.96 sqrtPriceX96 for a cRECY (18 decimals) / USDC (6 decimals) pool.
     * @param crecy Deployed cRECY token address (18 decimals).
     * @param usdc Circle USDC address (6 decimals).
     * @param priceMicroUsdcPerWholeCrecy Price of 1 whole cRECY in micro-USDC (e.g., 50_000 = $0.05).
     */
    function computeCrecyUsdcSqrtPriceX96(
        address crecy,
        address usdc,
        uint256 priceMicroUsdcPerWholeCrecy
    ) internal pure returns (uint160 sqrtPriceX96) {
        if (crecy == address(0) || usdc == address(0) || crecy == usdc) revert InvalidTokenPair();
        if (priceMicroUsdcPerWholeCrecy == 0) revert InvalidInitialPrice();

        uint256 ratioX192;
        if (crecy < usdc) {
            // currency0 = cRECY (1e18), currency1 = USDC (1e6) => price = rawUSDC / rawCRECY = P / 1e18
            ratioX192 = Math.mulDiv(priceMicroUsdcPerWholeCrecy, uint256(1) << 192, 1e18);
        } else {
            // currency0 = USDC (1e6), currency1 = cRECY (1e18) => price = rawCRECY / rawUSDC = 1e18 / P
            ratioX192 = Math.mulDiv(1e18, uint256(1) << 192, priceMicroUsdcPerWholeCrecy);
        }

        sqrtPriceX96 = SafeCast.toUint160(Math.sqrt(ratioX192));
        if (sqrtPriceX96 < MIN_PRICE_LIMIT || sqrtPriceX96 > MAX_PRICE_LIMIT) {
            revert PriceOutOfBounds();
        }
    }
}
