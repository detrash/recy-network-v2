// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {ERC721Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC721/ERC721Upgradeable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {PausableUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/PausableUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {RecyTraceabilityMetadata} from "./lib/RecyTraceabilityMetadata.sol";

interface IRecyReport {
    function getReportDetails(uint256 reportId)
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
        );
}

interface IRecyReportFactory {
    function getNameByProxy(address proxy) external view returns (string memory);
}

interface ISwapRouter02 {
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
 * @title RecyTraceabilityCertificate
 * @author Recy Network (Detrash Tecnologia Ltda)
 * @notice Consolidates validated RecyReports for a given actor and time period into a soulbound
 *         ERC-721 Waste Traceability Certificate with a full plaintext on-chain actor & report audit trail.
 *         Converts incoming payments to USDC, splits proceeds, executes slippage-protected USDC -> cRECY
 *         buybacks via RecyV4SwapAdapter, and queues failed or zero-min-out buybacks safely for treasury execution.
 */
contract RecyTraceabilityCertificate is
    Initializable,
    ERC721Upgradeable,
    AccessControlUpgradeable,
    PausableUpgradeable,
    ReentrancyGuardUpgradeable,
    UUPSUpgradeable
{
    using SafeERC20 for IERC20;

    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant AUDITOR_ROLE = keccak256("AUDITOR_ROLE");
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");
    uint16 public constant BPS_DENOMINATOR = 10_000;
    /// @notice Bounded to 50 reports/cert so worst-case consolidation stays strictly below Ethereum EIP-7825 (16.77M gas).
    uint256 public constant MAX_REPORTS_PER_CERTIFICATE = 50;

    uint8 public constant BUYBACK_QUEUE_ZERO_MIN_OUT = 1;
    uint8 public constant BUYBACK_QUEUE_NO_ROUTER = 2;
    uint8 public constant BUYBACK_QUEUE_SWAP_FAILED = 3;

    uint8 private constant ACTOR_GENERATOR_BIT = 1;
    uint8 private constant ACTOR_RECYCLER_BIT = 2;
    uint8 private constant ACTOR_AUDITOR_BIT = 4;

    struct ReportRef {
        address reportProxy;
        uint256 reportId;
    }

    struct WasteTreatmentVolume {
        uint8 wasteType;
        uint8 treatmentType;
        uint256 volumeGrams;
    }

    struct ConsolidatedReportRecord {
        address reportProxy;
        uint256 reportId;
        address generator;
        address recycler;
        address reportAuditor;
        uint8 wasteType;
        uint8 treatmentType;
        uint64 reportTimestamp;
        uint256 volumeGrams;
    }

    struct CertificateData {
        address issuer;
        uint64 periodStart;
        uint64 periodEnd;
        uint64 mintedAt;
        uint64 validatedAt;
        bool isValidated;
        address validatedBy;
        uint256 totalVolumeGrams;
        uint256 totalSustainableVolumeGrams;
        uint256 auditorRewardEscrowUsdc;
        address usdcTokenSnapshot;
        bytes32[] reportHashes;
    }

    struct SplitConfig {
        uint16 adminBps;
        uint16 auditorBps;
        uint16 buybackBps;
    }

    error InvalidTimePeriod();
    error EmptyReportBatch();
    error ReportBatchTooLarge(uint256 provided, uint256 maxAllowed);
    error ZeroTotalVolume();
    error UnregisteredReportProxy(address proxy);
    error ReportNotValidated(address proxy, uint256 reportId);
    error ReportOutsidePeriod(address proxy, uint256 reportId, uint64 timestamp);
    error IssuerNotInvolvedInReport(address proxy, uint256 reportId, address issuer);
    error ReportAlreadyConsolidatedInPeriod(
        address issuer, uint64 periodStart, uint64 periodEnd, address proxy, uint256 reportId
    );
    error CertificateDoesNotExist(uint256 certId);
    error CertificateAlreadyValidated(uint256 certId);
    error ConflictOfInterestAuditor(uint256 certId, address auditor);
    error InvalidSplitDistribution(uint256 totalBps);
    error ZeroAddressNotAllowed();
    error InvalidContractAddress();
    error SwapRouterNotConfigured();
    error InvalidPaymentAmount();
    error InsufficientPaymentReceived();
    error InvalidBuybackAmount();
    error InvalidBuybackSlippage();
    error InsufficientPendingBuyback(uint256 requested, uint256 available);
    error BuybackSlippageExceeded(uint256 actualOut, uint256 minOut);
    error CertificateIsSoulbound();

    event CertificateMinted(
        uint256 indexed certId,
        address indexed issuer,
        address indexed payToken,
        uint64 periodStart,
        uint64 periodEnd,
        uint256 reportCount,
        uint256 totalVolumeGrams,
        uint256 totalSustainableVolumeGrams,
        uint256 usdcPricePaid
    );

    event ReportConsolidated(
        uint256 indexed certId,
        address indexed reportProxy,
        uint256 indexed reportId,
        address generator,
        address recycler,
        address reportAuditor,
        uint8 wasteType,
        uint8 treatmentType,
        uint256 volumeGrams,
        uint64 reportTimestamp
    );

    event PaymentSwappedToUsdc(
        uint256 indexed certId, address indexed payToken, uint256 payTokenSpent, uint256 usdcReceived
    );

    event CertificateValidated(
        uint256 indexed certId, address indexed auditor, uint64 validatedAt, uint256 auditorUsdcRewardPaid
    );

    event BuybackExecuted(uint256 indexed certId, uint256 usdcIn, uint256 cRecyOut, address indexed recipient);

    event BuybackQueued(uint256 indexed certId, address indexed usdcToken, uint256 usdcAmount, uint8 reasonCode);

    event PendingBuybackExecuted(
        address indexed usdcToken, uint256 usdcIn, uint256 cRecyOut, address indexed recipient
    );

    event PendingBuybackSweptToAdmin(address indexed usdcToken, uint256 usdcAmount, address indexed adminWallet);

    event PricingUpdated(address indexed usdcToken, uint256 newPriceInUsdc);
    event VolumetricPricingUpdated(
        address indexed usdcToken, uint256 pricePerKgInUsdc, uint256 minCertificatePriceInUsdc, uint64 updatedAt
    );
    event SplitConfigUpdated(uint16 adminBps, uint16 auditorBps, uint16 buybackBps);
    event WalletsUpdated(address adminWallet, address buybackRecipient, address swapRouter, uint24 usdcToCRecyPoolFee);
    event LandfillTreatmentIdUpdated(uint8 newLandfillTreatmentId);
    event WhitelistedReportProxyUpdated(address indexed proxy, bool status);

    // --- V1 Storage Slots (preserve order for UUPS upgrades) ---
    IRecyReportFactory public reportFactory;
    IERC20 public usdcToken;
    IERC20 public cRecyToken;
    ISwapRouter02 public swapRouter;

    address public adminWallet;
    address public buybackRecipient;
    uint24 public usdcToCRecyPoolFee;
    uint8 public landfillTreatmentId;

    uint256 public certificatePriceInUsdc;
    SplitConfig public splitConfig;
    uint256 private _nextCertId;

    mapping(uint256 => CertificateData) private _certificates;
    mapping(uint256 => mapping(uint8 => mapping(uint8 => uint256))) private _volumeMatrix;
    mapping(uint256 => uint16[]) private _activeMatrixKeys;
    mapping(uint256 => mapping(uint16 => bool)) private _hasMatrixKey;
    mapping(uint256 => mapping(address => bool)) private _excludedAuditors;

    mapping(bytes32 => bool) public isReportConsolidatedByIssuerInPeriod;
    mapping(uint256 => mapping(bytes32 => bool)) private _isReportInCertificate;
    mapping(address => bool) public whitelistedReportProxies;

    // --- V2 Volumetric Pricing Storage ---
    uint256 public pricePerKgInUsdc;
    uint256 public minCertificatePriceInUsdc;
    uint64 public pricingLastUpdatedAt;

    // --- V3 Audit & On-Chain Auditability Storage (strictly appended; consumes 6 slots from __gap) ---
    mapping(address => uint256) public pendingBuybackUsdc;
    mapping(uint256 => ConsolidatedReportRecord[]) private _certificateReports;
    mapping(uint256 => address[]) private _certGenerators;
    mapping(uint256 => address[]) private _certRecyclers;
    mapping(uint256 => address[]) private _certReportAuditors;
    mapping(uint256 => mapping(address => uint8)) private _certActorFlags;

    uint256[41] private __gap;

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        address _admin,
        address _reportFactory,
        address _usdcToken,
        address _cRecyToken,
        address _swapRouter,
        address _adminWallet,
        address _buybackRecipient,
        uint24 _usdcToCRecyPoolFee,
        uint8 _landfillTreatmentId,
        uint256 _initialPriceInUsdc,
        SplitConfig calldata _initialSplit
    ) external initializer {
        if (_admin == address(0)) revert ZeroAddressNotAllowed();

        __ERC721_init("Recy Waste Traceability Certificate", "rWTC");
        __AccessControl_init();
        __Pausable_init();
        __ReentrancyGuard_init();
        __UUPSUpgradeable_init();

        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(ADMIN_ROLE, _admin);
        _grantRole(UPGRADER_ROLE, _admin);

        _initDependencies(_reportFactory, _usdcToken, _cRecyToken, _swapRouter, _adminWallet, _buybackRecipient);
        _initEconomicParams(_usdcToCRecyPoolFee, _landfillTreatmentId, _initialPriceInUsdc, _initialSplit);
    }

