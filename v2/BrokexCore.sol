// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import { ContractRegistry } from "@flarenetwork/flare-periphery-contracts/flare/ContractRegistry.sol";
import { FtsoV2Interface } from "@flarenetwork/flare-periphery-contracts/flare/FtsoV2Interface.sol";
import { ITeeExtensionRegistry } from "./interfaces/ITeeExtensionRegistry.sol";
import { ITeeMachineRegistry } from "./interfaces/ITeeMachineRegistry.sol";

// =============================================================
// Interfaces
// =============================================================

interface IERC20 {
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

interface IBrokexVault {
    function payTrader(address trader, uint256 amount) external;
    function getRequiredFreeUSDC() external returns (uint256);
    function USDT() external view returns (address);
}

// =============================================================
// BrokexCore
// =============================================================

contract BrokexCore {

    uint256 public constant PRECISION          = 1e6;
    uint256 public constant HOUR               = 1 hours;



    // Hard cap on leverage. Plafond absolu de 100x.
    // Même si le owner modifie la configuration, impossible de dépasser 100x.
    uint256 public constant MAX_LEVERAGE_HARD_CAP = 100;

    // Hard cap on spreadLong and spreadShort from every KMS proof.
    // Immutable — no setter, no owner override.
    // 1_000 = 0.1% (PRECISION-scaled).
    uint256 public constant MAX_SPREAD_ALLOWED = 1_000;

    // Hard cap on commission set by owner.
    // 10_000 = 1.0% (PRECISION-scaled).
    uint256 public constant MAX_COMMISSION_ALLOWED = 10_000;

    // Trade states
    uint8 public constant STATE_ORDER      = 0;
    uint8 public constant STATE_OPEN       = 1;
    uint8 public constant STATE_CLOSED     = 2;
    uint8 public constant STATE_CANCELLED  = 3;
    uint8 public constant STATE_LIQUIDATED = 4;
    uint8 public constant STATE_EMERGENCY  = 5;

    // Directions
    uint8 public constant DIR_LONG  = 1;
    uint8 public constant DIR_SHORT = 0;

    // Order types
    uint8 public constant ORDER_MARKET = 0;
    uint8 public constant ORDER_LIMIT  = 1;
    uint8 public constant ORDER_STOP   = 2;

    // Close reasons
    uint8 public constant REASON_MARKET    = 0;
    uint8 public constant REASON_SL        = 1;
    uint8 public constant REASON_TP        = 2;
    uint8 public constant REASON_LIQ       = 3;
    uint8 public constant REASON_EMERGENCY = 4;
    uint8 public constant REASON_CANCEL    = 5;

    // =========================================================
    // Structs
    // =========================================================

    struct AssetConfig {
        bytes21 feedId;             // e.g. 0x01504158472f555344000000000000000000000000 (FTSO V2 feed id)
        uint256 minLeverage;        // e.g. 2 = 2x (Unscaled plain integer)
        uint256 maxLeverage;        // e.g. 100 = 100x (Unscaled plain integer)
        // Minimum GROSS collateral the trader must send (margin + commission combined).
        uint256 minTradeSize;
        uint256 commissionBps;      // e.g. 1_000 = 0.1% (PRECISION-scaled)
        // Borrow: fee = OI * borrowRateHourly * elapsedSeconds / HOUR / PRECISION
        uint256 borrowRateHourly;
        uint256 profitCap;          // e.g. 100_000 = 10% of OI (PRECISION-scaled)
        uint256 executionTolerance; // e.g. 500 = 0.05% keeper price band (PRECISION-scaled)
        uint256 maxProofAge;        // seconds — max age for FTSOv2 price AND KMS proof
        uint256 maxTraderOI;        // Maximum allowed open interest per single trader (USDT-scaled, 6 decimals)
        uint256 maxGlobalOI;        // Maximum allowed global open interest (Long/Short independently, USDT-scaled)
        uint256 lockedCapitalBps;   // e.g. 500 = 5% (PRECISION-scaled)
        uint256 liqThresholdBps;    // e.g. 900_000 = 90% (PRECISION-scaled)
        bool listed;
        bool frozen;
    }

    struct Trade {
        uint256 id;
        address trader;
        uint256 assetId;

        uint8 state;
        uint8 direction;
        uint8 orderType;

        // STATE_ORDER : margin = full collateral (commission not yet deducted)
        // STATE_OPEN  : margin = collateral − commission
        uint256 margin;
        uint256 leverage;

        uint256 targetPrice;   // limit/stop trigger price (0 for market); raw oracle price, no spread
        uint256 openPrice;     // actual entry price WITH spread applied
        uint256 closePrice;    // actual exit price WITH spread applied

        uint256 stopLoss;      // raw oracle price at which SL triggers (no spread)
        uint256 takeProfit;    // raw oracle price at which TP triggers (no spread)

        uint256 openTimestamp;  // block.timestamp at activation
        uint256 closeTimestamp;
    }

    struct AssetExposure {
        uint256 openInterestLong;
        uint256 openInterestShort;
        uint256 avgEntryPriceLong;
        uint256 avgEntryPriceShort;
    }

    /**
     * @dev Flare Confidential Compute (FCC) TEE Risk Proof
     * Signed off-chain inside the secure TEE Enclave memory (`extension-tee`).
     * Signature covers: assetId, maxOILong, maxOIShort, spreadLong, spreadShort, timestamp.
     */
    struct TeeRiskProof {
        uint256 assetId;
        uint256 maxOILong;    // max allowed global long OI after this trade opens
        uint256 maxOIShort;   // max allowed global short OI after this trade opens
        uint256 spreadLong;   // spread when trader BUYS  (≤ MAX_SPREAD_ALLOWED)
        uint256 spreadShort;  // spread when trader SELLS (≤ MAX_SPREAD_ALLOWED)
        uint256 timestamp;    // unix timestamp — proof signed at this time inside TEE enclave
        bytes   sig;          // ECDSA over keccak256(abi.encode(assetId,maxOILong,maxOIShort,spreadLong,spreadShort,timestamp))
    }

    // Avoids stack-too-deep in _storeTrade
    struct TradeInit {
        uint256 assetId;
        uint8   direction;
        uint8   orderType;
        uint256 margin;
        uint256 leverage;
        uint256 targetPrice;
        uint256 openPrice;
        uint256 slPrice;
        uint256 tpPrice;
    }

    // =========================================================
    // Storage
    // =========================================================

    address public owner;
    address public pendingOwner;
    bool    private locked;

    IERC20           public immutable USDT;
    IBrokexVault     public immutable vault;

    // Official Flare Confidential Compute (FCC) TEE Enclave Signer & Registries
    address      public teeEnclaveSigner; // TEE Enclave Signer Address (isolated in TEE memory)
    uint256      public teeExtensionId;
    ITeeExtensionRegistry public teeExtensionRegistry;
    ITeeMachineRegistry   public teeMachineRegistry;

    mapping(uint256 => AssetConfig) public assets;

    bool public paused;
    bool public emergencyMode;

    mapping(uint256 => AssetExposure) public exposures;
    uint256 public totalLockedCapital;

    // Cumulative OI per trader (long + short combined)
    mapping(uint256 => mapping(address => uint256)) public traderOpenInterest;
    mapping(uint256 => Trade)     public trades;

    uint256 public nextTradeId = 1;
    uint256[] public listedAssetIds;

    // =========================================================
    // Events & Errors
    // =========================================================

    event TradeEvent(uint256 indexed tradeId);
    event OwnershipTransferStarted(address indexed old, address indexed pending);
    event OwnershipTransferred(address indexed old, address indexed next);
    event ConfigUpdated();
    event TeeSignerUpdated(address indexed signer);
    event TradingPaused();
    event TradingUnpaused();
    event EmergencyEnabled();
    event EmergencyDisabled();
    event InsolvencyWarning(uint256 indexed tradeId, uint256 owed, uint256 paid);

    error NotOwner();
    error NotPendingOwner();
    error Reentrancy();
    error ZeroAddress();
    error BadParameter();
    error ProtocolPaused();
    error NotPausedError();
    error EmergencyOnly();
    error NotTrader();
    error BadDirection();
    error BadOrderType();
    error BadLeverage();
    error BadMargin();
    error BadPrice();
    error BadSLTP();
    error DelayNotPassed();
    error InvalidState();
    error OIExceeded();
    error TraderOIExceeded();
    error GlobalOIExceeded();
    error InsufficientVaultCapital();
    error StalePrice();
    error PairNotInProof();
    error InvalidTeeProof();
    error TeeProofExpired();
    error SpreadExceedsMaxAllowed();
    error TransferFailed();
    error InsufficientFreeLiquidityForWithdrawals();

    // =========================================================
    // Modifiers
    // =========================================================

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    modifier nonReentrant() {
        if (locked) revert Reentrancy();
        locked = true;
        _;
        locked = false;
    }

    modifier notPaused() {
        if (paused) revert ProtocolPaused();
        _;
    }

    // =========================================================
    // Constructor
    // =========================================================

    constructor(
        address vaultAddress,
        address teeSignerAddress,
        address _teeExtensionRegistry,
        address _teeMachineRegistry
    ) {
        if (vaultAddress     == address(0)) revert ZeroAddress();
        if (teeSignerAddress == address(0)) revert ZeroAddress();

        owner              = msg.sender;
        vault              = IBrokexVault(vaultAddress);
        USDT               = IERC20(IBrokexVault(vaultAddress).USDT());
        teeEnclaveSigner   = teeSignerAddress; // Flare TEE Enclave Signer Key
        
        if (_teeExtensionRegistry != address(0)) {
            teeExtensionRegistry = ITeeExtensionRegistry(_teeExtensionRegistry);
        }
        if (_teeMachineRegistry != address(0)) {
            teeMachineRegistry = ITeeMachineRegistry(_teeMachineRegistry);
        }

        emit OwnershipTransferred(address(0), msg.sender);
    }

    // =========================================================
    // Ownership
    // =========================================================

    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert ZeroAddress();
        pendingOwner = newOwner;
        emit OwnershipTransferStarted(owner, newOwner);
    }

