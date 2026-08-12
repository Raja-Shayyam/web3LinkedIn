// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import "@openzeppelin/contracts/access/extensions/AccessControlDefaultAdminRules.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";

/// @title ProjectRegistry
/// @notice Immutable ownership certificates for projects. Each token = one project.
/// @dev KEY DISTINCTION (enforced by this contract):
///      - NFT ownership  ≠  copyright ownership
///      - NFT ownership  ≠  commercial license
///      - NFT ownership  ≠  exclusive license
///      - NFT ownership  ≠  full IP transfer
///      The NFT is purely an on-chain anchor proving the creator registered a
///      specific project at a specific time. What a buyer actually acquires is
///      recorded explicitly in LicenseRegistry. Transfers are intentionally
///      restricted — the project can only be transferred via the platform's
///      explicit `transferProject` function which requires an active
///      LicenseRegistry sale, preventing accidental or unauthorized transfers.
///
///      On-chain stores:
///        projectId, creator, metadataHash, repositoryCommitHash, licenseConfig,
///        createdAt, active flag.
///
///      Off-chain stores (never on-chain):
///        full description, README, videos, images, private repo URL.
contract ProjectRegistry is ERC721, AccessControlDefaultAdminRules, Pausable {

    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");
    bytes32 public constant PAUSER_ROLE   = keccak256("PAUSER_ROLE");

    // License types a creator can configure for their project.
    // These describe what is AVAILABLE to sell in LicenseRegistry,
    // not what is automatically transferred on NFT transfer.
    enum LicenseConfig {
        None,
        PersonalOnly,
        CommercialAvailable,
        ExclusiveAvailable,
        SourceAccessAvailable,
        FullIPTransferAvailable
    }

    struct Project {
        address creator;
        bytes32 metadataHash;        // hash of off-chain JSON (title, description, tags …)
        bytes32 repositoryCommitHash; // git commit hash anchoring a specific code version
        LicenseConfig licenseConfig;
        uint64  createdAt;
        bool    active;
        bool    metadataFrozen;      // set to true when an exclusive/IP-transfer sale is completed
    }

    uint256 private _nextProjectId;
    mapping(uint256 => Project) private _projects;

    // Track collaborators separately — they are NOT owners, only credited contributors.
    mapping(uint256 => address[]) private _collaborators;
    mapping(uint256 => mapping(address => bool)) private _isCollaborator;

    // Address of the LicenseRegistry — the ONLY contract authorised to call transferProject.
    address public licenseRegistry;

    event ProjectRegistered(
        uint256 indexed projectId,
        address indexed creator,
        bytes32 metadataHash,
        bytes32 repositoryCommitHash,
        LicenseConfig licenseConfig
    );
    event MetadataHashUpdated(uint256 indexed projectId, bytes32 newHash);
    event CommitHashUpdated(uint256 indexed projectId, bytes32 newCommitHash);
    event LicenseConfigUpdated(uint256 indexed projectId, LicenseConfig newConfig);
    event CollaboratorAdded(uint256 indexed projectId, address collaborator);
    event CollaboratorRemoved(uint256 indexed projectId, address collaborator);
    event ProjectDeactivated(uint256 indexed projectId);
    event MetadataFrozen(uint256 indexed projectId);
    event ProjectTransferred(uint256 indexed projectId, address indexed from, address indexed to);
    event LicenseRegistrySet(address licenseRegistry);

    error NotProjectOwner();
    error ProjectNotActive();
    error MetadataIsFrozen();
    error CollaboratorExists();
    error CollaboratorNotFound();
    error NotLicenseRegistry();
    error ZeroAddress();
    error AlreadySet();

    constructor(uint48 adminTransferDelay, address initialAdmin)
        ERC721("Web3LinkedInProject", "W3LPRJ")
        AccessControlDefaultAdminRules(adminTransferDelay, initialAdmin)
    {
        if (initialAdmin == address(0)) revert ZeroAddress();
        _grantRole(OPERATOR_ROLE, initialAdmin);
        _grantRole(PAUSER_ROLE, initialAdmin);
    }

    // ---------------------------------------------------------------------
    // LicenseRegistry integration
    // ---------------------------------------------------------------------

    /// @notice Set once — the LicenseRegistry address that may call transferProject.
    function setLicenseRegistry(address _licenseRegistry) external onlyRole(defaultAdminRole()) {
        if (licenseRegistry != address(0)) revert AlreadySet();
        if (_licenseRegistry == address(0)) revert ZeroAddress();
        licenseRegistry = _licenseRegistry;
        emit LicenseRegistrySet(_licenseRegistry);
    }

    function defaultAdminRole() public pure returns (bytes32) {
        return DEFAULT_ADMIN_ROLE;
    }

    // ---------------------------------------------------------------------
    // Project registration
    // ---------------------------------------------------------------------

    /// @notice Register a project and mint an ownership-certificate NFT.
    function registerProject(
        bytes32 metadataHash,
        bytes32 repositoryCommitHash,
        LicenseConfig licenseConfig
    ) external whenNotPaused returns (uint256 projectId) {
        projectId = _nextProjectId++;
        _projects[projectId] = Project({
            creator: msg.sender,
            metadataHash: metadataHash,
            repositoryCommitHash: repositoryCommitHash,
            licenseConfig: licenseConfig,
            createdAt: uint64(block.timestamp),
            active: true,
            metadataFrozen: false
        });
        _safeMint(msg.sender, projectId);

        emit ProjectRegistered(projectId, msg.sender, metadataHash, repositoryCommitHash, licenseConfig);
    }

    // ---------------------------------------------------------------------
    // Owner mutations (only by current NFT holder)
    // ---------------------------------------------------------------------

    modifier onlyProjectOwner(uint256 projectId) {
        if (ownerOf(projectId) != msg.sender) revert NotProjectOwner();
        _;
    }

    modifier projectActive(uint256 projectId) {
        if (!_projects[projectId].active) revert ProjectNotActive();
        _;
    }

    modifier notFrozen(uint256 projectId) {
        if (_projects[projectId].metadataFrozen) revert MetadataIsFrozen();
        _;
    }

    function updateMetadataHash(uint256 projectId, bytes32 newHash)
        external whenNotPaused onlyProjectOwner(projectId) projectActive(projectId) notFrozen(projectId)
    {
        _projects[projectId].metadataHash = newHash;
        emit MetadataHashUpdated(projectId, newHash);
    }

    function updateCommitHash(uint256 projectId, bytes32 newCommitHash)
        external whenNotPaused onlyProjectOwner(projectId) projectActive(projectId) notFrozen(projectId)
    {
        _projects[projectId].repositoryCommitHash = newCommitHash;
        emit CommitHashUpdated(projectId, newCommitHash);
    }

    function updateLicenseConfig(uint256 projectId, LicenseConfig newConfig)
        external whenNotPaused onlyProjectOwner(projectId) projectActive(projectId) notFrozen(projectId)
    {
        _projects[projectId].licenseConfig = newConfig;
        emit LicenseConfigUpdated(projectId, newConfig);
    }

    function addCollaborator(uint256 projectId, address collaborator)
        external whenNotPaused onlyProjectOwner(projectId) projectActive(projectId)
    {
        if (collaborator == address(0)) revert ZeroAddress();
        if (_isCollaborator[projectId][collaborator]) revert CollaboratorExists();
        _collaborators[projectId].push(collaborator);
        _isCollaborator[projectId][collaborator] = true;
        emit CollaboratorAdded(projectId, collaborator);
    }

    function removeCollaborator(uint256 projectId, address collaborator)
        external whenNotPaused onlyProjectOwner(projectId) projectActive(projectId)
    {
        if (!_isCollaborator[projectId][collaborator]) revert CollaboratorNotFound();
        _isCollaborator[projectId][collaborator] = false;
        address[] storage colabs = _collaborators[projectId];
        for (uint256 i = 0; i < colabs.length; i++) {
            if (colabs[i] == collaborator) {
                colabs[i] = colabs[colabs.length - 1];
                colabs.pop();
                break;
            }
        }
        emit CollaboratorRemoved(projectId, collaborator);
    }

    function deactivateProject(uint256 projectId)
        external whenNotPaused onlyProjectOwner(projectId)
    {
        _projects[projectId].active = false;
        emit ProjectDeactivated(projectId);
    }

    // ---------------------------------------------------------------------
    // Transfer — ONLY callable by LicenseRegistry after a completed IP-transfer sale.
    // Normal ERC-721 safeTransferFrom / transferFrom are BLOCKED to prevent
    // accidental or marketplace-bypass transfers.
    // ---------------------------------------------------------------------

    function transferProject(uint256 projectId, address to) external whenNotPaused {
        if (msg.sender != licenseRegistry) revert NotLicenseRegistry();
        if (to == address(0)) revert ZeroAddress();
        address from = ownerOf(projectId);
        _transfer(from, to, projectId);
        emit ProjectTransferred(projectId, from, to);
    }

    /// @dev Block all ERC-721 standard transfers so the NFT can ONLY move
    ///      through transferProject (called by LicenseRegistry).
    function transferFrom(address, address, uint256) public pure override {
        revert NotLicenseRegistry();
    }

    function safeTransferFrom(address, address, uint256, bytes memory) public pure override {
        revert NotLicenseRegistry();
    }

    // ---------------------------------------------------------------------
    // Metadata freeze — called by LicenseRegistry on ExclusiveAvailable / FullIP sales
    // ---------------------------------------------------------------------

    function freezeMetadata(uint256 projectId) external {
        if (msg.sender != licenseRegistry) revert NotLicenseRegistry();
        _projects[projectId].metadataFrozen = true;
        emit MetadataFrozen(projectId);
    }

    // ---------------------------------------------------------------------
    // Pause
    // ---------------------------------------------------------------------

    function pause() external onlyRole(PAUSER_ROLE) { _pause(); }
    function unpause() external onlyRole(PAUSER_ROLE) { _unpause(); }

    // ---------------------------------------------------------------------
    // Views
    // ---------------------------------------------------------------------

    function getProject(uint256 projectId) external view returns (
        address creator,
        bytes32 metadataHash,
        bytes32 repositoryCommitHash,
        LicenseConfig licenseConfig,
        uint64 createdAt,
        bool active,
        bool metadataFrozen,
        address currentOwner
    ) {
        Project storage p = _projects[projectId];
        return (
            p.creator,
            p.metadataHash,
            p.repositoryCommitHash,
            p.licenseConfig,
            p.createdAt,
            p.active,
            p.metadataFrozen,
            ownerOf(projectId)
        );
    }

    function getCollaborators(uint256 projectId) external view returns (address[] memory) {
        return _collaborators[projectId];
    }

    function isCollaborator(uint256 projectId, address wallet) external view returns (bool) {
        return _isCollaborator[projectId][wallet];
    }

    function totalProjects() external view returns (uint256) {
        return _nextProjectId;
    }

    // Required override — both parents define supportsInterface
    function supportsInterface(bytes4 interfaceId)
        public view override(ERC721, AccessControlDefaultAdminRules)
        returns (bool)
    {
        return super.supportsInterface(interfaceId);
    }
}
