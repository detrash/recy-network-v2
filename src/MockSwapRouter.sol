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
 * @notice Multi-token testnet Uniswap V3 SwapRouter02 mock for Celo Sepolia.
 *         Supports configurable USD prices (6 decimals per 1 whole token) for WBTC,
 *         WETH, BRLA, cRECY, cUSD, CELO, and USDC.
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

    /// @notice Price of 1 whole token (10**decimals) in 6-decimal USDC.
    ///         Unset tokens default to 1_000_000 ($1.00 USD).
    mapping(address => uint256) public tokenPriceInUsdc;

    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event TokenPriceUpdated(address indexed token, uint256 oldPrice, uint256 newPrice);
    event MockSwapExecuted(
        address indexed sender,
        address indexed tokenIn,
        address indexed tokenOut,
        uint256 amountIn,
        uint256 amountOut,
        address recipient
    );

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

        tokenPriceInUsdc[_usdcToken] = 1_000_000;
        tokenPriceInUsdc[_crecyToken] = _initialCrecyPriceInUsdc;

        emit OwnershipTransferred(address(0), msg.sender);
        emit TokenPriceUpdated(_usdcToken, 0, 1_000_000);
        emit TokenPriceUpdated(_crecyToken, 0, _initialCrecyPriceInUsdc);
    }

    function transferOwnership(address _newOwner) external onlyOwner {
        require(_newOwner != address(0), "MockSwapRouter: zero owner");
        emit OwnershipTransferred(owner, _newOwner);
        owner = _newOwner;
    }

    function setTokenPriceInUsdc(address _token, uint256 _newPriceInUsdc) external onlyOwner {
        require(_token != address(0), "MockSwapRouter: zero token");
        require(_newPriceInUsdc > 0, "MockSwapRouter: zero price");
        uint256 oldPrice = tokenPriceInUsdc[_token];
        tokenPriceInUsdc[_token] = _newPriceInUsdc;
        emit TokenPriceUpdated(_token, oldPrice, _newPriceInUsdc);
    }

    function setCrecyPriceInUsdc(uint256 _newPriceInUsdc) external onlyOwner {
        require(_newPriceInUsdc > 0, "MockSwapRouter: zero price");
        uint256 oldPrice = tokenPriceInUsdc[crecyToken];
        tokenPriceInUsdc[crecyToken] = _newPriceInUsdc;
        emit TokenPriceUpdated(crecyToken, oldPrice, _newPriceInUsdc);
    }

    function crecyPriceInUsdc() external view returns (uint256) {
        return _priceOrDefault(crecyToken);
    }

    function withdrawToken(address _token, address _to, uint256 _amount) external onlyOwner {
        require(_token != address(0), "MockSwapRouter: zero token");
        require(_to != address(0), "MockSwapRouter: zero recipient");
        require(IERC20Minimal(_token).transfer(_to, _amount), "MockSwapRouter: withdraw failed");
    }

    function quoteExactInput(address tokenIn, address tokenOut, uint256 amountIn)
        public
        view
        returns (uint256)
    {
        uint256 pIn = _priceOrDefault(tokenIn);
        uint256 pOut = _priceOrDefault(tokenOut);
        uint256 scaleIn = 10 ** _safeDecimals(tokenIn);
        uint256 scaleOut = 10 ** _safeDecimals(tokenOut);
        return (amountIn * pIn * scaleOut) / (scaleIn * pOut);
    }

    function quoteExactOutput(address tokenIn, address tokenOut, uint256 amountOut)
        public
        view
        returns (uint256)
    {
        uint256 pIn = _priceOrDefault(tokenIn);
        uint256 pOut = _priceOrDefault(tokenOut);
        uint256 scaleIn = 10 ** _safeDecimals(tokenIn);
        uint256 scaleOut = 10 ** _safeDecimals(tokenOut);
        uint256 denom = scaleOut * pIn;
        return (amountOut * pOut * scaleIn + denom - 1) / denom;
    }

    function exactInputSingle(ExactInputSingleParams calldata params)
        external
        returns (uint256 amountOut)
    {
        require(params.amountIn > 0, "MockSwapRouter: zero amountIn");
        require(params.recipient != address(0), "MockSwapRouter: zero recipient");

        amountOut = quoteExactInput(params.tokenIn, params.tokenOut, params.amountIn);
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

    function exactOutputSingle(ExactOutputSingleParams calldata params)
        external
        returns (uint256 amountIn)
    {
        require(params.amountOut > 0, "MockSwapRouter: zero amountOut");
        require(params.recipient != address(0), "MockSwapRouter: zero recipient");

        amountIn = quoteExactOutput(params.tokenIn, params.tokenOut, params.amountOut);
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

    function _priceOrDefault(address token) internal view returns (uint256) {
        uint256 p = tokenPriceInUsdc[token];
        return p == 0 ? 1_000_000 : p;
    }

    function _safeDecimals(address token) internal view returns (uint8) {
        try IERC20Minimal(token).decimals() returns (uint8 d) {
            return d;
        } catch {
            return 18;
        }
    }
}