    function acceptOwnership() external {
        if (msg.sender != pendingOwner) revert NotPendingOwner();
        address old  = owner;
        owner        = pendingOwner;
        pendingOwner = address(0);
        emit OwnershipTransferred(old, owner);
    }

    // =========================================================
    // Admin
    // =========================================================

    event AssetListed(uint256 indexed assetId);
    event AssetUpdated(uint256 indexed assetId);
    event AssetFrozen(uint256 indexed assetId);
    event AssetUnfrozen(uint256 indexed assetId);
    event AssetDelisted(uint256 indexed assetId);

    function listAsset(uint256 assetId, AssetConfig calldata cfg) external onlyOwner {
        if (assets[assetId].listed) revert BadParameter(); // Already listed
        if (listedAssetIds.length >= 10) revert BadParameter(); // Hard cap of 10 assets
        _validateConfig(cfg);
        AssetConfig memory newCfg = cfg;
        newCfg.listed = true;
        newCfg.frozen = false;
        assets[assetId] = newCfg;
        listedAssetIds.push(assetId);
        emit AssetListed(assetId);
    }

    function updateAsset(uint256 assetId, AssetConfig calldata cfg) external onlyOwner {
        if (!assets[assetId].listed) revert BadParameter(); // Not listed
        _validateConfig(cfg);
        AssetConfig memory newCfg = cfg;
        // profitCap, borrowRateHourly, lockedCapitalBps, and liqThresholdBps are immutable once listed
        newCfg.profitCap = assets[assetId].profitCap;
        newCfg.borrowRateHourly = assets[assetId].borrowRateHourly;
        newCfg.lockedCapitalBps = assets[assetId].lockedCapitalBps;
        newCfg.liqThresholdBps = assets[assetId].liqThresholdBps;
        newCfg.listed = true;
        newCfg.frozen = assets[assetId].frozen;
        assets[assetId] = newCfg;
        emit AssetUpdated(assetId);
    }

    function freezeAsset(uint256 assetId) external onlyOwner {
        if (!assets[assetId].listed) revert BadParameter();
        assets[assetId].frozen = true;
        emit AssetFrozen(assetId);
    }

    function unfreezeAsset(uint256 assetId) external onlyOwner {
        if (!assets[assetId].listed) revert BadParameter();
        assets[assetId].frozen = false;
        emit AssetUnfrozen(assetId);
    }

    function delistAsset(uint256 assetId) external onlyOwner {
        if (!assets[assetId].listed) revert BadParameter();
        if (exposures[assetId].openInterestLong != 0 || exposures[assetId].openInterestShort != 0) revert BadParameter();
        assets[assetId].listed = false;

        uint256 len = listedAssetIds.length;
        for (uint256 i = 0; i < len; i++) {
            if (listedAssetIds[i] == assetId) {
                listedAssetIds[i] = listedAssetIds[len - 1];
                listedAssetIds.pop();
                break;
            }
        }

        emit AssetDelisted(assetId);
    }

    function setTeeSigner(address newSigner) external onlyOwner {
        if (newSigner == address(0)) revert ZeroAddress();
        teeEnclaveSigner = newSigner;
        emit TeeSignerUpdated(newSigner);
    }

    /**
     * @notice Configure Flare Confidential Compute (FCC) TEE Enclave Signer & Registries
     * 
     * NEXT IMPLEMENTATION STEPS (When Flare releases Coston2 ExtensionGovernance update):
     * 1. Register extension on Coston2 TeeExtensionRegistry to obtain extensionId.
     * 2. Call setTeeExtensionConfig(extensionId, enclaveSignerAddress, teeExtensionRegistry, teeMachineRegistry).
     * 3. Enable direct on-chain machine attestation verification.
     */
    function setTeeExtensionConfig(
        uint256 _extensionId,
        address _enclaveSigner,
        address _teeExtensionRegistry,
        address _teeMachineRegistry
    ) external onlyOwner {
        if (_enclaveSigner != address(0)) teeEnclaveSigner = _enclaveSigner;
        teeExtensionId = _extensionId;
        if (_teeExtensionRegistry != address(0)) teeExtensionRegistry = ITeeExtensionRegistry(_teeExtensionRegistry);
        if (_teeMachineRegistry != address(0)) teeMachineRegistry = ITeeMachineRegistry(_teeMachineRegistry);
        emit ConfigUpdated();
    }


