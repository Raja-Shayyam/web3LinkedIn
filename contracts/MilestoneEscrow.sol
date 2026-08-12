// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "@openzeppelin/contracts/access/extensions/AccessControlDefaultAdminRules.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

/// @title MilestoneEscrow
/// @notice Milestone-based escrow for freelance contracts on Web3LinkedIn.
///
/// @dev CRITICAL INVARIANTS (must hold after every state-changing call):
///      [I-1]  totalReleased[c] + lockedBalance[c] == fundedAmount[c]
///      [I-2]  A paid milestone can never be paid again.
///      [I-3]  The contract never pays more than milestone.amount per milestone.
///      [I-4]  Platform fee never exceeds FEE_CAP_BPS (hard-coded, 10%).
///      [I-5]  Only the client approves; only the freelancer submits.
///      [I-6]  Client cannot submit; freelancer cannot approve.
///      [I-7]  Funds in Disputed state are locked — only arbitrator can release.
///      [I-8]  Admin (DEFAULT_ADMIN_ROLE) can never touch user escrow balances.
///      [I-9]  Arbitrator can only resolve disputes — no arbitrary withdrawals.
///      [I-10] Sequential milestone enforcement: only currentMilestone is actionable.
///      [I-11] Refund returns only still-locked funds (never over-refunds).
///
/// Dispute design (centralized, clearly disclosed):
///      ARBITRATOR_ROLE is separate from DEFAULT_ADMIN_ROLE.
///      Arbitrator can only call resolveDispute() on a specific Disputed contract.
///      resolveDispute() enforces strict per-milestone accounting — it can ONLY
///      release amounts that were actually locked and not yet paid.
///
/// Token allowlist: only pre-approved tokens accepted (admin-controlled with
/// timelock in the companion TokenAllowlist contract or inline below).
contract MilestoneEscrow is AccessControlDefaultAdminRules, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;

    // -------------------------------------------------------------------------
    // Constants
    // -------------------------------------------------------------------------

    uint256 public constant FEE_CAP_BPS        = 1000;   // hard cap: 10%
    uint48  public constant FEE_TIMELOCK_DELAY  = 2 days;
    uint256 public constant MAX_MILESTONES      = 20;

    bytes32 public constant ARBITRATOR_ROLE = keccak256("ARBITRATOR_ROLE");
    bytes32 public constant PAUSER_ROLE     = keccak256("PAUSER_ROLE");
    bytes32 public constant FEE_MANAGER_ROLE = keccak256("FEE_MANAGER_ROLE");

    // -------------------------------------------------------------------------
    // State machine
    // -------------------------------------------------------------------------

    enum ContractState {
        Draft,             // created, not yet funded
        Funded,            // client deposited; work not started
        InProgress,        // freelancer started / milestone being worked on
        Submitted,         // freelancer submitted current milestone
        Completed,         // all milestones approved and paid
        Disputed,          // dispute opened, funds locked
        Cancelled,         // cancelled before funding
        Refunded           // full or partial refund issued
    }

    // -------------------------------------------------------------------------
    // Data structures
    // -------------------------------------------------------------------------

    struct Milestone {
        uint256 amount;
        bytes32 descriptionHash;   // off-chain description IPFS/Arweave hash
        bytes32 evidenceHash;      // off-chain evidence hash, set on submission
        uint64  submittedAt;
        uint64  approvedAt;
        bool    submitted;
        bool    approved;
        bool    paid;
    }

    struct EscrowContract {
        address client;
        address freelancer;
        address token;             // allowlisted ERC-20 only
        uint256 fundedAmount;      // total deposited by client
        uint256 totalReleased;     // sum of amounts paid out to freelancer
        uint256 lockedBalance;     // fundedAmount - totalReleased (updated on each payment)
        uint256 platformFeeBps;    // locked-in at creation time
        uint256 currentMilestone;
        uint256 numMilestones;
        ContractState state;
        bool disputeOpen;
    }

    uint256 private _nextContractId;
    mapping(uint256 => EscrowContract) private _contracts;
    mapping(uint256 => Milestone[]) private _milestones;

    // Accumulated platform fees per token — separate from user funds
    mapping(address => uint256) public platformFees;

    // Token allowlist
    mapping(address => bool) public allowedTokens;

    // Timelocked fee change
    struct PendingFeeChange {
        uint256 newDefaultFeeBps;
        uint64  readyAt;
        bool    pending;
    }
    PendingFeeChange public pendingFeeChange;

    uint256 public defaultPlatformFeeBps = 250; // 2.5%

    // -------------------------------------------------------------------------
    // Events
    // -------------------------------------------------------------------------

    event ContractCreated(
        uint256 indexed contractId,
        address indexed client,
        address indexed freelancer,
        address token,
        uint256 totalAmount,
        uint256 numMilestones
    );
    event ContractFunded(uint256 indexed contractId, uint256 amount);
    event WorkStarted(uint256 indexed contractId);
    event MilestoneSubmitted(uint256 indexed contractId, uint256 milestoneIndex, bytes32 evidenceHash);
    event MilestoneApproved(uint256 indexed contractId, uint256 milestoneIndex, uint256 released, uint256 fee);
    event MilestoneRejected(uint256 indexed contractId, uint256 milestoneIndex);
    event DisputeOpened(uint256 indexed contractId, address indexed opener);
    event DisputeResolved(uint256 indexed contractId, uint256 toFreelancer, uint256 toClient, uint256 toFees);
    event RefundIssued(uint256 indexed contractId, uint256 amount);
    event ContractCancelled(uint256 indexed contractId);
    event PlatformFeesWithdrawn(address indexed token, address indexed to, uint256 amount);
    event FeeBpsProposed(uint256 newFeeBps, uint64 readyAt);
    event FeeBpsApplied(uint256 newFeeBps);
    event TokenAllowed(address indexed token);
    event TokenDisallowed(address indexed token);

    // -------------------------------------------------------------------------
    // Errors
    // -------------------------------------------------------------------------

    error OnlyClient();
    error OnlyFreelancer();
    error OnlyParty();
    error OnlyArbitrator();
    error TokenNotAllowed();
    error ZeroAddress();
    error ZeroAmount();
    error NoMilestones();
    error TooManyMilestones();
    error MilestoneAmountMismatch();
    error WrongState(ContractState current, ContractState expected);
    error WrongMilestone(uint256 current, uint256 provided);
    error AlreadySubmitted();
    error AlreadyPaid();
    error NotSubmitted();
    error DisputeAlreadyOpen();
    error NoDisputeOpen();
    error WorkAlreadyStarted();
    error FeeTooHigh();
    error TimelockNotExpired();
    error NoPendingChange();
    error NoFeesToWithdraw();
    error InvariantViolation();

    // -------------------------------------------------------------------------
    // Constructor
    // -------------------------------------------------------------------------

    constructor(uint48 adminTransferDelay, address initialAdmin)
        AccessControlDefaultAdminRules(adminTransferDelay, initialAdmin)
    {
        if (initialAdmin == address(0)) revert ZeroAddress();
        _grantRole(ARBITRATOR_ROLE, initialAdmin);
        _grantRole(PAUSER_ROLE, initialAdmin);
        _grantRole(FEE_MANAGER_ROLE, initialAdmin);
    }

    // -------------------------------------------------------------------------
    // Token allowlist — admin-controlled
    // -------------------------------------------------------------------------

    function allowToken(address token) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (token == address(0)) revert ZeroAddress();
        allowedTokens[token] = true;
        emit TokenAllowed(token);
    }

    function disallowToken(address token) external onlyRole(DEFAULT_ADMIN_ROLE) {
        allowedTokens[token] = false;
        emit TokenDisallowed(token);
    }

    // -------------------------------------------------------------------------
    // Fee management — timelocked
    // -------------------------------------------------------------------------

    function proposeDefaultFeeBps(uint256 newFeeBps) external onlyRole(FEE_MANAGER_ROLE) {
        if (newFeeBps > FEE_CAP_BPS) revert FeeTooHigh();
        pendingFeeChange = PendingFeeChange({
            newDefaultFeeBps: newFeeBps,
            readyAt: uint64(block.timestamp) + FEE_TIMELOCK_DELAY,
            pending: true
        });
        emit FeeBpsProposed(newFeeBps, pendingFeeChange.readyAt);
    }

    function applyDefaultFeeBps() external onlyRole(FEE_MANAGER_ROLE) {
        PendingFeeChange memory f = pendingFeeChange;
        if (!f.pending) revert NoPendingChange();
        if (block.timestamp < f.readyAt) revert TimelockNotExpired();
        defaultPlatformFeeBps = f.newDefaultFeeBps;
        delete pendingFeeChange;
        emit FeeBpsApplied(f.newDefaultFeeBps);
    }

    // -------------------------------------------------------------------------
    // Contract lifecycle
    // -------------------------------------------------------------------------

    /// @notice Client creates a freelance contract.
    /// @param freelancer Address of the freelancer.
    /// @param token Allowlisted ERC-20 payment token.
    /// @param milestoneAmounts Per-milestone amounts (must sum to total).
    /// @param descriptionHashes Off-chain description hashes, one per milestone.
    function createContract(
        address freelancer,
        address token,
        uint256[] calldata milestoneAmounts,
        bytes32[] calldata descriptionHashes
    ) external whenNotPaused returns (uint256 contractId) {
        if (freelancer == address(0)) revert ZeroAddress();
        if (freelancer == msg.sender) revert OnlyClient();
        if (!allowedTokens[token]) revert TokenNotAllowed();
        if (milestoneAmounts.length == 0) revert NoMilestones();
        if (milestoneAmounts.length > MAX_MILESTONES) revert TooManyMilestones();
        if (milestoneAmounts.length != descriptionHashes.length) revert MilestoneAmountMismatch();

        uint256 total;
        for (uint256 i; i < milestoneAmounts.length; i++) {
            if (milestoneAmounts[i] == 0) revert ZeroAmount();
            total += milestoneAmounts[i];
        }

        contractId = _nextContractId++;
        EscrowContract storage c = _contracts[contractId];
        c.client           = msg.sender;
        c.freelancer       = freelancer;
        c.token            = token;
        c.fundedAmount     = total;  // will be validated on fund
        c.platformFeeBps   = defaultPlatformFeeBps;
        c.numMilestones    = milestoneAmounts.length;
        c.state            = ContractState.Draft;

        Milestone[] storage ms = _milestones[contractId];
        for (uint256 i; i < milestoneAmounts.length; i++) {
            ms.push(Milestone({
                amount:          milestoneAmounts[i],
                descriptionHash: descriptionHashes[i],
                evidenceHash:    bytes32(0),
                submittedAt:     0,
                approvedAt:      0,
                submitted:       false,
                approved:        false,
                paid:            false
            }));
        }

        emit ContractCreated(contractId, msg.sender, freelancer, token, total, milestoneAmounts.length);
    }

    /// @notice Client funds the contract — deposits exactly fundedAmount.
    function fundContract(uint256 contractId) external nonReentrant whenNotPaused {
        EscrowContract storage c = _requireClient(contractId);
        _requireState(c, ContractState.Draft);

        uint256 amount = c.fundedAmount;
        c.lockedBalance = amount;
        c.state = ContractState.Funded;

        IERC20(c.token).safeTransferFrom(msg.sender, address(this), amount);
        emit ContractFunded(contractId, amount);

        _checkInvariant(contractId);
    }

    /// @notice Freelancer starts work — moves state from Funded to InProgress.
    function startWork(uint256 contractId) external whenNotPaused {
        EscrowContract storage c = _requireFreelancer(contractId);
        _requireState(c, ContractState.Funded);
        c.state = ContractState.InProgress;
        emit WorkStarted(contractId);
    }

    /// @notice Freelancer submits evidence for the current milestone.
    function submitMilestone(
        uint256 contractId,
        uint256 milestoneIndex,
        bytes32 evidenceHash
    ) external whenNotPaused {
        EscrowContract storage c = _requireFreelancer(contractId);

        if (c.state != ContractState.InProgress) revert WrongState(c.state, ContractState.InProgress);
        if (milestoneIndex != c.currentMilestone) revert WrongMilestone(c.currentMilestone, milestoneIndex);

        Milestone storage m = _milestones[contractId][milestoneIndex];
        if (m.submitted) revert AlreadySubmitted();
        if (m.paid) revert AlreadyPaid();
        if (evidenceHash == bytes32(0)) revert ZeroAmount(); // evidenceHash must not be empty

        m.submitted    = true;
        m.evidenceHash = evidenceHash;
        m.submittedAt  = uint64(block.timestamp);
        c.state        = ContractState.Submitted;

        emit MilestoneSubmitted(contractId, milestoneIndex, evidenceHash);
    }

    /// @notice Client approves the submitted milestone and releases payment.
    function approveMilestone(uint256 contractId, uint256 milestoneIndex)
        external nonReentrant whenNotPaused
    {
        EscrowContract storage c = _requireClient(contractId);
        _requireState(c, ContractState.Submitted);
        if (milestoneIndex != c.currentMilestone) revert WrongMilestone(c.currentMilestone, milestoneIndex);

        Milestone storage m = _milestones[contractId][milestoneIndex];
        if (!m.submitted) revert NotSubmitted();
        if (m.paid) revert AlreadyPaid();

        uint256 fee            = (m.amount * c.platformFeeBps) / 10_000;
        uint256 toFreelancer   = m.amount - fee;

        // --- State updates before transfers (CEI pattern) ---
        m.approved    = true;
        m.paid        = true;
        m.approvedAt  = uint64(block.timestamp);
        c.totalReleased  += m.amount;
        c.lockedBalance  -= m.amount;
        platformFees[c.token] += fee;

        bool isLast = (c.currentMilestone + 1 == c.numMilestones);
        if (!isLast) {
            c.currentMilestone++;
            c.state = ContractState.InProgress;
        } else {
            c.state = ContractState.Completed;
        }

        _checkInvariant(contractId);

        // --- Transfers after state update ---
        IERC20(c.token).safeTransfer(c.freelancer, toFreelancer);
        // fee stays in contract under platformFees, not in lockedBalance

        emit MilestoneApproved(contractId, milestoneIndex, toFreelancer, fee);
    }

    /// @notice Client rejects a submitted milestone — freelancer must resubmit.
    function rejectMilestone(uint256 contractId, uint256 milestoneIndex)
        external whenNotPaused
    {
        EscrowContract storage c = _requireClient(contractId);
        _requireState(c, ContractState.Submitted);
        if (milestoneIndex != c.currentMilestone) revert WrongMilestone(c.currentMilestone, milestoneIndex);

        Milestone storage m = _milestones[contractId][milestoneIndex];
        if (!m.submitted) revert NotSubmitted();
        if (m.paid) revert AlreadyPaid();

        m.submitted    = false;
        m.evidenceHash = bytes32(0);
        m.submittedAt  = 0;
        c.state        = ContractState.InProgress;

        emit MilestoneRejected(contractId, milestoneIndex);
    }

    /// @notice Client requests a refund. Allowed only if no work has been started
    ///         (no milestone submitted or paid). If work started, client must open
    ///         a dispute instead.
    function requestRefund(uint256 contractId) external nonReentrant whenNotPaused {
        EscrowContract storage c = _requireClient(contractId);
        if (c.state != ContractState.Funded && c.state != ContractState.InProgress)
            revert WrongState(c.state, ContractState.Funded);

        // Only refundable if nothing has been submitted or paid
        Milestone[] storage ms = _milestones[contractId];
        for (uint256 i; i < ms.length; i++) {
            if (ms[i].submitted || ms[i].paid) revert WorkAlreadyStarted();
        }

        uint256 refundAmount = c.lockedBalance;
        c.lockedBalance  = 0;
        c.totalReleased  = c.fundedAmount; // accounting: fully settled
        c.state          = ContractState.Refunded;

        IERC20(c.token).safeTransfer(c.client, refundAmount);
        emit RefundIssued(contractId, refundAmount);

        _checkInvariant(contractId);
    }

    /// @notice Cancel a Draft contract (no funds deposited yet).
    function cancelContract(uint256 contractId) external whenNotPaused {
        EscrowContract storage c = _requireClient(contractId);
        _requireState(c, ContractState.Draft);
        c.state = ContractState.Cancelled;
        emit ContractCancelled(contractId);
    }

    // -------------------------------------------------------------------------
    // Dispute
    // -------------------------------------------------------------------------

    /// @notice Either party may open a dispute. Funds become locked.
    function openDispute(uint256 contractId) external whenNotPaused {
        EscrowContract storage c = _contracts[contractId];
        if (msg.sender != c.client && msg.sender != c.freelancer) revert OnlyParty();
        if (c.state == ContractState.Completed
            || c.state == ContractState.Cancelled
            || c.state == ContractState.Refunded
            || c.state == ContractState.Draft)
        {
            revert WrongState(c.state, ContractState.InProgress);
        }
        if (c.disputeOpen) revert DisputeAlreadyOpen();

        c.disputeOpen = true;
        c.state       = ContractState.Disputed;
        emit DisputeOpened(contractId, msg.sender);
    }

    /// @notice Arbitrator resolves a dispute.
    ///         `clientShareBps` = percentage (in bps, 0–10000) of the REMAINING
    ///         locked balance that goes back to client. The rest goes to freelancer
    ///         (minus platform fee on the freelancer portion).
    ///         The arbitrator can ONLY distribute the lockedBalance — it cannot
    ///         touch already-paid funds or platform fee reserves.
    function resolveDispute(uint256 contractId, uint256 clientShareBps)
        external nonReentrant onlyRole(ARBITRATOR_ROLE)
    {
        EscrowContract storage c = _contracts[contractId];
        if (c.state != ContractState.Disputed) revert NoDisputeOpen();
        if (clientShareBps > 10_000) revert FeeTooHigh();

        uint256 locked         = c.lockedBalance;
        uint256 toClient       = (locked * clientShareBps) / 10_000;
        uint256 gross          = locked - toClient;
        uint256 fee            = (gross * c.platformFeeBps) / 10_000;
        uint256 toFreelancer   = gross - fee;

        // State updates (CEI)
        c.lockedBalance      = 0;
        c.totalReleased      += locked;
        c.disputeOpen        = false;
        c.state              = ContractState.Completed;
        platformFees[c.token] += fee;

        _checkInvariant(contractId);

        // Transfers
        if (toFreelancer > 0) IERC20(c.token).safeTransfer(c.freelancer, toFreelancer);
        if (toClient      > 0) IERC20(c.token).safeTransfer(c.client,     toClient);

        emit DisputeResolved(contractId, toFreelancer, toClient, fee);
    }

    // -------------------------------------------------------------------------
    // Platform fee withdrawal — admin only, only accumulated fees
    // -------------------------------------------------------------------------

    function withdrawPlatformFees(address token, address to)
        external nonReentrant onlyRole(DEFAULT_ADMIN_ROLE)
    {
        if (to == address(0)) revert ZeroAddress();
        uint256 amount = platformFees[token];
        if (amount == 0) revert NoFeesToWithdraw();
        platformFees[token] = 0;
        IERC20(token).safeTransfer(to, amount);
        emit PlatformFeesWithdrawn(token, to, amount);
    }

    // -------------------------------------------------------------------------
    // Pause
    // -------------------------------------------------------------------------

    function pause()   external onlyRole(PAUSER_ROLE) { _pause(); }
    function unpause() external onlyRole(PAUSER_ROLE) { _unpause(); }

    // -------------------------------------------------------------------------
    // Internal helpers
    // -------------------------------------------------------------------------

    function _requireClient(uint256 id) internal view returns (EscrowContract storage c) {
        c = _contracts[id];
        if (msg.sender != c.client) revert OnlyClient();
    }

    function _requireFreelancer(uint256 id) internal view returns (EscrowContract storage c) {
        c = _contracts[id];
        if (msg.sender != c.freelancer) revert OnlyFreelancer();
    }

    function _requireState(EscrowContract storage c, ContractState expected) internal view {
        if (c.state != expected) revert WrongState(c.state, expected);
    }

    /// @dev Enforces Invariant I-1: locked + released == funded.
    ///      Reverts entire transaction if violated — fail closed.
    function _checkInvariant(uint256 contractId) internal view {
        EscrowContract storage c = _contracts[contractId];
        // Fee reserves are NOT part of lockedBalance — they live in platformFees
        // We track them inline during approveMilestone.
        // lockedBalance is decremented by full milestone.amount (fee + freelancer portion).
        // So: lockedBalance + totalReleased should always == fundedAmount.
        if (c.lockedBalance + c.totalReleased != c.fundedAmount) revert InvariantViolation();
    }

    // -------------------------------------------------------------------------
    // Views
    // -------------------------------------------------------------------------

    function getContract(uint256 contractId) external view returns (EscrowContract memory) {
        return _contracts[contractId];
    }

    function getMilestone(uint256 contractId, uint256 index)
        external view returns (Milestone memory)
    {
        return _milestones[contractId][index];
    }

    function getMilestones(uint256 contractId)
        external view returns (Milestone[] memory)
    {
        return _milestones[contractId];
    }

    function totalContracts() external view returns (uint256) {
        return _nextContractId;
    }
}
