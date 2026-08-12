// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "@openzeppelin/contracts/access/extensions/AccessControlDefaultAdminRules.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

/// @title ReferralRegistry
/// @notice MVP referral tracking. Records who referred whom and what qualifying
///         event triggered the referral.
///
/// @dev No token rewards in this version (spec: "handle later after legal and
///      economic review"). Only records, no fund transfers.
///      REGISTRAR_ROLE is assigned to the backend service that validates events.
contract ReferralRegistry is AccessControlDefaultAdminRules, Pausable {

    bytes32 public constant REGISTRAR_ROLE = keccak256("REGISTRAR_ROLE");
    bytes32 public constant PAUSER_ROLE    = keccak256("PAUSER_ROLE");

    struct Referral {
        address referrer;
        address referee;
        bytes32 sourceHash;    // hash of referral source/campaign (off-chain)
        bytes32 eventHash;     // hash of qualifying event data (off-chain)
        uint64  timestamp;
        bool    rewarded;      // toggled by admin when reward is distributed off-chain
    }

    uint256 private _nextReferralId;
    mapping(uint256 => Referral) private _referrals;

    // Prevent duplicate referrals between the same pair
    mapping(address => mapping(address => bool)) public hasReferred;

    // Per-referrer count
    mapping(address => uint256) public referralCount;

    event ReferralRecorded(
        uint256 indexed referralId,
        address indexed referrer,
        address indexed referee,
        bytes32 sourceHash,
        bytes32 eventHash
    );
    event ReferralRewarded(uint256 indexed referralId);

    error SelfReferral();
    error AlreadyReferred();
    error AlreadyRewarded();
    error NotFound();
    error ZeroAddress();

    constructor(uint48 adminTransferDelay, address initialAdmin)
        AccessControlDefaultAdminRules(adminTransferDelay, initialAdmin)
    {
        if (initialAdmin == address(0)) revert ZeroAddress();
        _grantRole(REGISTRAR_ROLE, initialAdmin);
        _grantRole(PAUSER_ROLE, initialAdmin);
    }

    function recordReferral(
        address referrer,
        address referee,
        bytes32 sourceHash,
        bytes32 eventHash
    ) external onlyRole(REGISTRAR_ROLE) whenNotPaused returns (uint256 referralId) {
        if (referrer == address(0) || referee == address(0)) revert ZeroAddress();
        if (referrer == referee) revert SelfReferral();
        if (hasReferred[referrer][referee]) revert AlreadyReferred();

        referralId = _nextReferralId++;
        _referrals[referralId] = Referral({
            referrer:   referrer,
            referee:    referee,
            sourceHash: sourceHash,
            eventHash:  eventHash,
            timestamp:  uint64(block.timestamp),
            rewarded:   false
        });
        hasReferred[referrer][referee] = true;
        referralCount[referrer]++;

        emit ReferralRecorded(referralId, referrer, referee, sourceHash, eventHash);
    }

    function markRewarded(uint256 referralId) external onlyRole(DEFAULT_ADMIN_ROLE) {
        Referral storage r = _referrals[referralId];
        if (r.referrer == address(0)) revert NotFound();
        if (r.rewarded) revert AlreadyRewarded();
        r.rewarded = true;
        emit ReferralRewarded(referralId);
    }

    function pause()   external onlyRole(PAUSER_ROLE) { _pause(); }
    function unpause() external onlyRole(PAUSER_ROLE) { _unpause(); }

    function getReferral(uint256 id) external view returns (Referral memory) {
        return _referrals[id];
    }

    function totalReferrals() external view returns (uint256) {
        return _nextReferralId;
    }
}