    function pause() external onlyOwner {
        if (paused) revert ProtocolPaused();
        paused = true;
        emit TradingPaused();
    }

    function unpause() external onlyOwner {
        if (!paused) revert NotPausedError();
        paused = false;
        emit TradingUnpaused();
    }

    function enableEmergencyMode() external onlyOwner {
        paused        = true;
        emergencyMode = true;
        emit EmergencyEnabled();
    }

    /// @notice Disables emergency mode.
    /// @dev Leaving the protocol paused after disabling emergency mode is an intentional safety feature.
    ///      This allows the owner to inspect the state, resolve any issues, and manually call unpause() when ready.
    function disableEmergencyMode() external onlyOwner {
        emergencyMode = false;
        emit EmergencyDisabled();
    }

    // =========================================================
    // User — Open Market Position
    // =========================================================

    function openMarketPosition(
        uint256 assetId,
        uint8   direction,
        uint256 collateral,
        uint256 leverage,
        uint256 slPrice,
        uint256 tpPrice,
        TeeRiskProof calldata riskProof
    ) external nonReentrant notPaused returns (uint256 tradeId) {
        AssetConfig storage cfg = assets[assetId];
        if (!cfg.listed) revert BadParameter();
        if (cfg.frozen) revert BadParameter();

        if (direction != DIR_LONG && direction != DIR_SHORT) revert BadDirection();

        _verifyTeeProof(riskProof);
        _validateSpreadCap(riskProof.spreadLong, riskProof.spreadShort);

        (uint256 margin, uint256 oi) = _pullFundsAndCommission(assetId, collateral, leverage);

        uint256 oraclePrice = _getPrice(assetId);

        // Entry spread applied to the raw oracle price → stored as openPrice.
        // Spread does NOT affect SL/TP/liq trigger thresholds — those remain oracle-price-based.
        uint256 entryPrice = _applyEntrySpread(oraclePrice, direction, riskProof);

        // liqPrice is anchored to openPrice (spread-adjusted) so PnL math is consistent,
        // but the trigger comparison in _executeTriggered uses the raw oracle price vs liqPrice.
        // This means liqPrice already accounts for the entry spread premium paid by the trader.
        uint256 liqP = _liqPrice(entryPrice, leverage, direction, cfg.liqThresholdBps);

        // SL/TP are validated against the spread-adjusted entry price so the relationship
        // (SL below entry for longs, etc.) is always meaningful.
        if (slPrice != 0 || tpPrice != 0) _validateSLTP(direction, entryPrice, liqP, slPrice, tpPrice);

        _applyRisk(assetId, direction, oi, riskProof);

        if (direction == DIR_LONG) {
            uint256 oldOI = exposures[assetId].openInterestLong - oi;
            exposures[assetId].avgEntryPriceLong = (exposures[assetId].avgEntryPriceLong * oldOI + entryPrice * oi) / exposures[assetId].openInterestLong;
        } else {
            uint256 oldOI = exposures[assetId].openInterestShort - oi;
            exposures[assetId].avgEntryPriceShort = (exposures[assetId].avgEntryPriceShort * oldOI + entryPrice * oi) / exposures[assetId].openInterestShort;
        }

        tradeId = _storeTrade(TradeInit({
            assetId:     assetId,
            direction:   direction,
            orderType:   ORDER_MARKET,
            margin:      margin,
            leverage:    leverage,
            targetPrice: 0,
            openPrice:   entryPrice,
            slPrice:     slPrice,
            tpPrice:     tpPrice
        }));

        emit TradeEvent(tradeId);
    }

    // =========================================================
    // User — Create Limit / Stop Order
    // =========================================================

    /// @notice Full collateral is pulled here; commission is deducted at execution.
    ///         Spread is NOT applied at order creation — it is applied by the keeper
    ///         at execution time using the TEE proof supplied in batchExecute.
    ///         targetPrice is a raw oracle price; the trigger comparison is also raw.
    function createLimitOrStopOrder(
        uint256 assetId,
        uint8   direction,
        uint8   orderType,
        uint256 targetPrice,
        uint256 collateral,
        uint256 leverage,
        uint256 slPrice,
        uint256 tpPrice
    ) external nonReentrant notPaused returns (uint256 tradeId) {
        if (direction != DIR_LONG && direction != DIR_SHORT)             revert BadDirection();
        if (orderType != ORDER_LIMIT && orderType != ORDER_STOP)         revert BadOrderType();
        if (targetPrice == 0) revert BadPrice();

        AssetConfig storage cfg = assets[assetId];
        if (!cfg.listed) revert BadParameter();
        if (cfg.frozen) revert BadParameter();

        // minTradeSize is a GROSS collateral minimum — checked before any commission deduction.
        if (collateral < cfg.minTradeSize)                              revert BadMargin();
        if (leverage < cfg.minLeverage || leverage > cfg.maxLeverage || leverage > MAX_LEVERAGE_HARD_CAP) revert BadLeverage();

        // SL/TP pre-validation uses targetPrice as a proxy for the future entry price.
        // The actual entryPrice will differ by spread at execution, but we still enforce
        // directional correctness at order creation time.
        uint256 approxLiq  = _liqPrice(targetPrice, leverage, direction, cfg.liqThresholdBps);
        if (slPrice != 0 || tpPrice != 0) _validateSLTP(direction, targetPrice, approxLiq, slPrice, tpPrice);

        _pull(msg.sender, collateral);

        tradeId = _storeTrade(TradeInit({
            assetId:     assetId,
            direction:   direction,
            orderType:   orderType,
            margin:      collateral,   // full collateral stored; commission deducted at execution
            leverage:    leverage,
            targetPrice: targetPrice,
            openPrice:   0,
            slPrice:     slPrice,
            tpPrice:     tpPrice
        }));

        emit TradeEvent(tradeId);
    }

    // =========================================================
    // User — Cancel Order
    // =========================================================

    function cancelOrder(uint256 tradeId) external nonReentrant {
        Trade storage t = trades[tradeId];
        if (t.trader != msg.sender)  revert NotTrader();
        if (t.state  != STATE_ORDER) revert InvalidState();
        if (block.timestamp < t.openTimestamp + 1 minutes) revert DelayNotPassed();

        t.state          = STATE_CANCELLED;
        t.closeTimestamp = block.timestamp;

        // Commission was never taken — refund full collateral
        _send(msg.sender, t.margin);
        emit TradeEvent(tradeId);
    }

    // =========================================================
    // User — Modify SL / TP
    // =========================================================

