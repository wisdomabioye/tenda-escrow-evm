// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {Address} from "openzeppelin-contracts/contracts/utils/Address.sol";
import {ReentrancyGuard} from "openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";

/// @title TendaEscrow — chain-agnostic escrow primitive (EVM mirror)
/// @notice Mirrors the Solana Anchor program 1:1 (stage-3-base.md):
///         same status machine, deadlines, fee math, dispute-bond flow and
///         event vocabulary. One deliberate divergence: `raisedBy` is
///         recorded on-chain at dispute time (storage is cheap on EVM), so
///         `resolveDispute` needs no off-chain raiser attestation — the
///         Anchor program passes the raiser as an instruction argument
///         instead.
/// @dev    Funds semantics:
///         - `asset == address(0)` → native (ETH on BASE, CELO on Celo).
///         - otherwise ERC-20 via SafeERC20 (caller approves first).
///         The dispute bond is denominated in the SAME asset as the escrow
///         (exactly like the Anchor vaults).
///
///         AUDIT NOTE (push-payment griefing): native payouts use
///         Address.sendValue, so a contract party that reverts on receive
///         blocks only payouts *to itself* (self-grief). The one shared
///         path is a SPLIT resolution (pays both parties + raiser): if one
///         side refuses ETH the admin resolves to a single-winner outcome
///         instead — every dispute always has at least one executable
///         resolution. Pull-payments were deliberately not introduced
///         pre-audit; revisit with the auditor.
contract TendaEscrow is ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ---------------------------------------------------------------------
    // Types
    // ---------------------------------------------------------------------

    /// @dev Numbering matches the Anchor `EscrowStatus` enum exactly so the
    ///      server adapter shares one wire mapping across chains.
    enum Status {
        Open, // 0
        Accepted, // 1
        Submitted, // 2
        Completed, // 3
        Cancelled, // 4
        Refunded, // 5
        Disputed, // 6
        Resolved // 7
    }

    /// @dev 0=gig, 1=exchange — informational; the server enforces per-kind
    ///      asset policy off-chain (mirrors Anchor).
    uint8 public constant KIND_GIG = 0;
    uint8 public constant KIND_EXCHANGE = 1;

    /// @dev resolveDispute winner encoding (matches Anchor DisputeWinner).
    uint8 public constant WINNER_CREATOR = 0;
    uint8 public constant WINNER_COUNTERPARTY = 1;
    uint8 public constant WINNER_SPLIT = 2;

    struct Escrow {
        bytes16 escrowId;
        uint8 kind;
        address asset;
        uint256 amount;
        address creator;
        address counterparty;
        address assignedCounterparty;
        Status status;
        uint64 acceptDeadline;
        uint64 completionDuration;
        uint64 completionDeadline;
        uint64 approvalDeadline;
        uint256 disputeBond;
        bool isSeeker;
        /// @dev Set by disputeEscrow; consumed by resolveDispute (split
        ///      refunds the bond to the raiser).
        address raisedBy;
    }

    // ---------------------------------------------------------------------
    // Platform parameters (bounds mirror the Anchor constants)
    // ---------------------------------------------------------------------

    uint16 public constant MAX_PLATFORM_FEE_BPS = 1_000;
    uint64 public constant MIN_APPROVAL_WINDOW_SECONDS = 3_600;
    uint64 public constant MAX_APPROVAL_WINDOW_SECONDS = 30 days;
    uint64 public constant MAX_GRACE_PERIOD_SECONDS = 14 days;
    uint64 public constant MIN_COMPLETION_DURATION_SECONDS = 3_600;
    uint64 public constant MAX_COMPLETION_DURATION_SECONDS = 180 days;

    /// @notice Safe 3-of-5 — protocol params, treasury, dispute-admin rotation.
    address public admin;
    /// @notice SEPARATE authority — only signs resolveDispute (decision #17).
    address public disputeAdmin;
    address public treasury;
    uint16 public feeBps;
    uint16 public seekerFeeBps;
    uint64 public approvalWindowSeconds;
    uint64 public gracePeriodSeconds;

    mapping(bytes16 => Escrow) public escrows;

    // ---------------------------------------------------------------------
    // Events (stage-3 spec vocabulary — the listener's standing signals)
    // ---------------------------------------------------------------------

    event EscrowCreated(bytes16 indexed escrowId, address indexed creator, uint8 kind, address asset, uint256 amount);
    event EscrowAccepted(bytes16 indexed escrowId, address indexed counterparty);
    event EscrowDeclined(bytes16 indexed escrowId, address indexed assignedCounterparty);
    event ProofSubmitted(bytes16 indexed escrowId, bytes32 proofHash);
    event EscrowApproved(bytes16 indexed escrowId);
    event PaymentClaimed(bytes16 indexed escrowId, address indexed counterparty);
    event EscrowCancelled(bytes16 indexed escrowId);
    event EscrowExpired(bytes16 indexed escrowId);
    event EscrowAbandoned(bytes16 indexed escrowId, address indexed counterparty);
    event DisputeRaised(bytes16 indexed escrowId, address indexed raisedBy);
    event DisputeResolved(bytes16 indexed escrowId, uint8 winner);
    event PlatformConfigChanged(string parameter, address indexed changedBy);

    // ---------------------------------------------------------------------
    // Errors (typed — mirror the Anchor TendaError vocabulary)
    // ---------------------------------------------------------------------

    error NotAdmin();
    error NotDisputeAdmin();
    error NotCreator();
    error NotCounterparty();
    error NotDisputeParty();
    error NotAssignedCounterparty();
    error CannotAcceptOwnEscrow();
    error EscrowAlreadyExists();
    error EscrowNotFound();
    error InvalidEscrowStatus();
    error InvalidKind();
    error AmountTooLow();
    error AcceptDeadlineInPast();
    error AcceptDeadlinePassed();
    error AcceptDeadlineNotPassed();
    error CompletionDurationOutOfRange();
    error SubmissionWindowClosed();
    error ApprovalDeadlineNotPassed();
    error ReclaimWindowNotOpen();
    error DisputeBondMismatch();
    error InvalidWinner();
    error BadNativeValue();
    error FeeBpsOutOfRange();
    error ApprovalWindowOutOfRange();
    error GracePeriodOutOfRange();
    error ZeroAddress();

    // ---------------------------------------------------------------------
    // Constructor / admin
    // ---------------------------------------------------------------------

    constructor(
        address admin_,
        address disputeAdmin_,
        address treasury_,
        uint16 feeBps_,
        uint16 seekerFeeBps_,
        uint64 approvalWindowSeconds_,
        uint64 gracePeriodSeconds_
    ) {
        if (admin_ == address(0) || disputeAdmin_ == address(0) || treasury_ == address(0)) revert ZeroAddress();
        _validateFeeBps(feeBps_, seekerFeeBps_);
        _validateApprovalWindow(approvalWindowSeconds_);
        _validateGracePeriod(gracePeriodSeconds_);
        admin = admin_;
        disputeAdmin = disputeAdmin_;
        treasury = treasury_;
        feeBps = feeBps_;
        seekerFeeBps = seekerFeeBps_;
        approvalWindowSeconds = approvalWindowSeconds_;
        gracePeriodSeconds = gracePeriodSeconds_;
    }

    modifier onlyAdmin() {
        if (msg.sender != admin) revert NotAdmin();
        _;
    }

    function setProtocolAdmin(address newAdmin) external onlyAdmin {
        if (newAdmin == address(0)) revert ZeroAddress();
        admin = newAdmin;
        emit PlatformConfigChanged("protocol_admin", msg.sender);
    }

    function setDisputeAdmin(address newDisputeAdmin) external onlyAdmin {
        if (newDisputeAdmin == address(0)) revert ZeroAddress();
        disputeAdmin = newDisputeAdmin;
        emit PlatformConfigChanged("dispute_admin", msg.sender);
    }

    function setTreasury(address newTreasury) external onlyAdmin {
        if (newTreasury == address(0)) revert ZeroAddress();
        treasury = newTreasury;
        emit PlatformConfigChanged("treasury", msg.sender);
    }

    function setFeeBps(uint16 newFeeBps, uint16 newSeekerFeeBps) external onlyAdmin {
        _validateFeeBps(newFeeBps, newSeekerFeeBps);
        feeBps = newFeeBps;
        seekerFeeBps = newSeekerFeeBps;
        emit PlatformConfigChanged("fee_bps", msg.sender);
    }

    function setApprovalWindow(uint64 newWindowSeconds) external onlyAdmin {
        _validateApprovalWindow(newWindowSeconds);
        approvalWindowSeconds = newWindowSeconds;
        emit PlatformConfigChanged("approval_window_seconds", msg.sender);
    }

    function setGracePeriod(uint64 newGraceSeconds) external onlyAdmin {
        _validateGracePeriod(newGraceSeconds);
        gracePeriodSeconds = newGraceSeconds;
        emit PlatformConfigChanged("grace_period_seconds", msg.sender);
    }

    // ---------------------------------------------------------------------
    // Lifecycle
    // ---------------------------------------------------------------------

    /// @notice Create and fund an escrow. Native: `msg.value == amount`.
    ///         ERC-20: approve first; the bond (if any) is collected later
    ///         from whoever raises a dispute — exactly like the Anchor
    ///         program (the stage-doc's "amount + disputeBond" at create is
    ///         stale; the payable disputeEscrow below is the live design).
    function createEscrow(
        bytes16 escrowId,
        uint8 kind,
        address asset,
        uint256 amount,
        address assignedCounterparty,
        uint64 acceptDeadline,
        uint64 completionDuration,
        uint256 disputeBond,
        bool isSeeker
    ) external payable nonReentrant {
        if (kind > KIND_EXCHANGE) revert InvalidKind();
        if (amount == 0) revert AmountTooLow();
        if (acceptDeadline <= block.timestamp) revert AcceptDeadlineInPast();
        if (
            completionDuration < MIN_COMPLETION_DURATION_SECONDS
                || completionDuration > MAX_COMPLETION_DURATION_SECONDS
        ) revert CompletionDurationOutOfRange();
        if (escrows[escrowId].creator != address(0)) revert EscrowAlreadyExists();

        _collect(asset, amount);

        escrows[escrowId] = Escrow({
            escrowId: escrowId,
            kind: kind,
            asset: asset,
            amount: amount,
            creator: msg.sender,
            counterparty: address(0),
            assignedCounterparty: assignedCounterparty,
            status: Status.Open,
            acceptDeadline: acceptDeadline,
            completionDuration: completionDuration,
            completionDeadline: 0,
            approvalDeadline: 0,
            disputeBond: disputeBond,
            isSeeker: isSeeker,
            raisedBy: address(0)
        });

        emit EscrowCreated(escrowId, msg.sender, kind, asset, amount);
    }

    function acceptEscrow(bytes16 escrowId) external nonReentrant {
        Escrow storage e = _mustExist(escrowId);
        if (e.status != Status.Open) revert InvalidEscrowStatus();
        if (msg.sender == e.creator) revert CannotAcceptOwnEscrow();
        if (block.timestamp >= e.acceptDeadline) revert AcceptDeadlinePassed();
        if (e.assignedCounterparty != address(0) && msg.sender != e.assignedCounterparty) {
            revert NotAssignedCounterparty();
        }

        e.counterparty = msg.sender;
        e.status = Status.Accepted;
        e.completionDeadline = uint64(block.timestamp) + e.completionDuration;

        emit EscrowAccepted(escrowId, msg.sender);
    }

    function declineAssignedEscrow(bytes16 escrowId) external nonReentrant {
        Escrow storage e = _mustExist(escrowId);
        if (e.status != Status.Open) revert InvalidEscrowStatus();
        if (e.assignedCounterparty == address(0)) revert NotAssignedCounterparty();
        if (msg.sender != e.assignedCounterparty) revert NotAssignedCounterparty();

        e.assignedCounterparty = address(0);
        // Status STAYS Open; funds stay escrowed; gig becomes public.
        emit EscrowDeclined(escrowId, msg.sender);
    }

    function submitProof(bytes16 escrowId, bytes32 proofHash) external nonReentrant {
        Escrow storage e = _mustExist(escrowId);
        if (e.status != Status.Accepted) revert InvalidEscrowStatus();
        if (msg.sender != e.counterparty) revert NotCounterparty();
        if (block.timestamp >= e.completionDeadline + gracePeriodSeconds) revert SubmissionWindowClosed();

        e.approvalDeadline = uint64(block.timestamp) + approvalWindowSeconds;
        e.status = Status.Submitted;

        emit ProofSubmitted(escrowId, proofHash);
    }

    function approveCompletion(bytes16 escrowId) external nonReentrant {
        Escrow storage e = _mustExist(escrowId);
        if (e.status != Status.Submitted) revert InvalidEscrowStatus();
        if (msg.sender != e.creator) revert NotCreator();

        e.status = Status.Completed;
        _settleToCounterparty(e);

        emit EscrowApproved(escrowId);
    }

    /// @notice Counterparty self-serve payout after the creator ghosted the
    ///         approval window. Creator CANNOT call this — their post-submit
    ///         paths are approveCompletion or disputeEscrow only.
    function claimStalledPayment(bytes16 escrowId) external nonReentrant {
        Escrow storage e = _mustExist(escrowId);
        if (e.status != Status.Submitted) revert InvalidEscrowStatus();
        if (msg.sender != e.counterparty) revert NotCounterparty();
        if (block.timestamp < e.approvalDeadline) revert ApprovalDeadlineNotPassed();

        e.status = Status.Completed;
        _settleToCounterparty(e);

        emit PaymentClaimed(escrowId, msg.sender);
    }

    function cancelEscrow(bytes16 escrowId) external nonReentrant {
        Escrow storage e = _mustExist(escrowId);
        if (e.status != Status.Open) revert InvalidEscrowStatus();
        if (msg.sender != e.creator) revert NotCreator();

        e.status = Status.Cancelled;
        _payout(e.asset, e.creator, e.amount);

        emit EscrowCancelled(escrowId);
    }

    /// @notice "Nobody wanted the work" — Open past acceptDeadline.
    function refundExpired(bytes16 escrowId) external nonReentrant {
        Escrow storage e = _mustExist(escrowId);
        if (e.status != Status.Open) revert InvalidEscrowStatus();
        if (msg.sender != e.creator) revert NotCreator();
        if (block.timestamp < e.acceptDeadline) revert AcceptDeadlineNotPassed();

        e.status = Status.Refunded;
        _payout(e.asset, e.creator, e.amount);

        emit EscrowExpired(escrowId);
    }

    /// @notice "Worker took the job and ghosted" — Accepted past
    ///         completionDeadline + grace. Submitted is explicitly excluded.
    function reclaimAbandoned(bytes16 escrowId) external nonReentrant {
        Escrow storage e = _mustExist(escrowId);
        if (e.status != Status.Accepted) revert InvalidEscrowStatus();
        if (msg.sender != e.creator) revert NotCreator();
        if (block.timestamp < e.completionDeadline + gracePeriodSeconds) revert ReclaimWindowNotOpen();

        e.status = Status.Refunded;
        _payout(e.asset, e.creator, e.amount);

        emit EscrowAbandoned(escrowId, e.counterparty);
    }

    /// @notice Either party escalates. The raiser posts the bond in the
    ///         escrow's asset (native via msg.value, ERC-20 via approve +
    ///         transferFrom) — mirrors the Anchor vault flow.
    function disputeEscrow(bytes16 escrowId) external payable nonReentrant {
        Escrow storage e = _mustExist(escrowId);
        if (e.status != Status.Accepted && e.status != Status.Submitted) revert InvalidEscrowStatus();
        if (msg.sender != e.creator && msg.sender != e.counterparty) revert NotDisputeParty();

        if (e.asset == address(0)) {
            if (msg.value != e.disputeBond) revert DisputeBondMismatch();
        } else {
            if (msg.value != 0) revert BadNativeValue();
            if (e.disputeBond > 0) {
                IERC20(e.asset).safeTransferFrom(msg.sender, address(this), e.disputeBond);
            }
        }

        e.status = Status.Disputed;
        e.raisedBy = msg.sender;

        emit DisputeRaised(escrowId, msg.sender);
    }

    /// @notice dispute_admin distributes principal + bond per outcome
    ///         (mirrors the Anchor compute_distribution exactly):
    ///         - Creator wins:      principal + bond → creator (no fee).
    ///           (raiser==creator → bond refund; raiser==counterparty →
    ///           loser's bond forfeits to creator. Same destination.)
    ///         - Counterparty wins: principal − fee + bond → counterparty,
    ///           fee → treasury.
    ///         - Split:             principal halved, no fee; bond refunded
    ///           to whoever raised.
    function resolveDispute(bytes16 escrowId, uint8 winner) external nonReentrant {
        if (msg.sender != disputeAdmin) revert NotDisputeAdmin();
        Escrow storage e = _mustExist(escrowId);
        if (e.status != Status.Disputed) revert InvalidEscrowStatus();
        if (winner > WINNER_SPLIT) revert InvalidWinner();

        e.status = Status.Resolved;
        uint256 bond = e.disputeBond;

        if (winner == WINNER_CREATOR) {
            _payout(e.asset, e.creator, e.amount + bond);
        } else if (winner == WINNER_COUNTERPARTY) {
            uint256 fee = _fee(e.amount, e.isSeeker);
            _payout(e.asset, e.counterparty, e.amount - fee + bond);
            if (fee > 0) _payout(e.asset, treasury, fee);
        } else {
            uint256 half = e.amount / 2;
            _payout(e.asset, e.creator, half);
            _payout(e.asset, e.counterparty, e.amount - half);
            if (bond > 0) _payout(e.asset, e.raisedBy, bond);
        }

        emit DisputeResolved(escrowId, winner);
    }

    // ---------------------------------------------------------------------
    // Internals
    // ---------------------------------------------------------------------

    function _mustExist(bytes16 escrowId) private view returns (Escrow storage e) {
        e = escrows[escrowId];
        if (e.creator == address(0)) revert EscrowNotFound();
    }

    function _collect(address asset, uint256 amount) private {
        if (asset == address(0)) {
            if (msg.value != amount) revert BadNativeValue();
        } else {
            if (msg.value != 0) revert BadNativeValue();
            IERC20(asset).safeTransferFrom(msg.sender, address(this), amount);
        }
    }

    function _payout(address asset, address to, uint256 amount) private {
        if (amount == 0) return;
        if (asset == address(0)) {
            Address.sendValue(payable(to), amount);
        } else {
            IERC20(asset).safeTransfer(to, amount);
        }
    }

    /// @dev approve + claim share one settlement: amount − fee → counterparty,
    ///      fee → treasury. Floor division mirrors Anchor's compute_fee.
    function _settleToCounterparty(Escrow storage e) private {
        uint256 fee = _fee(e.amount, e.isSeeker);
        _payout(e.asset, e.counterparty, e.amount - fee);
        if (fee > 0) _payout(e.asset, treasury, fee);
    }

    function _fee(uint256 amount, bool isSeeker) private view returns (uint256) {
        uint16 bps = isSeeker ? seekerFeeBps : feeBps;
        return (amount * bps) / 10_000;
    }

    // ---------------------------------------------------------------------
    // Validation helpers (bounds mirror Anchor constants.rs)
    // ---------------------------------------------------------------------

    function _validateFeeBps(uint16 fee, uint16 seekerFee) private pure {
        if (fee > MAX_PLATFORM_FEE_BPS || seekerFee > MAX_PLATFORM_FEE_BPS) revert FeeBpsOutOfRange();
    }

    function _validateApprovalWindow(uint64 window) private pure {
        if (window < MIN_APPROVAL_WINDOW_SECONDS || window > MAX_APPROVAL_WINDOW_SECONDS) {
            revert ApprovalWindowOutOfRange();
        }
    }

    function _validateGracePeriod(uint64 grace) private pure {
        if (grace > MAX_GRACE_PERIOD_SECONDS) revert GracePeriodOutOfRange();
    }
}
