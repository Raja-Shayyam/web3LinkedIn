// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Minimal local/testnet escrow adapter for the Web3LinkedIn milestone lifecycle.
/// @dev This is intentionally separate from the legacy imported prototype until that contract
/// is reviewed and deployed. It has no upgrade/admin backdoor and guards each payout once.
contract LocalWeb3LinkedInEscrow {
    enum Status {
        Open,
        Hired,
        Submitted,
        Approved,
        Paid,
        Cancelled
    }

    struct Milestone {
        address developer;
        address recruiter;
        uint256 amount;
        Status status;
        bool escrowLocked;
        string title;
        string proofUrl;
        string githubUrl;
        string liveDemoUrl;
        string notes;
    }

    uint256 public nextMilestoneId;
    mapping(uint256 => Milestone) public milestones;
    mapping(address => bool) public frozenProfiles;
    mapping(uint256 => bool) public projectBurned;

    event MilestoneCreated(uint256 indexed milestoneId, address indexed developer, uint256 amount, string title);
    event MilestoneHired(uint256 indexed milestoneId, address indexed recruiter);
    event ProofSubmitted(uint256 indexed milestoneId, string proofUrl, string githubUrl, string liveDemoUrl);
    event WorkApproved(uint256 indexed milestoneId);
    event EscrowReleased(uint256 indexed milestoneId, address indexed developer, uint256 amount);
    event MilestoneCancelled(uint256 indexed milestoneId);
    event ProfileFrozen(address indexed account);
    event ProjectBurned(uint256 indexed projectId);

    modifier developerOnly(uint256 milestoneId) {
        require(msg.sender == milestones[milestoneId].developer, "developer only");
        _;
    }

    modifier recruiterOnly(uint256 milestoneId) {
        require(msg.sender == milestones[milestoneId].recruiter, "recruiter only");
        _;
    }

    function createMilestone(string calldata title, uint256 amount) external returns (uint256 milestoneId) {
        require(amount > 0, "amount required");
        require(!frozenProfiles[msg.sender], "profile frozen");
        milestoneId = nextMilestoneId++;
        milestones[milestoneId] = Milestone({
            developer: msg.sender,
            recruiter: address(0),
            amount: amount,
            status: Status.Open,
            escrowLocked: false,
            title: title,
            proofUrl: "",
            githubUrl: "",
            liveDemoUrl: "",
            notes: ""
        });
        emit MilestoneCreated(milestoneId, msg.sender, amount, title);
    }

    function hire(uint256 milestoneId) external payable {
        Milestone storage milestone = milestones[milestoneId];
        require(milestone.status == Status.Open, "not open");
        require(msg.value == milestone.amount, "exact amount required");
        milestone.recruiter = msg.sender;
        milestone.escrowLocked = true;
        milestone.status = Status.Hired;
        emit MilestoneHired(milestoneId, msg.sender);
    }

    function submitProof(
        uint256 milestoneId,
        string calldata proofUrl,
        string calldata githubUrl,
        string calldata liveDemoUrl,
        string calldata notes
    ) external developerOnly(milestoneId) {
        Milestone storage milestone = milestones[milestoneId];
        require(milestone.status == Status.Hired, "not hired");
        milestone.proofUrl = proofUrl;
        milestone.githubUrl = githubUrl;
        milestone.liveDemoUrl = liveDemoUrl;
        milestone.notes = notes;
        milestone.status = Status.Submitted;
        emit ProofSubmitted(milestoneId, proofUrl, githubUrl, liveDemoUrl);
    }

    function approve(uint256 milestoneId) external recruiterOnly(milestoneId) {
        require(milestones[milestoneId].status == Status.Submitted, "not submitted");
        milestones[milestoneId].status = Status.Approved;
        emit WorkApproved(milestoneId);
    }

    function release(uint256 milestoneId) external recruiterOnly(milestoneId) {
        Milestone storage milestone = milestones[milestoneId];
        require(milestone.status == Status.Approved, "not approved");
        require(milestone.escrowLocked, "escrow already released");
        milestone.escrowLocked = false;
        milestone.status = Status.Paid;
        (bool sent, ) = payable(milestone.developer).call{value: milestone.amount}("");
        require(sent, "payment failed");
        emit EscrowReleased(milestoneId, milestone.developer, milestone.amount);
    }

    function cancel(uint256 milestoneId) external {
        Milestone storage milestone = milestones[milestoneId];
        require(msg.sender == milestone.developer || msg.sender == milestone.recruiter, "not participant");
        require(milestone.status == Status.Open || milestone.status == Status.Hired, "cannot cancel");
        if (milestone.escrowLocked) {
            milestone.escrowLocked = false;
            (bool sent, ) = payable(milestone.recruiter).call{value: milestone.amount}("");
            require(sent, "refund failed");
        }
        milestone.status = Status.Cancelled;
        emit MilestoneCancelled(milestoneId);
    }

    function freezeProfile() external {
        frozenProfiles[msg.sender] = true;
        emit ProfileFrozen(msg.sender);
    }

    function burnProject(uint256 projectId) external {
        require(!projectBurned[projectId], "already burned");
        projectBurned[projectId] = true;
        emit ProjectBurned(projectId);
    }
}