    function _initDependencies(
        address _reportFactory,
        address _usdcToken,
        address _cRecyToken,
        address _swapRouter,
        address _adminWallet,
        address _buybackRecipient
    ) internal {
        if (
            _usdcToken == address(0) || _cRecyToken == address(0) || _adminWallet == address(0)
                || _buybackRecipient == address(0)
        ) revert ZeroAddressNotAllowed();
        if (_usdcToken.code.length == 0 || _cRecyToken.code.length == 0) revert InvalidContractAddress();

        reportFactory = IRecyReportFactory(_reportFactory);
        usdcToken = IERC20(_usdcToken);
        cRecyToken = IERC20(_cRecyToken);
        swapRouter = ISwapRouter02(_swapRouter);
        adminWallet = _adminWallet;
        buybackRecipient = _buybackRecipient;
    }

    function _initEconomicParams(
        uint24 _usdcToCRecyPoolFee,
        uint8 _landfillTreatmentId,
        uint256 _initialPriceInUsdc,
        SplitConfig calldata _initialSplit
    ) internal {
        uint256 totalBps = uint256(_initialSplit.adminBps) + uint256(_initialSplit.auditorBps)
            + uint256(_initialSplit.buybackBps);
        if (totalBps != BPS_DENOMINATOR) revert InvalidSplitDistribution(totalBps);

        usdcToCRecyPoolFee = _usdcToCRecyPoolFee;
        landfillTreatmentId = _landfillTreatmentId;
        certificatePriceInUsdc = _initialPriceInUsdc;
        splitConfig = _initialSplit;
        _nextCertId = 1;
    }