    /// @notice SL and TP are stored as raw oracle prices (no spread).
    ///         Validation uses openPrice (spread-adjusted) for open positions so that
    ///         the directional relationship is always enforced correctly.
    function modifyStops(uint256 tradeId, uint256 newSL, uint256 newTP) external {
        Trade storage t = trades[tradeId];
        if (t.trader != msg.sender) revert NotTrader();
        if (t.state != STATE_OPEN && t.state != STATE_ORDER) revert InvalidState();

        if (newSL != 0 || newTP != 0) {
            uint256 refPrice = t.state == STATE_OPEN ? t.openPrice   : t.targetPrice;
            uint256 liqP     = t.state == STATE_OPEN
                ? _liqPrice(t.openPrice, t.leverage, t.direction, assets[t.assetId].liqThresholdBps)
                : _liqPrice(t.targetPrice, t.leverage, t.direction, assets[t.assetId].liqThresholdBps);
            _validateSLTP(t.direction, refPrice, liqP, newSL, newTP);
        }

        t.stopLoss     = newSL;
        t.takeProfit   = newTP;
        emit TradeEvent(tradeId);
    }

    // =========================================================
    // User — Close Market
    // =========================================================

    /// @notice Allowed even when paused so traders can always exit.
    ///         The TEE proof supplies the spread for the exit leg.
    function closePositionMarket(
        uint256 assetId,
        uint256 tradeId,
        TeeRiskProof calldata riskProof
    ) external nonReentrant {
        Trade storage t = trades[tradeId];
        if (t.trader != msg.sender) revert NotTrader();
        if (t.state  != STATE_OPEN) revert InvalidState();
        if (t.assetId != assetId) revert BadParameter();
        if (riskProof.assetId != assetId) revert BadParameter();

        AssetConfig storage cfg = assets[assetId];
        if (!cfg.listed) revert BadParameter();

        _verifyTeeProof(riskProof);
        _validateSpreadCap(riskProof.spreadLong, riskProof.spreadShort);

        uint256 oraclePrice = _getPrice(assetId);
        _closeTrade(tradeId, oraclePrice, REASON_MARKET, riskProof);
    }

    // =========================================================
    // User — Emergency Close
    // =========================================================

    /// @notice In emergency mode, positions are unwound at net margin (no PnL, no oracle, no spread).
    function emergencyClose(uint256 tradeId) external nonReentrant {
        if (!emergencyMode) revert EmergencyOnly();

        Trade storage t = trades[tradeId];
        if (t.trader != msg.sender) revert NotTrader();

        if (t.state == STATE_ORDER) {
            // Commission never taken → refund full collateral
            t.state          = STATE_EMERGENCY;
            t.closeTimestamp = block.timestamp;
            _send(t.trader, t.margin);

        } else if (t.state == STATE_OPEN) {
            // Commission already taken → refund net margin only; no PnL / no spread
            _releaseExposure(tradeId);
            t.state          = STATE_EMERGENCY;
            t.closeTimestamp = block.timestamp;
            _send(t.trader, t.margin);

        } else {
            revert InvalidState();
        }

        emit TradeEvent(tradeId);
    }

    // =========================================================
    // Keeper — Batch Execute
    // =========================================================

    /// @notice One TEE proof per entry. The proof carries the spread for that execution leg.
    ///
    ///         Trigger evaluation (limit/stop/SL/TP/LIQ) is performed against the RAW oracle
    ///         price — no spread involved. Spread is applied AFTER the trigger fires, purely
    ///         to compute the execution price stored in openPrice / closePrice.
    ///
    ///         For pure-close triggers (SL/TP/LIQ) pass maxOILong = maxOIShort =
    ///         type(uint256).max; the OI check will always pass. Spread fields must still
    ///         be valid and within MAX_SPREAD_ALLOWED.
    ///
    /// @dev     Le prix de chaque trade est lu en direct on-chain via getPriceExternal(assetId) (FTSOv2).
    ///          Si l'appel revert (prix stale, non listé, etc.), le trade concerné est ignoré (skip)
    ///          silencieusement via un try/catch pour ne pas bloquer l'ensemble du batch.
    function batchExecute(
        uint256[] calldata tradeIds,
        uint8[]   calldata reasons,
        TeeRiskProof[] calldata riskProofs
    ) external nonReentrant returns (
        uint256[] memory executedIds,
        uint256[] memory skippedIds
    ) {
        if (tradeIds.length != reasons.length)    revert BadParameter();
        if (tradeIds.length != riskProofs.length) revert BadParameter();

        uint256 len         = tradeIds.length;

        uint256[] memory execTmp = new uint256[](len);
        uint256[] memory skipTmp = new uint256[](len);
        uint256 execCount;
        uint256 skipCount;

        for (uint256 i = 0; i < len; i++) {
            uint256 assetId = riskProofs[i].assetId;
            uint256 oraclePrice;
            try this.getPriceExternal(assetId) returns (uint256 p) {
                oraclePrice = p;
            } catch {
                skipTmp[skipCount++] = tradeIds[i];
                continue;
            }

            bool ok = _executeTriggered(tradeIds[i], oraclePrice, reasons[i], riskProofs[i]);
            if (ok) { execTmp[execCount++] = tradeIds[i]; }
            else    { skipTmp[skipCount++] = tradeIds[i]; }
        }

        executedIds = _trim(execTmp, execCount);
        skippedIds  = _trim(skipTmp, skipCount);
    }

    // =========================================================
    // INTERNAL — Keeper trigger dispatch
    // =========================================================

