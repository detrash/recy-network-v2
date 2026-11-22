// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

/**
 * @title DetrashDirectOTC
 * @author Detrash Tecnologia Ltda. (Recy Network)
 * @notice Bilateral non-custodial atomic DvP OTC desk for direct sales of Detrash treasury cRECY inventory.
 * @dev Resting contract balance is always zero: buyer retains payment tokens via allowance until atomic settlement.
 */
contract DetrashDirectOTC is Ownable2Step, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;

    enum ProposalStatus {
        NONE,
        PENDING,
        ACCEPTED,
        REJECTED,
        CANCELLED
    }

    struct PaymentTokenConfig {
        bool isSupported;
        uint256 minPaymentAmount;
        uint256 minPricePerWholeCrecy;
    }

    struct OTCProposal {
        uint256 id;
        address buyer;
        address paymentToken;
        uint256 paymentAmount;
        uint256 crecyAmount;
        uint64 createdAt;
        uint64 expiration;
        bytes32 termsAcceptedHash;
        bytes32 buyerComplianceRef;
        ProposalStatus status;
    }

    /// @notice Utility and traceability token cRECY (18 decimals)
    IERC20 public immutable crecyToken;

    /// @notice Exclusive Detrash treasury wallet (sole cRECY source and payment destination)
    address public detrashTreasury;

    /// @notice Authorized treasury operator permitted to accept or reject proposals
    address public treasuryOperator;

    /// @notice Active keccak256 hash of commercial utility token acquisition terms
    bytes32 public currentCommercialTermsHash;

    /// @notice Optional per-proposal cRECY ceiling limiting hot-operator blast radius (0 = unlimited)
    uint256 public maxCrecyPerProposal;

    uint64 public constant MIN_EXPIRATION_DURATION = 1 hours;
    uint64 public constant MAX_EXPIRATION_DURATION = 30 days;

    uint256 public nextProposalId = 1;

    mapping(address => PaymentTokenConfig) public paymentTokens;
    mapping(uint256 => OTCProposal) public proposals;
    mapping(address => uint256[]) private _buyerProposals;

    event ProposalCreated(
        uint256 indexed proposalId,
        address indexed buyer,
        address indexed paymentToken,
        uint256 paymentAmount,
        uint256 crecyAmount,
        uint64 expiration,
        bytes32 termsAcceptedHash,
        bytes32 buyerComplianceRef
    );

    event ProposalAccepted(
        uint256 indexed proposalId,
        address indexed buyer,
        address indexed paymentToken,
        uint256 paymentAmount,
        uint256 crecyAmount,
        address settledBy,
        uint256 timestamp
    );

    event ProposalRejected(uint256 indexed proposalId, address indexed buyer, string reason, address rejectedBy);
    event ProposalCancelled(uint256 indexed proposalId, address indexed buyer);
    event PaymentTokenConfigured(
        address indexed token, bool isSupported, uint256 minPaymentAmount, uint256 minPricePerWholeCrecy
    );
    event TreasuryUpdated(address indexed oldTreasury, address indexed newTreasury);
    event OperatorUpdated(address indexed oldOperator, address indexed newOperator);
    event CommercialTermsHashUpdated(bytes32 oldHash, bytes32 newHash);
    event MaxCrecyPerProposalUpdated(uint256 previousMax, uint256 newMax);
    event AccidentalERC20Rescued(address indexed token, address indexed recipient, uint256 amount);

    error InvalidAddress();
    error UnauthorizedTreasuryAction();
    error UnsupportedPaymentToken();
    error InvalidAmounts();
    error BelowMinimumPayment(uint256 provided, uint256 required);
    error BelowMinimumFloorPrice(uint256 providedPayment, uint256 minimumRequiredPayment);
    error ExceedsMaxCrecyPerProposal(uint256 requested, uint256 maxAllowed);
    error InvalidExpiration();
    error InvalidTermsHash(bytes32 provided, bytes32 expected);
    error InsufficientBuyerBalanceOrAllowance();
    error InsufficientTreasuryBalanceOrAllowance();
    error FeeOnTransferNotSupported();
    error ProposalNotPending(ProposalStatus currentStatus);
    error ProposalExpired(uint64 expiration, uint64 currentTime);
    error NotProposalBuyer();

    modifier onlyTreasuryOrOwner() {
        if (msg.sender != owner() && msg.sender != detrashTreasury && msg.sender != treasuryOperator) {
            revert UnauthorizedTreasuryAction();
        }
        _;
    }

    constructor(address _crecyToken, address _detrashTreasury, address _treasuryOperator, bytes32 _initialTermsHash)
        Ownable(msg.sender)
    {
        if (
            _crecyToken == address(0) || _crecyToken.code.length == 0 || _detrashTreasury == address(0)
                || _treasuryOperator == address(0)
        ) {
            revert InvalidAddress();
        }
        if (_crecyToken == _detrashTreasury) revert InvalidAddress();
        if (_initialTermsHash == bytes32(0)) revert InvalidTermsHash(bytes32(0), bytes32(0));

        crecyToken = IERC20(_crecyToken);
        detrashTreasury = _detrashTreasury;
        treasuryOperator = _treasuryOperator;
        currentCommercialTermsHash = _initialTermsHash;
    }

    function createProposal(
        address _paymentToken,
        uint256 _paymentAmount,
        uint256 _crecyAmount,
        uint64 _expiration,
        bytes32 _termsAcceptedHash,
        bytes32 _buyerComplianceRef
    ) public nonReentrant whenNotPaused returns (uint256 proposalId) {
        proposalId = _createProposalInternal(
            msg.sender,
            _paymentToken,
            _paymentAmount,
            _crecyAmount,
            _expiration,
            _termsAcceptedHash,
            _buyerComplianceRef
        );
    }

    function createProposalWithPermit(
        address _paymentToken,
        uint256 _paymentAmount,
        uint256 _crecyAmount,
        uint64 _expiration,
        bytes32 _termsAcceptedHash,
        bytes32 _buyerComplianceRef,
        uint256 _permitDeadline,
        uint8 _v,
        bytes32 _r,
        bytes32 _s
    ) external nonReentrant whenNotPaused returns (uint256 proposalId) {
        // Validate token whitelist BEFORE invoking external permit()
        if (!paymentTokens[_paymentToken].isSupported) revert UnsupportedPaymentToken();

        // Only invoke permit if existing allowance is insufficient (preserves larger multi-proposal allowances)
        if (IERC20(_paymentToken).allowance(msg.sender, address(this)) < _paymentAmount) {
            try IERC20Permit(_paymentToken)
                .permit(msg.sender, address(this), _paymentAmount, _permitDeadline, _v, _r, _s) {}
                catch {}
        }

        proposalId = _createProposalInternal(
            msg.sender,
            _paymentToken,
            _paymentAmount,
            _crecyAmount,
            _expiration,
            _termsAcceptedHash,
            _buyerComplianceRef
        );
    }

    function cancelProposal(uint256 _proposalId) external nonReentrant {
        OTCProposal storage prop = proposals[_proposalId];
        if (prop.buyer != msg.sender) revert NotProposalBuyer();
        if (prop.status != ProposalStatus.PENDING) revert ProposalNotPending(prop.status);

        prop.status = ProposalStatus.CANCELLED;
        emit ProposalCancelled(_proposalId, msg.sender);
    }

    function acceptProposal(uint256 _proposalId) external nonReentrant onlyTreasuryOrOwner whenNotPaused {
        OTCProposal storage prop = proposals[_proposalId];

        if (prop.status != ProposalStatus.PENDING) {
            revert ProposalNotPending(prop.status);
        }
        if (block.timestamp > prop.expiration) {
            revert ProposalExpired(prop.expiration, SafeCast.toUint64(block.timestamp));
        }
        if (!paymentTokens[prop.paymentToken].isSupported) {
            revert UnsupportedPaymentToken();
        }
        if (maxCrecyPerProposal > 0 && prop.crecyAmount > maxCrecyPerProposal) {
            revert ExceedsMaxCrecyPerProposal(prop.crecyAmount, maxCrecyPerProposal);
        }

        IERC20 payToken = IERC20(prop.paymentToken);
        address buyer = prop.buyer;
        address treasury = detrashTreasury;
        uint256 paymentAmount = prop.paymentAmount;
        uint256 crecyAmount = prop.crecyAmount;

        if (payToken.balanceOf(buyer) < paymentAmount || payToken.allowance(buyer, address(this)) < paymentAmount) {
            revert InsufficientBuyerBalanceOrAllowance();
        }
        if (crecyToken.balanceOf(treasury) < crecyAmount || crecyToken.allowance(treasury, address(this)) < crecyAmount)
        {
            revert InsufficientTreasuryBalanceOrAllowance();
        }

        // Effects first (CEI)
        prop.status = ProposalStatus.ACCEPTED;

        emit ProposalAccepted(
            _proposalId, buyer, prop.paymentToken, paymentAmount, crecyAmount, msg.sender, block.timestamp
        );

        // Atomic bilateral DvP with exact balance-delta verification
        uint256 treasuryPayBefore = payToken.balanceOf(treasury);
        payToken.safeTransferFrom(buyer, treasury, paymentAmount);
        if (payToken.balanceOf(treasury) - treasuryPayBefore != paymentAmount) {
            revert FeeOnTransferNotSupported();
        }

        uint256 buyerCrecyBefore = crecyToken.balanceOf(buyer);
        crecyToken.safeTransferFrom(treasury, buyer, crecyAmount);
        if (crecyToken.balanceOf(buyer) - buyerCrecyBefore != crecyAmount) {
            revert FeeOnTransferNotSupported();
        }
    }

    function rejectProposal(uint256 _proposalId, string calldata _reason) external nonReentrant onlyTreasuryOrOwner {
        OTCProposal storage prop = proposals[_proposalId];

        if (prop.status != ProposalStatus.PENDING) {
            revert ProposalNotPending(prop.status);
        }

        prop.status = ProposalStatus.REJECTED;
        emit ProposalRejected(_proposalId, prop.buyer, _reason, msg.sender);
    }

    function _createProposalInternal(
        address _buyer,
        address _paymentToken,
        uint256 _paymentAmount,
        uint256 _crecyAmount,
        uint64 _expiration,
        bytes32 _termsAcceptedHash,
        bytes32 _buyerComplianceRef
    ) internal returns (uint256 proposalId) {
        if (_buyer == detrashTreasury) revert InvalidAddress();

        PaymentTokenConfig memory config = paymentTokens[_paymentToken];
        if (!config.isSupported) revert UnsupportedPaymentToken();
        if (_paymentAmount == 0 || _crecyAmount == 0) revert InvalidAmounts();

        if (maxCrecyPerProposal > 0 && _crecyAmount > maxCrecyPerProposal) {
            revert ExceedsMaxCrecyPerProposal(_crecyAmount, maxCrecyPerProposal);
        }

        if (_termsAcceptedHash != currentCommercialTermsHash) {
            revert InvalidTermsHash(_termsAcceptedHash, currentCommercialTermsHash);
        }

        if (
            _expiration < block.timestamp + MIN_EXPIRATION_DURATION
                || _expiration > block.timestamp + MAX_EXPIRATION_DURATION
        ) {
            revert InvalidExpiration();
        }

        if (_paymentAmount < config.minPaymentAmount) {
            revert BelowMinimumPayment(_paymentAmount, config.minPaymentAmount);
        }

        // Ceiling floor price check prevents sub-floor rounding bypass and intermediate overflow
        if (config.minPricePerWholeCrecy > 0) {
            uint256 minRequiredPayment =
                Math.mulDiv(_crecyAmount, config.minPricePerWholeCrecy, 1e18, Math.Rounding.Ceil);
            if (_paymentAmount < minRequiredPayment) {
                revert BelowMinimumFloorPrice(_paymentAmount, minRequiredPayment);
            }
        }

        IERC20 payToken = IERC20(_paymentToken);
        if (payToken.balanceOf(_buyer) < _paymentAmount || payToken.allowance(_buyer, address(this)) < _paymentAmount) {
            revert InsufficientBuyerBalanceOrAllowance();
        }

        proposalId = nextProposalId++;

        proposals[proposalId] = OTCProposal({
            id: proposalId,
            buyer: _buyer,
            paymentToken: _paymentToken,
            paymentAmount: _paymentAmount,
            crecyAmount: _crecyAmount,
            createdAt: SafeCast.toUint64(block.timestamp),
            expiration: _expiration,
            termsAcceptedHash: _termsAcceptedHash,
            buyerComplianceRef: _buyerComplianceRef,
            status: ProposalStatus.PENDING
        });

        _buyerProposals[_buyer].push(proposalId);

        emit ProposalCreated(
            proposalId,
            _buyer,
            _paymentToken,
            _paymentAmount,
            _crecyAmount,
            _expiration,
            _termsAcceptedHash,
            _buyerComplianceRef
        );
    }

    function configurePaymentToken(
        address _token,
        bool _isSupported,
        uint256 _minPaymentAmount,
        uint256 _minPricePerWholeCrecy
    ) external onlyOwner {
        if (_token == address(0) || _token == address(crecyToken) || _token.code.length == 0) {
            revert InvalidAddress();
        }

        paymentTokens[_token] = PaymentTokenConfig({
            isSupported: _isSupported,
            minPaymentAmount: _minPaymentAmount,
            minPricePerWholeCrecy: _minPricePerWholeCrecy
        });

        emit PaymentTokenConfigured(_token, _isSupported, _minPaymentAmount, _minPricePerWholeCrecy);
    }

    function setDetrashTreasury(address _newTreasury) external onlyOwner {
        if (_newTreasury == address(0) || _newTreasury == address(crecyToken)) revert InvalidAddress();
        address old = detrashTreasury;
        detrashTreasury = _newTreasury;
        emit TreasuryUpdated(old, _newTreasury);
    }

    function setTreasuryOperator(address _newOperator) external onlyOwner {
        if (_newOperator == address(0)) revert InvalidAddress();
        address old = treasuryOperator;
        treasuryOperator = _newOperator;
        emit OperatorUpdated(old, _newOperator);
    }

    function setCommercialTermsHash(bytes32 _newTermsHash) external onlyOwner {
        if (_newTermsHash == bytes32(0)) revert InvalidTermsHash(bytes32(0), currentCommercialTermsHash);
        bytes32 old = currentCommercialTermsHash;
        currentCommercialTermsHash = _newTermsHash;
        emit CommercialTermsHashUpdated(old, _newTermsHash);
    }

    function setMaxCrecyPerProposal(uint256 _maxCrecyPerProposal) external onlyOwner {
        uint256 previous = maxCrecyPerProposal;
        maxCrecyPerProposal = _maxCrecyPerProposal;
        emit MaxCrecyPerProposalUpdated(previous, _maxCrecyPerProposal);
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    function rescueAccidentalERC20(address _token, uint256 _amount) external nonReentrant onlyOwner {
        if (_token == address(0)) revert InvalidAddress();
        if (_amount == 0) revert InvalidAmounts();
        emit AccidentalERC20Rescued(_token, detrashTreasury, _amount);
        IERC20(_token).safeTransfer(detrashTreasury, _amount);
    }

    function getBuyerProposals(address _buyer) external view returns (uint256[] memory) {
        return _buyerProposals[_buyer];
    }

    function getBuyerProposalCount(address _buyer) external view returns (uint256) {
        return _buyerProposals[_buyer].length;
    }

    function getBuyerProposalsPaginated(address _buyer, uint256 offset, uint256 limit)
        external
        view
        returns (uint256[] memory page, uint256 total)
    {
        uint256[] storage all = _buyerProposals[_buyer];
        total = all.length;
        if (offset >= total) return (new uint256[](0), total);

        uint256 end = offset + limit;
        if (end > total) end = total;

        uint256 len = end - offset;
        page = new uint256[](len);
        for (uint256 i = 0; i < len; i++) {
            page[i] = all[offset + i];
        }
    }

    function canSettleProposal(uint256 _proposalId) external view returns (bool settleable, string memory reason) {
        OTCProposal memory prop = proposals[_proposalId];
        if (prop.status != ProposalStatus.PENDING) return (false, "Proposal is not pending");
        if (block.timestamp > prop.expiration) return (false, "Proposal expired");
        if (!paymentTokens[prop.paymentToken].isSupported) return (false, "Payment token disabled");
        if (maxCrecyPerProposal > 0 && prop.crecyAmount > maxCrecyPerProposal) {
            return (false, "Exceeds max cRECY per proposal");
        }

        IERC20 payToken = IERC20(prop.paymentToken);
        if (payToken.balanceOf(prop.buyer) < prop.paymentAmount) return (false, "Buyer has insufficient balance");
        if (payToken.allowance(prop.buyer, address(this)) < prop.paymentAmount) {
            return (false, "Buyer revoked allowance");
        }

        if (crecyToken.balanceOf(detrashTreasury) < prop.crecyAmount) {
            return (false, "Treasury has insufficient cRECY");
        }
        if (crecyToken.allowance(detrashTreasury, address(this)) < prop.crecyAmount) {
            return (false, "Treasury needs to approve cRECY");
        }

        return (true, "Ready for atomic settlement");
    }
}
