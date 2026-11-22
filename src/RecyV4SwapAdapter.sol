// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {IPoolManager, IUnlockCallback, PoolKey, SwapParams, UniswapV4Math} from "./interfaces/IUniswapV4Minimal.sol";

interface ISwapRouter02Minimal {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    struct ExactOutputSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        address recipient;
        uint256 amountOut;
        uint256 amountInMaximum;
        uint160 sqrtPriceLimitX96;
    }

    function exactInputSingle(ExactInputSingleParams calldata params) external payable returns (uint256 amountOut);
    function exactOutputSingle(ExactOutputSingleParams calldata params) external payable returns (uint256 amountIn);
}

/**
 * @title RecyV4SwapAdapter
 * @notice Bridges RecyTraceabilityCertificate's ISwapRouter interface onto Uniswap v4 PoolManager
 *         for registered v4 pools (e.g., cRECY/USDC), with optional Uniswap v3 SwapRouter02 fallback
 *         for external payment tokens (WETH/USDT/WBTC -> USDC).
 */
contract RecyV4SwapAdapter is Ownable2Step, ReentrancyGuard, IUnlockCallback {
    using SafeERC20 for IERC20;

    IPoolManager public immutable poolManager;
    address public fallbackV3Router;

    mapping(bytes32 => PoolKey) private _v4Pools;
    mapping(bytes32 => bool) public hasV4Pool;

    struct CallbackData {
        PoolKey key;
        bool zeroForOne;
        int256 amountSpecified;
        uint160 sqrtPriceLimitX96;
        address recipient;
        uint256 maxInputAllowed;
    }

    event V4PoolRegistered(
        bytes32 indexed routeKey,
        bytes32 indexed poolId,
        address indexed currency0,
        address currency1,
        uint24 fee,
        int24 tickSpacing,
        address hooks
    );
    event V4PoolRemoved(bytes32 indexed routeKey);
    event FallbackV3RouterUpdated(address indexed previousRouter, address indexed newRouter);
    event ResidualTokenSwept(address indexed token, address indexed to, uint256 amount);

    error ZeroAddress();
    error InvalidAmount();
    error InvalidTickSpacing();
    error UnexpectedEth();
    error OnlyPoolManager();
    error NoRouteConfigured();
    error SlippageExceeded(uint256 actual, uint256 expectedLimit);
    error ExcessiveInputSpent(uint256 spent, uint256 maxAllowed);
    error UnexpectedSwapDelta();

    constructor(address _poolManager, address _fallbackV3Router, address _initialOwner) Ownable(_initialOwner) {
        if (_poolManager == address(0) || _initialOwner == address(0)) revert ZeroAddress();
        poolManager = IPoolManager(_poolManager);
        fallbackV3Router = _fallbackV3Router;
    }

    function routeKeyFor(address tokenA, address tokenB, uint24 fee) public pure returns (bytes32) {
        (address c0, address c1) = UniswapV4Math.sortCurrencies(tokenA, tokenB);
        return keccak256(abi.encode(c0, c1, fee));
    }

    function getV4PoolKey(address tokenA, address tokenB, uint24 fee) external view returns (PoolKey memory) {
        return _v4Pools[routeKeyFor(tokenA, tokenB, fee)];
    }

    function registerV4Pool(
        address tokenA,
        address tokenB,
        uint24 fee,
        int24 tickSpacing,
        address hooks
    ) external onlyOwner returns (bytes32 poolId) {
        if (tickSpacing <= 0) revert InvalidTickSpacing();
        (address c0, address c1) = UniswapV4Math.sortCurrencies(tokenA, tokenB);
        bytes32 rKey = keccak256(abi.encode(c0, c1, fee));

        PoolKey memory key = PoolKey({
            currency0: c0,
            currency1: c1,
            fee: fee,
            tickSpacing: tickSpacing,
            hooks: hooks
        });

        _v4Pools[rKey] = key;
        hasV4Pool[rKey] = true;
        poolId = UniswapV4Math.computePoolId(key);

        emit V4PoolRegistered(rKey, poolId, c0, c1, fee, tickSpacing, hooks);
    }

    function removeV4Pool(address tokenA, address tokenB, uint24 fee) external onlyOwner {
        bytes32 rKey = routeKeyFor(tokenA, tokenB, fee);
        delete _v4Pools[rKey];
        hasV4Pool[rKey] = false;
        emit V4PoolRemoved(rKey);
    }

    function setFallbackV3Router(address _newFallbackV3Router) external onlyOwner {
        address previous = fallbackV3Router;
        fallbackV3Router = _newFallbackV3Router;
        emit FallbackV3RouterUpdated(previous, _newFallbackV3Router);
    }

    function exactInputSingle(ISwapRouter02Minimal.ExactInputSingleParams calldata params)
        external
        payable
        nonReentrant
        returns (uint256 amountOut)
    {
        if (msg.value != 0) revert UnexpectedEth();
        if (params.amountIn == 0) revert InvalidAmount();
        if (params.recipient == address(0)) revert ZeroAddress();

        bytes32 rKey = routeKeyFor(params.tokenIn, params.tokenOut, params.fee);
        IERC20(params.tokenIn).safeTransferFrom(msg.sender, address(this), params.amountIn);

        if (hasV4Pool[rKey]) {
            PoolKey memory key = _v4Pools[rKey];
            bool zeroForOne = (params.tokenIn == key.currency0);

            (uint256 amountInUsed, uint256 amountOutReceived) = _executeV4Swap(
                key,
                zeroForOne,
                -SafeCast.toInt256(params.amountIn), // V4 exactInput = negative amountSpecified
                params.sqrtPriceLimitX96,
                params.recipient,
                params.amountIn
            );

            if (amountOutReceived < params.amountOutMinimum) {
                revert SlippageExceeded(amountOutReceived, params.amountOutMinimum);
            }
            if (params.amountIn > amountInUsed) {
                IERC20(params.tokenIn).safeTransfer(msg.sender, params.amountIn - amountInUsed);
            }
            return amountOutReceived;
        }

        address v3Router = fallbackV3Router;
        if (v3Router == address(0)) revert NoRouteConfigured();

        IERC20(params.tokenIn).forceApprove(v3Router, params.amountIn);
        amountOut = ISwapRouter02Minimal(v3Router).exactInputSingle(params);
        IERC20(params.tokenIn).forceApprove(v3Router, 0);
    }

    function exactOutputSingle(ISwapRouter02Minimal.ExactOutputSingleParams calldata params)
        external
        payable
        nonReentrant
        returns (uint256 amountIn)
    {
        if (msg.value != 0) revert UnexpectedEth();
        if (params.amountOut == 0 || params.amountInMaximum == 0) revert InvalidAmount();
        if (params.recipient == address(0)) revert ZeroAddress();

        bytes32 rKey = routeKeyFor(params.tokenIn, params.tokenOut, params.fee);
        IERC20(params.tokenIn).safeTransferFrom(msg.sender, address(this), params.amountInMaximum);

        if (hasV4Pool[rKey]) {
            PoolKey memory key = _v4Pools[rKey];
            bool zeroForOne = (params.tokenIn == key.currency0);

            (uint256 amountInUsed, uint256 amountOutReceived) = _executeV4Swap(
                key,
                zeroForOne,
                SafeCast.toInt256(params.amountOut), // V4 exactOutput = positive amountSpecified
                params.sqrtPriceLimitX96,
                params.recipient,
                params.amountInMaximum
            );

            if (amountOutReceived < params.amountOut) {
                revert SlippageExceeded(amountOutReceived, params.amountOut);
            }
            if (params.amountInMaximum > amountInUsed) {
                IERC20(params.tokenIn).safeTransfer(msg.sender, params.amountInMaximum - amountInUsed);
            }
            return amountInUsed;
        }

        address v3Router = fallbackV3Router;
        if (v3Router == address(0)) revert NoRouteConfigured();

        IERC20(params.tokenIn).forceApprove(v3Router, params.amountInMaximum);
        amountIn = ISwapRouter02Minimal(v3Router).exactOutputSingle(params);
        IERC20(params.tokenIn).forceApprove(v3Router, 0);

        if (params.amountInMaximum > amountIn) {
            IERC20(params.tokenIn).safeTransfer(msg.sender, params.amountInMaximum - amountIn);
        }
    }

    function _executeV4Swap(
        PoolKey memory key,
        bool zeroForOne,
        int256 amountSpecified,
        uint160 sqrtPriceLimitX96,
        address recipient,
        uint256 maxInputAllowed
    ) internal returns (uint256 amountInUsed, uint256 amountOutReceived) {
        uint160 effectiveLimit = sqrtPriceLimitX96 == 0
            ? (zeroForOne ? UniswapV4Math.MIN_PRICE_LIMIT : UniswapV4Math.MAX_PRICE_LIMIT)
            : sqrtPriceLimitX96;

        bytes memory result = poolManager.unlock(
            abi.encode(
                CallbackData({
                    key: key,
                    zeroForOne: zeroForOne,
                    amountSpecified: amountSpecified,
                    sqrtPriceLimitX96: effectiveLimit,
                    recipient: recipient,
                    maxInputAllowed: maxInputAllowed
                })
            )
        );
        return abi.decode(result, (uint256, uint256));
    }

    /// @inheritdoc IUnlockCallback
    function unlockCallback(bytes calldata rawData) external override returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert OnlyPoolManager();

        CallbackData memory cb = abi.decode(rawData, (CallbackData));
        int256 rawDelta = poolManager.swap(
            cb.key,
            SwapParams({
                zeroForOne: cb.zeroForOne,
                amountSpecified: cb.amountSpecified,
                sqrtPriceLimitX96: cb.sqrtPriceLimitX96
            }),
            ""
        );

        (int128 d0, int128 d1) = UniswapV4Math.decodeDelta(rawDelta);
        int128 inputDelta = cb.zeroForOne ? d0 : d1;
        int128 outputDelta = cb.zeroForOne ? d1 : d0;

        if (inputDelta >= 0 || outputDelta < 0) revert UnexpectedSwapDelta();

        uint256 amountInUsed = uint256(uint128(-inputDelta));
        uint256 amountOutReceived = uint256(uint128(outputDelta));

        if (amountInUsed > cb.maxInputAllowed) {
            revert ExcessiveInputSpent(amountInUsed, cb.maxInputAllowed);
        }

        address inputToken = cb.zeroForOne ? cb.key.currency0 : cb.key.currency1;
        address outputToken = cb.zeroForOne ? cb.key.currency1 : cb.key.currency0;

        // V4 ERC-20 flash settlement: sync -> transfer -> settle
        poolManager.sync(inputToken);
        IERC20(inputToken).safeTransfer(address(poolManager), amountInUsed);
        poolManager.settle();

        if (amountOutReceived > 0) {
            poolManager.take(outputToken, cb.recipient, amountOutReceived);
        }

        return abi.encode(amountInUsed, amountOutReceived);
    }

    function sweepResidualToken(address token, address to) external nonReentrant onlyOwner {
        if (token == address(0) || to == address(0)) revert ZeroAddress();
        uint256 bal = IERC20(token).balanceOf(address(this));
        if (bal == 0) revert InvalidAmount();
        emit ResidualTokenSwept(token, to, bal);
        IERC20(token).safeTransfer(to, bal);
    }
}
