// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "@openzeppelin/contracts/access/extensions/AccessControlDefaultAdminRules.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

/// @title ReputationAttestation
/// @notice Records verifiable work events as immutable on-chain attestations.
///
/// @dev The spec explicitly forbids a mutable "trust score" as the source of truth.
///      Instead, this contract records individual events that the frontend/backend
///      aggregates for display. Each attestation is:
///        - Tied to a specific contractId (from MilestoneEscrow)
///        - Submitted once per contract per direction (client->freelancer or reverse)
///        - Immutable after submission
///        - Linked to the actual contract parties (verified off-chain by backend
///          before calling attest())
///
///      Rating content (text comments, star displays) stays off-chain.
///      On-chain: who rated whom, for which contract, what event type, metadata hash.
///
///      ATTESTER_ROLE is assigned to a trusted backend service that verifies the
///      contract is actually completed before submitting an attestation.
///      Admin (DEFAULT_ADMIN_ROLE) CANNOT edit/delete attestations once made —
///      append-only by design.
contract ReputationAttestation is AccessControlDefaultAdminRules, Pausable {

    bytes32 public constant ATTESTER_ROLE = keccak256("ATTESTER_ROLE");
    bytes32 public constant PAUSER_ROLE   = keccak256("PAUSER_ROLE");

    enum EventType {
        ContractCompleted,       // 0
        MilestoneApproved,       // 1
        ProjectLicensed,         // 2
        ClientRatingSubmitted,   // 3  — client rated the freelancer
        FreelancerRatingSubmitted, // 4 — freelancer rated the client
        DisputeResolved          // 5
    }

    /// @notice A single verifiable event.
    /// @param contractId  On-chain contract id in MilestoneEscrow (or 0 if N/A).
    /// @param attester    Who submitted this attestation (ATTESTER_ROLE holder).
    /// @param subject     The wallet being attested about.
    /// @param rater       The wallet providing the rating/attestation.
    /// @param eventType   Type of event.
    /// @param metadataHash Hash of off-chain metadata (rating score, comment hash, IPFS link).
    /// @param timestamp   Block timestamp.
    struct Attestation {
        uint256  contractId;
        address  attester;
        address  subject;
        address  rater;
        EventType eventType;
        bytes32  metadataHash;
        uint64   timestamp;
    }

    uint256 private _nextAttestationId;
    mapping(uint256 => Attestation) private _attestations;

    // Prevent double-rating: contractId + rater + direction → already rated
    mapping(uint256 => mapping(address => bool)) public hasRated;

    // Per-wallet summary counters (append-only, never decremented)
    struct WalletStats {
        uint256 completedContracts;
        uint256 approvedMilestones;
        uint256 totalLicenses;
        uint256 disputesResolved;
        uint256 ratingsReceived;
    }
    mapping(address => WalletStats) private _stats;

    event AttestationRecorded(
        uint256 indexed attestationId,
        uint256 indexed contractId,
        address indexed subject,
        address rater,
        EventType eventType,
        bytes32 metadataHash
    );

    error ZeroAddress();
    error AlreadyRated();
    error InvalidEvent();

    constructor(uint48 adminTransferDelay, address initialAdmin)
        AccessControlDefaultAdminRules(adminTransferDelay, initialAdmin)
    {
        if (initialAdmin == address(0)) revert ZeroAddress();
        _grantRole(ATTESTER_ROLE, initialAdmin);
        _grantRole(PAUSER_ROLE, initialAdmin);
    }

    // -------------------------------------------------------------------------
    // Core attestation — called by ATTESTER_ROLE (trusted backend service)
    // -------------------------------------------------------------------------

    /// @notice Record a verifiable event.
    /// @param contractId  MilestoneEscrow contractId (0 if not contract-related).
    /// @param subject     Wallet being evaluated.
    /// @param rater       Wallet providing the evaluation (actual contract party).
    /// @param eventType   Type of event.
    /// @param metadataHash Hash of off-chain rating data.
    function attest(
        uint256   contractId,
        address   subject,
        address   rater,
        EventType eventType,
        bytes32   metadataHash
    ) external onlyRole(ATTESTER_ROLE) whenNotPaused returns (uint256 attestationId) {
        if (subject == address(0)) revert ZeroAddress();
        if (rater  == address(0)) revert ZeroAddress();

        // Ratings (client→freelancer, freelancer→client) are one per contract per rater.
        if (
            eventType == EventType.ClientRatingSubmitted
            || eventType == EventType.FreelancerRatingSubmitted
        ) {
            if (hasRated[contractId][rater]) revert AlreadyRated();
            hasRated[contractId][rater] = true;
        }

        attestationId = _nextAttestationId++;
        _attestations[attestationId] = Attestation({
            contractId:   contractId,
            attester:     msg.sender,
            subject:      subject,
            rater:        rater,
            eventType:    eventType,
            metadataHash: metadataHash,
            timestamp:    uint64(block.timestamp)
        });

        // Update summary counters
        WalletStats storage st = _stats[subject];
        if (eventType == EventType.ContractCompleted)         st.completedContracts++;
        else if (eventType == EventType.MilestoneApproved)    st.approvedMilestones++;
        else if (eventType == EventType.ProjectLicensed)      st.totalLicenses++;
        else if (eventType == EventType.DisputeResolved)      st.disputesResolved++;
        else if (
            eventType == EventType.ClientRatingSubmitted
            || eventType == EventType.FreelancerRatingSubmitted
        )                                                       st.ratingsReceived++;

        emit AttestationRecorded(attestationId, contractId, subject, rater, eventType, metadataHash);
    }

    // -------------------------------------------------------------------------
    // Pause
    // -------------------------------------------------------------------------

    function pause()   external onlyRole(PAUSER_ROLE) { _pause(); }
    function unpause() external onlyRole(PAUSER_ROLE) { _unpause(); }

    // -------------------------------------------------------------------------
    // Views — read-only, no mutation
    // -------------------------------------------------------------------------

    function getAttestation(uint256 id) external view returns (Attestation memory) {
        return _attestations[id];
    }

    /// @notice Returns append-only summary stats. NOT a mutable trust score.
    ///         Frontend/backend should aggregate individual attestations for full picture.
    function getStats(address wallet) external view returns (WalletStats memory) {
        return _stats[wallet];
    }

    function totalAttestations() external view returns (uint256) {
        return _nextAttestationId;
    }
}
