// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "@openzeppelin/contracts/access/extensions/AccessControlDefaultAdminRules.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "./ProjectRegistry.sol";

/// @title LicenseRegistry
/// @notice Records exactly what a buyer purchased — a LICENSE, not project ownership.
///
/// @dev Core invariants (never violated):
///      1. A license purchase does NOT transfer the project NFT (except FullIPTransfer type).
///      2. Seller cannot purchase their own listing.
///      3. Payment and license record happen atomically.
///      4. Platform fee never exceeds FEE_CAP_BPS (hard-coded).
///      5. Only allowlisted tokens are accepted.
///      6. Fee changes are timelocked (FEE_TIMELOCK_DELAY seconds).
///      7. Allowlist changes are timelocked.
///      8. SafeERC20 used for all token transfers.
///
/// License types (must match ProjectRegistry.LicenseConfig):
///   0 None | 1 Personal | 2 Commercial | 3 Exclusive | 4 SourceAccess | 5 FullIPTransfer
contract LicenseRegistry is AccessControlDefaultAdminRules, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;

    // -------------------------------------------------------------------------
    // Constants
    // -------------------------------------------------------------------------

    uint256 public constant FEE_CAP_BPS      = 1000;   // hard ceiling: 10%
    uint48  public constant FEE_TIMELOCK_DELAY = 2 days; // fee/allowlist changes must wait

    bytes32 public constant FEE_MANAGER_ROLE = keccak256("FEE_MANAGER_ROLE");
    bytes32 public constant PAUSER_ROLE      = keccak256("PAUSER_ROLE");

    // -------------------------------------------------------------------------
    // License types — must match spec exactly
    // -------------------------------------------------------------------------

    enum LicenseType {
        None,           // 0 — invalid
        Personal,       // 1
        Commercial,     // 2
        Exclusive,      // 3 — only one can be sold; freezes further commercial sales
        SourceAccess,   // 4 — buyer gets read access to private repo (backend listens to event)
        FullIPTransfer  // 5 — also triggers NFT transfer to buyer
    }

    // -------------------------------------------------------------------------
    // Storage
    // -------------------------------------------------------------------------

    ProjectRegistry public immutable projectRegistry;

    struct Listing {
        address seller;
        address token;        // allowlisted ERC-20 (e.g. USDC)
        uint256 price;
        LicenseType licenseType;
        bool active;
    }

    struct LicenseRecord {
        uint256 projectId;
        address seller;
        address buyer;
        address token;
        uint256 price;
        LicenseType licenseType;
        bytes32 metadataHash;     // hash of off-chain license terms
        uint64  purchasedAt;
        bool    active;
    }

    mapping(uint256 => Listing) public listings;             // projectId => Listing
    mapping(uint256 => LicenseRecord) public licenses;        // licenseId => LicenseRecord
    mapping(uint256 => bool) public exclusiveSold;            // projectId => exclusive sold?

    uint256 private _nextLicenseId;

    // Fee
    uint256 public platformFeeBps = 250;  // 2.5% default

    // Timelock for fee changes
    struct PendingFeeChange {
        uint256 newFeeBps;
        uint64  readyAt;
        bool    pending;
    }
    PendingFeeChange public pendingFee;

    // Token allowlist + timelock
    mapping(address => bool) public allowedTokens;
    struct PendingTokenChange {
        address token;
        bool    adding;
        uint64  readyAt;
        bool    pending;
    }
    PendingTokenChange public pendingTokenChange;

    // Accumulated fees per token (platform pulls via withdrawFees)
    mapping(address => uint256) public accumulatedFees;

    // -------------------------------------------------------------------------
    // Events
    // -------------------------------------------------------------------------

    event Listed(uint256 indexed projectId, address indexed seller, address token, uint256 price, LicenseType licenseType);
    event Unlisted(uint256 indexed projectId, address indexed seller);
    event LicensePurchased(
        uint256 indexed licenseId,
        uint256 indexed projectId,
        address indexed buyer,
        LicenseType licenseType,
        uint256 price,
        address token
    );
    event FeeBpsProposed(uint256 newFeeBps, uint64 readyAt);
    event FeeBpsApplied(uint256 newFeeBps);
    event TokenChangeProposed(address token, bool adding, uint64 readyAt);
    event TokenChangeApplied(address token, bool added);
    event FeesWithdrawn(address token, address to, uint256 amount);

    // -------------------------------------------------------------------------
    // Errors
    // -------------------------------------------------------------------------

    error TokenNotAllowed();
    error ListingNotActive();
    error CannotBuyOwnListing();
    error ExclusiveAlreadySold();
    error FeeTooHigh();
    error TimelockNotExpired();
    error NoPendingChange();
    error ZeroAddress();
    error ZeroPrice();
    error ProjectNotActive();
    error Unauthorized();
    error NoFeesToWithdraw();

    // -------------------------------------------------------------------------
    // Constructor
    // -------------------------------------------------------------------------

    constructor(
        address _projectRegistry,
        uint48  adminTransferDelay,
        address initialAdmin
    ) AccessControlDefaultAdminRules(adminTransferDelay, initialAdmin) {
        if (_projectRegistry == address(0)) revert ZeroAddress();
        if (initialAdmin == address(0)) revert ZeroAddress();
        projectRegistry = ProjectRegistry(_projectRegistry);
        _grantRole(FEE_MANAGER_ROLE, initialAdmin);
        _grantRole(PAUSER_ROLE, initialAdmin);
    }

    // -------------------------------------------------------------------------
    // Token allowlist (timelocked)
    // -------------------------------------------------------------------------

    function proposeTokenChange(address token, bool adding)
        external onlyRole(FEE_MANAGER_ROLE)
    {
        if (token == address(0)) revert ZeroAddress();
        pendingTokenChange = PendingTokenChange({
            token: token,
            adding: adding,
            readyAt: uint64(block.timestamp) + FEE_TIMELOCK_DELAY,
            pending: true
        });
        emit TokenChangeProposed(token, adding, pendingTokenChange.readyAt);
    }

    function applyTokenChange() external onlyRole(FEE_MANAGER_ROLE) {
        PendingTokenChange memory c = pendingTokenChange;
        if (!c.pending) revert NoPendingChange();
        if (block.timestamp < c.readyAt) revert TimelockNotExpired();
        allowedTokens[c.token] = c.adding;
        delete pendingTokenChange;
        emit TokenChangeApplied(c.token, c.adding);
    }

    // -------------------------------------------------------------------------
    // Fee management (timelocked)
    // -------------------------------------------------------------------------

    function proposeFeeBps(uint256 newFeeBps) external onlyRole(FEE_MANAGER_ROLE) {
        if (newFeeBps > FEE_CAP_BPS) revert FeeTooHigh();
        pendingFee = PendingFeeChange({
            newFeeBps: newFeeBps,
            readyAt: uint64(block.timestamp) + FEE_TIMELOCK_DELAY,
            pending: true
        });
        emit FeeBpsProposed(newFeeBps, pendingFee.readyAt);
    }

    function applyFeeBps() external onlyRole(FEE_MANAGER_ROLE) {
        PendingFeeChange memory f = pendingFee;
        if (!f.pending) revert NoPendingChange();
        if (block.timestamp < f.readyAt) revert TimelockNotExpired();
        platformFeeBps = f.newFeeBps;
        delete pendingFee;
        emit FeeBpsApplied(f.newFeeBps);
    }

    // -------------------------------------------------------------------------
    // Listing
    // -------------------------------------------------------------------------

    function listProject(
        uint256    projectId,
        address    token,
        uint256    price,
        LicenseType licenseType,
        bytes32    metadataHash
    ) external whenNotPaused {
        if (!allowedTokens[token]) revert TokenNotAllowed();
        if (price == 0) revert ZeroPrice();
        if (licenseType == LicenseType.None) revert Unauthorized();
        if (projectRegistry.ownerOf(projectId) != msg.sender) revert Unauthorized();

        (,,,, , bool active,,) = projectRegistry.getProject(projectId);
        if (!active) revert ProjectNotActive();

        // Cannot re-list if exclusive already sold
        if (licenseType == LicenseType.Exclusive && exclusiveSold[projectId]) revert ExclusiveAlreadySold();
        if (licenseType == LicenseType.FullIPTransfer && exclusiveSold[projectId]) revert ExclusiveAlreadySold();

        listings[projectId] = Listing({
            seller: msg.sender,
            token: token,
            price: price,
            licenseType: licenseType,
            active: true
        });

        emit Listed(projectId, msg.sender, token, price, licenseType);
    }

    function cancelListing(uint256 projectId) external whenNotPaused {
        Listing storage l = listings[projectId];
        if (!l.active) revert ListingNotActive();
        if (l.seller != msg.sender) revert Unauthorized();
        delete listings[projectId];
        emit Unlisted(projectId, msg.sender);
    }

    // -------------------------------------------------------------------------
    // Purchase — atomic: payment + license record (+ optional NFT transfer)
    // -------------------------------------------------------------------------

    function purchaseLicense(
        uint256 projectId,
        bytes32 metadataHash  // hash of agreed license terms stored off-chain
    ) external nonReentrant whenNotPaused returns (uint256 licenseId) {
        Listing memory l = listings[projectId];
        if (!l.active) revert ListingNotActive();
        if (msg.sender == l.seller) revert CannotBuyOwnListing();
        if (l.licenseType == LicenseType.Exclusive && exclusiveSold[projectId]) revert ExclusiveAlreadySold();

        uint256 fee            = (l.price * platformFeeBps) / 10_000;
        uint256 sellerProceeds = l.price - fee;

        // ---- Payment (atomic, SafeERC20) ----
        IERC20(l.token).safeTransferFrom(msg.sender, address(this), l.price);
        IERC20(l.token).safeTransfer(l.seller, sellerProceeds);
        accumulatedFees[l.token] += fee;

        // ---- License record ----
        licenseId = _nextLicenseId++;
        licenses[licenseId] = LicenseRecord({
            projectId:   projectId,
            seller:      l.seller,
            buyer:       msg.sender,
            token:       l.token,
            price:       l.price,
            licenseType: l.licenseType,
            metadataHash: metadataHash,
            purchasedAt: uint64(block.timestamp),
            active:      true
        });

        // ---- Post-purchase side-effects ----
        if (l.licenseType == LicenseType.Exclusive) {
            exclusiveSold[projectId] = true;
            delete listings[projectId]; // no more sales of this type
            projectRegistry.freezeMetadata(projectId);
        } else if (l.licenseType == LicenseType.FullIPTransfer) {
            exclusiveSold[projectId] = true;
            delete listings[projectId];
            projectRegistry.freezeMetadata(projectId);
            // NFT transfer: seller must have approved ProjectRegistry.transferProject
            projectRegistry.transferProject(projectId, msg.sender);
        } else {
            // Non-exclusive licenses: listing stays active for further purchases
        }

        emit LicensePurchased(licenseId, projectId, msg.sender, l.licenseType, l.price, l.token);
        // Note: backend listens to this event and grants repo access for SourceAccess licenses.
    }

    // -------------------------------------------------------------------------
    // Fee withdrawal — only to admin, only accumulated fees (not user funds)
    // -------------------------------------------------------------------------

    function withdrawFees(address token, address to) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (to == address(0)) revert ZeroAddress();
        uint256 amount = accumulatedFees[token];
        if (amount == 0) revert NoFeesToWithdraw();
        accumulatedFees[token] = 0;
        IERC20(token).safeTransfer(to, amount);
        emit FeesWithdrawn(token, to, amount);
    }

    // -------------------------------------------------------------------------
    // Pause
    // -------------------------------------------------------------------------

    function pause()   external onlyRole(PAUSER_ROLE) { _pause(); }
    function unpause() external onlyRole(PAUSER_ROLE) { _unpause(); }

    // -------------------------------------------------------------------------
    // Views
    // -------------------------------------------------------------------------

    function getLicense(uint256 licenseId) external view returns (LicenseRecord memory) {
        return licenses[licenseId];
    }

    function getListing(uint256 projectId) external view returns (Listing memory) {
        return listings[projectId];
    }
}
