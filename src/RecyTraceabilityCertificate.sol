// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Initializable} from "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import {UUPSUpgradeable} from "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import {ERC721Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC721/ERC721Upgradeable.sol";
import {AccessControlUpgradeable} from "@openzeppelin/contracts-upgradeable/access/AccessControlUpgradeable.sol";
import {ReentrancyGuardUpgradeable} from "@openzeppelin/contracts-upgradeable/utils/ReentrancyGuardUpgradeable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Strings} from "@openzeppelin/contracts/utils/Strings.sol";
import {Base64} from "@openzeppelin/contracts/utils/Base64.sol";

/**
 * @notice Minimal read interface for existing RecyReport proxy instances.
 */
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

/**
 * @notice Matches your deployed RecyReportFactory on Celo Sepolia (0xc9Fb52e7eDBA245aBeb9Cbee3e603aF10A44BBd0)
 */
interface IRecyReportFactory {
    function getNameByProxy(address proxy) external view returns (string memory);
}

/**
 * @notice Uniswap V3 SwapRouter02 interface (supports both ExactInputSingle and ExactOutputSingle)
 */
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

    function exactInputSingle(ExactInputSingleParams calldata params)
        external
        payable
        returns (uint256 amountOut);

    function exactOutputSingle(ExactOutputSingleParams calldata params)
        external
        payable
        returns (uint256 amountIn);
}

/**
 * @title RecyTraceabilityCertificate
 * @author Recy Network (Detrash Tecnologia Ltda)
 * @notice Consolidates validated RecyReports for a given actor and time period into an auditable
 *         ERC-721 Waste Traceability Certificate. Accepts any ERC-20 token with a USDC pool, converts
 *         to USDC, splits proceeds, and executes automated USDC -> cRECY buybacks.
 */