    function mintCertificate(
        uint64 periodStart,
        uint64 periodEnd,
        ReportRef[] calldata reports,
        address payToken,
        uint24 payTokenToUsdcPoolFee,
        uint256 maxPayTokenIn,
        uint256 minCRecyOut
    ) external nonReentrant whenNotPaused returns (uint256 certId) {
        if (periodStart >= periodEnd || periodEnd > block.timestamp) revert InvalidTimePeriod();
        uint256 reportCount = reports.length;
        if (reportCount == 0) revert EmptyReportBatch();
        if (reportCount > MAX_REPORTS_PER_CERTIFICATE) {
            revert ReportBatchTooLarge(reportCount, MAX_REPORTS_PER_CERTIFICATE);
        }

        certId = _nextCertId++;
        CertificateData storage cert = _certificates[certId];
        cert.issuer = msg.sender;
        cert.periodStart = periodStart;
        cert.periodEnd = periodEnd;
        cert.mintedAt = SafeCast.toUint64(block.timestamp);
        cert.usdcTokenSnapshot = address(usdcToken);

        _excludedAuditors[certId][msg.sender] = true;

        (uint256 totalVol, uint256 sustainableVol) = _consolidateReports(certId, periodStart, periodEnd, reports);
        if (totalVol == 0) revert ZeroTotalVolume();

        cert.totalVolumeGrams = totalVol;
        cert.totalSustainableVolumeGrams = sustainableVol;

        uint256 priceInUsdc = calculateCertificatePrice(totalVol);
        uint256 adminUsdc = 0;
        uint256 buybackUsdc = 0;

        if (priceInUsdc > 0) {
            SplitConfig memory split = splitConfig;
            adminUsdc = (priceInUsdc * split.adminBps) / BPS_DENOMINATOR;
            uint256 auditorUsdc = (priceInUsdc * split.auditorBps) / BPS_DENOMINATOR;
            buybackUsdc = priceInUsdc - adminUsdc - auditorUsdc;

            if (auditorUsdc > 0) {
                cert.auditorRewardEscrowUsdc = auditorUsdc;
            }

            _collectPaymentAsUsdc(certId, priceInUsdc, payToken, payTokenToUsdcPoolFee, maxPayTokenIn);
            _distributeUsdcProceeds(certId, adminUsdc, buybackUsdc, minCRecyOut);
        }

        emit CertificateMinted(
            certId, msg.sender, payToken, periodStart, periodEnd, reportCount, totalVol, sustainableVol, priceInUsdc
        );

        _safeMint(msg.sender, certId);
    }

