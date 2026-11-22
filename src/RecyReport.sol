// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {IERC4906} from "@openzeppelin/contracts/interfaces/IERC4906.sol";
import {IERC165} from "@openzeppelin/contracts/interfaces/IERC165.sol";
import {ERC721Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC721/ERC721Upgradeable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {RecyReportData} from "./RecyReportData.sol";
import {RecyConstants} from "./lib/RecyConstants.sol";
import {RecyTypes} from "./lib/RecyTypes.sol";
import {RecyErrors} from "./lib/RecyErrors.sol";
import {RecyReward} from "./lib/RecyReward.sol";

contract RecyReport is
    Initializable,
    ERC721Upgradeable,
    IERC4906,
    AccessControlUpgradeable,
    PausableUpgradeable,
    UUPSUpgradeable,
    ReentrancyGuardUpgradeable
{
    using SafeERC20 for IERC20;

    RecyReportData private data;
    ERC20 public token;

    bytes32 public constant AUDITOR_ROLE = RecyConstants.AUDITOR_ROLE;
    bytes32 public constant RECYCLER_ROLE = RecyConstants.RECYCLER_ROLE;
    bytes32 public constant EMERGENCY_ROLE = RecyConstants.EMERGENCY_ROLE;
    uint256 public constant MAX_MATERIALS_PER_REPORT = 20;

    event ReportResult(uint256 indexed tokenId, address indexed recycler, uint64 recycleDate, uint128 wasteAmount);
    event ReportValidated(
        uint256 indexed tokenId, address indexed validator, uint64 validationDate, uint128 rewardAmount
    );
    event ReportInvalidated(uint256 indexed tokenId, address indexed validator, uint64 invalidationDate);
    event RewardClaimed(uint256 indexed tokenId, address indexed claimant, uint128 rewardAmount);
    event FundsWalletUpdated(address indexed signatory, address indexed fundAddress);

    error InvalidReportStatus();
    error InvalidMaterials();
    error InvalidWasteAmount();
    error WasteAmountMismatch();
    error InvalidAttributeId();
    error AuditorCannotBeRecycler();
    error AuditorCannotBeGenerator();

    address public protocolAddress;

    uint128 public nftNextId;
    uint64 public unlockDelay; // Delay in seconds before the reward can be claimed
    uint8 public shareRecycler; // Percentage of the reward that goes to the recycler
    uint8 public shareValidator; // Percentage of the reward that goes to the validator
    uint8 public shareGenerator; // Percentage of the reward that goes to the generator
    uint8 public shareProtocol; // Percentage of the reward that goes to the protocol

    uint256 public rewardTotal;
    uint256 public rewardMinted; // Retained storage slot for UUPS upgrade compatibility
    uint256 public rewardClaimed;

    mapping(uint256 => RecyTypes.RecyInfo) public info;
    mapping(uint256 => RecyTypes.RecyMaterials[]) public materials;
    mapping(uint256 => RecyTypes.RecyReward) public reward;
    mapping(uint256 => uint8) public status;

    mapping(address => address) public funds;

    // Appended storage (upgrade-safe): immutable original waste generator per report tokenId
    mapping(uint256 => address) public reportGenerator;

    // Reserved storage gap for future UUPS upgrades
    uint256[49] private __gap;

    /**
     * @notice Checks if caller is the original generator, current NFT owner, recycler, or validator of the report.
     */
    modifier onlyTokenOwnerOrRecyclerOrAuditor(uint256 _tokenId) {
        address currentOwner = _ownerOf(_tokenId);
        if (currentOwner == address(0)) revert RecyErrors.NftNotExists();

        RecyTypes.RecyInfo storage _info = info[_tokenId];
        address generator = reportGenerator[_tokenId];
        if (generator == address(0)) {
            generator = currentOwner;
        }

        require(
            generator == msg.sender || currentOwner == msg.sender || _info.recycler == msg.sender
                || _info.validator == msg.sender,
            RecyErrors.NotReportOwner()
        );

        _;
    }

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        string memory _name,
        string memory _symbol,
        address _tokenAddress,
        address _dataAddress,
        address _protocolAddress,
        uint64 _unlockDelay,
        uint8 _shareRecycler,
        uint8 _shareValidator,
        uint8 _shareGenerator,
        uint8 _shareProtocol
    ) public initializer {
        if (_tokenAddress == address(0) || _dataAddress == address(0) || _protocolAddress == address(0)) {
            revert RecyErrors.AddressInvalid();
        }

        require(
            uint256(_shareRecycler) + uint256(_shareValidator) + uint256(_shareGenerator) + uint256(_shareProtocol)
                == RecyConstants.REWARD_TOTAL_PERCENTAGE,
            RecyErrors.RecyReportInvalidShareDistribution()
        );

        __ERC721_init(_name, _symbol);
        __AccessControl_init();
        __Pausable_init();
        __UUPSUpgradeable_init();
        __ReentrancyGuard_init();

        token = ERC20(_tokenAddress);
        data = RecyReportData(_dataAddress);

        protocolAddress = _protocolAddress;
        unlockDelay = _unlockDelay;

        shareRecycler = _shareRecycler;
        shareValidator = _shareValidator;
        shareGenerator = _shareGenerator;
        shareProtocol = _shareProtocol;

        // Grant admin/operational roles strictly to initializer caller (factory); protocolAddress is fee sink only
        _grantRole(DEFAULT_ADMIN_ROLE, _msgSender());
        _grantRole(AUDITOR_ROLE, _msgSender());
        _grantRole(RECYCLER_ROLE, _msgSender());
        _grantRole(EMERGENCY_ROLE, _msgSender());
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyRole(DEFAULT_ADMIN_ROLE) {}

    function version() public pure returns (string memory) {
        return "1.1.0";
    }

    function pauseRewardClaiming() external onlyRole(EMERGENCY_ROLE) {
        _pause();
    }

    function unpauseRewardClaiming() external onlyRole(EMERGENCY_ROLE) {
        _unpause();
    }

    function supportsInterface(bytes4 interfaceId)
        public
        view
        virtual
        override(AccessControlUpgradeable, ERC721Upgradeable, IERC165)
        returns (bool)
    {
        return interfaceId == RecyConstants.ERC4906_INTERFACE_ID || super.supportsInterface(interfaceId);
    }

    function tokenURI(uint256 _tokenId) public view override returns (string memory _tokenUri) {
        require(_ownerOf(_tokenId) != address(0), RecyErrors.NftNotExists());

        return data.tokenUriAttributes(
            _tokenId, status[_tokenId], token, reward[_tokenId], info[_tokenId], materials[_tokenId]
        );
    }

    function tokenJson(uint256 _tokenId) public view returns (string memory _tokenUri) {
        require(_ownerOf(_tokenId) != address(0), RecyErrors.NftNotExists());

        return data.tokenJson(_tokenId, status[_tokenId], token, reward[_tokenId], info[_tokenId], materials[_tokenId]);
    }

    /**
     * @notice Mints a new empty Recycle Report NFT (strict CEI before _safeMint).
     */
    function mintRecyReport() external nonReentrant whenNotPaused {
        uint256 nftId = nftNextId;
        nftNextId = SafeCast.toUint128(nftId + RecyConstants.NFT_ID_INCREMENT);
        status[nftId] = RecyConstants.RECYCLE_CREATED;
        reportGenerator[nftId] = msg.sender;

        _safeMint(msg.sender, nftId);
    }

    /**
     * @notice Mints a new Recycle Report NFT with complete recycling data (strict CEI before _safeMint).
     */
    function mintRecyReportResult(
        address _generator,
        uint64 _recycleDate,
        uint128 _wasteAmount,
        uint32[] calldata _materials,
        uint128[] calldata _materialAmounts,
        uint32[] calldata _recycleTypes,
        uint32[] calldata _recycleShapes,
        uint32 _disposalMethod
    ) external nonReentrant whenNotPaused onlyRole(RECYCLER_ROLE) {
        if (_generator == address(0)) revert RecyErrors.AddressInvalid();

        uint256 nftId = nftNextId;
        nftNextId = SafeCast.toUint128(nftId + RecyConstants.NFT_ID_INCREMENT);

        _validateAndStoreReportData(
            nftId,
            _recycleDate,
            _wasteAmount,
            _materials,
            _materialAmounts,
            _recycleTypes,
            _recycleShapes,
            _disposalMethod
        );

        reportGenerator[nftId] = _generator;
        status[nftId] = RecyConstants.RECYCLE_COMPLETED;

        emit MetadataUpdate(nftId);
        emit ReportResult(nftId, msg.sender, _recycleDate, _wasteAmount);

        _safeMint(_generator, nftId);
    }

    /**
     * @notice Populates an existing RECYCLE_CREATED NFT with recycling data.
     * @dev Reverts if token does not exist or has already moved past RECYCLE_CREATED.
     */
    function setRecyReportResult(
        uint256 _tokenId,
        uint64 _recycleDate,
        uint128 _wasteAmount,
        uint32[] calldata _materials,
        uint128[] calldata _materialAmounts,
        uint32[] calldata _recycleTypes,
        uint32[] calldata _recycleShapes,
        uint32 _disposalMethod
    ) external nonReentrant whenNotPaused onlyRole(RECYCLER_ROLE) {
        if (_ownerOf(_tokenId) == address(0)) revert RecyErrors.NftNotExists();
        if (status[_tokenId] != RecyConstants.RECYCLE_CREATED) revert InvalidReportStatus();

        delete materials[_tokenId];

        _validateAndStoreReportData(
            _tokenId,
            _recycleDate,
            _wasteAmount,
            _materials,
            _materialAmounts,
            _recycleTypes,
            _recycleShapes,
            _disposalMethod
        );

        status[_tokenId] = RecyConstants.RECYCLE_COMPLETED;

        emit MetadataUpdate(_tokenId);
        emit ReportResult(_tokenId, msg.sender, _recycleDate, _wasteAmount);
    }

    function _validateAndStoreReportData(
        uint256 _tokenId,
        uint64 _recycleDate,
        uint128 _wasteAmount,
        uint32[] calldata _materials,
        uint128[] calldata _materialAmounts,
        uint32[] calldata _recycleTypes,
        uint32[] calldata _recycleShapes,
        uint32 _disposalMethod
    ) internal {
        uint256 len = _materials.length;
        if (len != _materialAmounts.length || len != _recycleTypes.length || len != _recycleShapes.length) {
            revert RecyErrors.ArrayLengthMismatch();
        }
        if (len == 0 || len > MAX_MATERIALS_PER_REPORT) revert InvalidMaterials();
        if (_wasteAmount == 0) revert InvalidWasteAmount();
        if (_disposalMethod > type(uint8).max) revert InvalidAttributeId();

        RecyTypes.RecyInfo storage _info = info[_tokenId];
        _info.recycler = msg.sender;
        _info.recycleDate = _recycleDate;
        _info.wasteAmount = _wasteAmount;

        RecyTypes.RecyMaterials[] storage recyMaterials = materials[_tokenId];
        uint256 sumMaterialAmounts = 0;

        for (uint256 i = 0; i < len; i++) {
            uint32 matId = _materials[i];
            uint128 matAmt = _materialAmounts[i];
            if (matId > type(uint8).max) revert InvalidAttributeId();
            if (matAmt == 0) revert InvalidWasteAmount();

            sumMaterialAmounts += matAmt;
            recyMaterials.push(
                RecyTypes.RecyMaterials({
                    material: matId,
                    recycleType: _recycleTypes[i],
                    recycleShape: _recycleShapes[i],
                    disposalMethod: _disposalMethod,
                    amountRecycled: matAmt
                })
            );
        }

        if (sumMaterialAmounts != _wasteAmount) revert WasteAmountMismatch();
    }

    /**
     * @notice Validates a completed recycling report and calculates rewards.
     * @dev Enforces separation of duties: validator cannot be the report's recycler or generator.
     */
    function validateRecyReport(uint256 _tokenId) external nonReentrant whenNotPaused onlyRole(AUDITOR_ROLE) {
        if (_ownerOf(_tokenId) == address(0)) revert RecyErrors.NftNotExists();
        require(status[_tokenId] == RecyConstants.RECYCLE_COMPLETED, RecyErrors.RecyReportNotCompleted());

        RecyTypes.RecyInfo storage _info = info[_tokenId];
        address generator = _resolveGenerator(_tokenId);

        if (msg.sender == _info.recycler) revert AuditorCannotBeRecycler();
        if (msg.sender == generator) revert AuditorCannotBeGenerator();

        uint128 computedReward = RecyReward.calculateReward(_info.wasteAmount, token.totalSupply());
        uint64 nowTs = SafeCast.toUint64(block.timestamp);

        _info.validator = msg.sender;
        _info.validationDate = nowTs;

        RecyTypes.RecyReward storage _reward = reward[_tokenId];
        _reward.rewardAmount = computedReward;
        _reward.rewardUnlockDate = SafeCast.toUint64(block.timestamp + unlockDelay);

        rewardTotal += computedReward;
        status[_tokenId] = RecyConstants.RECYCLE_VALIDATED;

        emit MetadataUpdate(_tokenId);
        emit ReportValidated(_tokenId, msg.sender, nowTs, computedReward);
    }

    /**
     * @notice Permanently invalidates a completed recycling report on-chain.
     */
    function invalidateRecyReport(uint256 _tokenId) external nonReentrant whenNotPaused onlyRole(AUDITOR_ROLE) {
        if (_ownerOf(_tokenId) == address(0)) revert RecyErrors.NftNotExists();
        require(status[_tokenId] == RecyConstants.RECYCLE_COMPLETED, RecyErrors.RecyReportNotCompleted());

        RecyTypes.RecyInfo storage _info = info[_tokenId];
        if (msg.sender == _info.recycler) revert AuditorCannotBeRecycler();

        uint64 nowTs = SafeCast.toUint64(block.timestamp);
        _info.validator = msg.sender;
        _info.validationDate = nowTs;

        status[_tokenId] = RecyConstants.RECYCLE_INVALIDATED;

        emit MetadataUpdate(_tokenId);
        emit ReportInvalidated(_tokenId, msg.sender, nowTs);
    }

    /**
     * @notice Claims and distributes rewards for a validated recycling report using SafeERC20 and exact remainder conservation.
     */
    function claimRecyReportReward(uint256 _tokenId)
        public
        nonReentrant
        whenNotPaused
        onlyTokenOwnerOrRecyclerOrAuditor(_tokenId)
    {
        require(status[_tokenId] == RecyConstants.RECYCLE_VALIDATED, RecyErrors.RecyReportNotValidated());

        RecyTypes.RecyReward storage _reward = reward[_tokenId];
        require(_reward.rewardUnlockDate <= block.timestamp, RecyErrors.RewardNotUnlocked());
        uint128 ra = _reward.rewardAmount;
        require(token.balanceOf(address(this)) >= ra, RecyErrors.InsufficientRewardBalance());

        // Effects first (CEI)
        rewardClaimed += uint256(ra);
        status[_tokenId] = RecyConstants.RECYCLE_REWARDED;

        RecyTypes.RecyInfo storage _info = info[_tokenId];
        address generator = _resolveGenerator(_tokenId);
        address recycler = _info.recycler;
        address auditor = _info.validator;

        uint256 genAmt = (uint256(ra) * shareGenerator) / RecyConstants.REWARD_TOTAL_PERCENTAGE;
        uint256 recAmt = (uint256(ra) * shareRecycler) / RecyConstants.REWARD_TOTAL_PERCENTAGE;
        uint256 valAmt = (uint256(ra) * shareValidator) / RecyConstants.REWARD_TOTAL_PERCENTAGE;
        // Assign any rounding dust (0-3 wei) to protocolAddress so 100% of `ra` is conserved
        uint256 proAmt = uint256(ra) - genAmt - recAmt - valAmt;

        emit MetadataUpdate(_tokenId);
        emit RewardClaimed(_tokenId, msg.sender, ra);

        IERC20 rewardToken = IERC20(address(token));
        if (genAmt > 0) {
            rewardToken.safeTransfer(funds[generator] == address(0) ? generator : funds[generator], genAmt);
        }
        if (recAmt > 0) {
            rewardToken.safeTransfer(funds[recycler] == address(0) ? recycler : funds[recycler], recAmt);
        }
        if (valAmt > 0) {
            rewardToken.safeTransfer(funds[auditor] == address(0) ? auditor : funds[auditor], valAmt);
        }
        if (proAmt > 0) {
            rewardToken.safeTransfer(protocolAddress, proAmt);
        }
    }

    /**
     * @notice Adapter view matching IRecyReport.getReportDetails for RecyTraceabilityCertificate.
     */
    function getReportDetails(uint256 _tokenId)
        external
        view
        returns (
            address generator,
            address recycler,
            address auditor,
            uint8 wasteType,
            uint8 treatmentType,
            uint256 volumeGrams,
            uint64 reportTimestamp,
            bool isValidated
        )
    {
        if (_ownerOf(_tokenId) == address(0)) revert RecyErrors.NftNotExists();

        RecyTypes.RecyInfo storage _info = info[_tokenId];
        uint8 st = status[_tokenId];

        generator = _resolveGenerator(_tokenId);
        recycler = _info.recycler;
        auditor = _info.validator;
        reportTimestamp = _info.recycleDate;
        volumeGrams = uint256(_info.wasteAmount) / 1_000; // milligrams -> grams
        isValidated = (st == RecyConstants.RECYCLE_VALIDATED || st == RecyConstants.RECYCLE_REWARDED);

        RecyTypes.RecyMaterials[] storage mats = materials[_tokenId];
        if (mats.length > 0) {
            wasteType = SafeCast.toUint8(mats[0].material);
            treatmentType = SafeCast.toUint8(mats[0].disposalMethod);
        }
    }

    function getRecyReportMaterials(uint256 _tokenId) external view returns (RecyTypes.RecyMaterials[] memory) {
        return materials[_tokenId];
    }

    function unlockDate(uint256 _tokenId) external view returns (uint64) {
        RecyTypes.RecyReward storage _reward = reward[_tokenId];
        return _reward.rewardUnlockDate;
    }

    /**
     * @notice Sets or clears (address(0)) the payout fund wallet for a signatory.
     * @dev Only callable by DEFAULT_ADMIN_ROLE.
     */
    function setFundsWallet(address _signatory, address _fundAddress) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (_signatory == address(0)) revert RecyErrors.AddressInvalid();
        funds[_signatory] = _fundAddress;
        emit FundsWalletUpdated(_signatory, _fundAddress);
    }

    function _resolveGenerator(uint256 _tokenId) internal view returns (address) {
        address orig = reportGenerator[_tokenId];
        return orig != address(0) ? orig : ownerOf(_tokenId);
    }
}
