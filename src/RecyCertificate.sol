// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {ERC721URIStorage} from "@openzeppelin/contracts/token/ERC721/extensions/ERC721URIStorage.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";

/**
 * @title RecyCertificate / ImpactInvestmentCertificate (OpenZeppelin v5 Compatible)
 * @notice Whitepaper Section 3.1 & 4.1: Mints audited ESG & Circularity NFTs upon cRECY timelock.
 */
contract RecyCertificate is ERC721, ERC721URIStorage, AccessControl {
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    uint256 private _nextTokenId;

    address public immutable crecyToken;
    address public lockingContract;

    struct StoredCertificateMetadata {
        uint256 lockId;
        uint256 lockedCrecyAmount;
        uint256 unlockTimestamp;
    }

    mapping(uint256 => StoredCertificateMetadata) private _certificateDetails;

    event LockingContractUpdated(address indexed previousLockingContract, address indexed newLockingContract);
    event CertificateMinted(
        uint256 indexed tokenId,
        address indexed recipient,
        uint256 indexed lockId,
        uint256 lockedCrecyAmount,
        uint256 unlockTimestamp,
        string uri
    );

    constructor(address initialAdmin, address _crecyToken)
        ERC721("Impact Investment Certificate", "RECY-CERT")
    {
        require(initialAdmin != address(0) && _crecyToken != address(0), "Zero address");
        crecyToken = _crecyToken;
        _grantRole(DEFAULT_ADMIN_ROLE, initialAdmin);
        _grantRole(MINTER_ROLE, initialAdmin);
    }

    function nextTokenId() external view returns (uint256) {
        return _nextTokenId + 1;
    }

    function setLockingContract(address _lockingContract) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(_lockingContract != address(0), "Zero address");
        address previous = lockingContract;
        if (previous != address(0) && previous != _lockingContract) {
            _revokeRole(MINTER_ROLE, previous);
        }
        lockingContract = _lockingContract;
        _grantRole(MINTER_ROLE, _lockingContract);
        emit LockingContractUpdated(previous, _lockingContract);
    }

    function safeMint(address to, string memory uri) public onlyRole(MINTER_ROLE) returns (uint256) {
        require(to != address(0), "Zero recipient");
        require(bytes(uri).length > 0, "Empty URI");

        uint256 tokenId = ++_nextTokenId;
        // Write URI before _safeMint so onERC721Received callbacks observe finalized state
        _setTokenURI(tokenId, uri);
        _safeMint(to, tokenId);
        return tokenId;
    }

    function safeMintFromLock(
        address to,
        uint256 lockId,
        uint256 lockedAmount,
        uint256 unlockTimestamp,
        string calldata uri
    ) external onlyRole(MINTER_ROLE) returns (uint256 tokenId) {
        require(to != address(0), "Zero recipient");
        require(bytes(uri).length > 0, "Empty URI");

        tokenId = ++_nextTokenId;

        // Effects first (CEI): populate metadata and URI before _safeMint invokes onERC721Received
        _certificateDetails[tokenId] = StoredCertificateMetadata({
            lockId: lockId,
            lockedCrecyAmount: lockedAmount,
            unlockTimestamp: unlockTimestamp
        });
        _setTokenURI(tokenId, uri);

        emit CertificateMinted(tokenId, to, lockId, lockedAmount, unlockTimestamp, uri);

        _safeMint(to, tokenId);
    }

    /// @notice Preserves exact 4-field ABI while avoiding duplicate URI storage on Mainnet.
    function certificateDetails(uint256 tokenId)
        external
        view
        returns (
            uint256 lockId,
            uint256 lockedCrecyAmount,
            uint256 unlockTimestamp,
            string memory uri
        )
    {
        StoredCertificateMetadata memory meta = _certificateDetails[tokenId];
        string memory resolvedUri = _ownerOf(tokenId) != address(0) ? tokenURI(tokenId) : "";
        return (meta.lockId, meta.lockedCrecyAmount, meta.unlockTimestamp, resolvedUri);
    }

    function tokenURI(uint256 tokenId)
        public
        view
        override(ERC721, ERC721URIStorage)
        returns (string memory)
    {
        return super.tokenURI(tokenId);
    }

    function supportsInterface(bytes4 interfaceId)
        public
        view
        override(ERC721, ERC721URIStorage, AccessControl)
        returns (bool)
    {
        return super.supportsInterface(interfaceId);
    }
}
