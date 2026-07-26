// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

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
    function getRequiredFreeUSDC() external view returns (uint256);
}

/// @title BrokexCore V4 - Perpetual Trading & Risk Engine
/// @notice Core protocol engine responsible for trade execution, position management, asset exposure,
///         and protocol risk management.
/// @dev CORE ARCHITECTURE, UNITS & LIQUIDITY PRINCIPLES:
///
///      =================================================================================
///      1. UNITS & NUMERICAL SCALINGS (1e6 PRECISION):
///      =================================================================================
///         - Base Precision (`PRECISION`): 1,000,000 = 100.0000% = 1.0
///         - Percentage & Basis Point Conversions:
///             * 100%       = 1,000,000
///             * 10%        = 100,000   (e.g., profitCap = 100,000 for 10% max profit)
///             * 5%         = 50,000    (e.g., lockedCapitalBps = 50,000 for 5% locked capital)
///             * 1%         = 10,000    (e.g., MAX_COMMISSION_ALLOWED = 10,000)
///             * 0.10%      = 1,000     (e.g., 10 bps spread = 1,000)
///             * 0.01%      = 100       (1 bps = 100)
///         - Monetary Amounts (USDC / Margin / OI / Borrow Fee / PnL): 6 decimals (1,000,000 = 1.000000 USDC)
///         - Asset Spot Prices (KMS Signed Prices): 6 decimals (2,350,500,000 = $2350.500000 USD)
///
///      =================================================================================
///      2. OI-WEIGHTED AVERAGE ENTRY PRICE & PRO-RATA LOGIC:
///      =================================================================================
///         - `avgEntryPriceLong` and `avgEntryPriceShort` track the OI-weighted average entry price per asset per side.
///         - On Trade Open (Pro-Rata Formula):
///             newAvg = ((oldOI * oldAvg) + (tradeOI * tradeEntryPrice)) / (oldOI + tradeOI)
///         - On Trade Close: Position size is subtracted from side OI. The average price remains unchanged.
///         - Zero-OI Safety Reset: When a side's OI reaches 0, `avgEntryPrice` is hard-reset to 0 to eliminate price drift.
///
///      =================================================================================
///      3. KMS BATCH PROOF SEQUENTIAL VERIFICATION (ANTI-FRAUD):
///      =================================================================================
///         - `verifyAndComputeUnrealizedPnL(BatchRiskProof)` enforces that `proof.prices` contains EXACTLY
///           one price entry for every asset in `listedAssetIds`, in the EXACT SAME INDEX ORDER.
///         - Condition: `proof.prices[i].assetId == listedAssetIds[i]`.
///         - Reverts on any missing asset, duplicated asset, out-of-order asset, or price == 0.
///
///      =================================================================================
///      4. ROLE SEPARATION & SOLVENCY (`getFreeCapital()`):
///      =================================================================================
///         - Active trader collateral stays in BrokexCore; BrokexVault holds LP capital & net settlements.
///         - Dominant OI: dominantOI = max(openInterestLong, openInterestShort).
///         - Locked Capital: (dominantOI * lockedCapitalBps) / 1e6 (5% of dominant OI).
///         - Free Capital = Vault USDC Balance - totalLockedCapital - Pending LP Withdrawal Queue.
///         - Trades increasing dominant OI check Free Capital; non-dominant trades (e.g. SHORT when LONGs dominate)
///           do not increase locked capital and bring in commissions, pushing the pool toward delta-neutrality.
///
///      =================================================================================
///      5. PROFIT CAP & POSITIVE LIQUIDATION (AUTO TAKE-PROFIT):
///      =================================================================================
///         - Trader max profit is capped at `profitCap` (100,000 / 1e6 = 10% of OI).
///         - Keepers execute batch triggers (`REASON_PROFIT_CAP = 6`) when trade gain reaches `profitCap`,
///           closing the position under `STATE_LIQ_POS = 6`. Loss is bounded by initial margin (`t.margin`).
///
///      =================================================================================
///      6. SPREAD FORMULAS (ENTRY & EXIT SPREADS):
///      =================================================================================
///         - Entry Spread:
///             * LONG Entry:  entryPrice = oraclePrice + (oraclePrice * spreadLong) / 1e6 (buys at ask)
///             * SHORT Entry: entryPrice = oraclePrice - (oraclePrice * spreadShort) / 1e6 (sells at bid)
///         - Exit Spread:
///             * LONG Exit:  exitPrice = oraclePrice - (oraclePrice * spreadShort) / 1e6 (sells at bid)
///             * SHORT Exit: exitPrice = oraclePrice + (oraclePrice * spreadLong) / 1e6 (buys back at ask)
///
///      =================================================================================
///      7. BORROW FEE FORMULA:
///      =================================================================================
///         - Hourly rate per asset: `cfg.borrowRateHourly` (1e6 precision).
///         - Hours Elapsed: hoursElapsed = max(1, (block.timestamp - openTimestamp) / 3600).
///         - Borrow Fee: borrowFee = (margin * leverage * borrowRateHourly * hoursElapsed) / 1e6.
///         - Borrow fee is deducted from gross PnL upon position closure.
///
///      =================================================================================
///      8. PNL & LIQUIDATION TYPES:
///      =================================================================================
///         - Gross PnL Formula:
///             * LONG:  grossPnl = (oi * (closePrice - openPrice)) / openPrice
///             * SHORT: grossPnl = (oi * (openPrice - closePrice)) / openPrice
///         - Net Realized PnL = grossPnl - borrowFee.
///         - Standard Liquidation (`REASON_LIQ = 3`, `STATE_LIQUIDATED = 4`):
///             * Triggered when lossAmt >= (margin * liqThresholdBps) / 1e6 (e.g. 90% loss).
///             * Entire margin transferred to Vault.
///         - Positive Liquidation (`REASON_PROFIT_CAP = 6`, `STATE_LIQ_POS = 6`):
///             * Triggered when grossPnl >= (oi * profitCap) / 1e6.
///             * Trader profit capped at maxProfit; margin + maxProfit returned to trader.
///
///      =================================================================================
///      9. TRADING COMMISSION FORMULA & FUND FLOW:
///      =================================================================================
///         - Asset Commission Bps: `cfg.commissionBps` (capped at MAX_COMMISSION_ALLOWED = 10,000 / 1.0%).
///         - Gross Position OI: grossOI = collateral * leverage.
///         - Open Commission: commission = (grossOI * commissionBps) / 1e6.
///         - Net Position Margin: margin = collateral - commission.
///         - Net Position OI: oi = margin * leverage.
///         - Fund Flow: Full collateral is pulled from trader. Commission is immediately transferred to Vault,
///           enriching LP pool balance, while net margin is retained in Core as active trading collateral.
contract BrokexCore {

    uint256 public constant PRECISION          = 1e6;
    uint256 public constant HOUR               = 1 hours;



    // =========================================================================================
    // GARDE-FOUS ET SÉCURITÉ ADMINISTRATEUR (OWNER IMMUTABILITY & HARD CAPS)
    // =========================================================================================
    // 1. LIAISON CORE <-> VAULT IMMUTABLE :
    //    L'adresse `vault` est `immutable` et fixée à l'initialisation dans le constructeur.
    //    Aucun setter n'existe : il est IMPOSSIBLE pour l'Owner de modifier le Vault lié après déploiement.
    //
    // 2. PLAFONDS DE SÉCURITÉ INFRACTURABLES (HARD CAPS) :
    //    - Levier maximum : Capped à 100x (MAX_LEVERAGE_HARD_CAP = 100).
    //    - Spread maximum : Capped à 0.1% (MAX_SPREAD_ALLOWED = 1_000).
    //    - Commissions : Capped à 1.0% (MAX_COMMISSION_ALLOWED = 10_000).
    //    - Frais d'emprunt : Capped à 0.1%/heure max (1_000).
    //
    // 3. IMMUTABILITÉ DES PARAMÈTRES DE RISQUE PAR ACTIF (updateAsset) :
    //    Une fois un actif listé via listAsset(), l'Owner NE PEUT PLUS modifier :
    //    - profitCap (Cap de profit du trader)
    //    - borrowRateHourly (Taux d'emprunt)
    //    - lockedCapitalBps (Capital verrouillé)
    //    - liqThresholdBps (Seuil de liquidation - fixé strictement entre 90% et 98%)
    // =========================================================================================

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

    // Hard cap on hourly borrow rate set by owner.
    // 1_000 = 0.1% / hour (PRECISION-scaled).
    uint256 public constant MAX_BORROW_RATE_ALLOWED = 1_000;

    // Trade states
    uint8 public constant STATE_ORDER      = 0;
    uint8 public constant STATE_OPEN       = 1;
    uint8 public constant STATE_CLOSED     = 2;
    uint8 public constant STATE_CANCELLED  = 3;
    uint8 public constant STATE_LIQUIDATED = 4;
    uint8 public constant STATE_EMERGENCY  = 5;
    uint8 public constant STATE_LIQ_POS    = 6;

    // Directions
    uint8 public constant DIR_LONG  = 1;
    uint8 public constant DIR_SHORT = 0;

    // Order types
    uint8 public constant ORDER_MARKET = 0;
    uint8 public constant ORDER_LIMIT  = 1;
    uint8 public constant ORDER_STOP   = 2;

    // Close reasons
    uint8 public constant REASON_MARKET     = 0;
    uint8 public constant REASON_SL         = 1;
    uint8 public constant REASON_TP         = 2;
    uint8 public constant REASON_LIQ        = 3;
    uint8 public constant REASON_EMERGENCY  = 4;
    uint8 public constant REASON_CANCEL     = 5;
    uint8 public constant REASON_PROFIT_CAP = 6;

    // =========================================================
    // Structs
    // =========================================================

    struct AssetConfig {
        uint256 minLeverage;        // e.g. 2 = 2x (Unscaled plain integer)
        uint256 maxLeverage;        // e.g. 100 = 100x (Unscaled plain integer)
        // Minimum GROSS collateral the trader must send (margin + commission combined).
        uint256 minTradeSize;
        uint256 commissionBps;      // e.g. 1_000 = 0.1% (PRECISION-scaled)
        // Borrow: fee = OI * borrowRateHourly * elapsedSeconds / HOUR / PRECISION
        uint256 borrowRateHourly;
        uint256 profitCap;          // e.g. 100_000 = 10% of OI (PRECISION-scaled)
        uint256 executionTolerance; // e.g. 500 = 0.05% keeper price band (PRECISION-scaled)
        uint256 maxProofAge;        // seconds — max age for KMS proof
        uint256 maxTraderOI;        // Maximum allowed open interest per single trader (USDC-scaled, 6 decimals)
        uint256 maxGlobalOI;        // Maximum allowed global open interest (Long/Short independently, USDC-scaled)
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

        uint256 targetPrice;   // limit/stop trigger price (0 for market); raw KMS price, no spread
        uint256 openPrice;     // actual entry price WITH spread applied
        uint256 closePrice;    // actual exit price WITH spread applied

        uint256 stopLoss;      // raw KMS price at which SL triggers (no spread)
        uint256 takeProfit;    // raw KMS price at which TP triggers (no spread)

        uint256 openTimestamp;  // block.timestamp at activation
        uint256 closeTimestamp;

        uint256 borrowFee;      // borrow fee deducted at close (USDC 1e6)
    }

    struct RiskProof {
        uint256 assetId;
        uint256 price;         // KMS-signed price for this asset (PRECISION-scaled, 1e6)
        uint256 maxOILong;     // max allowed global long OI after this trade opens
        uint256 maxOIShort;    // max allowed global short OI after this trade opens
        uint256 spreadLong;    // spread when trader BUYS  (≤ MAX_SPREAD_ALLOWED)
        uint256 spreadShort;   // spread when trader SELLS (≤ MAX_SPREAD_ALLOWED)
        uint256 timestamp;     // unix timestamp — proof signed at this time
        bytes   sig;           // ECDSA over keccak256(abi.encode(assetId,price,maxOILong,maxOIShort,spreadLong,spreadShort,timestamp))
    }

    // Price entry inside a batch proof (used only for the vault-wide unrealized PnL read).
    struct AssetPriceData {
        uint256 assetId;
        uint256 price;         // PRECISION-scaled, 1e6
    }

    // Single ECDSA signature proof containing prices for ALL listed assets.
    struct BatchRiskProof {
        uint256 timestamp;
        AssetPriceData[] prices;
        bytes sig;              // ECDSA over keccak256(abi.encode(timestamp, prices))
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

    IERC20       public immutable USDC;
    IBrokexVault public immutable vault;

    address public kmsSigner;  // AWS KMS public address — settable by owner

    mapping(uint256 => AssetConfig) public assets;
    uint256[] public listedAssetIds;

    bool public paused;
    bool public emergencyMode;

    mapping(uint256 => uint256) public openInterestLong;
    mapping(uint256 => uint256) public openInterestShort;

    // OI-weighted average entry price per asset per side. Reset to 0 when that
    // side's OI returns to zero. Used by verifyAndComputeUnrealizedPnL.
    mapping(uint256 => uint256) public avgEntryPriceLong;
    mapping(uint256 => uint256) public avgEntryPriceShort;

    uint256 public totalLockedCapital;

    // Cumulative OI per trader (long + short combined)
    mapping(uint256 => mapping(address => uint256)) public traderOpenInterest;
    mapping(uint256 => Trade)     public trades;

    uint256 public nextTradeId = 1;

    // =========================================================
    // Events & Errors
    // =========================================================

    event TradeEvent(uint256 indexed tradeId);
    event OwnershipTransferStarted(address indexed old, address indexed pending);
    event OwnershipTransferred(address indexed old, address indexed next);
    event ConfigUpdated();
    event KmsSignerUpdated(address indexed signer);
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
    error PriceZero();
    error IncompleteBatchProof();
    error InvalidKmsProof();
    error KmsProofExpired();
    error SpreadExceedsMaxAllowed();
    error TransferFailed();

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
        address usdc,
        address vaultAddress,
        address kmsSignerAddress
    ) {
        if (usdc             == address(0)) revert ZeroAddress();
        if (vaultAddress     == address(0)) revert ZeroAddress();
        if (kmsSignerAddress == address(0)) revert ZeroAddress();

        owner     = msg.sender;
        USDC      = IERC20(usdc);
        vault     = IBrokexVault(vaultAddress);
        kmsSigner = kmsSignerAddress;

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

    /// @dev Note: delisting does not remove the asset from listedAssetIds (append-only
    ///      registry). A delisted asset has zero OI (enforced below) so it always
    ///      contributes exactly 0 to verifyAndComputeUnrealizedPnL — the KMS batch
    ///      proof still needs to include a price entry for it, but the value is inert.
    function delistAsset(uint256 assetId) external onlyOwner {
        if (!assets[assetId].listed) revert BadParameter();
        if (openInterestLong[assetId] != 0 || openInterestShort[assetId] != 0) revert BadParameter();
        assets[assetId].listed = false;
        emit AssetDelisted(assetId);
    }

    function setKmsSigner(address signer) external onlyOwner {
        if (signer == address(0)) revert ZeroAddress();
        kmsSigner = signer;
        emit KmsSignerUpdated(signer);
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
        RiskProof calldata riskProof
    ) external nonReentrant notPaused returns (uint256 tradeId) {
        AssetConfig storage cfg = assets[assetId];
        if (!cfg.listed) revert BadParameter();
        if (cfg.frozen) revert BadParameter();
        if (riskProof.assetId != assetId) revert BadParameter();

        if (direction != DIR_LONG && direction != DIR_SHORT) revert BadDirection();

        _verifyKmsProof(riskProof);
        _validateSpreadCap(riskProof.spreadLong, riskProof.spreadShort);

        (uint256 margin, uint256 oi) = _pullFundsAndCommission(assetId, collateral, leverage);

        // Entry spread applied to the raw KMS price → stored as openPrice.
        // Spread does NOT affect SL/TP/liq trigger thresholds — those remain raw-price-based.
        uint256 entryPrice = _applyEntrySpread(riskProof.price, direction, riskProof);

        // liqPrice is anchored to openPrice (spread-adjusted) so PnL math is consistent,
        // but the trigger comparison in _executeTriggered uses the raw KMS price vs liqPrice.
        // This means liqPrice already accounts for the entry spread premium paid by the trader.
        uint256 liqP = _liqPrice(entryPrice, leverage, direction, cfg.liqThresholdBps);

        // SL/TP are validated against the spread-adjusted entry price so the relationship
        // (SL below entry for longs, etc.) is always meaningful.
        if (slPrice != 0 || tpPrice != 0) _validateSLTP(direction, entryPrice, liqP, slPrice, tpPrice);

        _applyRisk(assetId, direction, oi, entryPrice, riskProof);

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
    ///         at execution time using the KMS proof supplied in batchExecute.
    ///         targetPrice is a raw KMS price; the trigger comparison is also raw.
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

    /// @notice SL and TP are stored as raw KMS prices (no spread).
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

        t.stopLoss   = newSL;
        t.takeProfit = newTP;
        emit TradeEvent(tradeId);
    }

    // =========================================================
    // User — Close Market
    // =========================================================

    /// @notice Allowed even when paused so traders can always exit.
    ///         The KMS proof supplies both the price and the spread for the exit leg.
    function closePositionMarket(
        uint256 assetId,
        uint256 tradeId,
        RiskProof calldata riskProof
    ) external nonReentrant {
        Trade storage t = trades[tradeId];
        if (t.trader != msg.sender) revert NotTrader();
        if (t.state  != STATE_OPEN) revert InvalidState();
        if (t.assetId != assetId) revert BadParameter();
        if (riskProof.assetId != assetId) revert BadParameter();

        AssetConfig storage cfg = assets[assetId];
        if (!cfg.listed) revert BadParameter();

        _verifyKmsProof(riskProof);
        _validateSpreadCap(riskProof.spreadLong, riskProof.spreadShort);

        _closeTrade(tradeId, riskProof.price, REASON_MARKET, riskProof);
    }

    // =========================================================
    // User — Emergency Close
    // =========================================================

    /// @notice In emergency mode, positions are unwound at net margin (no PnL, no price feed, no spread).
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

    /// @notice Keeper Batch Execution — Non-Atomic Batch Trigger Execution.
    /// @dev NON-ATOMIC EXECUTION PATTERN (SOFT-FAIL DESIGN):
    ///      - This function processes a batch of trade execution requests (Limit, Stop, SL, TP, LIQ, PROFIT_CAP).
    ///      - Unlike strict atomic functions, a failure or unfulfilled condition on a single trade does NOT
    ///        revert the entire batch transaction.
    ///      - Example: If a Keeper passes 10 trade IDs, and only 6 meet execution conditions (e.g., target price hit),
    ///        those 6 trades will be executed and settled on-chain. The 4 non-executable trades are softly skipped
    ///        and returned in `skippedIds`.
    ///      - Returns two arrays: `executedIds` (successfully executed trades) and `skippedIds` (skipped trades).
    ///
    /// @param tradeIds Array of trade IDs to attempt execution for.
    /// @param reasons Array of execution trigger reasons (REASON_MARKET=0, REASON_SL=1, REASON_TP=2, REASON_LIQ=3, REASON_PROFIT_CAP=6).
    /// @param riskProofs Array of verified KMS RiskProof structs corresponding to each trade.
    /// @return executedIds Array of trade IDs that were successfully executed in this call.
    /// @return skippedIds Array of trade IDs that were skipped due to unfulfilled conditions or invalid proofs.
    function batchExecute(
        uint256[] calldata tradeIds,
        uint8[]   calldata reasons,
        RiskProof[] calldata riskProofs
    ) external nonReentrant returns (
        uint256[] memory executedIds,
        uint256[] memory skippedIds
    ) {
        if (tradeIds.length != reasons.length)    revert BadParameter();
        if (tradeIds.length != riskProofs.length) revert BadParameter();

        uint256 len = tradeIds.length;

        uint256[] memory execTmp = new uint256[](len);
        uint256[] memory skipTmp = new uint256[](len);
        uint256 execCount;
        uint256 skipCount;

        for (uint256 i = 0; i < len; i++) {
            bool ok = _executeTriggered(tradeIds[i], riskProofs[i].price, reasons[i], riskProofs[i]);
            if (ok) { execTmp[execCount++] = tradeIds[i]; }
            else    { skipTmp[skipCount++] = tradeIds[i]; }
        }

        executedIds = _trim(execTmp, execCount);
        skippedIds  = _trim(skipTmp, skipCount);
    }

    // =========================================================
    // INTERNAL — Keeper trigger dispatch
    // =========================================================

    /// @dev All trigger conditions compare the raw KMS price against the stored raw
    ///      target/SL/TP/liqPrice. No tolerance band beyond executionTolerance — the
    ///      backend submits the batch only once the condition is met on the raw price.
    ///      Spread is applied ONLY inside _executeOrder / _closeTrade for the execution price.
    function _executeTriggered(
        uint256 tradeId,
        uint256 oraclePrice,
        uint8   reason,
        RiskProof calldata rp
    ) internal returns (bool) {
        Trade storage t = trades[tradeId];
        if (t.assetId != rp.assetId) return false;

        AssetConfig storage cfg = assets[rp.assetId];
        if (!cfg.listed) return false;

        // Validate KMS proof and hard spread cap for every execution path — no bypass.
        // Soft-fail so the keeper batch doesn't revert on a single bad proof.
        if (!_checkKmsProof(rp)) return false;
        if (rp.spreadLong  > MAX_SPREAD_ALLOWED)               return false;
        if (rp.spreadShort > MAX_SPREAD_ALLOWED)               return false;

        // ---- Activate a pending limit/stop order ----
        // Trigger: raw KMS price vs targetPrice with executionTolerance band.
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
        // Trigger: raw KMS price vs SL/TP/liqPrice with executionTolerance band.
        if (t.state == STATE_OPEN) {
            bool ok;
            if (reason == REASON_LIQ) {
                uint256 liqPrice = _liqPrice(t.openPrice, t.leverage, t.direction, cfg.liqThresholdBps);
                uint256 tol = (liqPrice * cfg.executionTolerance) / PRECISION;
                // LONG  liq: KMS price has fallen to or below liqPrice + tol
                // SHORT liq: KMS price has risen  to or above liqPrice - tol
                ok = t.direction == DIR_LONG
                    ? oraclePrice <= liqPrice + tol
                    : oraclePrice + tol >= liqPrice;
            } else if (reason == REASON_SL) {
                uint256 tol = (t.stopLoss * cfg.executionTolerance) / PRECISION;
                ok = t.stopLoss != 0 && (
                    t.direction == DIR_LONG
                        ? oraclePrice <= t.stopLoss + tol   // LONG  SL: price dropped to SL + tol
                        : oraclePrice + tol >= t.stopLoss   // SHORT SL: price rose to SL - tol
                );
            } else if (reason == REASON_TP) {
                uint256 tol = (t.takeProfit * cfg.executionTolerance) / PRECISION;
                ok = t.takeProfit != 0 && (
                    t.direction == DIR_LONG
                        ? oraclePrice + tol >= t.takeProfit  // LONG  TP: price rose to TP - tol
                        : oraclePrice <= t.takeProfit + tol  // SHORT TP: price dropped to TP + tol
                );
            } else if (reason == REASON_PROFIT_CAP) {
                uint256 exitPrice = t.direction == DIR_LONG
                    ? (oraclePrice * (PRECISION - rp.spreadShort)) / PRECISION
                    : (oraclePrice * (PRECISION + rp.spreadLong)) / PRECISION;
                uint256 oi = t.margin * t.leverage;
                uint256 grossPnl = 0;
                if (t.direction == DIR_LONG && exitPrice > t.openPrice) {
                    grossPnl = (oi * (exitPrice - t.openPrice)) / t.openPrice;
                } else if (t.direction == DIR_SHORT && t.openPrice > exitPrice) {
                    grossPnl = (oi * (t.openPrice - exitPrice)) / t.openPrice;
                }
                uint256 maxProfit = (oi * cfg.profitCap) / PRECISION;
                uint256 tol = (maxProfit * cfg.executionTolerance) / PRECISION;
                ok = grossPnl + tol >= maxProfit;
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

    function _executeOrder(uint256 tradeId, uint256 oraclePrice, RiskProof calldata rp)
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

        uint256 newLong  = openInterestLong[t.assetId]  + (t.direction == DIR_LONG  ? oi : 0);
        uint256 newShort = openInterestShort[t.assetId] + (t.direction == DIR_SHORT ? oi : 0);

        // Soft-fail so keeper can skip without reverting the whole batch
        if (newLong  > rp.maxOILong)  return false;
        if (newShort > rp.maxOIShort) return false;
        if (newLong  > cfg.maxGlobalOI) return false;
        if (newShort > cfg.maxGlobalOI) return false;
        if (traderOpenInterest[t.assetId][t.trader] + oi > cfg.maxTraderOI) return false;

        // Check capital sufficiency before mutating state or sending commission
        int256 longDelta = t.direction == DIR_LONG ? int256(oi) : int256(0);
        int256 shortDelta = t.direction == DIR_SHORT ? int256(oi) : int256(0);
        uint256 newTotalLockedCapital = _getNewTotalLocked(t.assetId, longDelta, shortDelta);

        uint256 deltaLocked = newTotalLockedCapital > totalLockedCapital 
            ? newTotalLockedCapital - totalLockedCapital 
            : 0;

        if (deltaLocked > getFreeCapital()) return false;

        // Commission → vault
        if (commission > 0) _sendToVault(commission);

        // Record avg entry price BEFORE mutating OI, then update OI/locked capital.
        _recordEntryPrice(t.assetId, t.direction, oi, entryPrice);
        _updateExposure(t.assetId, longDelta, shortDelta, newTotalLockedCapital);
        traderOpenInterest[t.assetId][t.trader] += oi;

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
    /// @notice Unifies position closure logic for all triggers (Market, SL, TP, LIQ, PROFIT_CAP).
    /// @dev CALCULATION STEPS & FORMULAS:
    ///      1. Duration = block.timestamp - t.openTimestamp
    ///      2. Exit Spread & Close Price:
    ///            - LONG Exit:  closePrice = oraclePrice - (oraclePrice * spreadShort) / 1e6 (sells at bid)
    ///            - SHORT Exit: closePrice = oraclePrice + (oraclePrice * spreadLong) / 1e6 (buys back at ask)
    ///      3. Gross PnL: _pnl(oi, t.openPrice, closePrice, t.direction)
    ///      4. Linear Borrow Fee: borrowFee = (oi * borrowRateHourly * duration) / (1 hours * 1e6)
    ///      5. Net PnL: netPnl = grossPnl - borrowFee
    ///      6. Max Profit Cap: if netPnl > (oi * profitCap) / 1e6, netPnl = maxProfit (e.g. 10% max profit)
    ///      7. Standard Liquidation Check: if netPnl loss >= (margin * liqThresholdBps) / 1e6, state = STATE_LIQUIDATED (4)
    ///      8. Positive Liquidation / Auto Take-Profit: if reason == REASON_PROFIT_CAP (6), state = STATE_LIQ_POS (6)
    function _closeTrade(
        uint256 tradeId,
        uint256 oraclePrice,
        uint8   reason,
        RiskProof calldata rp
    ) internal {
        Trade storage t = trades[tradeId];
        if (t.state != STATE_OPEN) revert InvalidState();

        AssetConfig storage cfg = assets[t.assetId];

        // 1. Calcul de la durée du trade
        uint256 duration = block.timestamp > t.openTimestamp ? block.timestamp - t.openTimestamp : 0;

        // 2. Récupération du spread de sortie brut et calcul du closePrice
        uint256 oi = t.margin * t.leverage;
        uint256 spread = _getExitSpread(t.direction, rp);
        uint256 amount = (oraclePrice * spread) / PRECISION;
        uint256 closePrice;
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

        t.state          = reason == REASON_LIQ ? STATE_LIQUIDATED : (reason == REASON_PROFIT_CAP ? STATE_LIQ_POS : STATE_CLOSED);
        t.closePrice     = closePrice;
        t.closeTimestamp = block.timestamp;
        t.borrowFee      = borrowFee;

        _releaseExposure(tradeId);

        _settle(t, netPnl, reason);

        emit TradeEvent(tradeId);
    }

    // =========================================================
    // INTERNAL — Pull collateral + take commission
    // =========================================================

    /// @notice Pulls collateral from trader and routes open commission to BrokexVault.
    /// @dev Formula:
    ///      1. grossOI = collateral * leverage
    ///      2. commission = (grossOI * cfg.commissionBps) / 1e6
    ///      3. netMargin = collateral - commission
    ///      4. netOI = netMargin * leverage
    ///      Pulls full collateral from trader. Immediately sends commission to Vault (increasing LP pool balance).
    function _pullFundsAndCommission(uint256 assetId, uint256 collateral, uint256 leverage)
        internal returns (uint256 margin, uint256 oi)
    {
        AssetConfig storage cfg = assets[assetId];

        // Gross minimum: the full amount the trader sends must be at least minTradeSize.
        // This guarantees that e.g. exactly 10 USDC always passes, even after commission.
        if (collateral < cfg.minTradeSize) revert BadMargin();
        if (leverage < cfg.minLeverage || leverage > cfg.maxLeverage || leverage > MAX_LEVERAGE_HARD_CAP) revert BadLeverage();

        uint256 grossOI = collateral * leverage;
        uint256 commission = (grossOI * cfg.commissionBps) / PRECISION;
        margin = collateral - commission;
        oi = margin * leverage;

        _pull(msg.sender, collateral);
        if (commission > 0) _sendToVault(commission);
    }

    // =========================================================
    // INTERNAL — Verify KMS proof, update OI, lock delta (revert path)
    // =========================================================

    /// @dev Used on the user-facing market open path — reverts on any failure.
    function _applyRisk(
        uint256    assetId,
        uint8      direction,
        uint256    oi,
        uint256    entryPrice,
        RiskProof calldata rp
    ) internal {
        AssetConfig storage cfg = assets[assetId];

        uint256 newLong  = openInterestLong[assetId]  + (direction == DIR_LONG  ? oi : 0);
        uint256 newShort = openInterestShort[assetId] + (direction == DIR_SHORT ? oi : 0);

        if (newLong  > rp.maxOILong)  revert OIExceeded();
        if (newShort > rp.maxOIShort) revert OIExceeded();

        if (newLong  > cfg.maxGlobalOI) revert GlobalOIExceeded();
        if (newShort > cfg.maxGlobalOI) revert GlobalOIExceeded();

        uint256 totalTraderOI = traderOpenInterest[assetId][msg.sender] + oi;
        if (totalTraderOI > cfg.maxTraderOI) revert TraderOIExceeded();

        // Enforce strict vault capital check at opening against available free capital
        int256 longDelta = direction == DIR_LONG ? int256(oi) : int256(0);
        int256 shortDelta = direction == DIR_SHORT ? int256(oi) : int256(0);
        uint256 newTotalLockedCapital = _getNewTotalLocked(assetId, longDelta, shortDelta);

        uint256 deltaLocked = newTotalLockedCapital > totalLockedCapital 
            ? newTotalLockedCapital - totalLockedCapital 
            : 0;

        if (deltaLocked > getFreeCapital()) revert InsufficientVaultCapital();

        // Record avg entry price BEFORE mutating OI, then update OI/locked capital.
        _recordEntryPrice(assetId, direction, oi, entryPrice);
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
        uint256 oldLong = openInterestLong[assetId];
        uint256 oldShort = openInterestShort[assetId];
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
            openInterestLong[assetId] += uint256(longDelta);
        } else if (longDelta < 0) {
            uint256 sub = uint256(-longDelta);
            openInterestLong[assetId] = openInterestLong[assetId] > sub ? openInterestLong[assetId] - sub : 0;
            if (openInterestLong[assetId] == 0) avgEntryPriceLong[assetId] = 0;
        }

        if (shortDelta > 0) {
            openInterestShort[assetId] += uint256(shortDelta);
        } else if (shortDelta < 0) {
            uint256 sub = uint256(-shortDelta);
            openInterestShort[assetId] = openInterestShort[assetId] > sub ? openInterestShort[assetId] - sub : 0;
            if (openInterestShort[assetId] == 0) avgEntryPriceShort[assetId] = 0;
        }

        totalLockedCapital = newTotalLocked;
    }

    function _releaseExposure(uint256 tradeId) internal {
        Trade storage t = trades[tradeId];

        uint256 oi = t.margin * t.leverage;

        _removeEntryPriceContribution(t.assetId, t.direction, oi, t.openPrice);

        int256 longDelta = t.direction == DIR_LONG ? -int256(oi) : int256(0);
        int256 shortDelta = t.direction == DIR_SHORT ? -int256(oi) : int256(0);
        uint256 newTotalLockedCapital = _getNewTotalLocked(t.assetId, longDelta, shortDelta);

        _updateExposure(t.assetId, longDelta, shortDelta, newTotalLockedCapital);

        traderOpenInterest[t.assetId][t.trader] = traderOpenInterest[t.assetId][t.trader] > oi
            ? traderOpenInterest[t.assetId][t.trader] - oi : 0;
    }

    // =========================================================
    // HELPERS — Average entry price tracking
    // =========================================================

    /// @dev OI-WEIGHTED AVERAGE ENTRY PRICE ARCHITECTURE:
    ///      - Isolated Individual PnL: `avgEntryPriceLong`/`Short` is strictly used for estimating protocol-wide 
    ///        Unrealized PnL (`verifyAndComputeUnrealizedPnL`). Individual trader PnL settlements NEVER read this value, 
    ///        relying instead on exact immutable trade open prices (`t.openPrice`).
    ///      - Zero-OI Reset Guarantee: Potential cumulative integer division drift is bounded and self-clearing. 
    ///        Whenever side Open Interest reaches zero (`openInterestLong/Short[assetId] == 0`), `avgEntryPrice` is 
    ///        hard-reset to 0 in `_updateExposure`, completely eliminating state drift over time.
    function _recordEntryPrice(uint256 assetId, uint8 direction, uint256 oi, uint256 price) internal {
        if (direction == DIR_LONG) {
            uint256 oldOI = openInterestLong[assetId];
            avgEntryPriceLong[assetId] = oldOI == 0
                ? price
                : (avgEntryPriceLong[assetId] * oldOI + price * oi) / (oldOI + oi);
        } else {
            uint256 oldOI = openInterestShort[assetId];
            avgEntryPriceShort[assetId] = oldOI == 0
                ? price
                : (avgEntryPriceShort[assetId] * oldOI + price * oi) / (oldOI + oi);
        }
    }

    function _removeEntryPriceContribution(uint256 assetId, uint8 direction, uint256 oi, uint256 price) internal {
        if (direction == DIR_LONG) {
            uint256 oldOI = openInterestLong[assetId];
            if (oldOI <= oi) {
                avgEntryPriceLong[assetId] = 0;
            } else {
                uint256 newOI = oldOI - oi;
                uint256 oldTotalVal = avgEntryPriceLong[assetId] * oldOI;
                uint256 tradeVal = price * oi;
                avgEntryPriceLong[assetId] = oldTotalVal > tradeVal ? (oldTotalVal - tradeVal) / newOI : 0;
            }
        } else {
            uint256 oldOI = openInterestShort[assetId];
            if (oldOI <= oi) {
                avgEntryPriceShort[assetId] = 0;
            } else {
                uint256 newOI = oldOI - oi;
                uint256 oldTotalVal = avgEntryPriceShort[assetId] * oldOI;
                uint256 tradeVal = price * oi;
                avgEntryPriceShort[assetId] = oldTotalVal > tradeVal ? (oldTotalVal - tradeVal) / newOI : 0;
            }
        }
    }

    // =========================================================
    // Vault-wide unrealized PnL
    // =========================================================

    /// @notice Computes the total unrealized PnL (long + short, all listed assets) from
    ///         a single KMS-signed batch proof. Matches BrokexVault's expected
    ///         IBrokexCore.verifyAndComputeUnrealizedPnL(BatchRiskProof) shape.
    /// @dev proof.prices must contain exactly one entry per id in listedAssetIds, in the
    ///      same order (including delisted-but-registered ids, which contribute 0 since
    ///      their OI is always 0 — see delistAsset).
    function verifyAndComputeUnrealizedPnL(BatchRiskProof calldata proof)
        external view returns (int256 totalUnrealizedPnL)
    {
        uint256 len = listedAssetIds.length;
        if (proof.prices.length != len) revert IncompleteBatchProof();

        if (proof.timestamp > block.timestamp) {
            if (proof.timestamp - block.timestamp > 15) revert InvalidKmsProof();
        } else {
            if (block.timestamp - proof.timestamp > 60) revert KmsProofExpired();
        }

        bytes32 hash    = keccak256(abi.encode(proof.timestamp, proof.prices));
        bytes32 ethHash = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", hash));

        (bytes32 r, bytes32 s, uint8 v) = _splitSig(proof.sig);
        address recovered = ecrecover(ethHash, v, r, s);
        if (recovered == address(0) || recovered != kmsSigner) revert InvalidKmsProof();

        for (uint256 i = 0; i < len; i++) {
            uint256 expectedId = listedAssetIds[i];
            AssetPriceData calldata pd = proof.prices[i];

            if (pd.assetId != expectedId) revert IncompleteBatchProof();
            if (pd.price == 0) revert PriceZero();

            uint256 price = pd.price;
            uint256 oiLong = openInterestLong[expectedId];
            uint256 oiShort = openInterestShort[expectedId];

            /// @dev DELISTING INVARIANT & ZERO-OI ASSET SKIPPING:
            ///      `delistAsset()` strictly enforces `openInterestLong == 0` and `openInterestShort == 0` before allowing a delist.
            ///      Since new trades are rejected on non-listed assets, delisted assets maintain zero OI permanently.
            ///      Consequently, `oiLong > 0` and `oiShort > 0` evaluate to false, skipping calculation and safely contributing exactly 0 to Unrealized PnL.
            if (oiLong > 0 && avgEntryPriceLong[expectedId] > 0) {
                uint256 avg = avgEntryPriceLong[expectedId];
                if (price >= avg) {
                    totalUnrealizedPnL += int256((oiLong * (price - avg)) / avg);
                } else {
                    totalUnrealizedPnL -= int256((oiLong * (avg - price)) / avg);
                }
            }

            if (oiShort > 0 && avgEntryPriceShort[expectedId] > 0) {
                uint256 avg = avgEntryPriceShort[expectedId];
                if (avg >= price) {
                    totalUnrealizedPnL += int256((oiShort * (avg - price)) / avg);
                } else {
                    totalUnrealizedPnL -= int256((oiShort * (price - avg)) / avg);
                }
            }
        }
    }

    // =========================================================
    // INTERNAL — Settle funds after close
    // =========================================================

    /// @notice Settles trader margin and profits/losses upon position closure.
    /// @dev INTENTIONAL VAULT SOLVENCY & REVERT DESIGN:
    ///      - If trader makes a profit, `vault.payTrader(t.trader, toPay)` is invoked.
    ///      - Should the Vault lack USDC balance (`USDC.balanceOf(vault) < toPay`), `vault.payTrader()`
    ///        reverts with `InsufficientVaultBalance`.
    ///      - INTENTIONAL RATIONALE: Vault insolvency is an extremely improbable tail-event thanks to strict
    ///        `getFreeCapital()` verification upon opening, 5% `lockedCapital` reserves, and the 10% `profitCap`.
    ///      - Reverting on insufficient balance guarantees strict payment accounting integrity, preventing
    ///        traders from receiving silent partial payments and alerting Keepers/admins immediately.
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
                uint256 available = USDC.balanceOf(address(vault));
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
    // HELPERS — Spread (KMS-controlled, constant hard cap)
    // =========================================================

    /// @dev Return the spread bps for the ENTRY leg.
    function _getEntrySpread(uint8 direction, RiskProof calldata rp)
        internal pure returns (uint256)
    {
        return direction == DIR_LONG ? rp.spreadLong : rp.spreadShort;
    }

    /// @dev Return the spread bps for the EXIT leg.
    function _getExitSpread(uint8 direction, RiskProof calldata rp)
        internal pure returns (uint256)
    {
        return direction == DIR_LONG ? rp.spreadShort : rp.spreadLong;
    }

    /// @notice Applies entry spread to raw KMS oracle spot price.
    /// @dev LONG Entry:  entryPrice = oraclePrice + (oraclePrice * spreadLong) / 1e6 (buys at ask)
    ///      SHORT Entry: entryPrice = oraclePrice - (oraclePrice * spreadShort) / 1e6 (sells at bid)
    function _applyEntrySpread(uint256 oraclePrice, uint8 direction, RiskProof calldata rp)
        internal pure returns (uint256)
    {
        uint256 spread = _getEntrySpread(direction, rp);
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

    /// @notice Calculates gross position PnL based on openPrice, closePrice, position OI, and direction.
    /// @dev LONG:  grossPnl = (oi * (closePrice - openPrice)) / openPrice
    ///      SHORT: grossPnl = (oi * (openPrice - closePrice)) / openPrice
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
    // HELPERS — KMS proof verification (ECDSA)
    // =========================================================

    function _verifyKmsProof(RiskProof calldata rp) internal view {
        AssetConfig storage cfg = assets[rp.assetId];
        if (!cfg.listed) revert BadParameter();
        if (rp.price == 0) revert PriceZero();

        if (rp.timestamp > block.timestamp) {
            if (rp.timestamp - block.timestamp > 15)           revert InvalidKmsProof();
        } else {
            if (block.timestamp - rp.timestamp > cfg.maxProofAge) revert KmsProofExpired();
        }

        bytes32 hash    = keccak256(abi.encode(
            rp.assetId, rp.price, rp.maxOILong, rp.maxOIShort, rp.spreadLong, rp.spreadShort, rp.timestamp
        ));
        bytes32 ethHash = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", hash));

        (bytes32 r, bytes32 s, uint8 v) = _splitSig(rp.sig);
        address recovered = ecrecover(ethHash, v, r, s);

        if (recovered == address(0) || recovered != kmsSigner) revert InvalidKmsProof();
    }

    function _checkKmsProof(RiskProof calldata rp) internal view returns (bool) {
        AssetConfig storage cfg = assets[rp.assetId];
        if (!cfg.listed) return false;
        if (rp.price == 0) return false;

        if (rp.timestamp > block.timestamp) {
            if (rp.timestamp - block.timestamp > 15)           return false;
        } else {
            if (block.timestamp - rp.timestamp > cfg.maxProofAge) return false;
        }

        bytes32 hash    = keccak256(abi.encode(
            rp.assetId, rp.price, rp.maxOILong, rp.maxOIShort, rp.spreadLong, rp.spreadShort, rp.timestamp
        ));
        bytes32 ethHash = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", hash));

        if (rp.sig.length != 65) return false;
        (bytes32 r, bytes32 s, uint8 v) = _splitSigNoRevert(rp.sig);
        address recovered = ecrecover(ethHash, v, r, s);

        return recovered != address(0) && recovered == kmsSigner;
    }

    function _splitSig(bytes calldata sig) internal pure returns (bytes32 r, bytes32 s, uint8 v) {
        if (sig.length != 65) revert InvalidKmsProof();
        return _splitSigNoRevert(sig);
    }

    function _splitSigNoRevert(bytes calldata sig) internal pure returns (bytes32 r, bytes32 s, uint8 v) {
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
        if (cfg.minLeverage == 0 || cfg.maxLeverage < cfg.minLeverage) revert BadParameter();
        if (cfg.maxLeverage > MAX_LEVERAGE_HARD_CAP) revert BadParameter();
        if (cfg.minTradeSize      == 0)          revert BadParameter();
        if (cfg.commissionBps      > MAX_COMMISSION_ALLOWED) revert BadParameter(); // max 1%
        if (cfg.profitCap == 0 || cfg.profitCap > PRECISION) revert BadParameter();
        if (cfg.executionTolerance == 0 || cfg.executionTolerance > 10_000) revert BadParameter(); // max 1%, non-zero
        if (cfg.maxProofAge == 0 || cfg.maxProofAge > 60) revert BadParameter();
        if (cfg.borrowRateHourly  > MAX_BORROW_RATE_ALLOWED) revert BadParameter(); // max 0.1%/hour
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
        if (!USDC.transferFrom(from, address(this), amount)) revert TransferFailed();
    }

    function _send(address to, uint256 amount) internal {
        if (amount == 0) return;
        if (!USDC.transfer(to, amount)) revert TransferFailed();
    }

    function _sendToVault(uint256 amount) internal {
        if (amount == 0) return;
        if (!USDC.transfer(address(vault), amount)) revert TransferFailed();
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

    /// @notice Single source of truth for free capital available in the Vault to back trading risk.
    /// @dev Formula: Vault USDC Balance - totalLockedCapital - Vault's reserved LP withdrawal queue
    function getFreeCapital() public view returns (uint256) {
        uint256 vaultBal = USDC.balanceOf(address(vault));
        uint256 reservedWithdrawals = vault.getRequiredFreeUSDC();
        uint256 totalDeductions = totalLockedCapital + reservedWithdrawals;

        if (vaultBal <= totalDeductions) return 0;
        return vaultBal - totalDeductions;
    }

    function getTrade(uint256 tradeId) external view returns (Trade memory) {
        return trades[tradeId];
    }

    function getListedAssetIds() external view returns (uint256[] memory) {
        return listedAssetIds;
    }
}
