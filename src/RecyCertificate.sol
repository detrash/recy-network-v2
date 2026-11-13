// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC721} from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {ERC721URIStorage} from "@openzeppelin/contracts/token/ERC721/extensions/ERC721URIStorage.sol";
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/**
 * @title RecyCertificate / ImpactInvestmentCertificate (OpenZeppelin v5 Compatible)
 * @notice Whitepaper Section 3.1 & 4.1: Mints audited ESG & Circularity NFTs upon cRECY timelock.
 */
contract RecyCertificate is ERC721, ERC721URIStorage, Ownable, AccessControl {
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    uint256 private _nextTokenId;

    address public immutable crecyToken;
    address public lockingContract;

    struct CertificateMetadata {
        uint256 lockId;
        uint256 lockedCrecyAmount;
        uint256 unlockTimestamp;
        string uri;
    }

    mapping(uint256 => CertificateMetadata) public certificateDetails;

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
        Ownable(initialAdmin)
    {
        require(initialAdmin != address(0) && _crecyToken != address(0), "Zero address");
        crecyToken = _crecyToken;
        _grantRole(DEFAULT_ADMIN_ROLE, initialAdmin);
        _grantRole(MINTER_ROLE, initialAdmin);
    }

    function setLockingContract(address _lockingContract) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(_lockingContract != address(0), "Zero address");
        lockingContract = _lockingContract;
        _grantRole(MINTER_ROLE, _lockingContract);
    }

    function safeMint(address to, string memory uri) public onlyRole(MINTER_ROLE) returns (uint256) {
        uint256 tokenId = ++_nextTokenId;
        _safeMint(to, tokenId);
        _setTokenURI(tokenId, uri);
        return tokenId;
    }

    function safeMintFromLock(
        address to,
        uint256 lockId,
        uint256 lockedAmount,
        uint256 unlockTimestamp,
        string calldata uri
    ) external onlyRole(MINTER_ROLE) returns (uint256 tokenId) {
        tokenId = ++_nextTokenId;
        _safeMint(to, tokenId);
        _setTokenURI(tokenId, uri);

        certificateDetails[tokenId] = CertificateMetadata({
            lockId: lockId,
            lockedCrecyAmount: lockedAmount,
            unlockTimestamp: unlockTimestamp,
            uri: uri
        });

        emit CertificateMinted(tokenId, to, lockId, lockedAmount, unlockTimestamp, uri);
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