    function _consolidateReports(uint256 certId, uint64 periodStart, uint64 periodEnd, ReportRef[] calldata reports)
        internal
        returns (uint256 totalVol, uint256 sustainableVol)
    {
        CertificateData storage cert = _certificates[certId];
        uint256 reportCount = reports.length;
        uint8 landfillId = landfillTreatmentId;

        for (uint256 i = 0; i < reportCount;) {
            ReportRef calldata ref = reports[i];

            if (!_isValidProxy(ref.reportProxy)) {
                revert UnregisteredReportProxy(ref.reportProxy);
            }

            bytes32 consolidationKey =
                keccak256(abi.encode(msg.sender, periodStart, periodEnd, ref.reportProxy, ref.reportId));
            if (isReportConsolidatedByIssuerInPeriod[consolidationKey]) {
                revert ReportAlreadyConsolidatedInPeriod(
                    msg.sender, periodStart, periodEnd, ref.reportProxy, ref.reportId
                );
            }
            isReportConsolidatedByIssuerInPeriod[consolidationKey] = true;
            _isReportInCertificate[certId][keccak256(abi.encode(ref.reportProxy, ref.reportId))] = true;

            (uint256 volGrams, uint8 treatmentType) = _recordSingleReport(cert, certId, periodStart, periodEnd, ref);

            totalVol += volGrams;
            if (treatmentType != landfillId) {
                sustainableVol += volGrams;
            }

            unchecked {
                ++i;
            }
        }
    }

    function _recordSingleReport(
        CertificateData storage cert,
        uint256 certId,
        uint64 periodStart,
        uint64 periodEnd,
        ReportRef calldata ref
    ) internal returns (uint256 volumeGrams, uint8 treatmentType) {
        ConsolidatedReportRecord memory rec;
        rec.reportProxy = ref.reportProxy;
        rec.reportId = ref.reportId;

        bool reportValidated;
        (
            rec.generator,
            rec.recycler,
            rec.reportAuditor,
            rec.wasteType,
            rec.treatmentType,
            rec.volumeGrams,
            rec.reportTimestamp,
            reportValidated
        ) = IRecyReport(ref.reportProxy).getReportDetails(ref.reportId);

        if (!reportValidated) {
            revert ReportNotValidated(ref.reportProxy, ref.reportId);
        }
        if (rec.reportTimestamp < periodStart || rec.reportTimestamp > periodEnd) {
            revert ReportOutsidePeriod(ref.reportProxy, ref.reportId, rec.reportTimestamp);
        }
        if (msg.sender != rec.generator && msg.sender != rec.recycler && msg.sender != rec.reportAuditor) {
            revert IssuerNotInvolvedInReport(ref.reportProxy, ref.reportId, msg.sender);
        }

        _storeReportAuditTrail(cert, certId, rec);
        return (rec.volumeGrams, rec.treatmentType);
    }

    function _storeReportAuditTrail(CertificateData storage cert, uint256 certId, ConsolidatedReportRecord memory rec)
        internal
    {
        _excludedAuditors[certId][rec.generator] = true;
        _excludedAuditors[certId][rec.recycler] = true;
        _excludedAuditors[certId][rec.reportAuditor] = true;

        _recordActor(certId, rec.generator, ACTOR_GENERATOR_BIT, _certGenerators[certId]);
        _recordActor(certId, rec.recycler, ACTOR_RECYCLER_BIT, _certRecyclers[certId]);
        _recordActor(certId, rec.reportAuditor, ACTOR_AUDITOR_BIT, _certReportAuditors[certId]);

        _certificateReports[certId].push(rec);

        uint16 matrixKey = (uint16(rec.wasteType) << 8) | uint16(rec.treatmentType);
        if (!_hasMatrixKey[certId][matrixKey]) {
            _hasMatrixKey[certId][matrixKey] = true;
            _activeMatrixKeys[certId].push(matrixKey);
        }
        _volumeMatrix[certId][rec.wasteType][rec.treatmentType] += rec.volumeGrams;

        cert.reportHashes.push(_hashReportRecord(rec));

        emit ReportConsolidated(
            certId,
            rec.reportProxy,
            rec.reportId,
            rec.generator,
            rec.recycler,
            rec.reportAuditor,
            rec.wasteType,
            rec.treatmentType,
            rec.volumeGrams,
            rec.reportTimestamp
        );
    }

