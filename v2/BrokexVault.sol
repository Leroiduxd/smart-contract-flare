// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IERC20 {
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

interface ICore {
    function emergencyMode() external view returns (bool);
    function totalLockedCapital() external view returns (uint256);
    // getUnrealizedPnL returns price-normalized net PnL (long + short combined)
    function getUnrealizedPnL(uint256 assetId) external returns (int256);
    function getTotalUnrealizedPnL() external returns (int256);
}

contract BrokexVault {

    // =========================================================
    // ERC20 State Variables (LP Token)
    // =========================================================
    string public name;
    string public symbol;
    uint8 public constant decimals = 18;
    uint256 public totalSupply;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    // =========================================================
    // Vault State
    // =========================================================
    IERC20 public immutable USDT;
    address public owner;
    address public pendingOwner;
    address public primaryCore;
    
    uint256 public constant GOLD_ASSET_ID = 5500;

    // Reentrancy Guard
    bool private locked;

    struct WithdrawalRequest {
        address user;
        uint256 lpAmountRemaining; // decreases at each partial/full settlement
    }

    mapping(uint256 => WithdrawalRequest) public withdrawalQueue;
    uint256 public queueHead;      // next request index to be processed
    uint256 public queueTail;      // next available request index
    uint256 public totalPendingLP;  // sum of lpAmountRemaining in queue

    // =========================================================
    // Events
    // =========================================================
    event Deposit(address indexed user, uint256 amountIn, uint256 lpMinted, uint256 priceAtDeposit);
    event WithdrawalRequested(uint256 indexed requestId, address indexed user, uint256 lpAmount);
    event WithdrawalPaid(uint256 indexed requestId, address indexed user, uint256 lpBurned, uint256 usdtPaid, uint256 priceAtPayment);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);

    // =========================================================
    // Modifiers
    // =========================================================
    modifier onlyOwner() {
        require(msg.sender == owner, "NotOwner");
        _;
    }

    modifier nonReentrant() {
        require(!locked, "ReentrancyGuard");
        locked = true;
        _;
        locked = false;
    }

    // =========================================================
    // Constructor
    // =========================================================
    constructor(
        address _usdt,
        string memory _name,
        string memory _symbol
    ) {
        require(_usdt != address(0), "ZeroAddress");
        USDT = IERC20(_usdt);
        name = _name;
        symbol = _symbol;
        owner = msg.sender;
    }

    // =========================================================
    // ERC20 Inline Functions
    // =========================================================
    function transfer(address to, uint256 value) external returns (bool) {
        require(to != address(0), "ZeroAddress");
        require(balanceOf[msg.sender] >= value, "InsufficientBalance");
        balanceOf[msg.sender] -= value;
        balanceOf[to] += value;
        emit Transfer(msg.sender, to, value);
        return true;
    }

    function approve(address spender, uint256 value) external returns (bool) {
        require(spender != address(0), "ZeroAddress");
        allowance[msg.sender][spender] = value;
        emit Approval(msg.sender, spender, value);
        return true;
    }

    function transferFrom(address from, address to, uint256 value) external returns (bool) {
        require(to != address(0), "ZeroAddress");
        require(balanceOf[from] >= value, "InsufficientBalance");
        if (msg.sender != from && allowance[from][msg.sender] != type(uint256).max) {
            require(allowance[from][msg.sender] >= value, "InsufficientAllowance");
            allowance[from][msg.sender] -= value;
        }
        balanceOf[from] -= value;
        balanceOf[to] += value;
        emit Transfer(from, to, value);
        return true;
    }

    // =========================================================
    // LP Price Calculation
    // =========================================================
    
    /// @notice Calculates the LP price scaled to 1e6 (same decimals as USDT)
    ///         totalAssets = USDT.balanceOf(vault) - unrealizedPnL (positive = owed to traders)
    function getLPPrice() public returns (uint256) {
        int256 unrealizedPnL = 0;
        if (primaryCore != address(0)) {
            unrealizedPnL = ICore(primaryCore).getTotalUnrealizedPnL();
        }

        uint256 usdtBal = USDT.balanceOf(address(this));
        int256 totalAssetsInt = int256(usdtBal) - unrealizedPnL;
        
        uint256 totalAssets;
        if (totalAssetsInt <= 0) {
            totalAssets = 0;
        } else {
            totalAssets = uint256(totalAssetsInt);
        }

        // Standard ERC4626 Offset Method (scaled to 1 USDT and 1 LP):
        // Virtual Assets = 1 USDT (10^6 units)
        // Virtual Shares = 1 LP (10^18 units)
        // price = (totalAssets + 10^6) * 1e18 / (totalSupply + 1e18)
        uint256 price = ((totalAssets + 10**6) * 1e18) / (totalSupply + 10**18);
        return price;
    }

    // =========================================================
    // Deposit / Mint LP
    // =========================================================

    /// @notice Deposit USDT into the vault to receive LP tokens
    function deposit(uint256 amount) external nonReentrant returns (uint256 lpMinted) {
        require(amount > 0, "ZeroAmount");

        uint256 price = getLPPrice();
        require(USDT.transferFrom(msg.sender, address(this), amount), "TransferFailed");

        // Adjust scales: amount (6 decimals) * 1e18 / price (6 decimals) => 18 decimals LP
        lpMinted = (amount * 1e18) / price;
        require(lpMinted > 0, "ZeroLPMinted");

        totalSupply += lpMinted;
        balanceOf[msg.sender] += lpMinted;
        emit Transfer(address(0), msg.sender, lpMinted);

        emit Deposit(msg.sender, amount, lpMinted, price);
    }

    /// @notice Deposit specifying the desired amount of LP tokens to receive.
    ///         The contract will calculate and pull the corresponding USDT amount.
    function depositLP(uint256 lpAmount) external nonReentrant returns (uint256 amount) {
        require(lpAmount > 0, "ZeroAmount");

        uint256 price = getLPPrice();
        // Calculate required USDT (round up to prevent precision loss)
        amount = (lpAmount * price + 1e18 - 1) / 1e18;
        require(amount > 0, "ZeroAmount");

        require(USDT.transferFrom(msg.sender, address(this), amount), "TransferFailed");

        totalSupply += lpAmount;
        balanceOf[msg.sender] += lpAmount;
        emit Transfer(address(0), msg.sender, lpAmount);

        emit Deposit(msg.sender, amount, lpAmount, price);
    }

    // =========================================================
    // Request Withdrawal (FIFO)
    // =========================================================

    /// @notice Request a withdrawal. LP tokens are frozen inside this contract until processed.
    function requestWithdraw(uint256 lpAmount) external nonReentrant returns (uint256 requestId) {
        require(lpAmount > 0, "ZeroAmount");
        require(balanceOf[msg.sender] >= lpAmount, "InsufficientLPBalance");

        balanceOf[msg.sender] -= lpAmount;
        balanceOf[address(this)] += lpAmount;
        emit Transfer(msg.sender, address(this), lpAmount);

        requestId = queueTail;
        withdrawalQueue[requestId] = WithdrawalRequest({
            user: msg.sender,
            lpAmountRemaining: lpAmount
        });
        queueTail++;

        totalPendingLP += lpAmount;

        emit WithdrawalRequested(requestId, msg.sender, lpAmount);
    }

    // =========================================================
    // Queue Processing
    // =========================================================

    /// @notice Permissionless function to process the withdrawal queue
    function processQueue() external nonReentrant {
        _processQueue();
    }

    function _processQueue() internal {
        uint256 limit = 20;
        uint256 count = 0;

        while (queueHead < queueTail && count < limit) {
            uint256 totalUSDT = USDT.balanceOf(address(this));
            uint256 lockedCap = 0;
            if (primaryCore != address(0)) {
                lockedCap = ICore(primaryCore).totalLockedCapital();
            }
            uint256 freeUSDT = totalUSDT > lockedCap ? totalUSDT - lockedCap : 0;

            if (freeUSDT == 0) {
                break;
            }

            WithdrawalRequest storage request = withdrawalQueue[queueHead];
            if (request.lpAmountRemaining == 0) {
                queueHead++;
                count++;
                continue;
            }

            uint256 price = getLPPrice();
            uint256 valueOwedUSDT = (request.lpAmountRemaining * price) / 1e18;
            uint256 toPayUSDT = valueOwedUSDT < freeUSDT ? valueOwedUSDT : freeUSDT;

            if (toPayUSDT == 0) {
                // If there's dust remaining (less than 0.0001 LP) but toPayUSDT is 0,
                // we clean it up so the queue is not blocked indefinitely
                if (request.lpAmountRemaining < 10**14) {
                    uint256 dustToSettle = request.lpAmountRemaining;
                    balanceOf[address(this)] -= dustToSettle;
                    totalSupply -= dustToSettle;
                    emit Transfer(address(this), address(0), dustToSettle);
                    request.lpAmountRemaining = 0;
                    totalPendingLP -= dustToSettle;
                    queueHead++;
                    count++;
                    continue;
                }
                break;
            }

            uint256 lpToSettle = (toPayUSDT * 1e18) / price;
            // Dust protection: if remaining LP after this step is less than 0.0001 LP (1e14),
            // or if calculated lpToSettle exceeds remaining, settle everything.
            if (lpToSettle > request.lpAmountRemaining || request.lpAmountRemaining - lpToSettle < 10**14) {
                lpToSettle = request.lpAmountRemaining;
            }

            // Burn LP tokens
            balanceOf[address(this)] -= lpToSettle;
            totalSupply -= lpToSettle;
            emit Transfer(address(this), address(0), lpToSettle);

            // Transfer USDT to user
            require(USDT.transfer(request.user, toPayUSDT), "TransferFailed");

            request.lpAmountRemaining -= lpToSettle;
            totalPendingLP -= lpToSettle;

            emit WithdrawalPaid(queueHead, request.user, lpToSettle, toPayUSDT, price);

            if (request.lpAmountRemaining == 0) {
                queueHead++;
            }

            count++;

            // If we ran out of cash to pay the full request, stop processing
            if (toPayUSDT < valueOwedUSDT) {
                break;
            }
        }
    }

    // =========================================================
    // Core Integration Functions
    // =========================================================

    /// @notice Returns the amount of USDT needed to cover pending withdrawals
    function getRequiredFreeUSDC() external returns (uint256) {
        uint256 price = getLPPrice();
        return (totalPendingLP * price) / 1e18;
    }

    /// @notice Core contract calls this to pay profitable trades
    function payTrader(address trader, uint256 amount) external {
        require(msg.sender == primaryCore, "NotCore");
        require(amount > 0, "ZeroAmount");
        require(USDT.transfer(trader, amount), "TransferFailed");
    }

    // =========================================================
    // Admin Functions
    // =========================================================

    function setPrimaryCore(address _coreAddress) external onlyOwner {
        require(_coreAddress != address(0), "ZeroAddress");
        primaryCore = _coreAddress;
    }

    function setPendingOwner(address newPending) external onlyOwner {
        pendingOwner = newPending;
    }

    function acceptOwnership() external {
        require(msg.sender == pendingOwner, "NotPendingOwner");
        emit OwnershipTransferred(owner, pendingOwner);
        owner = pendingOwner;
        pendingOwner = address(0);
    }
}