    /// @dev All trigger conditions compare the raw oracle price against the stored raw
    ///      target/SL/TP/liqPrice.  No tolerance band is applied — the backend submits
    ///      the batch only once the condition is met on the raw price.
    ///      Spread is applied ONLY inside _executeOrder / _closeTrade for the execution price.
    function _executeTriggered(
        uint256 tradeId,
        uint256 oraclePrice,
        uint8   reason,
        TeeRiskProof calldata rp
    ) internal returns (bool) {
        Trade storage t = trades[tradeId];
        if (t.assetId != rp.assetId) return false;

        AssetConfig storage cfg = assets[rp.assetId];
        if (!cfg.listed) return false;

        // Validate TEE proof and hard spread cap for every execution path — no bypass.
        // Soft-fail so the keeper batch doesn't revert on a single bad proof.
        if (!_checkTeeProof(rp)) return false;
        if (rp.spreadLong  > MAX_SPREAD_ALLOWED)               return false;
        if (rp.spreadShort > MAX_SPREAD_ALLOWED)               return false;

        // ---- Activate a pending limit/stop order ----
        // Trigger: raw oracle price vs targetPrice with executionTolerance band.
        if (t.state == STATE_ORDER) {
            if (paused || cfg.frozen) return false; // Block activation of pending orders when paused or when asset is frozen!
            bool ok;
            uint256 tol = (t.targetPrice * cfg.executionTolerance) / PRECISION;
            if (t.orderType == ORDER_LIMIT) {
                // LONG  limit: fire when market is at/below targetPrice + tol (better price, or slightly worse up to tol)
                // SHORT limit: fire when market is at/above targetPrice - tol (better price, or slightly worse down to tol)
                ok = t.direction == DIR_LONG
                    ? oraclePrice <= t.targetPrice + tol
                    : oraclePrice + tol >= t.targetPrice;
            } else if (t.orderType == ORDER_STOP) {
                // LONG  stop: fire when market is at/above targetPrice - tol (worse price, or slightly better down to tol)
                // SHORT stop: fire when market is at/below targetPrice + tol (worse price, or slightly better up to tol)
                ok = t.direction == DIR_LONG
                    ? oraclePrice + tol >= t.targetPrice
                    : oraclePrice <= t.targetPrice + tol;
            }
            if (!ok) return false;
            return _executeOrder(tradeId, oraclePrice, rp);
        }

        // ---- Close an open position (SL / TP / LIQ) ----
        // Trigger: raw oracle price vs SL/TP/liqPrice with executionTolerance band.
        if (t.state == STATE_OPEN) {
            bool ok;
            if (reason == REASON_LIQ) {
                uint256 liqPrice = _liqPrice(t.openPrice, t.leverage, t.direction, cfg.liqThresholdBps);
                uint256 tol = (liqPrice * cfg.executionTolerance) / PRECISION;
                // LONG  liq: oracle has fallen to or below liqPrice + tol
                // SHORT liq: oracle has risen  to or above liqPrice - tol
                ok = t.direction == DIR_LONG
                    ? oraclePrice <= liqPrice + tol
                    : oraclePrice + tol >= liqPrice;
            } else if (reason == REASON_SL) {
                uint256 tol = (t.stopLoss * cfg.executionTolerance) / PRECISION;
                ok = t.stopLoss != 0 && (
                    t.direction == DIR_LONG
                        ? oraclePrice <= t.stopLoss + tol   // LONG  SL: oracle dropped to SL + tol
                        : oraclePrice + tol >= t.stopLoss   // SHORT SL: oracle rose to SL - tol
                );
            } else if (reason == REASON_TP) {
                uint256 tol = (t.takeProfit * cfg.executionTolerance) / PRECISION;
                ok = t.takeProfit != 0 && (
                    t.direction == DIR_LONG
                        ? oraclePrice + tol >= t.takeProfit  // LONG  TP: oracle rose to TP - tol
                        : oraclePrice <= t.takeProfit + tol  // SHORT TP: oracle dropped to TP + tol
                );
            }
            if (!ok) return false;
            _closeTrade(tradeId, oraclePrice, reason, rp);
            return true;
        }

        return false;
    }

    // =========================================================
    // INTERNAL — Execute a pending limit/stop order
    // =========================================================

    function _executeOrder(uint256 tradeId, uint256 oraclePrice, TeeRiskProof calldata rp)
        internal returns (bool)
    {
        Trade storage t    = trades[tradeId];
        AssetConfig storage cfg = assets[t.assetId];

        uint256 grossOI = t.margin * t.leverage;
        uint256 commission = (grossOI * cfg.commissionBps) / PRECISION;
        uint256 margin     = t.margin - commission;
        uint256 oi         = margin * t.leverage;

        // Entry spread applied AFTER the trigger condition has fired — purely for execution price.
        uint256 entryPrice = _applyEntrySpread(oraclePrice, t.direction, rp);

        uint256 newLong  = exposures[t.assetId].openInterestLong  + (t.direction == DIR_LONG  ? oi : 0);
        uint256 newShort = exposures[t.assetId].openInterestShort + (t.direction == DIR_SHORT ? oi : 0);

        // Soft-fail so keeper can skip without reverting the whole batch
        if (newLong  > rp.maxOILong)  return false;
        if (newShort > rp.maxOIShort) return false;
        if (newLong  > cfg.maxGlobalOI) return false;
        if (newShort > cfg.maxGlobalOI) return false;
        if (traderOpenInterest[t.assetId][t.trader] + oi > cfg.maxTraderOI) return false;

        // Check capital sufficiency before mutating state or sending commission
        uint256 vaultBalance = USDT.balanceOf(address(vault));
        int256 longDelta = t.direction == DIR_LONG ? int256(oi) : int256(0);
        int256 shortDelta = t.direction == DIR_SHORT ? int256(oi) : int256(0);
        uint256 newTotalLockedCapital = _getNewTotalLocked(t.assetId, longDelta, shortDelta);
        if (newTotalLockedCapital > vaultBalance) return false;

        uint256 requiredFree = vault.getRequiredFreeUSDC();
        if (vaultBalance - newTotalLockedCapital < requiredFree) return false;

        // Commission → distributed (30% owner, 70% vault)
        if (commission > 0) _distributeCommission(commission);

        // Update OI using our helper
        _updateExposure(t.assetId, longDelta, shortDelta, newTotalLockedCapital);
        traderOpenInterest[t.assetId][t.trader] += oi;

        if (t.direction == DIR_LONG) {
            uint256 oldOI = exposures[t.assetId].openInterestLong - oi;
            exposures[t.assetId].avgEntryPriceLong = (exposures[t.assetId].avgEntryPriceLong * oldOI + entryPrice * oi) / exposures[t.assetId].openInterestLong;
        } else {
            uint256 oldOI = exposures[t.assetId].openInterestShort - oi;
            exposures[t.assetId].avgEntryPriceShort = (exposures[t.assetId].avgEntryPriceShort * oldOI + entryPrice * oi) / exposures[t.assetId].openInterestShort;
        }

        t.margin        = margin;
        t.state         = STATE_OPEN;
        t.openPrice     = entryPrice;   // stored WITH spread
        t.openTimestamp = block.timestamp;

        // Overwrite invalid SL / TP to 0 to prevent immediate trigger / bad state
        uint256 liqP = _liqPrice(entryPrice, t.leverage, t.direction, cfg.liqThresholdBps);
        (bool slValid, bool tpValid) = _checkSLTP(t.direction, entryPrice, liqP, t.stopLoss, t.takeProfit);
        if (!slValid) {
            t.stopLoss = 0;
        }
        if (!tpValid) {
            t.takeProfit = 0;
        }

        emit TradeEvent(tradeId);

        return true;
    }