    function _recordActor(uint256 certId, address actor, uint8 bit, address[] storage list) internal {
        if (actor == address(0)) return;
        uint8 flags = _certActorFlags[certId][actor];
        if ((flags & bit) == 0) {
            _certActorFlags[certId][actor] = flags | bit;
            list.push(actor);
        }
    }

    function _hashReportRecord(ConsolidatedReportRecord memory rec) internal view returns (bytes32) {
        return keccak256(
            abi.encode(
                block.chainid,
                rec.reportProxy,
                rec.reportId,
                rec.generator,
                rec.recycler,
                rec.reportAuditor,
                rec.wasteType,
                rec.treatmentType,
                rec.volumeGrams,
                rec.reportTimestamp
            )
        );
    }

    function validateCertificate(uint256 certId) external nonReentrant onlyRole(AUDITOR_ROLE) {
        CertificateData storage cert = _certificates[certId];
        if (cert.issuer == address(0)) revert CertificateDoesNotExist(certId);
        if (cert.isValidated) revert CertificateAlreadyValidated(certId);
        if (_excludedAuditors[certId][msg.sender]) {
            revert ConflictOfInterestAuditor(certId, msg.sender);
        }

        uint64 nowTs = SafeCast.toUint64(block.timestamp);
        cert.isValidated = true;
        cert.validatedAt = nowTs;
        cert.validatedBy = msg.sender;

        uint256 rewardUsdc = cert.auditorRewardEscrowUsdc;
        cert.auditorRewardEscrowUsdc = 0;

        emit CertificateValidated(certId, msg.sender, nowTs, rewardUsdc);

        if (rewardUsdc > 0) {
            IERC20(cert.usdcTokenSnapshot).safeTransfer(msg.sender, rewardUsdc);
        }
    }

    function executePendingBuyback(address _usdcToken, uint256 _amount, uint256 _minCRecyOut)
        external
        nonReentrant
        onlyRole(ADMIN_ROLE)
        returns (uint256 cRecyOut)
    {
        if (_usdcToken == address(0)) revert ZeroAddressNotAllowed();
        if (_amount == 0) revert InvalidBuybackAmount();
        if (_minCRecyOut == 0) revert InvalidBuybackSlippage();
        if (address(swapRouter) == address(0)) revert SwapRouterNotConfigured();

        uint256 available = pendingBuybackUsdc[_usdcToken];
        if (_amount > available) revert InsufficientPendingBuyback(_amount, available);

        pendingBuybackUsdc[_usdcToken] = available - _amount;

        IERC20 usdc = IERC20(_usdcToken);
        usdc.forceApprove(address(swapRouter), _amount);

        cRecyOut = swapRouter.exactInputSingle(
            ISwapRouter02.ExactInputSingleParams({
                tokenIn: _usdcToken,
                tokenOut: address(cRecyToken),
                fee: usdcToCRecyPoolFee,
                recipient: buybackRecipient,
                amountIn: _amount,
                amountOutMinimum: _minCRecyOut,
                sqrtPriceLimitX96: 0
            })
        );

        usdc.forceApprove(address(swapRouter), 0);
        if (cRecyOut < _minCRecyOut) revert BuybackSlippageExceeded(cRecyOut, _minCRecyOut);

        emit PendingBuybackExecuted(_usdcToken, _amount, cRecyOut, buybackRecipient);
    }

    function sweepPendingBuybackToAdmin(address _usdcToken, uint256 _amount)
        external
        nonReentrant
        onlyRole(ADMIN_ROLE)
    {
        if (_usdcToken == address(0)) revert ZeroAddressNotAllowed();
        if (_amount == 0) revert InvalidBuybackAmount();

        uint256 available = pendingBuybackUsdc[_usdcToken];
        if (_amount > available) revert InsufficientPendingBuyback(_amount, available);

        pendingBuybackUsdc[_usdcToken] = available - _amount;
        emit PendingBuybackSweptToAdmin(_usdcToken, _amount, adminWallet);

        IERC20(_usdcToken).safeTransfer(adminWallet, _amount);
    }

