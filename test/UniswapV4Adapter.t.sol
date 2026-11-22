// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {RecyV4SwapAdapter, ISwapRouter02Minimal} from "../src/RecyV4SwapAdapter.sol";
import {IPoolManager, IUnlockCallback, PoolKey, SwapParams, UniswapV4Math} from "../src/interfaces/IUniswapV4Minimal.sol";

contract MockToken is ERC20 {
    uint8 private immutable _dec;

    constructor(string memory n, string memory s, uint8 dec) ERC20(n, s) {
        _dec = dec;
        _mint(msg.sender, 1_000_000_000 * (10 ** dec));
    }

    function decimals() public view override returns (uint8) {
        return _dec;
    }
}

contract MockV4PoolManager is IPoolManager {
    address private _syncedCurrency;
    uint256 private _syncedBalance;
    uint256 private _expectedIn;
    address private _expectedInToken;

    // Rate: 1 USDC (1e6) = 20 cRECY (20e18) => $0.05/cRECY
    address public immutable usdc;
    address public immutable crecy;

    constructor(address _usdc, address _crecy) {
        usdc = _usdc;
        crecy = _crecy;
    }

    function initialize(PoolKey memory, uint160) external pure override returns (int24) {
        return 0;
    }

    function unlock(bytes calldata data) external override returns (bytes memory res) {
        res = IUnlockCallback(msg.sender).unlockCallback(data);
        require(_expectedIn == 0, "CurrencyNotSettled");
    }

    function swap(PoolKey memory key, SwapParams memory params, bytes calldata)
        external
        override
        returns (int256 swapDelta)
    {
        address tokenIn = params.zeroForOne ? key.currency0 : key.currency1;
        uint256 amtIn;
        uint256 amtOut;

        if (params.amountSpecified < 0) {
            amtIn = uint256(-params.amountSpecified);
            amtOut = tokenIn == usdc ? amtIn * 20 * 1e12 : amtIn / (20 * 1e12);
        } else {
            amtOut = uint256(params.amountSpecified);
            amtIn = tokenIn == usdc ? amtOut / (20 * 1e12) : amtOut * 20 * 1e12;
        }

        _expectedIn = amtIn;
        _expectedInToken = tokenIn;

        int128 d0 = params.zeroForOne ? -int128(uint128(amtIn)) : int128(uint128(amtOut));
        int128 d1 = params.zeroForOne ? int128(uint128(amtOut)) : -int128(uint128(amtIn));

        assembly ("memory-safe") {
            swapDelta := or(shl(128, d0), and(sub(shl(128, 1), 1), d1))
        }
    }

    function sync(address currency) external override {
        _syncedCurrency = currency;
        _syncedBalance = IERC20(currency).balanceOf(address(this));
    }

    function settle() external payable override returns (uint256 paid) {
        require(_syncedCurrency == _expectedInToken, "Wrong settle currency");
        paid = IERC20(_syncedCurrency).balanceOf(address(this)) - _syncedBalance;
        require(paid == _expectedIn, "Insufficient settle");
        _expectedIn = 0;
    }

    function take(address currency, address to, uint256 amount) external override {
        require(IERC20(currency).transfer(to, amount), "Take transfer failed");
    }
}

contract UniswapV4AdapterTest is Test {
    MockToken public usdc;
    MockToken public crecy;
    MockV4PoolManager public poolManager;
    RecyV4SwapAdapter public adapter;

    address public stakingRecipient = address(0x57A4);

    function setUp() public {
        usdc = new MockToken("USD Coin", "USDC", 6);
        crecy = new MockToken("cRECY", "cRECY", 18);
        poolManager = new MockV4PoolManager(address(usdc), address(crecy));
        adapter = new RecyV4SwapAdapter(address(poolManager), address(0), address(this));

        // Seed mock PoolManager liquidity
        usdc.transfer(address(poolManager), 1_000_000 * 1e6);
        crecy.transfer(address(poolManager), 20_000_000 * 1e18);

        adapter.registerV4Pool(address(crecy), address(usdc), 3000, 60, address(0));
    }

    function test_V4ExactInputBuybackUsdcToCrecy() public {
        uint256 usdcIn = 25 * 1e6; // $25 USDC buyback leg
        usdc.approve(address(adapter), usdcIn);

        uint256 crecyOut = adapter.exactInputSingle(
            ISwapRouter02Minimal.ExactInputSingleParams({
                tokenIn: address(usdc),
                tokenOut: address(crecy),
                fee: 3000,
                recipient: stakingRecipient,
                amountIn: usdcIn,
                amountOutMinimum: 499 * 1e18,
                sqrtPriceLimitX96: 0
            })
        );

        assertEq(crecyOut, 500 * 1e18);
        assertEq(crecy.balanceOf(stakingRecipient), 500 * 1e18);
    }

    function test_V4ExactOutputRefundsUnusedInput() public {
        uint256 maxCrecyIn = 1_500 * 1e18;
        uint256 targetUsdcOut = 50 * 1e6; // Requires 1,000 cRECY at $0.05
        crecy.approve(address(adapter), maxCrecyIn);

        uint256 balBefore = crecy.balanceOf(address(this));
        uint256 spent = adapter.exactOutputSingle(
            ISwapRouter02Minimal.ExactOutputSingleParams({
                tokenIn: address(crecy),
                tokenOut: address(usdc),
                fee: 3000,
                recipient: stakingRecipient,
                amountOut: targetUsdcOut,
                amountInMaximum: maxCrecyIn,
                sqrtPriceLimitX96: 0
            })
        );

        assertEq(spent, 1_000 * 1e18);
        assertEq(balBefore - crecy.balanceOf(address(this)), 1_000 * 1e18); // 500 cRECY refunded
        assertEq(usdc.balanceOf(stakingRecipient), targetUsdcOut);
    }

    function test_V4SlippageGuardReverts() public {
        usdc.approve(address(adapter), 25 * 1e6);
        vm.expectRevert(abi.encodeWithSelector(RecyV4SwapAdapter.SlippageExceeded.selector, 500 * 1e18, 501 * 1e18));
        adapter.exactInputSingle(
            ISwapRouter02Minimal.ExactInputSingleParams({
                tokenIn: address(usdc),
                tokenOut: address(crecy),
                fee: 3000,
                recipient: stakingRecipient,
                amountIn: 25 * 1e6,
                amountOutMinimum: 501 * 1e18,
                sqrtPriceLimitX96: 0
            })
        );
    }

    function test_OnlyPoolManagerCanInvokeUnlockCallback() public {
        vm.expectRevert(RecyV4SwapAdapter.OnlyPoolManager.selector);
        adapter.unlockCallback("");
    }

    function test_SqrtPriceX96ScalingBothSortOrders() public pure {
        // Case A: crecy < usdc (price = 50_000 / 1e18 => ~1.771595e22)
        uint160 pA = UniswapV4Math.computeCrecyUsdcSqrtPriceX96(address(0x1000), address(0x2000), 50_000);
        assertGt(pA, 1.77e22);
        assertLt(pA, 1.78e22);

        // Case B: usdc < crecy (price = 1e18 / 50_000 => ~3.543191e35)
        uint160 pB = UniswapV4Math.computeCrecyUsdcSqrtPriceX96(address(0x2000), address(0x1000), 50_000);
        assertGt(pB, 3.54e35);
        assertLt(pB, 3.55e35);
    }
}
