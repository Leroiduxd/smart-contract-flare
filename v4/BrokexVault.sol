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

interface IBrokexCore {
    struct AssetPriceData {
        uint256 assetId;
        uint256 price;
    }

    struct BatchRiskProof {
        uint256 timestamp;
        AssetPriceData[] prices;
        bytes sig;
    }

    function verifyAndComputeUnrealizedPnL(BatchRiskProof calldata proof)
        external view returns (int256 totalUnrealizedPnL);
    function totalLockedCapital() external view returns (uint256);
}

// =============================================================
// BrokexVault
// =============================================================

/// @title BrokexVault V4 - LP Liquidity Pool & Token (bUSDC)
/// @notice LP liquidity pool + LP share token (bUSDC) + FIFO withdrawal settlement.
/// @dev CORE ARCHITECTURE, UNITS & LIQUIDITY RULES:
///
///      =================================================================================
///      1. UNITS & NUMERICAL SCALINGS (1e6 PRECISION):
///      =================================================================================
///         - Base Precision: 1,000,000 = 1.0 (100.0000%)
///         - USDC Token Precision (`decimals = 6`): 1,000,000 = 1.000000 USDC
///         - LP Token (`bUSDC`) Precision (`decimals = 6`): 1,000,000 = 1.000000 bUSDC
///         - LP Token Price (`lastKnownPrice` / Exact Price): 1,000,000 = $1.000000 USD per bUSDC share
///
///      =================================================================================
///      2. MARGIN SEGREGATION & FREE LIQUIDITY:
///      =================================================================================
///         - Active trader margin lives ENTIRELY in BrokexCore, never inside this Vault.
///         - This Vault holds LP capital, trading commissions received from Core, and net PnL settlements.
///         - `getFreeLiquidity()` returns the raw USDC balance of this contract without netting trader collateral.
///
///      =================================================================================
///      3. MINTING LP TOKENS (`deposit` / `depositLP`):
///      =================================================================================
///         - Requires a fresh, verified `BatchRiskProof` containing prices for ALL listed assets.
///         - The exact LP price is recomputed from the Vault NAV:
///             NAV = Vault USDC Balance - Net Protocol Unrealized PnL
///             Exact LP Price = (NAV * 1e6) / totalSupply
///         - LP shares minted: `lpMinted = (usdcAmount * 1e6) / Exact LP Price`.
///         - `lastKnownPrice` is updated to this fresh exact price at the end of the transaction.
///
///      =================================================================================
///      4. TWO-STEP FIFO WITHDRAWAL QUEUE (`requestWithdrawLP` & `processWithdrawalQueue`):
///      =================================================================================
///         - STEP 1 (`requestWithdrawLP`): Proof-less & free of oracle fees for the user.
///           User specifies `lpAmount`. LP tokens are immediately locked on Vault contract.
///           A unique `requestId` is assigned at `queueTail`. `totalPendingLP` is incremented.
///           LP tokens are NOT burned yet.
///         - STEP 2 (`processWithdrawalQueue`): Processed FIFO (`queueHead` -> `queueTail`) by a Keeper
///           providing a fresh `BatchRiskProof`.
///           The exact LP price is recomputed. USDC payout is calculated:
///             usdcPaid = (lpAmount * Exact LP Price) / 1e6
///           LP tokens are ONLY NOW permanently burned (`_burn`). `totalPendingLP` is decremented.
///           USDC is paid out to user. `queueHead` advances.
///
///      =================================================================================
///      5. SOLVENCY & CACHED `lastKnownPrice`:
///      =================================================================================
///         - `lastKnownPrice` stores the last verified exact LP price computed on-chain.
///         - `getRequiredFreeUSDC()` uses `lastKnownPrice` to provide a fast, proof-less estimate of USDC
///           needed to fulfill all pending withdrawal requests in the queue:
///             Required Free USDC = (totalPendingLP * lastKnownPrice) / 1e6
///         - BrokexCore uses this value to deduct pending withdrawals from Free Capital before allowing new trades.
contract BrokexVault {

    uint256 public constant DEFAULT_PROCESS_LIMIT = 20;
    uint8   public constant decimals = 6; // matches USDC precision

    // =========================================================
    // ERC20 STATE VARIABLES (LP Token: bUSDC)
    // =========================================================
    string public name;
    string public symbol;
    uint256 public totalSupply;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    // =========================================================
    // VAULT STATE VARIABLES
    // =========================================================
    IERC20  public immutable USDC;
    address public owner;
    address public pendingOwner;
    address public coreContract;
    bool    private locked;

    /// @notice Last exact LP price computed from a verified proof (1e6 precision).
    /// @dev ESTIMATE ONLY — see contract-level dev doc, rule 2(b). Never used to settle payments.
    uint256 public lastKnownPrice = 1e6;

    // FIFO Withdrawal Queue
    struct WithdrawalRequest {
        address user;
        uint256 lpAmountRemaining;
    }

    mapping(uint256 => WithdrawalRequest) public withdrawalQueue;
    uint256 public queueHead;
    uint256 public queueTail;
    uint256 public totalPendingLP;

    // =========================================================
    // EVENTS
    // =========================================================
    event LPDeposited(address indexed user, uint256 usdcAmount, uint256 lpMinted, uint256 price);
    event WithdrawalRequested(uint256 indexed requestId, address indexed user, uint256 lpAmount);
    event WithdrawalPaid(uint256 indexed requestId, address indexed user, uint256 lpBurned, uint256 usdcPaid, uint256 price);

    // =========================================================
    // ERRORS
    // =========================================================
    error NotOwner();
    error NotPendingOwner();
    error NotCoreContract();
    error Reentrancy();
    error ZeroAddress();
    error ZeroAmount();
    error ZeroLPMinted();
    error InsufficientLPBalance();
    error InsufficientVaultBalance();
    error TransferFailed();

    // =========================================================
    // MODIFIERS
    // =========================================================
    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    modifier onlyCore() {
        if (msg.sender != coreContract) revert NotCoreContract();
        _;
    }

    modifier nonReentrant() {
        if (locked) revert Reentrancy();
        locked = true;
        _;
        locked = false;
    }

    // =========================================================
    // CONSTRUCTOR
    // =========================================================
    constructor(address usdc, string memory _name, string memory _symbol) {
        if (usdc == address(0)) revert ZeroAddress();
        USDC   = IERC20(usdc);
        name   = _name;
        symbol = _symbol;
        owner  = msg.sender;
    }

    // =========================================================
    // ADMIN
    // =========================================================

    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert ZeroAddress();
        pendingOwner = newOwner;
    }

    function acceptOwnership() external {
        if (msg.sender != pendingOwner) revert NotPendingOwner();
        owner        = pendingOwner;
        pendingOwner = address(0);
    }

    function setCoreContract(address _coreContract) external onlyOwner {
        if (_coreContract == address(0)) revert ZeroAddress();
        coreContract = _coreContract;
    }

    // =========================================================
    // ERC20 FUNCTIONS
    // =========================================================

    function transfer(address to, uint256 value) external returns (bool) {
        if (to == address(0)) revert ZeroAddress();
        if (balanceOf[msg.sender] < value) revert InsufficientLPBalance();
        balanceOf[msg.sender] -= value;
        balanceOf[to]         += value;
        emit Transfer(msg.sender, to, value);
        return true;
    }

    function approve(address spender, uint256 value) external returns (bool) {
        allowance[msg.sender][spender] = value;
        emit Approval(msg.sender, spender, value);
        return true;
    }

    function transferFrom(address from, address to, uint256 value) external returns (bool) {
        if (to == address(0)) revert ZeroAddress();
        if (balanceOf[from] < value) revert InsufficientLPBalance();

        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) {
            if (allowed < value) revert InsufficientLPBalance();
            allowance[from][msg.sender] = allowed - value;
        }

        balanceOf[from] -= value;
        balanceOf[to]   += value;
        emit Transfer(from, to, value);
        return true;
    }

    /// @notice Calculates the exact LP Token Price and Vault-wide Unrealized PnL.
    /// @dev Formula: Exact LP Price = (Net Vault Assets * 1e6) / Total LP Supply
    ///      Where Net Vault Assets = Vault USDC Balance - Protocol Net Unrealized PnL (from Core).
    ///      Unrealized trader gains decrease Net Assets (liability), while losses increase Net Assets.
    /// @param proof Verified KMS BatchRiskProof containing signed prices for all listed assets.
    /// @return price Exact LP Token Price scaled to 1e6 ($1.000000 = 1,000,000).
    /// @return totalUnrealizedPnL Total net unrealized PnL across all open positions.
    function _getLPPriceAndPnL(IBrokexCore.BatchRiskProof calldata proof)
        internal view returns (uint256 price, int256 totalUnrealizedPnL)
    {
        if (totalSupply == 0 || coreContract == address(0)) {
            return (1e6, 0);
        }

        totalUnrealizedPnL = IBrokexCore(coreContract).verifyAndComputeUnrealizedPnL(proof);
        int256 netAssets = int256(getFreeLiquidity()) - totalUnrealizedPnL;

        if (netAssets <= 0) {
            price = 1e6;
        } else {
            price = (uint256(netAssets) * 1e6) / totalSupply;
        }
    }

    function getLPPriceWithProof(IBrokexCore.BatchRiskProof calldata proof)
        external view returns (uint256 price)
    {
        (price, ) = _getLPPriceAndPnL(proof);
    }

    // =========================================================
    // LP DEPOSIT — instant, two modes
    // =========================================================

    /// @notice Deposit an exact USDC amount, receive however many LP shares it buys.
    function deposit(uint256 usdcAmount, IBrokexCore.BatchRiskProof calldata proof)
        external nonReentrant returns (uint256 lpMinted)
    {
        if (usdcAmount == 0) revert ZeroAmount();

        (uint256 price, ) = _getLPPriceAndPnL(proof);
        lpMinted = (usdcAmount * 1e6) / price;
        if (lpMinted == 0) revert ZeroLPMinted();

        _pull(msg.sender, usdcAmount);

        totalSupply           += lpMinted;
        balanceOf[msg.sender] += lpMinted;
        lastKnownPrice = price;

        emit Transfer(address(0), msg.sender, lpMinted);
        emit LPDeposited(msg.sender, usdcAmount, lpMinted, price);
    }

    /// @notice Deposit by specifying exactly how many LP shares to receive.
    function depositLP(uint256 lpAmount, IBrokexCore.BatchRiskProof calldata proof)
        external nonReentrant returns (uint256 usdcRequired)
    {
        if (lpAmount == 0) revert ZeroAmount();

        (uint256 price, ) = _getLPPriceAndPnL(proof);
        usdcRequired = (lpAmount * price) / 1e6;
        if (usdcRequired == 0) revert ZeroAmount();

        _pull(msg.sender, usdcRequired);

        totalSupply           += lpAmount;
        balanceOf[msg.sender] += lpAmount;
        lastKnownPrice = price;

        emit Transfer(address(0), msg.sender, lpAmount);
        emit LPDeposited(msg.sender, usdcRequired, lpAmount, price);
    }

    /// @notice STEP 1: Reserve a spot in the FIFO LP Withdrawal Queue (Proof-less & Oracle Fee Free).
    /// @dev LP tokens are transferred to the Vault contract and locked. They are NOT burned yet.
    ///      Creates a WithdrawalRequest in `withdrawalQueue[queueTail++]` and increments `totalPendingLP`.
    /// @param lpAmount Number of LP tokens (bUSDC, 6 decimals) to request for withdrawal.
    /// @return requestId Unique FIFO queue index assigned to this withdrawal request.
    function requestWithdraw(uint256 lpAmount) external nonReentrant returns (uint256 requestId) {
        if (lpAmount == 0) revert ZeroAmount();
        if (balanceOf[msg.sender] < lpAmount) revert InsufficientLPBalance();

        balanceOf[msg.sender]    -= lpAmount;
        balanceOf[address(this)] += lpAmount;
        emit Transfer(msg.sender, address(this), lpAmount);

        requestId = queueTail++;
        withdrawalQueue[requestId] = WithdrawalRequest({
            user: msg.sender,
            lpAmountRemaining: lpAmount
        });

        totalPendingLP += lpAmount;
        emit WithdrawalRequested(requestId, msg.sender, lpAmount);
    }

    // =========================================================
    // LP WITHDRAWAL — STEP 2: PROCESS QUEUE (public, fresh proof)
    // =========================================================

    /// @notice Process up to DEFAULT_PROCESS_LIMIT (20) pending withdrawal requests.
    function processWithdrawalQueue(IBrokexCore.BatchRiskProof calldata proof) external nonReentrant {
        _processWithdrawalQueue(DEFAULT_PROCESS_LIMIT, proof);
    }

    /// @notice Process up to `limit` pending withdrawal requests. Open to anyone —
    ///         in practice only callable usefully by whoever can produce a valid
    ///         KMS-signed BatchRiskProof.
    function processWithdrawalQueue(uint256 limit, IBrokexCore.BatchRiskProof calldata proof) external nonReentrant {
        _processWithdrawalQueue(limit, proof);
    }

    /// @dev STEP 2: FIFO Queue Execution (Requires verified BatchRiskProof).
    ///      Iterates from `queueHead` towards `queueTail` (up to `limit` requests).
    ///      Calculates exact USDC payout at current LP price: usdcPaid = (lpAmount * Exact LP Price) / 1e6.
    ///      PERMANENTLY BURNS locked LP tokens (`_burn`) upon payout and transfers USDC to the user.
    ///      Updates `lastKnownPrice` and advances `queueHead`.
    function _processWithdrawalQueue(uint256 limit, IBrokexCore.BatchRiskProof calldata proof) internal {
        (uint256 price, ) = _getLPPriceAndPnL(proof);
        lastKnownPrice = price;

        // =========================================================================================
        // SÉCURITÉ & SOLVABILITÉ DU VAULT (RÉFUTATION DU POINT 3) :
        // coreLocked représente le capital réservé pour garantir les positions ouvertes des traders (5% de l'OI).
        // Soustraire coreLocked de vaultBal pour obtenir safeFreeUSDC est une PROTECTION ESSENTIELLE :
        // 1. Évite un "Bank Run" des LPs pendant que le protocole supporte un risque directionnel trader élevé.
        // 2. Empêche la double-soustraction : getFreeCapital() régule les ENTRÉES de trades dans le Core,
        //    tandis que safeFreeUSDC régule les SORTIES LP dans le Vault pour garantir la liquidité des traders gagnants (payTrader).
        // 3. Traitement FIFO gracieux : si safeFreeUSDC == 0, les requêtes LP restent en file d'attente
        //    sans perte de capital et seront traitées dès la fermeture des positions traders.
        // =========================================================================================
        uint256 vaultBal = USDC.balanceOf(address(this));
        uint256 coreLocked = coreContract != address(0) ? IBrokexCore(coreContract).totalLockedCapital() : 0;
        uint256 safeFreeUSDC = vaultBal > coreLocked ? vaultBal - coreLocked : 0;

        uint256 count = 0;

        while (queueHead < queueTail && count < limit) {
            if (safeFreeUSDC == 0) break;

            WithdrawalRequest storage req = withdrawalQueue[queueHead];
            if (req.lpAmountRemaining == 0) {
                queueHead++;
                count++;
                continue;
            }

            uint256 valueOwedUSDC = (req.lpAmountRemaining * price) / 1e6;
            uint256 toPayUSDC = valueOwedUSDC < safeFreeUSDC ? valueOwedUSDC : safeFreeUSDC;

            if (toPayUSDC == 0) {
                /// @dev DUST CLEANUP & QUEUE ADVANCEMENT DESIGN:
                ///      If remaining LP tokens fall below 1e1 (0.00001 bUSDC / ~$0.00001 USD), the payout rounds down to 0 USDC.
                ///      Pruning this sub-cent dust is an intentional EVM gas optimization. It prevents queue head blocking 
                ///      and avoids infinite loop overhead during queue iteration for negligible capital fractions.
                if (req.lpAmountRemaining < 1e1) {
                    uint256 dust = req.lpAmountRemaining;
                    balanceOf[address(this)] -= dust;
                    totalSupply               -= dust;
                    emit Transfer(address(this), address(0), dust);
                    req.lpAmountRemaining = 0;
                    totalPendingLP        -= dust;
                    queueHead++;
                    count++;
                    continue;
                }
                break;
            }

            uint256 lpToSettle = (toPayUSDC * 1e6) / price;
            if (lpToSettle > req.lpAmountRemaining || req.lpAmountRemaining - lpToSettle < 1e1) {
                lpToSettle = req.lpAmountRemaining;
            }

            req.lpAmountRemaining    -= lpToSettle;
            totalPendingLP           -= lpToSettle;
            balanceOf[address(this)] -= lpToSettle;
            totalSupply               -= lpToSettle;
            emit Transfer(address(this), address(0), lpToSettle);

            safeFreeUSDC -= toPayUSDC;
            _send(req.user, toPayUSDC);

            emit WithdrawalPaid(queueHead, req.user, lpToSettle, toPayUSDC, price);

            if (req.lpAmountRemaining == 0) {
                queueHead++;
            }
            count++;
        }
    }

    // =========================================================
    // CORE INTEGRATION — TRADER PROFIT PAYOUT
    // =========================================================

    /// @notice Pays a winning trader's profit. Called by BrokexCore on trade close.
    function payTrader(address trader, uint256 amount) external onlyCore {
        if (amount == 0) return;
        uint256 vaultBalance = USDC.balanceOf(address(this));
        if (vaultBalance < amount) revert InsufficientVaultBalance();
        _send(trader, amount);
    }

    // =========================================================
    // VIEW FUNCTIONS
    // =========================================================

    /// @notice Raw USDC balance held by this Vault. Deliberately NOT netted against
    ///         trader collateral — that collateral lives in BrokexCore, never here.
    function getFreeLiquidity() public view returns (uint256) {
        return USDC.balanceOf(address(this));
    }

    /// @notice Cheap, proof-less ESTIMATE of USDC needed to cover the pending
    ///         withdrawal queue, using the last exact price computed. Used by
    ///         BrokexCore's solvency check before opening a trade.
    function getRequiredFreeUSDC() external view returns (uint256) {
        if (totalPendingLP == 0) return 0;
        return (totalPendingLP * lastKnownPrice) / 1e6;
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
}