    function _collectPaymentAsUsdc(
        uint256 certId,
        uint256 priceInUsdc,
        address payToken,
        uint24 payTokenToUsdcPoolFee,
        uint256 maxPayTokenIn
    ) internal {
        if (payToken == address(0)) revert ZeroAddressNotAllowed();
        IERC20 usdc = usdcToken;
        uint256 usdcBefore = usdc.balanceOf(address(this));

        if (payToken == address(usdc)) {
            usdc.safeTransferFrom(msg.sender, address(this), priceInUsdc);
        } else {
            if (address(swapRouter) == address(0)) revert SwapRouterNotConfigured();
            if (maxPayTokenIn == 0) revert InvalidPaymentAmount();

            IERC20 incomingToken = IERC20(payToken);
            uint256 payBefore = incomingToken.balanceOf(address(this));
            incomingToken.safeTransferFrom(msg.sender, address(this), maxPayTokenIn);
            uint256 actualPayIn = incomingToken.balanceOf(address(this)) - payBefore;
            if (actualPayIn == 0) revert InvalidPaymentAmount();

            incomingToken.forceApprove(address(swapRouter), actualPayIn);

            uint256 amountInUsed = swapRouter.exactOutputSingle(
                ISwapRouter02.ExactOutputSingleParams({
                    tokenIn: payToken,
                    tokenOut: address(usdc),
                    fee: payTokenToUsdcPoolFee,
                    recipient: address(this),
                    amountOut: priceInUsdc,
                    amountInMaximum: actualPayIn,
                    sqrtPriceLimitX96: 0
                })
            );

            incomingToken.forceApprove(address(swapRouter), 0);

            if (actualPayIn > amountInUsed) {
                incomingToken.safeTransfer(msg.sender, actualPayIn - amountInUsed);
            }

            emit PaymentSwappedToUsdc(certId, payToken, amountInUsed, priceInUsdc);
        }

        if (usdc.balanceOf(address(this)) - usdcBefore < priceInUsdc) {
            revert InsufficientPaymentReceived();
        }
    }

    function _distributeUsdcProceeds(uint256 certId, uint256 adminUsdc, uint256 buybackUsdc, uint256 minCRecyOut)
        internal
    {
        IERC20 usdc = usdcToken;

        if (adminUsdc > 0) {
            usdc.safeTransfer(adminWallet, adminUsdc);
        }

        if (buybackUsdc > 0) {
            if (address(swapRouter) == address(0)) {
                pendingBuybackUsdc[address(usdc)] += buybackUsdc;
                emit BuybackQueued(certId, address(usdc), buybackUsdc, BUYBACK_QUEUE_NO_ROUTER);
            } else if (minCRecyOut == 0) {
                pendingBuybackUsdc[address(usdc)] += buybackUsdc;
                emit BuybackQueued(certId, address(usdc), buybackUsdc, BUYBACK_QUEUE_ZERO_MIN_OUT);
            } else {
                usdc.forceApprove(address(swapRouter), buybackUsdc);

                try swapRouter.exactInputSingle(
                    ISwapRouter02.ExactInputSingleParams({
                        tokenIn: address(usdc),
                        tokenOut: address(cRecyToken),
                        fee: usdcToCRecyPoolFee,
                        recipient: buybackRecipient,
                        amountIn: buybackUsdc,
                        amountOutMinimum: minCRecyOut,
                        sqrtPriceLimitX96: 0
                    })
                ) returns (
                    uint256 cRecyOut
                ) {
                    usdc.forceApprove(address(swapRouter), 0);
                    emit BuybackExecuted(certId, buybackUsdc, cRecyOut, buybackRecipient);
                } catch {
                    usdc.forceApprove(address(swapRouter), 0);
                    pendingBuybackUsdc[address(usdc)] += buybackUsdc;
                    emit BuybackQueued(certId, address(usdc), buybackUsdc, BUYBACK_QUEUE_SWAP_FAILED);
                }
            }
        }
    }

    /// @dev Enforces strict soulbound semantics: certificates can only be minted to `cert.issuer`, never transferred or burned.
    function _update(address to, uint256 tokenId, address auth) internal override returns (address) {
        if (_ownerOf(tokenId) != address(0)) {
            revert CertificateIsSoulbound();
        }
        return super._update(to, tokenId, auth);
    }

    function _isValidProxy(address proxy) internal view returns (bool) {
        if (whitelistedReportProxies[proxy]) return true;
        if (address(reportFactory) != address(0)) {
            try reportFactory.getNameByProxy(proxy) returns (string memory proxyName) {
                return bytes(proxyName).length != 0;
            } catch {
                return false;
            }
        }
        return false;
    }

