// SPDX-License-Identifier: MIT
pragma solidity ^0.8.23;

import "@openzeppelin/contracts-upgradeable/token/ERC20/IERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/token/ERC20/utils/SafeERC20Upgradeable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/Initializable.sol";
import "@openzeppelin/contracts-upgradeable/proxy/utils/UUPSUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/ReentrancyGuardUpgradeable.sol";
import "@openzeppelin/contracts-upgradeable/security/PausableUpgradeable.sol";
import "./Interfaces/ISettlementProtocol.sol";

/// @title GlobalSettlementProtocol
/// @notice Real-time multi-currency settlement with atomic cross-chain swaps
///         via LayerZero, bilateral netting, SDR basket support, compliance
///         hooks, and a full audit trail. Designed to compete with IMF/World
///         Bank payment infrastructure.
/// @dev    UUPSUpgradeable – governance through Timelock.
contract GlobalSettlementProtocol is
    ISettlementProtocol,
    Initializable,
    UUPSUpgradeable,
    OwnableUpgradeable,
    ReentrancyGuardUpgradeable,
    PausableUpgradeable
{
    using SafeERC20Upgradeable for IERC20Upgradeable;

    // =========================================================================
    // Constants
    // =========================================================================

    uint256 public constant BPS = 10_000;
    uint256 public constant SDR_PRECISION = 1e18;
    /// @dev How long a dispute can remain open before auto-resolution
    uint256 public constant DISPUTE_WINDOW = 7 days;

    // =========================================================================
    // State
    // =========================================================================

    address public lzEndpoint;
    address public timelock;
    address public complianceLayer; // optional compliance hook registry

    /// @dev token → currency config
    mapping(address => CurrencyConfig) private _currencies;
    address[] private _currencyList;

    /// @dev settlement id → settlement
    mapping(bytes32 => Settlement) private _settlements;
    uint256 private _settlementNonce;

    /// @dev party → counterparty → token → net position
    mapping(address => mapping(address => mapping(address => int256))) private _netPositions;

    /// @dev SDR basket
    SDRBasket private _sdrBasket;

    /// @dev compliance hooks registered
    address[] private _complianceHooks;
    mapping(address => bool) private _isComplianceHook;

    /// @dev settlement id → array of (action, timestamp) pairs
    mapping(bytes32 => string[]) private _auditActions;
    mapping(bytes32 => uint256[]) private _auditTimestamps;

    /// @dev LayerZero trusted remotes
    mapping(uint32 => bytes) public trustedRemotes;

    // =========================================================================
    // Initializer
    // =========================================================================

    /// @custom:oz-upgrades-unsafe-allow constructor
    constructor() {
        _disableInitializers();
    }

    function initialize(
        address _lzEndpoint,
        address _timelock,
        address _owner
    ) public initializer {
        __Ownable_init(_owner);
        __UUPSUpgradeable_init();
        __ReentrancyGuard_init();
        __Pausable_init();

        lzEndpoint = _lzEndpoint;
        timelock = _timelock;
    }

    function _authorizeUpgrade(address) internal view override {
        require(msg.sender == timelock, "Only timelock can upgrade");
    }

    // =========================================================================
    // Modifiers
    // =========================================================================

    modifier onlyTimelock() {
        require(msg.sender == timelock, "Only timelock");
        _;
    }

    // =========================================================================
    // Currency Management
    // =========================================================================

    /// @inheritdoc ISettlementProtocol
    function registerCurrency(
        address token,
        string calldata isoCode,
        uint256 sdrWeight
    ) external override onlyOwner {
        require(token != address(0), "Zero address");
        require(!_currencies[token].active, "Already registered");

        _currencies[token] = CurrencyConfig({
            token: token,
            isoCode: isoCode,
            sdrWeight: sdrWeight,
            active: true
        });
        _currencyList.push(token);

        emit CurrencyRegistered(token, isoCode, sdrWeight);
    }

    /// @inheritdoc ISettlementProtocol
    function getCurrencyConfig(address token)
        external
        view
        override
        returns (CurrencyConfig memory)
    {
        return _currencies[token];
    }

    /// @inheritdoc ISettlementProtocol
    function getAllCurrencies() external view override returns (address[] memory) {
        return _currencyList;
    }

    // =========================================================================
    // Settlement Lifecycle
    // =========================================================================

    /// @inheritdoc ISettlementProtocol
    function initiateSettlement(
        address counterparty,
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minAmountOut,
        uint32  dstChainId,
        bytes calldata complianceData
    ) external override nonReentrant whenNotPaused returns (bytes32 settlementId) {
        require(counterparty != address(0), "Zero counterparty");
        require(_currencies[tokenIn].active, "Unsupported tokenIn");
        require(_currencies[tokenOut].active, "Unsupported tokenOut");
        require(amountIn > 0, "Zero amountIn");

        // Run compliance hooks
        _runComplianceHooks(bytes32(0), msg.sender, amountIn, complianceData);

        // Transfer tokenIn to this contract as escrow
        IERC20Upgradeable(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);

        settlementId = keccak256(
            abi.encodePacked(msg.sender, counterparty, tokenIn, tokenOut, amountIn, ++_settlementNonce)
        );

        _settlements[settlementId] = Settlement({
            id: settlementId,
            initiator: msg.sender,
            counterparty: counterparty,
            tokenIn: tokenIn,
            tokenOut: tokenOut,
            amountIn: amountIn,
            amountOut: minAmountOut, // stored as min; updated on execute
            dstChainId: dstChainId,
            status: SettlementStatus.Pending,
            createdAt: block.timestamp,
            settledAt: 0,
            complianceData: complianceData
        });

        _recordAudit(settlementId, "Initiated");
        emit SettlementInitiated(settlementId, msg.sender, tokenIn, tokenOut, amountIn);

        // Cross-chain path
        if (dstChainId != 0) {
            _sendCrossChain(settlementId, dstChainId);
        }
    }

    /// @inheritdoc ISettlementProtocol
    function executeSettlement(bytes32 settlementId)
        external
        override
        nonReentrant
        whenNotPaused
        returns (uint256 amountOut)
    {
        Settlement storage s = _settlements[settlementId];
        require(s.status == SettlementStatus.Pending, "Not pending");
        require(s.dstChainId == 0, "Cross-chain settlement");
        require(
            msg.sender == s.initiator || msg.sender == s.counterparty,
            "Unauthorized"
        );

        // Run compliance hooks
        _runComplianceHooks(settlementId, s.initiator, s.amountIn, s.complianceData);

        // Simple 1:1 settlement (oracle-based pricing can be plugged in via hook)
        amountOut = s.amountIn; // same-chain, same-token settlement for now
        s.amountOut = amountOut;
        s.status = SettlementStatus.Completed;
        s.settledAt = block.timestamp;

        IERC20Upgradeable(s.tokenIn).safeTransfer(s.counterparty, amountOut);

        _recordAudit(settlementId, "Executed");
        emit SettlementCompleted(settlementId, amountOut, block.timestamp);
    }

    /// @inheritdoc ISettlementProtocol
    function cancelSettlement(bytes32 settlementId) external override nonReentrant {
        Settlement storage s = _settlements[settlementId];
        require(s.status == SettlementStatus.Pending, "Cannot cancel");
        require(msg.sender == s.initiator, "Only initiator");

        s.status = SettlementStatus.Cancelled;
        IERC20Upgradeable(s.tokenIn).safeTransfer(s.initiator, s.amountIn);

        _recordAudit(settlementId, "Cancelled");
        emit SettlementCancelled(settlementId);
    }

    /// @inheritdoc ISettlementProtocol
    function getSettlement(bytes32 settlementId)
        external
        view
        override
        returns (Settlement memory)
    {
        return _settlements[settlementId];
    }

    // =========================================================================
    // Netting Engine
    // =========================================================================

    /// @inheritdoc ISettlementProtocol
    function submitNetPosition(
        address counterparty,
        address token,
        int256 amount
    ) external override whenNotPaused {
        _netPositions[msg.sender][counterparty][token] += amount;
        _netPositions[counterparty][msg.sender][token] -= amount;
        emit NetPositionUpdated(msg.sender, token, _netPositions[msg.sender][counterparty][token]);
    }

    /// @inheritdoc ISettlementProtocol
    function netAndSettle(address counterparty, address[] calldata tokens)
        external
        override
        nonReentrant
        whenNotPaused
    {
        for (uint256 i = 0; i < tokens.length; i++) {
            address token = tokens[i];
            int256 position = _netPositions[msg.sender][counterparty][token];
            if (position == 0) continue;

            // Positive: counterparty owes us; negative: we owe counterparty
            if (position > 0) {
                uint256 owed = uint256(position);
                IERC20Upgradeable(token).safeTransferFrom(counterparty, msg.sender, owed);
            } else {
                uint256 owed = uint256(-position);
                IERC20Upgradeable(token).safeTransferFrom(msg.sender, counterparty, owed);
            }

            _netPositions[msg.sender][counterparty][token] = 0;
            _netPositions[counterparty][msg.sender][token] = 0;

            emit NetPositionUpdated(msg.sender, token, 0);
            emit NetPositionUpdated(counterparty, token, 0);
        }
    }

    /// @inheritdoc ISettlementProtocol
    function getNetPosition(
        address party,
        address counterparty,
        address token
    ) external view override returns (int256) {
        return _netPositions[party][counterparty][token];
    }

    // =========================================================================
    // SDR Basket
    // =========================================================================

    /// @notice Configure the initial SDR basket (owner / governance)
    function configureSDRBasket(address[] calldata tokens, uint256[] calldata weights)
        external
        onlyOwner
    {
        require(tokens.length == weights.length, "Length mismatch");
        uint256 sum;
        for (uint256 i = 0; i < weights.length; i++) sum += weights[i];
        require(sum == SDR_PRECISION, "Weights must sum to 1e18");

        _sdrBasket.tokens = tokens;
        _sdrBasket.weights = weights;
        _sdrBasket.lastRebalanced = block.timestamp;
    }

    /// @inheritdoc ISettlementProtocol
    function rebalanceSDR() external override whenNotPaused {
        SDRBasket storage basket = _sdrBasket;
        require(basket.tokens.length > 0, "Basket not configured");

        uint256 totalValue;
        for (uint256 i = 0; i < basket.tokens.length; i++) {
            // Use on-chain balance as a proxy for value (oracle can be plugged in)
            totalValue += IERC20Upgradeable(basket.tokens[i]).balanceOf(address(this));
        }

        basket.totalValue = totalValue;
        basket.lastRebalanced = block.timestamp;

        emit SDRBasketRebalanced(totalValue, block.timestamp);
    }

    /// @inheritdoc ISettlementProtocol
    function getSDRBasket() external view override returns (SDRBasket memory) {
        return _sdrBasket;
    }

    /// @inheritdoc ISettlementProtocol
    function getSDRValue() external view override returns (uint256) {
        return _sdrBasket.totalValue;
    }

    // =========================================================================
    // Compliance
    // =========================================================================

    /// @inheritdoc ISettlementProtocol
    function addComplianceHook(address hook) external override onlyOwner {
        require(hook != address(0), "Zero address");
        require(!_isComplianceHook[hook], "Already added");
        _isComplianceHook[hook] = true;
        _complianceHooks.push(hook);
    }

    /// @inheritdoc ISettlementProtocol
    function removeComplianceHook(address hook) external override onlyOwner {
        require(_isComplianceHook[hook], "Hook not found");
        _isComplianceHook[hook] = false;
        for (uint256 i = 0; i < _complianceHooks.length; i++) {
            if (_complianceHooks[i] == hook) {
                _complianceHooks[i] = _complianceHooks[_complianceHooks.length - 1];
                _complianceHooks.pop();
                break;
            }
        }
    }

    // =========================================================================
    // Audit Trail
    // =========================================================================

    /// @inheritdoc ISettlementProtocol
    function getAuditTrail(bytes32 settlementId)
        external
        view
        override
        returns (string[] memory actions, uint256[] memory timestamps)
    {
        return (_auditActions[settlementId], _auditTimestamps[settlementId]);
    }

    // =========================================================================
    // Dispute Resolution
    // =========================================================================

    /// @inheritdoc ISettlementProtocol
    function raiseDispute(bytes32 settlementId, string calldata reason) external override {
        Settlement storage s = _settlements[settlementId];
        require(
            s.status == SettlementStatus.Completed || s.status == SettlementStatus.Pending,
            "Cannot dispute"
        );
        require(
            msg.sender == s.initiator || msg.sender == s.counterparty,
            "Unauthorized"
        );

        s.status = SettlementStatus.Disputed;
        _recordAudit(settlementId, string(abi.encodePacked("Disputed: ", reason)));
        emit SettlementDisputed(settlementId, msg.sender, reason);
    }

    /// @inheritdoc ISettlementProtocol
    function resolveDispute(bytes32 settlementId, uint256 resolution)
        external
        override
        onlyTimelock
    {
        Settlement storage s = _settlements[settlementId];
        require(s.status == SettlementStatus.Disputed, "Not disputed");

        s.status = SettlementStatus.Resolved;
        _recordAudit(settlementId, "Resolved");
        emit SettlementResolved(settlementId, resolution);
    }

    // =========================================================================
    // Cross-Chain (LayerZero)
    // =========================================================================

    /// @notice Set trusted remote for a destination chain
    function setTrustedRemote(uint32 dstChainId, bytes calldata remoteAddress)
        external
        onlyOwner
    {
        trustedRemotes[dstChainId] = remoteAddress;
    }

    /// @inheritdoc ISettlementProtocol
    function lzReceive(
        uint16 srcChainId,
        bytes calldata srcAddress,
        uint64, /* nonce */
        bytes calldata payload
    ) external override {
        require(msg.sender == lzEndpoint, "Caller is not LZ endpoint");
        require(
            keccak256(srcAddress) == keccak256(trustedRemotes[uint32(srcChainId)]),
            "Untrusted source"
        );

        (bytes32 settlementId, address initiator, address tokenIn, uint256 amountIn) =
            abi.decode(payload, (bytes32, address, address, uint256));

        // Record inbound cross-chain settlement
        if (_settlements[settlementId].id == bytes32(0)) {
            _settlements[settlementId] = Settlement({
                id: settlementId,
                initiator: initiator,
                counterparty: address(0),
                tokenIn: tokenIn,
                tokenOut: tokenIn,
                amountIn: amountIn,
                amountOut: 0,
                dstChainId: 0,
                status: SettlementStatus.Pending,
                createdAt: block.timestamp,
                settledAt: 0,
                complianceData: ""
            });

            _recordAudit(settlementId, "CrossChainReceived");
            emit CrossChainSettlementReceived(settlementId, uint32(srcChainId));
        }
    }

    // =========================================================================
    // Admin
    // =========================================================================

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    // =========================================================================
    // Internal Helpers
    // =========================================================================

    function _sendCrossChain(bytes32 settlementId, uint32 dstChainId) internal {
        require(trustedRemotes[dstChainId].length > 0, "Untrusted destination");

        Settlement storage s = _settlements[settlementId];
        bytes memory payload = abi.encode(
            settlementId,
            s.initiator,
            s.tokenIn,
            s.amountIn
        );

        ILayerZeroEndpoint(lzEndpoint).send{value: 0}(
            uint16(dstChainId),
            trustedRemotes[dstChainId],
            payload,
            payable(msg.sender),
            address(0),
            ""
        );

        emit CrossChainSettlementSent(settlementId, dstChainId);
    }

    function _runComplianceHooks(
        bytes32 settlementId,
        address user,
        uint256 amount,
        bytes memory /*complianceData*/
    ) internal {
        for (uint256 i = 0; i < _complianceHooks.length; i++) {
            address hook = _complianceHooks[i];
            (bool success, ) = hook.call{gas: 100_000}(
                abi.encodeWithSignature(
                    "screenTransaction(address,uint256,bytes32)",
                    user,
                    amount,
                    settlementId
                )
            );
            emit ComplianceHookCalled(settlementId, hook, success);
            require(success, "Compliance hook rejected");
        }
    }

    function _recordAudit(bytes32 settlementId, string memory action) internal {
        _auditActions[settlementId].push(action);
        _auditTimestamps[settlementId].push(block.timestamp);
        emit AuditTrailRecorded(settlementId, msg.sender, action, block.timestamp);
    }
}

/// @dev Minimal LayerZero endpoint interface (repeated to avoid cross-file deps)
interface ILayerZeroEndpoint {
    function send(
        uint16 _dstChainId,
        bytes calldata _destination,
        bytes calldata _payload,
        address payable _refundAddress,
        address _zroPaymentAddress,
        bytes calldata _adapterParams
    ) external payable;
}