contract RecyTraceabilityCertificate is
    Initializable,
    ERC721Upgradeable,
    AccessControlUpgradeable,
    ReentrancyGuardUpgradeable,
    UUPSUpgradeable
{
    using SafeERC20 for IERC20;
    using Strings for uint256;

    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant AUDITOR_ROLE = keccak256("AUDITOR_ROLE");
    bytes32 public constant UPGRADER_ROLE = keccak256("UPGRADER_ROLE");
    uint16 public constant BPS_DENOMINATOR = 10_000;

    struct ReportRef {
        address reportProxy;
        uint256 reportId;
    }

    struct WasteTreatmentVolume {
        uint8 wasteType;
        uint8 treatmentType;
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
    error UnregisteredReportProxy(address proxy);
    error ReportNotValidated(address proxy, uint256 reportId);
    error ReportOutsidePeriod(address proxy, uint256 reportId, uint64 timestamp);
    error IssuerNotInvolvedInReport(address proxy, uint256 reportId, address issuer);
    error ReportAlreadyConsolidatedInPeriod(
        address issuer,
        uint64 periodStart,
        uint64 periodEnd,
        address proxy,
        uint256 reportId
    );
    error CertificateDoesNotExist(uint256 certId);
    error CertificateAlreadyValidated(uint256 certId);
    error ConflictOfInterestAuditor(uint256 certId, address auditor);
    error InvalidSplitDistribution(uint256 totalBps);
    error ZeroAddressNotAllowed();
    error SwapRouterNotConfigured();

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

    event PaymentSwappedToUsdc(
        uint256 indexed certId,
        address indexed payToken,
        uint256 payTokenSpent,
        uint256 usdcReceived
    );

    event CertificateValidated(
        uint256 indexed certId,
        address indexed auditor,
        uint64 validatedAt,
        uint256 auditorUsdcRewardPaid
    );

    event BuybackExecuted(
        uint256 indexed certId,
        uint256 usdcIn,
        uint256 cRecyOut,
        address indexed recipient
    );

    event BuybackFallbackRouted(
        uint256 indexed certId,
        uint256 usdcAmount,
        address indexed fallbackRecipient
    );

    event PricingUpdated(address indexed usdcToken, uint256 newPriceInUsdc);
    event SplitConfigUpdated(uint16 adminBps, uint16 auditorBps, uint16 buybackBps);
    event WalletsUpdated(
        address adminWallet,
        address buybackRecipient,
        address swapRouter,
        uint24 usdcToCRecyPoolFee
    );
    event LandfillTreatmentIdUpdated(uint8 newLandfillTreatmentId);

    IRecyReportFactory public reportFactory;
    IERC20 public usdcToken;
    IERC20 public cRecyToken;
    ISwapRouter02 public swapRouter;

    address public adminWallet;
    address public buybackRecipient;
    uint24 public usdcToCRecyPoolFee;
    uint8 public landfillTreatmentId;

    // Price denominated in USDC (6 decimals, e.g., 50 * 1e6 = 50 USDC)
    uint256 public certificatePriceInUsdc;
    SplitConfig public splitConfig;
    uint256 private _nextCertId;

    mapping(uint256 => CertificateData) private _certificates;
    mapping(uint256 => mapping(uint8 => mapping(uint8 => uint256))) private _volumeMatrix;
    mapping(uint256 => uint16[]) private _activeMatrixKeys;
    mapping(uint256 => mapping(uint16 => bool)) private _hasMatrixKey;
    mapping(uint256 => mapping(address => bool)) private _excludedAuditors;

    // Period-scoped key: keccak256(abi.encode(issuer, periodStart, periodEnd, reportProxy, reportId))
    mapping(bytes32 => bool) public isReportConsolidatedByIssuerInPeriod;
    mapping(uint256 => mapping(bytes32 => bool)) private _isReportInCertificate;
    mapping(address => bool) public whitelistedReportProxies;

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
        if (
            _admin == address(0) ||
            _usdcToken == address(0) ||
            _cRecyToken == address(0) ||
            _adminWallet == address(0) ||
            _buybackRecipient == address(0)
        ) revert ZeroAddressNotAllowed();

        uint256 totalBps = uint256(_initialSplit.adminBps) +
            uint256(_initialSplit.auditorBps) +
            uint256(_initialSplit.buybackBps);
        if (totalBps != BPS_DENOMINATOR) revert InvalidSplitDistribution(totalBps);

        __ERC721_init("Recy Waste Traceability Certificate", "rWTC");
        __AccessControl_init();
        __ReentrancyGuard_init();
        __UUPSUpgradeable_init();

        _grantRole(DEFAULT_ADMIN_ROLE, _admin);
        _grantRole(ADMIN_ROLE, _admin);
        _grantRole(UPGRADER_ROLE, _admin);

        reportFactory = IRecyReportFactory(_reportFactory);
        usdcToken = IERC20(_usdcToken);
        cRecyToken = IERC20(_cRecyToken);
        swapRouter = ISwapRouter02(_swapRouter);

        adminWallet = _adminWallet;
        buybackRecipient = _buybackRecipient;
        usdcToCRecyPoolFee = _usdcToCRecyPoolFee;
        landfillTreatmentId = _landfillTreatmentId;

        certificatePriceInUsdc = _initialPriceInUsdc;
        splitConfig = _initialSplit;
        _nextCertId = 1;
    }

    /**
     * @notice Consolidates a period's validated RecyReports for `msg.sender` and mints an unvalidated Certificate.
     * @param periodStart Start timestamp (inclusive) of the certificate period.
     * @param periodEnd End timestamp (inclusive) of the certificate period.
     * @param reports Array of (reportProxy, reportId) references involving `msg.sender`.
     * @param payToken ERC-20 token used by `msg.sender` to pay (pass `address(usdcToken)` to pay directly in USDC,
     *                 or any ERC-20 token to automatically swap `payToken -> USDC` first).
     * @param payTokenToUsdcPoolFee Uniswap V3 pool fee tier between `payToken` and `USDC` (ignored if `payToken == address(usdcToken)`).
     * @param maxPayTokenIn Maximum `payToken` amount `msg.sender` is willing to spend to cover `certificatePriceInUsdc`.
     * @param minCRecyOut Minimum cRECY tokens expected from the automated `USDC -> cRECY` buyback swap.
     */
    function mintCertificate(
        uint64 periodStart,
        uint64 periodEnd,
        ReportRef[] calldata reports,
        address payToken,
        uint24 payTokenToUsdcPoolFee,
        uint256 maxPayTokenIn,
        uint256 minCRecyOut
    ) external nonReentrant returns (uint256 certId) {
        if (periodStart >= periodEnd || periodEnd > block.timestamp) revert InvalidTimePeriod();
        uint256 reportCount = reports.length;
        if (reportCount == 0) revert EmptyReportBatch();

        certId = _nextCertId++;
        CertificateData storage cert = _certificates[certId];
        cert.issuer = msg.sender;
        cert.periodStart = periodStart;
        cert.periodEnd = periodEnd;
        cert.mintedAt = uint64(block.timestamp);
        cert.usdcTokenSnapshot = address(usdcToken);

        _excludedAuditors[certId][msg.sender] = true;

        uint256 totalVol = 0;
        uint256 sustainableVol = 0;
        uint8 landfillId = landfillTreatmentId;

        for (uint256 i = 0; i < reportCount; ) {
            ReportRef calldata ref = reports[i];

            if (!_isValidProxy(ref.reportProxy)) {
                revert UnregisteredReportProxy(ref.reportProxy);
            }

            bytes32 consolidationKey = keccak256(
                abi.encode(msg.sender, periodStart, periodEnd, ref.reportProxy, ref.reportId)
            );
            if (isReportConsolidatedByIssuerInPeriod[consolidationKey]) {
                revert ReportAlreadyConsolidatedInPeriod(
                    msg.sender,
                    periodStart,
                    periodEnd,
                    ref.reportProxy,
                    ref.reportId
                );
            }
            isReportConsolidatedByIssuerInPeriod[consolidationKey] = true;

            bytes32 reportRefKey = keccak256(abi.encode(ref.reportProxy, ref.reportId));
            _isReportInCertificate[certId][reportRefKey] = true;

            (
                address generator,
                address recycler,
                address reportAuditor,
                uint8 wasteType,
                uint8 treatmentType,
                uint256 volumeGrams,
                uint64 reportTimestamp,
                bool reportValidated
            ) = IRecyReport(ref.reportProxy).getReportDetails(ref.reportId);

            if (!reportValidated) {
                revert ReportNotValidated(ref.reportProxy, ref.reportId);
            }
            if (reportTimestamp < periodStart || reportTimestamp > periodEnd) {
                revert ReportOutsidePeriod(ref.reportProxy, ref.reportId, reportTimestamp);
            }
            if (msg.sender != generator && msg.sender != recycler && msg.sender != reportAuditor) {
                revert IssuerNotInvolvedInReport(ref.reportProxy, ref.reportId, msg.sender);
            }

            _excludedAuditors[certId][reportAuditor] = true;

            uint16 matrixKey = (uint16(wasteType) << 8) | uint16(treatmentType);
            if (!_hasMatrixKey[certId][matrixKey]) {
                _hasMatrixKey[certId][matrixKey] = true;
                _activeMatrixKeys[certId].push(matrixKey);
            }
            _volumeMatrix[certId][wasteType][treatmentType] += volumeGrams;

            totalVol += volumeGrams;
            if (treatmentType != landfillId) {
                sustainableVol += volumeGrams;
            }

            bytes32 reportHash = keccak256(
                abi.encode(
                    block.chainid,
                    ref.reportProxy,
                    ref.reportId,
                    generator,
                    recycler,
                    reportAuditor,
                    wasteType,
                    treatmentType,
                    volumeGrams,
                    reportTimestamp
                )
            );
            cert.reportHashes.push(reportHash);

            unchecked {
                ++i;
            }
        }

        cert.totalVolumeGrams = totalVol;
        cert.totalSustainableVolumeGrams = sustainableVol;

        uint256 priceInUsdc = certificatePriceInUsdc;
        if (priceInUsdc > 0) {
            _processCertificatePayment(
                certId,
                priceInUsdc,
                payToken,
                payTokenToUsdcPoolFee,
                maxPayTokenIn,
                minCRecyOut
            );
        }

        _safeMint(msg.sender, certId);

        emit CertificateMinted(
            certId,
            msg.sender,
            payToken,
            periodStart,
            periodEnd,
            reportCount,
            totalVol,
            sustainableVol,
            priceInUsdc
        );
    }

    /**
     * @notice Validates a Waste Traceability Certificate and releases the escrowed USDC bounty.
     */
    function validateCertificate(uint256 certId) external nonReentrant onlyRole(AUDITOR_ROLE) {
        CertificateData storage cert = _certificates[certId];
        if (cert.issuer == address(0)) revert CertificateDoesNotExist(certId);
        if (cert.isValidated) revert CertificateAlreadyValidated(certId);
        if (_excludedAuditors[certId][msg.sender]) {
            revert ConflictOfInterestAuditor(certId, msg.sender);
        }

        cert.isValidated = true;
        cert.validatedAt = uint64(block.timestamp);
        cert.validatedBy = msg.sender;

        uint256 rewardUsdc = cert.auditorRewardEscrowUsdc;
        cert.auditorRewardEscrowUsdc = 0;

        if (rewardUsdc > 0) {
            IERC20(cert.usdcTokenSnapshot).safeTransfer(msg.sender, rewardUsdc);
        }

        emit CertificateValidated(certId, msg.sender, cert.validatedAt, rewardUsdc);
    }

    /**
     * @dev Stage 1: If `payToken != address(usdcToken)`, swaps `payToken -> USDC` for exact `priceInUsdc`.
     *      Stage 2: Splits `priceInUsdc` into Admin USDC, Auditor Escrow USDC, and `USDC -> cRECY` buyback.
     */
    function _processCertificatePayment(
        uint256 certId,
        uint256 priceInUsdc,
        address payToken,
        uint24 payTokenToUsdcPoolFee,
        uint256 maxPayTokenIn,
        uint256 minCRecyOut
    ) internal {
        if (payToken == address(0)) revert ZeroAddressNotAllowed();
        IERC20 usdc = usdcToken;

        // Stage 1: Normalize incoming payment into USDC
        if (payToken == address(usdc)) {
            usdc.safeTransferFrom(msg.sender, address(this), priceInUsdc);
        } else {
            if (address(swapRouter) == address(0)) revert SwapRouterNotConfigured();
            IERC20 incomingToken = IERC20(payToken);

            incomingToken.safeTransferFrom(msg.sender, address(this), maxPayTokenIn);
            incomingToken.forceApprove(address(swapRouter), maxPayTokenIn);

            ISwapRouter02.ExactOutputSingleParams memory swapToUsdcParams = ISwapRouter02
                .ExactOutputSingleParams({
                    tokenIn: payToken,
                    tokenOut: address(usdc),
                    fee: payTokenToUsdcPoolFee,
                    recipient: address(this),
                    amountOut: priceInUsdc,
                    amountInMaximum: maxPayTokenIn,
                    sqrtPriceLimitX96: 0
                });

            uint256 amountInUsed = swapRouter.exactOutputSingle(swapToUsdcParams);

            // Reset leftover approval and refund unspent payToken to the issuer
            if (maxPayTokenIn > amountInUsed) {
                incomingToken.forceApprove(address(swapRouter), 0);
                incomingToken.safeTransfer(msg.sender, maxPayTokenIn - amountInUsed);
            }

            emit PaymentSwappedToUsdc(certId, payToken, amountInUsed, priceInUsdc);
        }

        // Stage 2: Split USDC proceeds between Admin, Auditor Escrow, and USDC -> cRECY Buyback
        SplitConfig memory split = splitConfig;
        uint256 adminUsdc = (priceInUsdc * split.adminBps) / BPS_DENOMINATOR;
        uint256 auditorUsdc = (priceInUsdc * split.auditorBps) / BPS_DENOMINATOR;
        uint256 buybackUsdc = priceInUsdc - adminUsdc - auditorUsdc;

        if (adminUsdc > 0) {
            usdc.safeTransfer(adminWallet, adminUsdc);
        }

        if (auditorUsdc > 0) {
            _certificates[certId].auditorRewardEscrowUsdc = auditorUsdc;
        }

        // Stage 3: Swap buybackUsdc -> cRECY via your USDC/cRECY liquidity pool
        if (buybackUsdc > 0) {
            if (address(swapRouter) != address(0)) {
                usdc.forceApprove(address(swapRouter), buybackUsdc);

                ISwapRouter02.ExactInputSingleParams memory buybackParams = ISwapRouter02
                    .ExactInputSingleParams({
                        tokenIn: address(usdc),
                        tokenOut: address(cRecyToken),
                        fee: usdcToCRecyPoolFee,
                        recipient: buybackRecipient,
                        amountIn: buybackUsdc,
                        amountOutMinimum: minCRecyOut,
                        sqrtPriceLimitX96: 0
                    });

                try swapRouter.exactInputSingle(buybackParams) returns (uint256 cRecyOut) {
                    emit BuybackExecuted(certId, buybackUsdc, cRecyOut, buybackRecipient);
                } catch {
                    usdc.forceApprove(address(swapRouter), 0);
                    usdc.safeTransfer(buybackRecipient, buybackUsdc);
                    emit BuybackFallbackRouted(certId, buybackUsdc, buybackRecipient);
                }
            } else {
                usdc.safeTransfer(buybackRecipient, buybackUsdc);
                emit BuybackFallbackRouted(certId, buybackUsdc, buybackRecipient);
            }
        }
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

    function getCertificateVolumeBreakdown(uint256 certId)
        external
        view
        returns (WasteTreatmentVolume[] memory breakdown)
    {
        if (_certificates[certId].issuer == address(0)) revert CertificateDoesNotExist(certId);
        uint16[] storage keys = _activeMatrixKeys[certId];
        uint256 len = keys.length;
        breakdown = new WasteTreatmentVolume[](len);

        for (uint256 i = 0; i < len; ) {
            uint16 key = keys[i];
            uint8 wType = uint8(key >> 8);
            uint8 tType = uint8(key & 0xFF);
            breakdown[i] = WasteTreatmentVolume({
                wasteType: wType,
                treatmentType: tType,
                volumeGrams: _volumeMatrix[certId][wType][tType]
            });
            unchecked {
                ++i;
            }
        }
    }

    function isReportInCertificate(
        uint256 certId,
        address reportProxy,
        uint256 reportId
    ) external view returns (bool) {
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

    function tokenURI(uint256 certId) public view override returns (string memory) {
        _requireOwned(certId);
        CertificateData storage cert = _certificates[certId];

        string memory validationStatus = cert.isValidated ? "Validated" : "Pending Independent Audit";
        string memory json = string(
            abi.encodePacked(
                '{"name":"Recy Waste Traceability Certificate #',
                certId.toString(),
                '","description":"Consolidated on-chain waste traceability certificate issued by Recy Network.",',
                '"attributes":[',
                '{"trait_type":"Issuer","value":"',
                Strings.toHexString(uint160(cert.issuer), 20),
                '"},{"display_type":"date","trait_type":"Period Start","value":',
                uint256(cert.periodStart).toString(),
                '},{"display_type":"date","trait_type":"Period End","value":',
                uint256(cert.periodEnd).toString(),
                '},{"display_type":"number","trait_type":"Total Volume (g)","value":',
                cert.totalVolumeGrams.toString(),
                '},{"display_type":"number","trait_type":"Sustainable Volume Ex-Landfill (g)","value":',
                cert.totalSustainableVolumeGrams.toString(),
                '},{"display_type":"number","trait_type":"Consolidated Reports","value":',
                cert.reportHashes.length.toString(),
                '},{"trait_type":"Status","value":"',
                validationStatus,
                '"},{"display_type":"date","trait_type":"Validated At","value":',
                uint256(cert.validatedAt).toString(),
                "}]}"
            )
        );

        return string(abi.encodePacked("data:application/json;base64,", Base64.encode(bytes(json))));
    }

    function setPricingConfig(address _usdcToken, uint256 _newPriceInUsdc) external onlyRole(ADMIN_ROLE) {
        if (_usdcToken == address(0)) revert ZeroAddressNotAllowed();
        usdcToken = IERC20(_usdcToken);
        certificatePriceInUsdc = _newPriceInUsdc;
        emit PricingUpdated(_usdcToken, _newPriceInUsdc);
    }

    function setSplitConfig(
        uint16 _adminBps,
        uint16 _auditorBps,
        uint16 _buybackBps
    ) external onlyRole(ADMIN_ROLE) {
        uint256 totalBps = uint256(_adminBps) + uint256(_auditorBps) + uint256(_buybackBps);
        if (totalBps != BPS_DENOMINATOR) revert InvalidSplitDistribution(totalBps);
        splitConfig = SplitConfig({
            adminBps: _adminBps,
            auditorBps: _auditorBps,
            buybackBps: _buybackBps
        });
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

    function setWhitelistedReportProxy(address proxy, bool status) external onlyRole(ADMIN_ROLE) {
        whitelistedReportProxies[proxy] = status;
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
