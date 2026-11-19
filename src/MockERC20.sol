// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title MockERC20
 * @notice Minimal mintable ERC-20 for Celo Sepolia testnet payment tokens (WBTC, BRLA, WETH).
 *         DO NOT deploy to Celo Mainnet.
 */
contract MockERC20 {
    string public name;
    string public symbol;
    uint8 public immutable decimals;
    uint256 public totalSupply;
    address public owner;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    error NotOwner();
    error ZeroAddress();
    error InsufficientBalance(uint256 available, uint256 required);
    error InsufficientAllowance(uint256 available, uint256 required);

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    constructor(
        string memory _name,
        string memory _symbol,
        uint8 _decimals,
        uint256 _initialSupply
    ) {
        name = _name;
        symbol = _symbol;
        decimals = _decimals;
        owner = msg.sender;
        emit OwnershipTransferred(address(0), msg.sender);

        if (_initialSupply > 0) {
            totalSupply = _initialSupply;
            balanceOf[msg.sender] = _initialSupply;
            emit Transfer(address(0), msg.sender, _initialSupply);
        }
    }

    function transferOwnership(address _newOwner) external onlyOwner {
        if (_newOwner == address(0)) revert ZeroAddress();
        emit OwnershipTransferred(owner, _newOwner);
        owner = _newOwner;
    }

    function mint(address _to, uint256 _amount) external onlyOwner {
        if (_to == address(0)) revert ZeroAddress();
        totalSupply += _amount;
        balanceOf[_to] += _amount;
        emit Transfer(address(0), _to, _amount);
    }

    function burn(uint256 _amount) external {
        uint256 bal = balanceOf[msg.sender];
        if (bal < _amount) revert InsufficientBalance(bal, _amount);
        unchecked {
            balanceOf[msg.sender] = bal - _amount;
            totalSupply -= _amount;
        }
        emit Transfer(msg.sender, address(0), _amount);
    }

    function approve(address _spender, uint256 _amount) external returns (bool) {
        if (_spender == address(0)) revert ZeroAddress();
        allowance[msg.sender][_spender] = _amount;
        emit Approval(msg.sender, _spender, _amount);
        return true;
    }

    function transfer(address _to, uint256 _amount) external returns (bool) {
        return _transfer(msg.sender, _to, _amount);
    }

    function transferFrom(address _from, address _to, uint256 _amount) external returns (bool) {
        uint256 currentAllowance = allowance[_from][msg.sender];
        if (currentAllowance != type(uint256).max) {
            if (currentAllowance < _amount) {
                revert InsufficientAllowance(currentAllowance, _amount);
            }
            unchecked {
                allowance[_from][msg.sender] = currentAllowance - _amount;
            }
        }
        return _transfer(_from, _to, _amount);
    }

    function _transfer(address _from, address _to, uint256 _amount) internal returns (bool) {
        if (_to == address(0)) revert ZeroAddress();
        uint256 bal = balanceOf[_from];
        if (bal < _amount) revert InsufficientBalance(bal, _amount);
        unchecked {
            balanceOf[_from] = bal - _amount;
            balanceOf[_to] += _amount;
        }
        emit Transfer(_from, _to, _amount);
        return true;
    }
}