    // --- On-Chain Audit & View Functions ---

    function getCertificate(uint256 certId)
        external
        view
        returns (
            address issuer,
            uint64 periodStart,
            uint64 periodEnd,
            uint256 totalVolumeGrams,
            uint256 totalSustainableVolumeGrams,
            bool isValidated,
            uint64 validatedAt,
            address validatedBy,
            bytes32[] memory reportHashes
        )
    {
        CertificateData storage cert = _certificates[certId];
        if (cert.issuer == address(0)) revert CertificateDoesNotExist(certId);
        return (
            cert.issuer,
            cert.periodStart,
            cert.periodEnd,
            cert.totalVolumeGrams,
            cert.totalSustainableVolumeGrams,
            cert.isValidated,
            cert.validatedAt,
            cert.validatedBy,
            cert.reportHashes
        );
    }

    function getCertificateReports(uint256 certId) external view returns (ConsolidatedReportRecord[] memory records) {
        if (_certificates[certId].issuer == address(0)) revert CertificateDoesNotExist(certId);
        return _certificateReports[certId];
    }

    function getCertificateActors(uint256 certId)
        external
        view
        returns (
            address issuer,
            address[] memory generators,
            address[] memory recyclers,
            address[] memory reportAuditors,
            address certificateAuditor
        )
    {
        CertificateData storage cert = _certificates[certId];
        if (cert.issuer == address(0)) revert CertificateDoesNotExist(certId);
        return
            (
                cert.issuer,
                _certGenerators[certId],
                _certRecyclers[certId],
                _certReportAuditors[certId],
                cert.validatedBy
            );
    }

    function getCertificateVolumeBreakdown(uint256 certId)
        external
        view
        returns (WasteTreatmentVolume[] memory breakdown)
    {
        if (_certificates[certId].issuer == address(0)) revert CertificateDoesNotExist(certId);
        uint16[] storage keys = _activeMatrixKeys[certId];
        uint256 len = keys.length;
        breakdown = new WasteTreatmentVolume[](len);

        for (uint256 i = 0; i < len;) {
            uint16 key = keys[i];
            // forge-lint: disable-next-line(unsafe-typecast)
            uint8 wType = uint8(key >> 8);
            uint8 tType = uint8(key & 0xFF);
            breakdown[i] = WasteTreatmentVolume({
                wasteType: wType, treatmentType: tType, volumeGrams: _volumeMatrix[certId][wType][tType]
            });
            unchecked {
                ++i;
            }
        }
    }

    function isReportInCertificate(uint256 certId, address reportProxy, uint256 reportId) external view returns (bool) {
        return _isReportInCertificate[certId][keccak256(abi.encode(reportProxy, reportId))];
    }

    function hasIssuerConsolidatedReportInPeriod(
        address issuer,
        uint64 periodStart,
        uint64 periodEnd,
        address reportProxy,
        uint256 reportId
    ) external view returns (bool) {
        bytes32 key = keccak256(abi.encode(issuer, periodStart, periodEnd, reportProxy, reportId));
        return isReportConsolidatedByIssuerInPeriod[key];
    }

    function canAuditorValidate(uint256 certId, address auditor) external view returns (bool) {
        CertificateData storage cert = _certificates[certId];
        if (cert.issuer == address(0) || cert.isValidated) return false;
        if (!hasRole(AUDITOR_ROLE, auditor)) return false;
        return !_excludedAuditors[certId][auditor];
    }

    function tokenJson(uint256 certId) public view returns (string memory) {
        _requireOwned(certId);
        return RecyTraceabilityMetadata.buildTokenJson(_buildMetadataInput(certId));
    }

    function tokenURI(uint256 certId) public view override returns (string memory) {
        _requireOwned(certId);
        return RecyTraceabilityMetadata.buildTokenUri(_buildMetadataInput(certId));
    }

    function _buildMetadataInput(uint256 certId) internal view returns (RecyTraceabilityMetadata.MetadataInput memory) {
        CertificateData storage cert = _certificates[certId];
        return RecyTraceabilityMetadata.MetadataInput({
            certId: certId,
            issuer: cert.issuer,
            periodStart: cert.periodStart,
            periodEnd: cert.periodEnd,
            totalVolumeGrams: cert.totalVolumeGrams,
            totalSustainableVolumeGrams: cert.totalSustainableVolumeGrams,
            reportCount: cert.reportHashes.length,
            isValidated: cert.isValidated,
            validatedAt: cert.validatedAt,
            validatedBy: cert.validatedBy,
            generators: _certGenerators[certId],
            recyclers: _certRecyclers[certId],
            reportAuditors: _certReportAuditors[certId]
        });
    }