    // =========================================================
    // INTERNAL — Close trade (all reasons share this path)
    // =========================================================
    function _closeTrade(
        uint256 tradeId,
        uint256 oraclePrice,
        uint8   reason,
        TeeRiskProof calldata rp
    ) internal {
        Trade storage t = trades[tradeId];
        if (t.state != STATE_OPEN) revert InvalidState();

        AssetConfig storage cfg = assets[t.assetId];

        // 1. Calcul de la durée du trade
        uint256 duration = block.timestamp > t.openTimestamp ? block.timestamp - t.openTimestamp : 0;

        // 2. Récupération du spread de sortie brut et calcul du closePrice
        uint256 closePrice;
        uint256 oi = t.margin * t.leverage;

        uint256 spread = t.direction == DIR_LONG ? rp.spreadShort : rp.spreadLong;
        uint256 amount = (oraclePrice * spread) / PRECISION;
        if (t.direction == DIR_LONG) {
            closePrice = oraclePrice > amount ? oraclePrice - amount : 0;
        } else {
            closePrice = oraclePrice + amount;
        }

        // 3. Calcul du PnL brut (spread-adjusted close price)
        int256 rawPnl = _pnl(oi, t.openPrice, closePrice, t.direction);

        // 4. Calcul linéaire des frais de borrow sur l'Open Interest
        uint256 borrowFee = (oi * cfg.borrowRateHourly * duration) / (HOUR * PRECISION);

        // 5. PnL Net = PnL Brut - Frais de Borrow
        int256 netPnl = rawPnl - int256(borrowFee);

        // Cap profit at locked max
        uint256 maxProfit = (oi * cfg.profitCap) / PRECISION;
        if (netPnl > int256(maxProfit)) netPnl = int256(maxProfit);

        // Liquidation override: loss >= custom asset threshold of margin
        uint256 lossAmt = netPnl < 0 ? uint256(-netPnl) : 0;
        if (lossAmt >= (t.margin * cfg.liqThresholdBps) / PRECISION) {
            reason = REASON_LIQ;
        }

        t.state          = reason == REASON_LIQ ? STATE_LIQUIDATED : STATE_CLOSED;
        t.closePrice     = closePrice;   // WITH spread pour market/TP/LIQ/SL
        t.closeTimestamp = block.timestamp;

        _releaseExposure(tradeId);

        _settle(t, netPnl, reason);

        emit TradeEvent(tradeId);
    }

    // =========================================================
    // INTERNAL — Pull collateral + take commission
    // =========================================================

    /// @dev minTradeSize is checked against GROSS collateral (before commission deduction).
    function _pullFundsAndCommission(uint256 assetId, uint256 collateral, uint256 leverage)
        internal returns (uint256 margin, uint256 oi)
    {
        AssetConfig storage cfg = assets[assetId];

        // Gross minimum: the full amount the trader sends must be at least minTradeSize.
        // This guarantees that e.g. exactly 10 USDT always passes, even after commission.
        if (collateral < cfg.minTradeSize) revert BadMargin();
        if (leverage < cfg.minLeverage || leverage > cfg.maxLeverage || leverage > MAX_LEVERAGE_HARD_CAP) revert BadLeverage();

        uint256 grossOI = collateral * leverage;
        uint256 commission = (grossOI * cfg.commissionBps) / PRECISION;
        margin = collateral - commission;
        oi = margin * leverage;

        _pull(msg.sender, collateral);
        if (commission > 0) _distributeCommission(commission);
    }

    // =========================================================
    // INTERNAL — Verify TEE proof, update OI, lock delta (revert path)
    // =========================================================

    /// @dev Used on the user-facing market open path — reverts on any failure.
    function _applyRisk(
        uint256    assetId,
        uint8      direction,
        uint256    oi,
        TeeRiskProof calldata rp
    ) internal {
        AssetConfig storage cfg = assets[assetId];

        uint256 newLong  = exposures[assetId].openInterestLong  + (direction == DIR_LONG  ? oi : 0);
        uint256 newShort = exposures[assetId].openInterestShort + (direction == DIR_SHORT ? oi : 0);

        if (newLong  > rp.maxOILong)  revert OIExceeded();
        if (newShort > rp.maxOIShort) revert OIExceeded();

        if (newLong  > cfg.maxGlobalOI) revert GlobalOIExceeded();
        if (newShort > cfg.maxGlobalOI) revert GlobalOIExceeded();

        uint256 totalTraderOI = traderOpenInterest[assetId][msg.sender] + oi;
        if (totalTraderOI > cfg.maxTraderOI) revert TraderOIExceeded();

        // Enforce strict vault capital check at opening
        uint256 vaultBalance = USDT.balanceOf(address(vault));
        int256 longDelta = direction == DIR_LONG ? int256(oi) : int256(0);
        int256 shortDelta = direction == DIR_SHORT ? int256(oi) : int256(0);
        uint256 newTotalLockedCapital = _getNewTotalLocked(assetId, longDelta, shortDelta);
        if (newTotalLockedCapital > vaultBalance) revert InsufficientVaultCapital();

        uint256 requiredFree = vault.getRequiredFreeUSDC();
        if (vaultBalance - newTotalLockedCapital < requiredFree) revert InsufficientFreeLiquidityForWithdrawals();

        _updateExposure(assetId, longDelta, shortDelta, newTotalLockedCapital);

        traderOpenInterest[assetId][msg.sender] = totalTraderOI;
    }

    // =========================================================
    // INTERNAL — Release OI + unlock capital delta on close
    // =========================================================

    function _getNewTotalLocked(
        uint256 assetId,
        int256 longDelta,
        int256 shortDelta
    ) internal view returns (uint256) {
        AssetConfig storage cfg = assets[assetId];
        uint256 oldLong = exposures[assetId].openInterestLong;
        uint256 oldShort = exposures[assetId].openInterestShort;
        uint256 oldDominant = oldLong > oldShort ? oldLong : oldShort;
        uint256 oldLocked = (oldDominant * cfg.lockedCapitalBps) / PRECISION;

        uint256 newLong = longDelta >= 0
            ? oldLong + uint256(longDelta)
            : (oldLong > uint256(-longDelta) ? oldLong - uint256(-longDelta) : 0);

        uint256 newShort = shortDelta >= 0
            ? oldShort + uint256(shortDelta)
            : (oldShort > uint256(-shortDelta) ? oldShort - uint256(-shortDelta) : 0);

        uint256 newDominant = newLong > newShort ? newLong : newShort;
        uint256 newLocked = (newDominant * cfg.lockedCapitalBps) / PRECISION;

        uint256 baseLocked = totalLockedCapital > oldLocked ? totalLockedCapital - oldLocked : 0;
        return baseLocked + newLocked;
    }

    function _updateExposure(
        uint256 assetId,
        int256 longDelta,
        int256 shortDelta,
        uint256 newTotalLocked
    ) internal {
        AssetConfig memory cfg = assets[assetId];
        if (!cfg.listed) revert BadParameter();

        if (longDelta > 0) {
            exposures[assetId].openInterestLong += uint256(longDelta);
        } else if (longDelta < 0) {
            uint256 sub = uint256(-longDelta);
            exposures[assetId].openInterestLong = exposures[assetId].openInterestLong > sub ? exposures[assetId].openInterestLong - sub : 0;
        }

        if (shortDelta > 0) {
            exposures[assetId].openInterestShort += uint256(shortDelta);
        } else if (shortDelta < 0) {
            uint256 sub = uint256(-shortDelta);
            exposures[assetId].openInterestShort = exposures[assetId].openInterestShort > sub ? exposures[assetId].openInterestShort - sub : 0;
        }

        totalLockedCapital = newTotalLocked;
    }

