// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

/**
 * @title DetrashDirectOTC
 * @author Detrash Tecnologia Ltda. (Rede Recy)
 * @notice Contrato bilateral exclusivo para venda direta de estoque próprio de cRECY da tesouraria da Detrash.
 * @dev Arquitetura Non-Custodial Atomic DvP (Delivery versus Payment):
 *      - O contrato NUNCA retém ou custodia ativos de compradores ou da Detrash (saldo em repouso = 0).
 *      - Compradores registram propostas on-chain mantendo seus ativos em suas próprias carteiras via ERC20 allowance.
 *      - A liquidação ocorre de forma 100% atômica e direta (Carteira Comprador <-> Tesouraria Detrash) no momento do aceite.
 */
contract DetrashDirectOTC is Ownable2Step, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;

    // ==========================================
    // ENUMS & STRUCTS
    // ==========================================

    enum ProposalStatus {
        NONE,
        PENDING,
        ACCEPTED,
        REJECTED,
        CANCELLED
    }

    struct PaymentTokenConfig {
        bool isSupported;
        uint256 minPaymentAmount; // Valor mínimo da proposta na escala decimal do token de pagamento
        uint256 minPricePerWholeCrecy; // Piso anti-spam por 1e18 cRECY (na escala decimal do token de pagamento)
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
        bytes32 buyerComplianceRef; // Hash opcional de referência comercial/nota fiscal (sem dados pessoais em claro)
        ProposalStatus status;
    }

    // ==========================================
    // STATE VARIABLES
    // ==========================================

    /// @notice Token utilitário e de rastreabilidade cRECY (18 decimais)
    IERC20 public immutable crecyToken;

    /// @notice Carteira exclusiva da Tesouraria da Detrash (única origem de cRECY e único destino de pagamento)
    address public detrashTreasury;

    /// @notice Operador autorizado da tesouraria para aceitar/recusar propostas
    address public treasuryOperator;

    /// @notice Hash keccak256 vigente dos Termos de Aquisição de Token de Utilidade (proteção regulatória)
    bytes32 public currentCommercialTermsHash;

    /// @notice Limites de tempo de expiração para propostas
    uint64 public constant MIN_EXPIRATION_DURATION = 1 hours;
    uint64 public constant MAX_EXPIRATION_DURATION = 30 days;

    /// @notice Contador sequencial de propostas
    uint256 public nextProposalId = 1;

    /// @notice Configurações dos tokens de pagamento aceitos (ex: USDC, USDT, cREAL)
    mapping(address => PaymentTokenConfig) public paymentTokens;

    /// @notice Armazenamento de todas as propostas por ID
    mapping(uint256 => OTCProposal) public proposals;

    /// @notice Índice de propostas por endereço de comprador
    mapping(address => uint256[]) private _buyerProposals;

    // ==========================================
    // EVENTS
    // ==========================================

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

    // ==========================================
    // ERRORS
    // ==========================================

    error InvalidAddress();
    error UnauthorizedTreasuryAction();
    error UnsupportedPaymentToken();
    error InvalidAmounts();
    error BelowMinimumPayment(uint256 provided, uint256 required);
    error BelowMinimumFloorPrice(uint256 providedPayment, uint256 minimumRequiredPayment);
    error InvalidExpiration();
    error InvalidTermsHash(bytes32 provided, bytes32 expected);
    error InsufficientBuyerBalanceOrAllowance();
    error InsufficientTreasuryBalanceOrAllowance();
    error ProposalNotPending(ProposalStatus currentStatus);
    error ProposalExpired(uint64 expiration, uint64 currentTime);
    error NotProposalBuyer();

    // ==========================================
    // MODIFIERS
    // ==========================================

    modifier onlyTreasuryOrOwner() {
        if (msg.sender != owner() && msg.sender != detrashTreasury && msg.sender != treasuryOperator) {
            revert UnauthorizedTreasuryAction();
        }
        _;
    }

    // ==========================================
    // CONSTRUCTOR
    // ==========================================

    /**
     * @param _crecyToken Endereço do contrato cRECY na Celo
     * @param _detrashTreasury Carteira da tesouraria da Detrash que detém os cRECY e receberá os pagamentos
     * @param _treasuryOperator Carteira operacional que pode aprovar/rejeitar propostas
     * @param _initialTermsHash Hash keccak256 do Termo de Compra Mercantil de Ativo de Utilidade
     */
    constructor(address _crecyToken, address _detrashTreasury, address _treasuryOperator, bytes32 _initialTermsHash)
        Ownable(msg.sender)
    {
        if (_crecyToken == address(0) || _detrashTreasury == address(0) || _treasuryOperator == address(0)) {
            revert InvalidAddress();
        }
        if (_crecyToken == _detrashTreasury) revert InvalidAddress();

        crecyToken = IERC20(_crecyToken);
        detrashTreasury = _detrashTreasury;
        treasuryOperator = _treasuryOperator;
        currentCommercialTermsHash = _initialTermsHash;
    }

    // ==========================================
    // BUYER FUNCTIONS (PROPOSAL CREATION)
    // ==========================================

    /**
     * @notice Cria uma proposta de compra OTC de cRECY sem transferir fundos para o contrato.
     * @dev O comprador deve ter executado `paymentToken.approve(address(this), _paymentAmount)` previamente.
     */
    function createProposal(
        address _paymentToken,
        uint256 _paymentAmount,
        uint256 _crecyAmount,
        uint64 _expiration,
        bytes32 _termsAcceptedHash,
        bytes32 _buyerComplianceRef
    ) public whenNotPaused nonReentrant returns (uint256 proposalId) {
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

    /**
     * @notice Cria uma proposta usando assinatura EIP-2612 Permit (ex: USDC na Celo) em uma única transação.
     */
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
    ) external whenNotPaused nonReentrant returns (uint256 proposalId) {
        // Executa o permit (try/catch previne falha caso front-running submeta o permit antes)
        try IERC20Permit(_paymentToken)
            .permit(msg.sender, address(this), _paymentAmount, _permitDeadline, _v, _r, _s) {}
            catch {}

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

    /**
     * @notice Permite ao comprador cancelar sua proposta a qualquer momento antes do aceite da Detrash.
     */
    function cancelProposal(uint256 _proposalId) external nonReentrant {
        OTCProposal storage prop = proposals[_proposalId];
        if (prop.buyer != msg.sender) revert NotProposalBuyer();
        if (prop.status != ProposalStatus.PENDING) revert ProposalNotPending(prop.status);

        prop.status = ProposalStatus.CANCELLED;

        emit ProposalCancelled(_proposalId, msg.sender);
    }

    // ==========================================
    // DETRASH TREASURY FUNCTIONS (DECISION & SETTLEMENT)
    // ==========================================

    /**
     * @notice A Detrash aceita a proposta e executa a liquidação atômica bilateral (DvP).
     * @dev Transfere o pagamento direto do comprador para `detrashTreasury` e o cRECY direto da `detrashTreasury` para o comprador.
     *      Nenhum token fica armazenado neste contrato.
     */
    function acceptProposal(uint256 _proposalId) external onlyTreasuryOrOwner whenNotPaused nonReentrant {
        OTCProposal storage prop = proposals[_proposalId];

        if (prop.status != ProposalStatus.PENDING) {
            revert ProposalNotPending(prop.status);
        }
        if (block.timestamp > prop.expiration) {
            revert ProposalExpired(prop.expiration, uint64(block.timestamp));
        }

        IERC20 payToken = IERC20(prop.paymentToken);

        // Verifica solvência e allowance do comprador no momento exato da liquidação
        if (
            payToken.balanceOf(prop.buyer) < prop.paymentAmount
                || payToken.allowance(prop.buyer, address(this)) < prop.paymentAmount
        ) {
            revert InsufficientBuyerBalanceOrAllowance();
        }

        // Verifica solvência e allowance da tesouraria da Detrash
        if (
            crecyToken.balanceOf(detrashTreasury) < prop.crecyAmount
                || crecyToken.allowance(detrashTreasury, address(this)) < prop.crecyAmount
        ) {
            revert InsufficientTreasuryBalanceOrAllowance();
        }

        // Effects antes de Interactions (CEI Pattern)
        prop.status = ProposalStatus.ACCEPTED;

        // 1. Puxa o pagamento diretamente da carteira do comprador para a Tesouraria da Detrash
        payToken.safeTransferFrom(prop.buyer, detrashTreasury, prop.paymentAmount);

        // 2. Puxa o cRECY diretamente da Tesouraria da Detrash para a carteira do comprador
        crecyToken.safeTransferFrom(detrashTreasury, prop.buyer, prop.crecyAmount);

        emit ProposalAccepted(
            _proposalId,
            prop.buyer,
            prop.paymentToken,
            prop.paymentAmount,
            prop.crecyAmount,
            msg.sender,
            block.timestamp
        );
    }

    /**
     * @notice A Detrash recusa formalmente uma proposta pendente.
     */
    function rejectProposal(uint256 _proposalId, string calldata _reason) external onlyTreasuryOrOwner nonReentrant {
        OTCProposal storage prop = proposals[_proposalId];

        if (prop.status != ProposalStatus.PENDING) {
            revert ProposalNotPending(prop.status);
        }

        prop.status = ProposalStatus.REJECTED;

        emit ProposalRejected(_proposalId, prop.buyer, _reason, msg.sender);
    }

    // ==========================================
    // INTERNAL LOGIC
    // ==========================================

    function _createProposalInternal(
        address _buyer,
        address _paymentToken,
        uint256 _paymentAmount,
        uint256 _crecyAmount,
        uint64 _expiration,
        bytes32 _termsAcceptedHash,
        bytes32 _buyerComplianceRef
    ) internal returns (uint256 proposalId) {
        PaymentTokenConfig memory config = paymentTokens[_paymentToken];
        if (!config.isSupported) revert UnsupportedPaymentToken();
        if (_paymentAmount == 0 || _crecyAmount == 0) revert InvalidAmounts();

        // Valida assinatura do Termo de Utilidade vigente
        if (_termsAcceptedHash != currentCommercialTermsHash) {
            revert InvalidTermsHash(_termsAcceptedHash, currentCommercialTermsHash);
        }

        // Valida janela de expiração
        if (
            _expiration < block.timestamp + MIN_EXPIRATION_DURATION
                || _expiration > block.timestamp + MAX_EXPIRATION_DURATION
        ) {
            revert InvalidExpiration();
        }

        // Valida valor mínimo da proposta
        if (_paymentAmount < config.minPaymentAmount) {
            revert BelowMinimumPayment(_paymentAmount, config.minPaymentAmount);
        }

        // Valida piso de preço anti-spam (cRECY possui 18 casas decimais)
        if (config.minPricePerWholeCrecy > 0) {
            uint256 minRequiredPayment = (_crecyAmount * config.minPricePerWholeCrecy) / 1e18;
            if (_paymentAmount < minRequiredPayment) {
                revert BelowMinimumFloorPrice(_paymentAmount, minRequiredPayment);
            }
        }

        // Garante que o comprador possui saldo e concedeu allowance na criação (evita propostas falsas/spam)
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
            createdAt: uint64(block.timestamp),
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

    // ==========================================
    // ADMIN & CONFIGURATION FUNCTIONS
    // ==========================================

    /**
     * @notice Configura ou atualiza um token de pagamento aceito pela Detrash.
     * @param _token Endereço do ERC20 (ex: USDC, USDT, cREAL)
     * @param _isSupported True para habilitar, False para desabilitar
     * @param _minPaymentAmount Valor mínimo absoluto por proposta (na escala decimal do `_token`)
     * @param _minPricePerWholeCrecy Piso mínimo por 1 cRECY inteiro (1e18 unidades) na escala decimal do `_token`
     */
    function configurePaymentToken(
        address _token,
        bool _isSupported,
        uint256 _minPaymentAmount,
        uint256 _minPricePerWholeCrecy
    ) external onlyOwner {
        if (_token == address(0) || _token == address(crecyToken)) revert InvalidAddress();

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
        bytes32 old = currentCommercialTermsHash;
        currentCommercialTermsHash = _newTermsHash;
        emit CommercialTermsHashUpdated(old, _newTermsHash);
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    /**
     * @notice Resgate de segurança caso alguém transfira tokens acidentalmente direto para o endereço do contrato.
     * @dev Reforça a política de Saldo Zero no contrato.
     */
    function rescueAccidentalERC20(address _token, uint256 _amount) external onlyOwner {
        IERC20(_token).safeTransfer(detrashTreasury, _amount);
    }

    // ==========================================
    // VIEW FUNCTIONS (FRONTEND & DASHBOARD)
    // ==========================================

    function getBuyerProposals(address _buyer) external view returns (uint256[] memory) {
        return _buyerProposals[_buyer];
    }

    /**
     * @notice Verifica em tempo real se uma proposta está apta a ser liquidada pela Detrash agora.
     */
    function canSettleProposal(uint256 _proposalId) external view returns (bool settleable, string memory reason) {
        OTCProposal memory prop = proposals[_proposalId];
        if (prop.status != ProposalStatus.PENDING) return (false, "Proposal is not pending");
        if (block.timestamp > prop.expiration) return (false, "Proposal expired");

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