    // --- Governance & Configuration ---

    function pause() external onlyRole(ADMIN_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(ADMIN_ROLE) {
        _unpause();
    }

    function setPricingConfig(address _usdcToken, uint256 _newPriceInUsdc) external onlyRole(ADMIN_ROLE) {
        if (_usdcToken == address(0)) revert ZeroAddressNotAllowed();
        if (_usdcToken.code.length == 0) revert InvalidContractAddress();
        usdcToken = IERC20(_usdcToken);
        certificatePriceInUsdc = _newPriceInUsdc;
        emit PricingUpdated(_usdcToken, _newPriceInUsdc);
    }

    function setSplitConfig(uint16 _adminBps, uint16 _auditorBps, uint16 _buybackBps) external onlyRole(ADMIN_ROLE) {
        uint256 totalBps = uint256(_adminBps) + uint256(_auditorBps) + uint256(_buybackBps);
        if (totalBps != BPS_DENOMINATOR) revert InvalidSplitDistribution(totalBps);
        splitConfig = SplitConfig({adminBps: _adminBps, auditorBps: _auditorBps, buybackBps: _buybackBps});
        emit SplitConfigUpdated(_adminBps, _auditorBps, _buybackBps);
    }

    function setWalletsAndDex(
        address _adminWallet,
        address _buybackRecipient,
        address _swapRouter,
        uint24 _usdcToCRecyPoolFee
    ) external onlyRole(ADMIN_ROLE) {
        if (_adminWallet == address(0) || _buybackRecipient == address(0)) {
            revert ZeroAddressNotAllowed();
        }
        adminWallet = _adminWallet;
        buybackRecipient = _buybackRecipient;
        swapRouter = ISwapRouter02(_swapRouter);
        usdcToCRecyPoolFee = _usdcToCRecyPoolFee;
        emit WalletsUpdated(_adminWallet, _buybackRecipient, _swapRouter, _usdcToCRecyPoolFee);
    }

    function setLandfillTreatmentId(uint8 _landfillTreatmentId) external onlyRole(ADMIN_ROLE) {
        landfillTreatmentId = _landfillTreatmentId;
        emit LandfillTreatmentIdUpdated(_landfillTreatmentId);
    }

    function calculateCertificatePrice(uint256 volumeGrams) public view returns (uint256) {
        uint256 ratePerKg = pricePerKgInUsdc;
        if (ratePerKg == 0) {
            return certificatePriceInUsdc;
        }
        uint256 volumetricPrice = volumeGrams == 0 ? 0 : (volumeGrams * ratePerKg + 999) / 1000;
        return volumetricPrice < minCertificatePriceInUsdc ? minCertificatePriceInUsdc : volumetricPrice;
    }

    function setVolumetricPricingConfig(
        address _usdcToken,
        uint256 _pricePerKgInUsdc,
        uint256 _minCertificatePriceInUsdc
    ) external onlyRole(ADMIN_ROLE) {
        if (_usdcToken == address(0)) revert ZeroAddressNotAllowed();
        if (_usdcToken.code.length == 0) revert InvalidContractAddress();
        usdcToken = IERC20(_usdcToken);
        pricePerKgInUsdc = _pricePerKgInUsdc;
        minCertificatePriceInUsdc = _minCertificatePriceInUsdc;
        pricingLastUpdatedAt = SafeCast.toUint64(block.timestamp);
        emit VolumetricPricingUpdated(_usdcToken, _pricePerKgInUsdc, _minCertificatePriceInUsdc, pricingLastUpdatedAt);
    }

    function setWhitelistedReportProxy(address proxy, bool status) external onlyRole(ADMIN_ROLE) {
        if (proxy == address(0)) revert ZeroAddressNotAllowed();
        whitelistedReportProxies[proxy] = status;
        emit WhitelistedReportProxyUpdated(proxy, status);
    }

    function _authorizeUpgrade(address newImplementation) internal override onlyRole(UPGRADER_ROLE) {}

    function supportsInterface(bytes4 interfaceId)
        public
        view
        override(ERC721Upgradeable, AccessControlUpgradeable)
        returns (bool)
    {
        return super.supportsInterface(interfaceId);
    }
}