    function _releaseExposure(uint256 tradeId) internal {
        Trade storage t = trades[tradeId];

        uint256 oi = t.margin * t.leverage;

        if (t.direction == DIR_LONG) {
            uint256 oldOI = exposures[t.assetId].openInterestLong;
            uint256 newOI = oldOI > oi ? oldOI - oi : 0;
            if (newOI == 0) {
                exposures[t.assetId].avgEntryPriceLong = 0;
            } else {
                exposures[t.assetId].avgEntryPriceLong = (exposures[t.assetId].avgEntryPriceLong * oldOI - t.openPrice * oi) / newOI;
            }
        } else {
            uint256 oldOI = exposures[t.assetId].openInterestShort;
            uint256 newOI = oldOI > oi ? oldOI - oi : 0;
            if (newOI == 0) {
                exposures[t.assetId].avgEntryPriceShort = 0;
            } else {
                exposures[t.assetId].avgEntryPriceShort = (exposures[t.assetId].avgEntryPriceShort * oldOI - t.openPrice * oi) / newOI;
            }
        }

        int256 longDelta = t.direction == DIR_LONG ? -int256(oi) : int256(0);
        int256 shortDelta = t.direction == DIR_SHORT ? -int256(oi) : int256(0);
        uint256 newTotalLockedCapital = _getNewTotalLocked(t.assetId, longDelta, shortDelta);

        _updateExposure(t.assetId, longDelta, shortDelta, newTotalLockedCapital);

        traderOpenInterest[t.assetId][t.trader] = traderOpenInterest[t.assetId][t.trader] > oi
            ? traderOpenInterest[t.assetId][t.trader] - oi : 0;
    }

    // =========================================================
    // INTERNAL — Settle funds after close
    // =========================================================

    function _settle(
        Trade storage t,
        int256  pnl,
        uint8   reason
    ) internal {
        // Liquidation: entire margin goes to Vault
        if (reason == REASON_LIQ) {
            if (t.margin > 0) _sendToVault(t.margin);
            return;
        }

        if (t.margin == 0) return;

        if (pnl >= 0) {
            // Refund initial margin to trader
            _send(t.trader, t.margin);
            uint256 profit = uint256(pnl);
            if (profit > 0) {
                uint256 available = USDT.balanceOf(address(vault));
                uint256 toPay     = available >= profit ? profit : available;
                if (toPay > 0) vault.payTrader(t.trader, toPay);
                if (toPay < profit) emit InsolvencyWarning(t.id, profit, toPay);
            }
        } else {
            uint256 loss = uint256(-pnl);
            if (loss >= t.margin) {
                _sendToVault(t.margin);
            } else {
                _sendToVault(loss);
                _send(t.trader, t.margin - loss);
            }
        }
    }

    // =========================================================
    // INTERNAL — Store trade
    // =========================================================

    function _storeTrade(TradeInit memory init) internal returns (uint256 tradeId) {
        tradeId = nextTradeId++;
        Trade storage t = trades[tradeId];

        t.id            = tradeId;
        t.trader        = msg.sender;
        t.assetId       = init.assetId;
        t.direction     = init.direction;
        t.orderType     = init.orderType;
        t.margin        = init.margin;
        t.leverage      = init.leverage;
        t.targetPrice   = init.targetPrice;
        t.openPrice     = init.openPrice;
        t.stopLoss      = init.slPrice;
        t.takeProfit    = init.tpPrice;
        t.openTimestamp = block.timestamp;
        t.state         = init.orderType == ORDER_MARKET ? STATE_OPEN : STATE_ORDER;
    }

    // =========================================================
    // HELPERS — Spread (TEE-controlled, constant hard cap)
    // =========================================================

    /// @dev Apply entry spread to the raw oracle price.
    function _applyEntrySpread(uint256 oraclePrice, uint8 direction, TeeRiskProof calldata rp)
        internal pure returns (uint256)
    {
        uint256 spread = direction == DIR_LONG ? rp.spreadLong : rp.spreadShort;
        uint256 amount = (oraclePrice * spread) / PRECISION;
        if (direction == DIR_LONG) return oraclePrice + amount;
        return oraclePrice > amount ? oraclePrice - amount : 0;
    }

    /// @dev Enforce the immutable MAX_SPREAD_ALLOWED on both spread fields.
    function _validateSpreadCap(uint256 spreadLong, uint256 spreadShort) internal pure {
        if (spreadLong  > MAX_SPREAD_ALLOWED) revert SpreadExceedsMaxAllowed();
        if (spreadShort > MAX_SPREAD_ALLOWED) revert SpreadExceedsMaxAllowed();
    }

    // =========================================================
    // HELPERS — Oracle price (FTSOv2 timestamps are in seconds, on-chain aggregated, no price data to verify)
    // =========================================================

    function _getPrice(uint256 assetId) internal returns (uint256) {
        AssetConfig storage cfg = assets[assetId];
        if (!cfg.listed) revert BadParameter();

        FtsoV2Interface ftsoV2 = ContractRegistry.getFtsoV2();
        (uint256 value, int8 dec, uint64 timestamp) = ftsoV2.getFeedById(cfg.feedId);

        if (timestamp > block.timestamp) {
            if (timestamp - block.timestamp > cfg.maxProofAge) revert StalePrice();
        } else {
            if (block.timestamp - timestamp > cfg.maxProofAge) revert StalePrice();
        }

        return _normalizePrice(value, uint256(int256(dec)));
    }

    function getPriceExternal(uint256 assetId) external returns (uint256) {
        return _getPrice(assetId);
    }

    function getUnrealizedPnL(uint256 assetId) public returns (int256) {
        AssetConfig storage cfg = assets[assetId];
        if (!cfg.listed) return 0;

        uint256 currentPrice = _getPrice(assetId);
        int256 totalPnL = 0;

        // Long PnL
        uint256 longOI = exposures[assetId].openInterestLong;
        uint256 avgLong = exposures[assetId].avgEntryPriceLong;
        if (longOI > 0 && avgLong > 0) {
            totalPnL += int256(longOI) * (int256(currentPrice) - int256(avgLong)) / int256(avgLong);
        }

        // Short PnL
        uint256 shortOI = exposures[assetId].openInterestShort;
        uint256 avgShort = exposures[assetId].avgEntryPriceShort;
        if (shortOI > 0 && avgShort > 0) {
            totalPnL += int256(shortOI) * (int256(avgShort) - int256(currentPrice)) / int256(avgShort);
        }

        return totalPnL;
    }

    function getTotalUnrealizedPnL() external returns (int256) {
        int256 totalPnL = 0;
        uint256 len = listedAssetIds.length;
        for (uint256 i = 0; i < len; i++) {
            totalPnL += getUnrealizedPnL(listedAssetIds[i]);
        }
        return totalPnL;
    }

    function _normalizePrice(uint256 price, uint256 decimals) internal pure returns (uint256) {
        if (decimals == 6) return price;
        if (decimals  > 6) return price / (10 ** (decimals - 6));
        return price * (10 ** (6 - decimals));
    }

    // =========================================================
    // HELPERS — Liquidation price
    // =========================================================

    function _liqPrice(uint256 openPrice, uint256 leverage, uint8 direction, uint256 liqThresholdBps)
        internal pure returns (uint256)
    {
        uint256 move = (openPrice * liqThresholdBps) / (leverage * PRECISION);
        if (direction == DIR_LONG) return openPrice > move ? openPrice - move : 0;
        return openPrice + move;
    }

