// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

// =============================================================
// YieldCreditCardVault — 
// Split: 
// =============================================================

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";

import "./YieldCreditCardStorage.sol";

contract YieldCreditCardVault is Ownable, ReentrancyGuard,YieldCreditCardStorage {

    using SafeERC20 for IERC20;
    //using ECDSA     for bytes32;

    uint256 public LTV = 9000; // 90% (basis points)
    uint256 public constant BPS = 10000;
    uint256 public constant PROPOSAL_TTL = 2 days;


    mapping(address => CardBalance) public cardBalances;
    mapping(bytes32 => Transaction) public transactions;
    mapping(bytes32 => bool)    public transactionRefUsed;
    IERC20  public immutable token;
    uint256 public immutable TOKEN_SCALE;

    //Global Totals
    uint256 public totalCollateral;
    uint256 public totalDebt;
    uint256 public totalLocked;
    uint256 public totalCreditLimit;

    address[3] public admins;
    address public cardProcessor;
    mapping(address => bool) public isAdmin;
    uint256 public requiredApprovals = 2;

    mapping(bytes32 => Proposal) public proposals;
    mapping(bytes32 => mapping(address => bool)) public approvedBy;
    bytes32[] public proposalIndex;
    uint256 public proposalNonce;
    mapping(bytes32 => uint256) public proposalPosition;
    mapping(address => bytes32) public activeProposal;

    mapping(bytes32 => WithdrawalRequest) public withdrawals;
    mapping(address => bytes32[]) public userWithdrawals;
    mapping(address => bytes32) public activeWithdrawal;

    bool    public paused;

    address public feeWallet;
    address public penaltyWallet;
    address public settlementWallet;
    address public prepaidWallet;

    event Paused(address indexed admin);
    event Unpaused(address indexed admin);
    event AuthorizeCharge(address indexed user, uint256 amount, bytes32 refNo, TxStatus status);
    event CaptureCharged(address indexed user, uint256 amount, bytes32 refNo, TxStatus status);
    event VoidCharged(address indexed user, uint256 amount, bytes32 refNo, TxStatus status);
    event RefundCharged(address indexed user, uint256 amount, bytes32 refNo, TxStatus status);
    event CardProcessorChanged(address indexed oldProcessor, address indexed newProcessor);
    event CreditLimitIncrease(address indexed user, uint256 oldLimit, uint256 newLimit);
    event WithdrawalApproved(address indexed user,uint256 available,uint256 amount);
    event AmountLocked(address indexed user, uint256 available, uint256 oldLock, uint256 amount);
    event CardBlocked(address indexed user);
    event CardUnBlocked(address indexed user);
    event ProposalSubmitted(bytes32 indexed proposalId, address indexed user, AdminAction action,bytes data);
    event ProposalApproved(bytes32 indexed proposalId, address indexed approver, uint256 approvals);
    event ProposalExecuted(bytes32 indexed proposalId, address indexed user, AdminAction action, uint256 amount);
    event ProposalCancelled(bytes32 indexed proposalId);
    event WithdrawalInitiated(address indexed user, bytes32 proposalId, uint256 amount);
    event Deposited(address indexed user, uint256 amount, uint256 newCreditLimit);
    event FeePosted(address indexed user,uint256 amount);

     constructor(
        address _token,
        address _cardProcessor,
        address _creditAdmin1,
        address _creditAdmin2,
        address _creditAdmin3
    )
        Ownable(msg.sender)
    {
        
        require(_token != address(0),"zero Token address") ;
        //require(IERC20Metadata(_token).decimals() == 6,"Token Decimal must be 6") ;
        require(_cardProcessor != address(0),"zero Card Processor address") ;
        require(_creditAdmin1 != address(0),"zero Credit Admin 1 address") ;
        require(_creditAdmin2 != address(0),"zero Credit Admin 2 address") ;
        require(_creditAdmin3 != address(0),"zero Credit Admin 3 address") ;
        
        token              = IERC20(_token);
        TOKEN_SCALE        = 10 ** IERC20Metadata(token).decimals();

        cardProcessor = _cardProcessor;

        admins[0] = _creditAdmin1;
        admins[1] = _creditAdmin2;
        admins[2] = _creditAdmin3;
        isAdmin[admins[0]] = true;
        isAdmin[admins[1]] = true;
        isAdmin[admins[2]] = true;
    }

    modifier onlyCreditAdmin() {
        require(isAdmin[msg.sender], "Not Credit Admin");
        _;
    }

    modifier onlyCardProcessor() {
        require(msg.sender == cardProcessor, "Not Card Processor");
        _;
    }

    modifier onlyAuthorized() {
        require(msg.sender == cardProcessor || isAdmin[msg.sender], "Not Card Processor");
        _;
    }

    modifier whenNotPaused() {
        require(!paused, "PAUSED");
        _;
    }

     // ─── Pause ────────────────────────────────────────────────────────────────
    function pause() external onlyCreditAdmin {
        paused = true;
        emit Paused(msg.sender);
    }

    function unpause() external onlyCreditAdmin {
        paused = false;
        emit Unpaused(msg.sender);
    }

    function lockAmount(address user, uint256 amount) external onlyAuthorized {
        require(user != address(0), "Invalid user");
        uint256 available = getAvailableBalance(user);
        require(available >= amount, "Insufficient available");
        uint256 oldlock = cardBalances[user].locked;
        cardBalances[user].locked += amount;

        emit AmountLocked(user,available, oldlock,amount);
    }

    function blockCard(address user) external onlyAuthorized {
        require(user != address(0), "Invalid address");
        cardBalances[user].blocked = true;
        emit CardBlocked(user);
    }
    function _unblockCard(address user) internal {
        require(user != address(0), "Invalid address");
        cardBalances[user].blocked = false;
        emit CardUnBlocked(user);
    }

    function unlockAmount(address user, uint256 amount) external onlyAuthorized {
        require(user != address(0), "Invalid user");
        require(cardBalances[user].locked >= amount, "Too much unlock");
        cardBalances[user].locked -= amount;
    }

    function getAvailableBalance(address user) public view returns (uint256) {
        CardBalance memory b = cardBalances[user];

        if (b.cardType == CardType.PREPAID) {
            if (b.collateral < b.locked) return 0;
            return b.collateral - b.locked;
        }

        uint256 total = b.collateral + b.creditLimit;

        if (total < b.locked) return 0;
        return total - b.locked;
    }

    function _checkUserInvariant(address user) internal view {
        CardBalance memory b = cardBalances[user];

        if (b.cardType == CardType.PREPAID) {
            require(b.locked <= b.collateral, "prepaid balance overdrawn");
        } else {
            require(b.debt + b.locked <= b.collateral + b.creditLimit,"Insufficient credit limit");
        }
    }

    function _getHealthFactor(address user) internal view returns (uint256) {
        CardBalance memory b = cardBalances[user];
        if (b.locked == 0) return type(uint256).max;
        return ((b.collateral + b.creditLimit) * BPS) / b.locked;
    }

    function getHealthFactor(address user) external view returns (uint256) {
       return _getHealthFactor(user);
    }

    function getCardBalance(address user) external view returns (uint256,uint256,uint256) {
        return (cardBalances[user].collateral,cardBalances[user].locked, cardBalances[user].creditLimit);
    }
    
    function _exposureCheck(address user, uint256 amount) internal view {
        CardBalance memory b = cardBalances[user];
        // total exposure after operation
        uint256 newExposure = b.debt + b.locked + amount;
        require(newExposure <= b.collateral + b.creditLimit,"INSUFFICIENT_BUYING_POWER");
    }

    function authorizeCard(address user, uint256 amount, bytes32 refNo) external whenNotPaused nonReentrant onlyCardProcessor {
        require(user != address(0), "Invalid user");
        require(getAvailableBalance(user) >= amount, "Insufficient balance");
        if (b.cardType == CardType.PREPAID) {
           require(b.collateral - b.locked >= amount, "Insufficient prepaid");
        }
        require(transactionRefUsed[refNo] == false, "TRANSACTION_REF_USED");
        _exposureCheck(user,amount);

        transactions[refNo] = Transaction({
            user:    user,
            amount:    amount,
            status:    TxStatus.AUTHORIZED,
            refNo:     refNo
        });
        
        transactionRefUsed[refNo] = true;
        cardBalances[user].locked += amount;
        _checkUserInvariant(user);
        emit AuthorizeCharge(user,amount,refNo,TxStatus.AUTHORIZED);
     
    }

    function captureCharge(bytes32 refNo) external whenNotPaused nonReentrant onlyCardProcessor {
      require(transactionRefUsed[refNo] == true, "TRANSACTION_REF_INVALID");

      Transaction storage txLog = transactions[refNo];
      require(txLog.status == TxStatus.AUTHORIZED, "Invalid");
      require(cardBalances[txLog.user].locked >= txLog.amount,"locked amount going to negative");
      txLog.status = TxStatus.CAPTURED;

      CardBalance storage b = cardBalances[txLog.user];
      cardBalances[txLog.user].locked -= txLog.amount;
      cardBalances[user].debt += amount;
      _checkUserInvariant(txLog.user);
      emit CaptureCharged(txLog.user,txLog.amount,txLog.refNo,txLog.status);
     
    }

    function voidCharge(bytes32 refNo) external whenNotPaused nonReentrant onlyCardProcessor {
      require(transactionRefUsed[refNo] == true, "TRANSACTION_REF_INVALID");

      Transaction storage txLog = transactions[refNo];
      require(txLog.status == TxStatus.AUTHORIZED, "only authorized can be voided");
      CardBalance storage b = cardBalances[txLog.user];
      require(b.debt >= txLog.amount, "Debt underflow");
      txLog.status = TxStatus.VOIDED;
      b.debt -= txLog.amount;
      _checkUserInvariant(txLog.user);
      emit VoidCharged(txLog.user,txLog.amount,txLog.refNo,txLog.status);
     
    }

    function _refundCharge(bytes32 refNo) internal {
      require(transactionRefUsed[refNo] == true, "TRANSACTION_REF_INVALID");

      Transaction storage txLog = transactions[refNo];
      require(txLog.status == TxStatus.CAPTURED, "Invalid");
      CardBalance storage b = cardBalances[txLog.user];
      require(b.debt >= txLog.amount, "DEBT_UNDERFLOW");

      txLog.status = TxStatus.REFUNDED;
      b.debt -= txLog.amount;
      _checkUserInvariant(txLog.user);
      emit RefundCharged(txLog.user,txLog.amount,txLog.refNo,txLog.status);
     
    }

    function proposeAdminAction(
        AdminAction action,
        address user,
        uint256 amount
    ) external onlyCreditAdmin returns (bytes32) {

        require(isAdmin[msg.sender], "Not admin");
        require(user != address(0), "Invalid user");
        bytes memory data = abi.encode(action, user, amount,bytes32(0));
        proposalNonce++;
        bytes32 proposalId = keccak256(
            abi.encode(action, user, amount, block.timestamp,proposalNonce)
        );
        _proposeAction(proposalId, data,action,user);
        return proposalId;
    }

    function _proposeAction(bytes32 proposalId,bytes memory data,AdminAction action,address user)
    {
        
        //require(proposalPosition[proposalId] == 0, "Proposal already exists");
        
        require(proposals[proposalId].createdAt == 0, "Proposal Id already exists");
        bytes32 existing = activeProposal[user];
        require(existing == bytes32(0) || proposals[existing].executed,"Active proposal exists");

        proposals[proposalId] = Proposal({
            target: address(this),
            data: data,
            approvals: 0,
            executed: false,
            createdAt: block.timestamp,
            expiresAt: block.timestamp + PROPOSAL_TTL
        });

        proposalIndex.push(proposalId);
        proposalPosition[proposalId] = proposalIndex.length; 
        activeProposal[user] = proposalId;
        emit ProposalSubmitted(proposalId,user,action,data);
    }

    function approve(bytes32 proposalId) external onlyCreditAdmin {
        require(isAdmin[msg.sender], "Not admin");

        Proposal storage p = proposals[proposalId];

        require(p.target != address(0), "Invalid proposal");
        require(!p.executed, "Already executed");
        require(!approvedBy[proposalId][msg.sender], "Already approved");
        require(block.timestamp <= p.expiresAt, "Proposal expired");

        // record approval
        approvedBy[proposalId][msg.sender] = true;
        p.approvals += 1;

        emit ProposalApproved(proposalId, msg.sender, p.approvals);

        // ✅ Optional: auto-execute when threshold reached
        if (p.approvals >= requiredApprovals) {
            _execute(proposalId);
        }
    }

    function execute(bytes32 proposalId) external whenNotPaused nonReentrant onlyCreditAdmin 
    {
        _execute(proposalId);
    }

    function _execute(bytes32 proposalId) internal {
        Proposal storage p = proposals[proposalId];

        require(p.target != address(0), "Invalid proposal");
        require(!p.executed, "Already executed");
        require(block.timestamp <= p.expiresAt, "Proposal expired");
        require(p.approvals >= requiredApprovals, "Not enough approvals");

        p.executed = true;

        (AdminAction action, address user, uint256 amount, bytes32 refNo) =
                abi.decode(p.data, (AdminAction, address, uint256,bytes32));

        if (action == AdminAction.REFUND) {
            _refundCharge(refNo);
            // optional: fetch user for event
            user = transactions[refNo].user;
            amount = transactions[refNo].amount;

        } else {
           
            if (action == AdminAction.INCREASE_CREDIT_LIMIT) {
                _increaseCreditLimit(user, amount);

            } else if (action == AdminAction.APPROVE_WITHDRAWAL) {
                _approveWithdrawal(user, amount);
                withdrawals[proposalId].executed = true;
                activeWithdrawal[user] = bytes32(0);

            } else if (action == AdminAction.UNBLOCK_CARD) {
                _unblockCard(user);

            } else if (action == AdminAction.SET_FEE_WALLET) {
                _setFeeWallet(user);

            } else if (action == AdminAction.SET_SETTLEMENT_WALLET) {
                _setSettlementWallet(user);

            } else {
                revert("Invalid action");
            }
        }

        // clear active proposal (only if user is valid)
        if (user != address(0)) {
            activeProposal[user] = bytes32(0);
        }

        emit ProposalExecuted(proposalId, user, action, amount);
    }

    function cancelProposal(bytes32 proposalId) external nonReentrant onlyCreditAdmin {
        Proposal storage p = proposals[proposalId];
        require(!p.executed, "Already executed");
        require(block.timestamp > p.expiresAt, "Not expired");
        p.executed = true; // mark as dead

        (AdminAction action, address user, uint256 amount,refNo) =
            abi.decode(p.data, (AdminAction, address, uint256,bytes32));

        if(action == AdminAction.APPROVE_WITHDRAWAL)
        {
            WithdrawalRequest storage w = withdrawals[proposalId];

            if (w.user != address(0) && !w.executed) {
                w.cancelled = true;
                // 🔓 RELEASE LOCK
                if(cardBalances[w.user].locked >= w.amount)
                    cardBalances[w.user].locked -= w.amount;
              
            }
            activeWithdrawal[user] = bytes32(0);
        }
        activeProposal[user] = bytes32(0);

        emit ProposalCancelled(proposalId);
    }

    function _setCardProcessor(address newProcessor) internal {
        require(newProcessor != address(0), "Invalid address");
        address oldProcessor = cardProcessor;
        cardProcessor = newProcessor;
        emit CardProcessorChanged(oldProcessor,newProcessor);
    }

    function _increaseCreditLimit(address user, uint256 newLimit) internal {
        require(newLimit > cardBalances[user].creditLimit, "Must increase");
        uint256 oldLimit = cardBalances[user].creditLimit;
        cardBalances[user].creditLimit = newLimit;
        totalCreditLimit += (newLimit - oldLimit);
        emit CreditLimitIncrease(user,oldLimit,newLimit);
    }

    function _approveWithdrawal(address user, uint256 amount) internal {
        uint256 available = getAvailableBalance(user);
        require(amount <= available, "exceed available balance");
        //require(isAdmin[msg.sender],"Not admin");
        require(cardBalances[user].locked >= amount, "Locked insufficient");
        require(cardBalances[user].collateral >= amount, "Total insufficient");

        // allow override using credit or locked funds
        
        cardBalances[user].collateral -= amount;
        cardBalances[user].locked -= amount;
        _checkUserInvariant(user);
        IERC20(address(token)).safeTransfer(user,amount);
        emit WithdrawalApproved(user,available,amount);
    }
    

    function initiateWithdrawal(uint256 amount) external whenNotPaused nonReentrant returns (bytes32) {
        require(getAvailableBalance(msg.sender) >= amount, "Insufficient balance");
        require(!cardBalances[msg.sender].blocked, "User Card is blocked");
        require(!isAdmin[msg.sender] && msg.sender != cardProcessor,"Not Allowed");

        // ✅ check no active withdrawal
        //bytes32 existing = activeWithdrawal[msg.sender];
        //require(existing == bytes32(0) || withdrawals[existing].executed,"Active withdrawal exists");
        
        bytes32 existing = activeProposal[msg.sender];
        require(existing == bytes32(0) || proposals[existing].executed,"Active proposal exists");

        // lock funds immediately
        cardBalances[msg.sender].locked += amount;
        //bytes32 requestId = keccak256(abi.encode(msg.sender, amount, block.timestamp));
        bytes memory data = abi.encode(AdminAction.APPROVE_WITHDRAWAL, msg.sender, amount,bytes32(0));
        proposalNonce++;
        bytes32 proposalId = keccak256(
                    abi.encode(AdminAction.APPROVE_WITHDRAWAL, msg.sender, amount, block.timestamp,proposalNonce)
                );
        withdrawals[proposalId] = WithdrawalRequest({
            user: msg.sender,
            amount: amount,
            approved: false,
            executed: false,
            cancelled: false
        });
        userWithdrawals[msg.sender].push(proposalId);
        activeWithdrawal[msg.sender] = proposalId;
        emit WithdrawalInitiated(msg.sender,proposalId,amount);
        _proposeAction(proposalId,data,AdminAction.APPROVE_WITHDRAWAL,msg.sender);
        return proposalId;
    }

     function initiateRefund(bytes32 refNo) external onlyCardProcessor {
       
       require(transactionRefUsed[refNo] == true, "TRANSACTION_REF_INVALID");
       Transaction storage txLog = transactions[refNo];
       require(txLog.status == TxStatus.CAPTURED, "Txn not in CAPTURED state");
       bytes32 existing = activeProposal[txLog.user];
       require(existing == bytes32(0) || proposals[existing].executed,"Active proposal exists");

        proposalNonce++;
        bytes32 proposalId = keccak256(
            abi.encode(AdminAction.REFUND, txLog.user, txLog.amount, block.timestamp,proposalNonce)
        );

        bytes memory data = abi.encode(AdminAction.REFUND, txLog.user, txLog.amount,refNo);
        //bytes memory data = abi.encode(AdminAction.REFUND, refNo);
                
        _proposeAction(proposalId,data,AdminAction.REFUND,txLog.user);
        
    }
   

    function deposit(address user, uint256 amount) external whenNotPaused nonReentrant {
        require(user != address(0), "Invalid user");
        require(amount > 0, "Invalid amount");
        IERC20(token).safeTransferFrom(user, address(this), amount);
        CardBalance storage cb = cardBalances[user];
        uint256 oldLimit = cb.creditLimit;

        // 3. Update total collateral
        cb.collateral += amount;
        totalCollateral += amount;
        // 4. Recalculate credit limit based on LTV
        uint256 newCreditLimit = (cb.collateral * LTV) / BPS;
        // 5. Apply new credit limit
        cb.creditLimit = newCreditLimit;
        totalCreditLimit += (newCreditLimit - oldLimit);
        // 6. (Optional safety) ensure locked does not exceed new capacity
        uint256 maxUsable = cb.collateral + cb.creditLimit;
        require(cb.locked <= maxUsable, "Locked exceeds limit");
        emit Deposited(user,amount,newCreditLimit);
    }

    function reclaimExpiredWithdrawal(bytes32 proposalId) external {
        WithdrawalRequest storage w = withdrawals[proposalId];
        Proposal storage p = proposals[proposalId];

        require(w.user == msg.sender, "Not yours");
        require(!w.executed && !w.cancelled, "Already done");
        require(block.timestamp > p.expiresAt, "Not expired");

        w.cancelled = true;

        cardBalances[msg.sender].locked -= w.amount;

        activeProposal[msg.sender] = bytes32(0);
        activeWithdrawal[msg.sender] = bytes32(0);
    }

    function postFee(address user, uint256 amount) external onlyAuthorized nonReentrant {
        CardBalance storage b = cardBalances[user];

        require(amount > 0, "ZERO");
        require(feeWallet != address(0) = "zero fee address");
        require(b.collateral >= amount, "INSUFFICIENT_COLLATERAL");


        b.collateral -= amount;
        totalCollateral -= amount;

        IERC20(token).safeTransfer(feeWallet, amount);

        _checkUserInvariant(user);
        emit FeePosted(user,amount);
    }

    function fundVault(uint256 amount) external {
        IERC20(token).safeTransferFrom(msg.sender, address(this), amount);
        emit VaultFunded(msg.sender,amount);
    }

    function _setFeeWallet(address wallet) internal {
       require(wallet != address(0) = "zero fee address");
       feeWallet = wallet;
       emit FeeWalletChanged(wallet);
    }

    function _setSettlementWallet(address wallet) internal {
       require(wallet != address(0) = "zero settlement address");
       settlementWallet = wallet;
       emit SettlementWalletChanged(wallet);
    }
   



}

    
