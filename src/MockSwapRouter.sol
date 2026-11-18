// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

interface IERC20Minimal {
    function decimals() external view returns (uint8);
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

/**
 * @title MockSwapRouter
 * @notice Testnet-only Uniswap V3 SwapRouter02 mock for Celo Sepolia.
 *         Matches the exact 7-field ExactInputSingleParams and ExactOutputSingleParams
 *         structs declared in RecyTraceabilityCertificate.sol.
 *         DO NOT deploy to Celo Mainnet (use official Uniswap V3 SwapRouter02 on Mainnet).
 */
contract MockSwapRouter {
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

    address public owner;
    address public immutable usdcToken;
    address public immutable crecyToken;

    /// @notice Mock price of 1e18 cRECY expressed in 6-decimal USDC (default: 250_000 = $0.25)
    uint256 public crecyPriceInUsdc;

    event MockSwapExecuted(
        address indexed sender,
        address indexed tokenIn,
        address indexed tokenOut,
        uint256 amountIn,
        uint256 amountOut,
        address recipient
    );

    event PriceUpdated(uint256 oldPrice, uint256 newPrice);

    modifier onlyOwner() {
        require(msg.sender == owner, "MockSwapRouter: not owner");
        _;
    }

    constructor(address _usdcToken, address _crecyToken, uint256 _initialCrecyPriceInUsdc) {
        require(_usdcToken != address(0) && _crecyToken != address(0), "MockSwapRouter: zero token");
        require(_initialCrecyPriceInUsdc > 0, "MockSwapRouter: zero price");
        owner = msg.sender;
        usdcToken = _usdcToken;
        crecyToken = _crecyToken;
        crecyPriceInUsdc = _initialCrecyPriceInUsdc;
    }

    function setCrecyPriceInUsdc(uint256 _newPrice) external onlyOwner {
        require(_newPrice > 0, "MockSwapRouter: zero price");
        emit PriceUpdated(crecyPriceInUsdc, _newPrice);
        crecyPriceInUsdc = _newPrice;
    }

    function withdrawToken(address _token, address _to, uint256 _amount) external onlyOwner {
        require(_to != address(0), "MockSwapRouter: zero recipient");
        require(IERC20Minimal(_token).transfer(_to, _amount), "MockSwapRouter: withdraw failed");
    }

    /// @notice Implements SwapRouter02 exactInputSingle (used for USDC -> cRECY buybacks)
    function exactInputSingle(ExactInputSingleParams calldata params)
        external
        payable
        returns (uint256 amountOut)
    {
        require(params.amountIn > 0, "MockSwapRouter: zero amountIn");
        require(params.recipient != address(0), "MockSwapRouter: zero recipient");

        amountOut = _quoteExactInput(params.tokenIn, params.tokenOut, params.amountIn);
        require(amountOut >= params.amountOutMinimum, "MockSwapRouter: slippage exceeded");
        require(
            IERC20Minimal(params.tokenOut).balanceOf(address(this)) >= amountOut,
            "MockSwapRouter: insufficient output liquidity"
        );

        require(
            IERC20Minimal(params.tokenIn).transferFrom(msg.sender, address(this), params.amountIn),
            "MockSwapRouter: transferFrom failed"
        );
        require(
            IERC20Minimal(params.tokenOut).transfer(params.recipient, amountOut),
            "MockSwapRouter: transfer failed"
        );

        emit MockSwapExecuted(
            msg.sender,
            params.tokenIn,
            params.tokenOut,
            params.amountIn,
            amountOut,
            params.recipient
        );
    }

    /// @notice Implements SwapRouter02 exactOutputSingle (used for payToken -> USDC conversion)
    function exactOutputSingle(ExactOutputSingleParams calldata params)
        external
        payable
        returns (uint256 amountIn)
    {
        require(params.amountOut > 0, "MockSwapRouter: zero amountOut");
        require(params.recipient != address(0), "MockSwapRouter: zero recipient");

        amountIn = _quoteExactOutput(params.tokenIn, params.tokenOut, params.amountOut);
        require(amountIn <= params.amountInMaximum, "MockSwapRouter: max input exceeded");
        require(
            IERC20Minimal(params.tokenOut).balanceOf(address(this)) >= params.amountOut,
            "MockSwapRouter: insufficient output liquidity"
        );

        require(
            IERC20Minimal(params.tokenIn).transferFrom(msg.sender, address(this), amountIn),
            "MockSwapRouter: transferFrom failed"
        );
        require(
            IERC20Minimal(params.tokenOut).transfer(params.recipient, params.amountOut),
            "MockSwapRouter: transfer failed"
        );

        emit MockSwapExecuted(
            msg.sender,
            params.tokenIn,
            params.tokenOut,
            amountIn,
            params.amountOut,
            params.recipient
        );
    }

    function _quoteExactInput(address tokenIn, address tokenOut, uint256 amountIn)
        internal
        view
        returns (uint256)
    {
        if (tokenIn == usdcToken && tokenOut == crecyToken) {
            return (amountIn * 1e18) / crecyPriceInUsdc;
        }
        if (tokenIn == crecyToken && tokenOut == usdcToken) {
            return (amountIn * crecyPriceInUsdc) / 1e18;
        }
        return _scaleDecimals(tokenIn, tokenOut, amountIn);
    }

    function _quoteExactOutput(address tokenIn, address tokenOut, uint256 amountOut)
        internal
        view
        returns (uint256)
    {
        if (tokenIn == crecyToken && tokenOut == usdcToken) {
            // Round up by 1 wei to ensure output is fully covered
            return (amountOut * 1e18 + crecyPriceInUsdc - 1) / crecyPriceInUsdc;
        }
        if (tokenIn == usdcToken && tokenOut == crecyToken) {
            return (amountOut * crecyPriceInUsdc + 1e18 - 1) / 1e18;
        }
        return _scaleDecimals(tokenOut, tokenIn, amountOut);
    }

    function _scaleDecimals(address fromToken, address toToken, uint256 amount)
        internal
        view
        returns (uint256)
    {
        uint8 decFrom = _safeDecimals(fromToken);
        uint8 decTo = _safeDecimals(toToken);
        if (decTo > decFrom) {
            return amount * (10 ** (decTo - decFrom));
        }
        if (decFrom > decTo) {
            return amount / (10 ** (decFrom - decTo));
        }
        return amount;
    }

    function _safeDecimals(address token) internal view returns (uint8) {
        try IERC20Minimal(token).decimals() returns (uint8 d) {
            return d;
        } catch {
            return 18;
        }
    }
}
