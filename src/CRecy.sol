// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Pausable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Pausable.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";

/**
 * @title cRECY Token (OpenZeppelin v5 Compatible)
 * @notice Whitepaper Section 3.1 & 3.2: Non-burnable utility/tracking token hard-capped at 22,000,000 cRECY.
 * @dev Governance uses AccessControl exclusively. Transfer DEFAULT_ADMIN_ROLE and PAUSER_ROLE to a Safe multisig
 *      on Ethereum Mainnet (note: pausing freezes ERC-20 transfers inside Uniswap V4 PoolManager).
 */
contract CRecy is ERC20, ERC20Pausable, AccessControl {
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    uint256 public constant MAX_SUPPLY = 22_000_000 * 1e18;

    event MinterUpdated(address indexed minter, bool allowed);

    constructor(address initialTreasury, uint256 initialSupply) ERC20("cRECY", "cRECY") {
        require(initialTreasury != address(0), "Zero treasury address");
        require(initialSupply <= MAX_SUPPLY, "Exceeds 22M cap");

        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(PAUSER_ROLE, msg.sender);
        _grantRole(MINTER_ROLE, msg.sender);

        _mint(initialTreasury, initialSupply);
    }

    function pause() public onlyRole(PAUSER_ROLE) {
        _pause();
    }

    function unpause() public onlyRole(PAUSER_ROLE) {
        _unpause();
    }

    function mint(address to, uint256 amount) public onlyRole(MINTER_ROLE) {
        require(to != address(0), "Zero recipient");
        require(totalSupply() + amount <= MAX_SUPPLY, "Exceeds 22M hard cap");
        _mint(to, amount);
    }

    function setMinter(address minter, bool allowed) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(minter != address(0), "Zero minter address");
        if (allowed) {
            _grantRole(MINTER_ROLE, minter);
        } else {
            _revokeRole(MINTER_ROLE, minter);
        }
        emit MinterUpdated(minter, allowed);
    }

    function _update(address from, address to, uint256 value)
        internal
        override(ERC20, ERC20Pausable)
    {
        super._update(from, to, value);
    }
}