    // =========================================================
    // HELPERS — PnL
    // =========================================================

    function _pnl(uint256 oi, uint256 openPrice, uint256 closePrice, uint8 direction)
        internal pure returns (int256)
    {
        if (openPrice == 0) return 0;
        if (direction == DIR_LONG) {
            if (closePrice >= openPrice) return  int256((oi * (closePrice - openPrice)) / openPrice);
            return -int256((oi * (openPrice - closePrice)) / openPrice);
        } else {
            if (closePrice <= openPrice) return  int256((oi * (openPrice - closePrice)) / openPrice);
            return -int256((oi * (closePrice - openPrice)) / openPrice);
        }
    }

    // =========================================================
    // HELPERS — Flare Confidential Compute (FCC) TEE Proof Verification
    // =========================================================

    function _verifyTeeProof(TeeRiskProof calldata rp) internal view {
        AssetConfig storage cfg = assets[rp.assetId];
        if (!cfg.listed) revert BadParameter();

        if (rp.timestamp > block.timestamp) {
            if (rp.timestamp - block.timestamp > 15)           revert InvalidTeeProof();
        } else {
            if (block.timestamp - rp.timestamp > cfg.maxProofAge) revert TeeProofExpired();
        }

        bytes32 hash    = keccak256(abi.encode(
            rp.assetId, rp.maxOILong, rp.maxOIShort, rp.spreadLong, rp.spreadShort, rp.timestamp
        ));
        bytes32 ethHash = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", hash));

        (bytes32 r, bytes32 s, uint8 v) = _splitSig(rp.sig);
        address recovered = ecrecover(ethHash, v, r, s);

        // Verify cryptographic signature strictly against authorized TEE Enclave Signer key
        if (recovered == address(0) || recovered != teeEnclaveSigner) revert InvalidTeeProof();
    }

    function _checkTeeProof(TeeRiskProof calldata rp) internal view returns (bool) {
        AssetConfig storage cfg = assets[rp.assetId];
        if (!cfg.listed) return false;

        if (rp.timestamp > block.timestamp) {
            if (rp.timestamp - block.timestamp > 15)           return false;
        } else {
            if (block.timestamp - rp.timestamp > cfg.maxProofAge) return false;
        }

        bytes32 hash    = keccak256(abi.encode(
            rp.assetId, rp.maxOILong, rp.maxOIShort, rp.spreadLong, rp.spreadShort, rp.timestamp
        ));
        bytes32 ethHash = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", hash));

        if (rp.sig.length != 65) return false;
        (bytes32 r, bytes32 s, uint8 v) = _splitSig(rp.sig);
        address recovered = ecrecover(ethHash, v, r, s);

        return recovered != address(0) && recovered == teeEnclaveSigner;
    }

    function _splitSig(bytes calldata sig) internal pure returns (bytes32 r, bytes32 s, uint8 v) {
        if (sig.length != 65) revert InvalidTeeProof();
        assembly {
            r := calldataload(sig.offset)
            s := calldataload(add(sig.offset, 32))
            v := byte(0, calldataload(add(sig.offset, 64)))
        }
    }

    // =========================================================
    // HELPERS — SL/TP validation
    // =========================================================

    function _checkSLTP(
        uint8   direction,
        uint256 entryPrice,
        uint256 liqP,
        uint256 slPrice,
        uint256 tpPrice
    ) internal pure returns (bool slValid, bool tpValid) {
        slValid = true;
        tpValid = true;
        if (direction == DIR_LONG) {
            if (slPrice != 0) {
                if (slPrice >= entryPrice || slPrice < liqP) slValid = false;
            }
            if (tpPrice != 0 && tpPrice <= entryPrice) tpValid = false;
        } else {
            if (slPrice != 0) {
                if (slPrice <= entryPrice || slPrice > liqP) slValid = false;
            }
            if (tpPrice != 0 && tpPrice >= entryPrice) tpValid = false;
        }
    }

    function _validateSLTP(
        uint8   direction,
        uint256 entryPrice,
        uint256 liqP,
        uint256 slPrice,
        uint256 tpPrice
    ) internal pure {
        (bool slValid, bool tpValid) = _checkSLTP(direction, entryPrice, liqP, slPrice, tpPrice);
        if (!slValid || !tpValid) revert BadSLTP();
    }

    // =========================================================
    // HELPERS — Config validation
    // =========================================================

    function _validateConfig(AssetConfig memory cfg) internal pure {
        if (cfg.feedId == bytes21(0)) revert BadParameter();
        if (cfg.minLeverage == 0 || cfg.maxLeverage < cfg.minLeverage) revert BadParameter();
        if (cfg.maxLeverage > MAX_LEVERAGE_HARD_CAP) revert BadParameter();
        if (cfg.minTradeSize      == 0)          revert BadParameter();
        if (cfg.commissionBps      > MAX_COMMISSION_ALLOWED) revert BadParameter(); // max 1%
        if (cfg.profitCap == 0 || cfg.profitCap > PRECISION) revert BadParameter();
        if (cfg.executionTolerance == 0 || cfg.executionTolerance > 10_000) revert BadParameter(); // max 1%, non-zero
        if (cfg.maxProofAge == 0 || cfg.maxProofAge > 3600) revert BadParameter(); // FTSO updates can be slower on testnets
        if (cfg.borrowRateHourly  > 100_000)    revert BadParameter(); // max 10%/hour
        if (cfg.maxTraderOI == 0)                revert BadParameter();
        if (cfg.maxGlobalOI == 0)                revert BadParameter();
        if (cfg.lockedCapitalBps  > 100_000)    revert BadParameter();
        if (cfg.liqThresholdBps < 900_000 || cfg.liqThresholdBps > 980_000) revert BadParameter();
    }

    // =========================================================
    // HELPERS — Safe transfers
    // =========================================================

    function _pull(address from, uint256 amount) internal {
        if (amount == 0) return;
        if (!USDT.transferFrom(from, address(this), amount)) revert TransferFailed();
    }

    function _send(address to, uint256 amount) internal {
        if (amount == 0) return;
        if (!USDT.transfer(to, amount)) revert TransferFailed();
    }

    function _sendToVault(uint256 amount) internal {
        if (amount == 0) return;
        if (!USDT.transfer(address(vault), amount)) revert TransferFailed();
    }

    function _distributeCommission(uint256 commission) internal {
        if (commission == 0) return;
        uint256 ownerShare = (commission * 300_000) / PRECISION; // 30%
        uint256 vaultShare = commission - ownerShare;
        if (ownerShare > 0) _send(owner, ownerShare);
        if (vaultShare > 0) _sendToVault(vaultShare);
    }

    // =========================================================
    // HELPERS — Array trim
    // =========================================================

    function _trim(uint256[] memory arr, uint256 len) internal pure returns (uint256[] memory out) {
        out = new uint256[](len);
        for (uint256 i = 0; i < len; i++) out[i] = arr[i];
    }

    // =========================================================
    // Views
    // =========================================================

    function getTrade(uint256 tradeId) external view returns (Trade memory) {
        return trades[tradeId];
    }
}
