// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Burnable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {ERC20Pausable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Pausable.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title cRECY Token (OpenZeppelin v5 Compatible)
 * @notice Whitepaper Section 3.1 & 3.2: Hard-capped at 22,000,000 cRECY.
 */
contract CRecy is ERC20, ERC20Pausable, Ownable, AccessControl {
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    uint256 public constant MAX_SUPPLY = 22_000_000 * 1e18;

    constructor(address initialTreasury, uint256 initialSupply)
        ERC20("cRECY", "cRecy")
        Ownable(msg.sender)
    {
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
        require(totalSupply() + amount <= MAX_SUPPLY, "Exceeds 22M hard cap");
        _mint(to, amount);
    }

    function setMinter(address minter, bool allowed) external onlyOwner {
        if (allowed) {
            _grantRole(MINTER_ROLE, minter);
        } else {
            _revokeRole(MINTER_ROLE, minter);
        }
    }

    // OpenZeppelin v5 replaces _beforeTokenTransfer with _update
    function _update(address from, address to, uint256 value)
        internal
        override(ERC20, ERC20Pausable)
    {
        super._update(from, to, value);
    }
}
