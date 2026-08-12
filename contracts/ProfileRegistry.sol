// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "@openzeppelin/contracts/access/extensions/AccessControlDefaultAdminRules.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import "@openzeppelin/contracts/utils/cryptography/MessageHashUtils.sol";

/// @title ProfileRegistry
/// @notice On-chain identity anchor. Stores ONLY hashes/flags, never emails,
///         names or other PII. Maps: Google account -> platform user (off-chain)
///         -> platformUserIdHash -> primary wallet -> linked wallets.
/// @dev Admin role transfer is 2-step and time-delayed (AccessControlDefaultAdminRules).
///      VERIFIER_ROLE can only grant/revoke verification badges and perform
///      platform-controlled wallet recovery — it can NEVER move funds or
///      silently take over a user's wallet identity for itself.
contract ProfileRegistry is AccessControlDefaultAdminRules, Pausable {
    using ECDSA for bytes32;
    using MessageHashUtils for bytes32;

    bytes32 public constant VERIFIER_ROLE = keccak256("VERIFIER_ROLE");
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    struct Profile {
        bytes32 platformUserIdHash;   // hash of off-chain platform user id (never raw email)
        bytes32 profileMetadataHash;  // hash of off-chain profile JSON/bio
        bool verifiedStudent;
        bool verifiedRecruiter;
        bool exists;
    }

    mapping(address => Profile) private _profiles;       // primary wallet => profile
    mapping(bytes32 => address) public userIdToPrimary;   // platformUserIdHash => primary wallet (1:1)
    mapping(address => address) public primaryOf;         // secondary wallet => primary wallet
    mapping(address => bool) public isPrimary;
    mapping(address => uint256) public linkNonce;         // replay protection for link signatures

    event ProfileRegistered(address indexed primaryWallet, bytes32 indexed platformUserIdHash, bytes32 profileMetadataHash);
    event ProfileMetadataUpdated(address indexed primaryWallet, bytes32 newMetadataHash);
    event WalletLinked(address indexed primaryWallet, address indexed secondaryWallet);
    event WalletUnlinked(address indexed primaryWallet, address indexed secondaryWallet);
    event StudentVerified(address indexed wallet);
    event RecruiterVerified(address indexed wallet);
    event VerificationRevoked(address indexed wallet);
    event WalletRecovered(bytes32 indexed platformUserIdHash, address indexed oldPrimary, address indexed newPrimary);

    error ProfileExists();
    error ProfileNotFound();
    error ZeroAddress();
    error AlreadyLinked();
    error NotLinked();
    error InvalidSignature();
    error SelfLink();

    /// @param adminTransferDelay seconds an admin-role transfer must wait before it can be accepted (2-step, timelocked)
    constructor(uint48 adminTransferDelay, address initialAdmin)
        AccessControlDefaultAdminRules(adminTransferDelay, initialAdmin)
    {
        if (initialAdmin == address(0)) revert ZeroAddress();
        _grantRole(VERIFIER_ROLE, initialAdmin);
        _grantRole(PAUSER_ROLE, initialAdmin);
    }

    // ---------------------------------------------------------------------
    // Profile registration
    // ---------------------------------------------------------------------

    function registerProfile(bytes32 platformUserIdHash, bytes32 profileMetadataHash) external whenNotPaused {
        if (_profiles[msg.sender].exists) revert ProfileExists();
        if (userIdToPrimary[platformUserIdHash] != address(0)) revert ProfileExists();

        _profiles[msg.sender] = Profile({
            platformUserIdHash: platformUserIdHash,
            profileMetadataHash: profileMetadataHash,
            verifiedStudent: false,
            verifiedRecruiter: false,
            exists: true
        });
        userIdToPrimary[platformUserIdHash] = msg.sender;
        isPrimary[msg.sender] = true;

        emit ProfileRegistered(msg.sender, platformUserIdHash, profileMetadataHash);
    }

    function updateMetadataHash(bytes32 newMetadataHash) external whenNotPaused {
        if (!_profiles[msg.sender].exists) revert ProfileNotFound();
        _profiles[msg.sender].profileMetadataHash = newMetadataHash;
        emit ProfileMetadataUpdated(msg.sender, newMetadataHash);
    }

    // ---------------------------------------------------------------------
    // Wallet linking — requires a signature FROM the new wallet proving ownership.
    // A new wallet never auto-creates a second identity.
    // ---------------------------------------------------------------------

    /// @notice Link a secondary wallet to caller's (primary) profile.
    /// @param secondary The wallet being linked.
    /// @param signature Signature by `secondary` over
    ///        keccak256(primary, secondary, nonce, address(this), "LINK")
    function linkWallet(address secondary, bytes calldata signature) external whenNotPaused {
        if (!_profiles[msg.sender].exists) revert ProfileNotFound();
        if (secondary == address(0)) revert ZeroAddress();
        if (secondary == msg.sender) revert SelfLink();
        if (primaryOf[secondary] != address(0) || isPrimary[secondary]) revert AlreadyLinked();

        uint256 nonce = linkNonce[secondary];
        bytes32 digest = keccak256(
            abi.encodePacked(msg.sender, secondary, nonce, address(this), "LINK")
        ).toEthSignedMessageHash();

        if (digest.recover(signature) != secondary) revert InvalidSignature();

        linkNonce[secondary] = nonce + 1;
        primaryOf[secondary] = msg.sender;

        emit WalletLinked(msg.sender, secondary);
    }

    /// @notice Caller (primary) unlinks one of its secondary wallets. No signature
    ///         needed from the secondary — the primary profile owner controls this.
    function unlinkWallet(address secondary) external whenNotPaused {
        if (primaryOf[secondary] != msg.sender) revert NotLinked();
        delete primaryOf[secondary];
        emit WalletUnlinked(msg.sender, secondary);
    }

    /// @notice Platform-controlled recovery: reassigns the primary wallet for a
    ///         platform user when the old wallet is lost. Off-chain identity
    ///         verification (Google re-auth / KYC) MUST gate this call before
    ///         the backend submits it. This only re-points the identity mapping —
    ///         it never moves funds and does not give the verifier custody of
    ///         anything the user owns.
    function recoverPrimaryWallet(bytes32 platformUserIdHash, address newPrimary)
        external
        onlyRole(VERIFIER_ROLE)
        whenNotPaused
    {
        if (newPrimary == address(0)) revert ZeroAddress();
        address oldPrimary = userIdToPrimary[platformUserIdHash];
        if (oldPrimary == address(0)) revert ProfileNotFound();
        if (_profiles[newPrimary].exists) revert ProfileExists();

        Profile memory p = _profiles[oldPrimary];
        delete _profiles[oldPrimary];
        isPrimary[oldPrimary] = false;

        _profiles[newPrimary] = p;
        isPrimary[newPrimary] = true;
        userIdToPrimary[platformUserIdHash] = newPrimary;

        emit WalletRecovered(platformUserIdHash, oldPrimary, newPrimary);
    }

    // ---------------------------------------------------------------------
    // Verification badges — VERIFIER_ROLE cannot touch funds or wallet links
    // ---------------------------------------------------------------------

    function verifyStudent(address wallet) external onlyRole(VERIFIER_ROLE) {
        if (!_profiles[wallet].exists) revert ProfileNotFound();
        _profiles[wallet].verifiedStudent = true;
        emit StudentVerified(wallet);
    }

    function verifyRecruiter(address wallet) external onlyRole(VERIFIER_ROLE) {
        if (!_profiles[wallet].exists) revert ProfileNotFound();
        _profiles[wallet].verifiedRecruiter = true;
        emit RecruiterVerified(wallet);
    }

    function revokeVerification(address wallet) external onlyRole(VERIFIER_ROLE) {
        if (!_profiles[wallet].exists) revert ProfileNotFound();
        _profiles[wallet].verifiedStudent = false;
        _profiles[wallet].verifiedRecruiter = false;
        emit VerificationRevoked(wallet);
    }

    // ---------------------------------------------------------------------
    // Pause (emergency stop)
    // ---------------------------------------------------------------------

    function pause() external onlyRole(PAUSER_ROLE) { _pause(); }
    function unpause() external onlyRole(PAUSER_ROLE) { _unpause(); }

    // ---------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------

    function getProfile(address wallet) external view returns (
        bytes32 platformUserIdHash,
        bytes32 profileMetadataHash,
        bool verifiedStudent,
        bool verifiedRecruiter,
        bool exists
    ) {
        Profile storage p = _profiles[wallet];
        return (p.platformUserIdHash, p.profileMetadataHash, p.verifiedStudent, p.verifiedRecruiter, p.exists);
    }

    /// @notice Resolves any wallet (primary or secondary) to its primary wallet.
    function resolvePrimary(address wallet) external view returns (address) {
        if (isPrimary[wallet]) return wallet;
        return primaryOf[wallet];
    }
}
