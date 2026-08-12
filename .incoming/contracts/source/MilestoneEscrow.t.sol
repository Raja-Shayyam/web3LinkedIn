// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "forge-std/Test.sol";
import "../contracts/MilestoneEscrow.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";

/// @dev Minimal mock USDC
contract MockUSDC is ERC20 {
    constructor() ERC20("Mock USDC", "USDC") {
        _mint(msg.sender, 1_000_000 * 1e6);
    }
    function decimals() public pure override returns (uint8) { return 6; }
    function mint(address to, uint256 amount) external { _mint(to, amount); }
}

contract MilestoneEscrowTest is Test {

    MilestoneEscrow public escrow;
    MockUSDC        public usdc;

    address admin      = makeAddr("admin");
    address arbitrator = makeAddr("arbitrator");
    address client     = makeAddr("client");
    address freelancer = makeAddr("freelancer");
    address attacker   = makeAddr("attacker");

    uint256[] threeAmounts;
    bytes32[] threeHashes;

    function setUp() public {
        vm.startPrank(admin);
        escrow = new MilestoneEscrow(1 days, admin);
        usdc   = new MockUSDC();

        escrow.allowToken(address(usdc));
        escrow.grantRole(escrow.ARBITRATOR_ROLE(), arbitrator);
        vm.stopPrank();

        // Fund client
        usdc.mint(client, 100_000 * 1e6);

        // Default 3-milestone setup
        threeAmounts = [uint256(300e6), uint256(500e6), uint256(200e6)];
        threeHashes  = [bytes32("hash0"), bytes32("hash1"), bytes32("hash2")];
    }

    // =========================================================================
    // Helpers
    // =========================================================================

    function _createAndFund(uint256[] memory amounts, bytes32[] memory hashes)
        internal returns (uint256 cid)
    {
        vm.prank(client);
        cid = escrow.createContract(freelancer, address(usdc), amounts, hashes);

        uint256 total;
        for (uint i; i < amounts.length; i++) total += amounts[i];
        vm.startPrank(client);
        usdc.approve(address(escrow), total);
        escrow.fundContract(cid);
        vm.stopPrank();
    }

    function _start(uint256 cid) internal {
        vm.prank(freelancer);
        escrow.startWork(cid);
    }

    function _submit(uint256 cid, uint256 idx) internal {
        vm.prank(freelancer);
        escrow.submitMilestone(cid, idx, bytes32(uint256(idx + 1) * 0xdeadbeef));
    }

    function _approve(uint256 cid, uint256 idx) internal {
        vm.prank(client);
        escrow.approveMilestone(cid, idx);
    }

    // =========================================================================
    // Happy path — full 3-milestone flow
    // =========================================================================

    function test_HappyPath_ThreeMilestones() public {
        uint256 cid = _createAndFund(threeAmounts, threeHashes);
        _start(cid);

        uint256 freelancerBefore = usdc.balanceOf(freelancer);

        for (uint256 i; i < 3; i++) {
            _submit(cid, i);
            _approve(cid, i);
        }

        MilestoneEscrow.EscrowContract memory c = escrow.getContract(cid);
        assertEq(uint(c.state), uint(MilestoneEscrow.ContractState.Completed));
        assertEq(c.lockedBalance, 0);
        assertEq(c.totalReleased, c.fundedAmount);

        // Freelancer received funds (minus fee)
        uint256 total = 300e6 + 500e6 + 200e6;
        uint256 fee   = (total * 250) / 10_000;
        assertEq(usdc.balanceOf(freelancer) - freelancerBefore, total - fee);
    }

    // =========================================================================
    // Invariant I-1: lockedBalance + totalReleased == fundedAmount
    // =========================================================================

    function test_Invariant_BalanceAccountingAfterEachApproval() public {
        uint256 cid = _createAndFund(threeAmounts, threeHashes);
        _start(cid);

        for (uint256 i; i < 3; i++) {
            _submit(cid, i);
            _approve(cid, i);

            MilestoneEscrow.EscrowContract memory c = escrow.getContract(cid);
            assertEq(c.lockedBalance + c.totalReleased, c.fundedAmount,
                "Invariant I-1 violated after approval");
        }
    }

    // =========================================================================
    // Invariant I-2: paid milestone cannot be paid again
    // =========================================================================

    function test_CannotDoublePayMilestone() public {
        uint256 cid = _createAndFund(threeAmounts, threeHashes);
        _start(cid);
        _submit(cid, 0);
        _approve(cid, 0);

        // Milestone 0 is now paid, state moved to InProgress for milestone 1.
        // Re-submitting milestone 0 should fail (wrong index).
        vm.prank(freelancer);
        vm.expectRevert(
            abi.encodeWithSelector(MilestoneEscrow.WrongMilestone.selector, 1, 0)
        );
        escrow.submitMilestone(cid, 0, bytes32("resubmit"));
    }

    // =========================================================================
    // Invariant I-3: freelancer cannot approve, client cannot submit
    // =========================================================================

    function test_FreelancerCannotApprove() public {
        uint256 cid = _createAndFund(threeAmounts, threeHashes);
        _start(cid);
        _submit(cid, 0);

        vm.prank(freelancer);
        vm.expectRevert(MilestoneEscrow.OnlyClient.selector);
        escrow.approveMilestone(cid, 0);
    }

    function test_ClientCannotSubmit() public {
        uint256 cid = _createAndFund(threeAmounts, threeHashes);
        _start(cid);

        vm.prank(client);
        vm.expectRevert(MilestoneEscrow.OnlyFreelancer.selector);
        escrow.submitMilestone(cid, 0, bytes32("evidence"));
    }

    // =========================================================================
    // Invariant I-4: fee cap
    // =========================================================================

    function test_FeeCapEnforced() public {
        vm.prank(admin);
        vm.expectRevert(MilestoneEscrow.FeeTooHigh.selector);
        escrow.proposeDefaultFeeBps(1001); // > 1000 bps (10%)
    }

    // =========================================================================
    // Invariant I-9: arbitrator cannot withdraw arbitrary funds
    // =========================================================================

    function test_ArbitratorCanOnlyResolveDispute() public {
        // Arbitrator has no withdrawPlatformFees access
        vm.prank(arbitrator);
        vm.expectRevert();
        escrow.withdrawPlatformFees(address(usdc), arbitrator);
    }

    // =========================================================================
    // Invariant I-8: admin cannot touch user escrow
    // =========================================================================

    function test_AdminCannotTouchUserEscrow() public {
        _createAndFund(threeAmounts, threeHashes);
        // Admin cannot approve milestones (not the client)
        vm.prank(admin);
        vm.expectRevert(MilestoneEscrow.OnlyClient.selector);
        escrow.approveMilestone(0, 0);
    }

    // =========================================================================
    // Invariant I-10: sequential milestones
    // =========================================================================

    function test_CannotSkipMilestone() public {
        uint256 cid = _createAndFund(threeAmounts, threeHashes);
        _start(cid);

        // Try to submit milestone 1 before 0
        vm.prank(freelancer);
        vm.expectRevert(
            abi.encodeWithSelector(MilestoneEscrow.WrongMilestone.selector, 0, 1)
        );
        escrow.submitMilestone(cid, 1, bytes32("evidence"));
    }

    // =========================================================================
    // Rejection flow
    // =========================================================================

    function test_RejectAndResubmit() public {
        uint256 cid = _createAndFund(threeAmounts, threeHashes);
        _start(cid);
        _submit(cid, 0);

        vm.prank(client);
        escrow.rejectMilestone(cid, 0);

        // State back to InProgress
        MilestoneEscrow.EscrowContract memory c = escrow.getContract(cid);
        assertEq(uint(c.state), uint(MilestoneEscrow.ContractState.InProgress));

        // Resubmit
        _submit(cid, 0);
        _approve(cid, 0);

        MilestoneEscrow.Milestone memory m = escrow.getMilestone(cid, 0);
        assertTrue(m.paid);
    }

    // =========================================================================
    // Refund — before work started
    // =========================================================================

    function test_RefundBeforeWorkStarted() public {
        uint256 cid = _createAndFund(threeAmounts, threeHashes);
        _start(cid);

        uint256 clientBefore = usdc.balanceOf(client);
        vm.prank(client);
        escrow.requestRefund(cid);

        uint256 total = 300e6 + 500e6 + 200e6;
        assertEq(usdc.balanceOf(client) - clientBefore, total);

        MilestoneEscrow.EscrowContract memory c = escrow.getContract(cid);
        assertEq(uint(c.state), uint(MilestoneEscrow.ContractState.Refunded));
        assertEq(c.lockedBalance, 0);
    }

    function test_CannotRefundAfterSubmission() public {
        uint256 cid = _createAndFund(threeAmounts, threeHashes);
        _start(cid);
        _submit(cid, 0);

        vm.prank(client);
        vm.expectRevert(MilestoneEscrow.WorkAlreadyStarted.selector);
        escrow.requestRefund(cid);
    }

    // =========================================================================
    // Dispute + resolution
    // =========================================================================

    function test_DisputeFlow_50_50() public {
        uint256 cid = _createAndFund(threeAmounts, threeHashes);
        _start(cid);
        _submit(cid, 0);

        // Open dispute by freelancer
        vm.prank(freelancer);
        escrow.openDispute(cid);

        uint256 clientBefore     = usdc.balanceOf(client);
        uint256 freelancerBefore = usdc.balanceOf(freelancer);

        // Arbitrator resolves: 50% to client, 50% to freelancer
        vm.prank(arbitrator);
        escrow.resolveDispute(cid, 5000); // 5000 bps = 50%

        MilestoneEscrow.EscrowContract memory c = escrow.getContract(cid);
        assertEq(c.lockedBalance, 0);
        assertEq(uint(c.state), uint(MilestoneEscrow.ContractState.Completed));
        assertFalse(c.disputeOpen);

        // Verify some funds went to both parties
        assertGt(usdc.balanceOf(client)     - clientBefore,     0);
        assertGt(usdc.balanceOf(freelancer) - freelancerBefore, 0);
    }

    function test_DisputeResolution_FullToFreelancer() public {
        uint256 cid = _createAndFund(threeAmounts, threeHashes);
        _start(cid);

        vm.prank(client);
        escrow.openDispute(cid);

        uint256 locked = escrow.getContract(cid).lockedBalance;
        uint256 freelancerBefore = usdc.balanceOf(freelancer);

        // clientShare = 0 bps → all to freelancer (minus fee)
        vm.prank(arbitrator);
        escrow.resolveDispute(cid, 0);

        uint256 fee         = (locked * 250) / 10_000;
        uint256 expectedPay = locked - fee;
        assertEq(usdc.balanceOf(freelancer) - freelancerBefore, expectedPay);
    }

    function test_DisputeResolution_FullRefund() public {
        uint256 cid = _createAndFund(threeAmounts, threeHashes);
        _start(cid);

        vm.prank(freelancer);
        escrow.openDispute(cid);

        uint256 clientBefore = usdc.balanceOf(client);

        // clientShare = 10000 bps → full refund to client
        vm.prank(arbitrator);
        escrow.resolveDispute(cid, 10_000);

        uint256 total = 300e6 + 500e6 + 200e6;
        assertEq(usdc.balanceOf(client) - clientBefore, total);
    }

    function test_NonArbitratorCannotResolve() public {
        uint256 cid = _createAndFund(threeAmounts, threeHashes);
        _start(cid);
        vm.prank(freelancer);
        escrow.openDispute(cid);

        vm.prank(attacker);
        vm.expectRevert();
        escrow.resolveDispute(cid, 5000);
    }

    // =========================================================================
    // Unauthorized token
    // =========================================================================

    function test_CannotCreateWithUnauthorizedToken() public {
        MockUSDC fake = new MockUSDC();
        vm.prank(client);
        vm.expectRevert(MilestoneEscrow.TokenNotAllowed.selector);
        escrow.createContract(freelancer, address(fake), threeAmounts, threeHashes);
    }

    // =========================================================================
    // Zero values
    // =========================================================================

    function test_ZeroMilestoneAmountReverts() public {
        uint256[] memory bad = new uint256[](2);
        bad[0] = 100e6;
        bad[1] = 0;         // invalid
        bytes32[] memory h = new bytes32[](2);
        h[0] = bytes32("a");
        h[1] = bytes32("b");

        vm.prank(client);
        vm.expectRevert(MilestoneEscrow.ZeroAmount.selector);
        escrow.createContract(freelancer, address(usdc), bad, h);
    }

    function test_EmptyEvidenceHashReverts() public {
        uint256 cid = _createAndFund(threeAmounts, threeHashes);
        _start(cid);

        vm.prank(freelancer);
        vm.expectRevert(MilestoneEscrow.ZeroAmount.selector); // re-used for empty hash
        escrow.submitMilestone(cid, 0, bytes32(0));
    }

    // =========================================================================
    // Paused state
    // =========================================================================

    function test_PausedBlocksOperations() public {
        vm.prank(admin);
        escrow.pause();

        vm.prank(client);
        vm.expectRevert();
        escrow.createContract(freelancer, address(usdc), threeAmounts, threeHashes);
    }

    function test_UnpauseRestoresOperations() public {
        vm.startPrank(admin);
        escrow.pause();
        escrow.unpause();
        vm.stopPrank();

        vm.prank(client);
        escrow.createContract(freelancer, address(usdc), threeAmounts, threeHashes);
    }

    // =========================================================================
    // Fee timelock
    // =========================================================================

    function test_FeeChangeRequiresTimelock() public {
        vm.startPrank(admin);
        escrow.proposeDefaultFeeBps(500);

        // Applying immediately should revert
        vm.expectRevert(MilestoneEscrow.TimelockNotExpired.selector);
        escrow.applyDefaultFeeBps();

        // Warp past delay
        vm.warp(block.timestamp + 2 days + 1);
        escrow.applyDefaultFeeBps();
        vm.stopPrank();

        assertEq(escrow.defaultPlatformFeeBps(), 500);
    }

    // =========================================================================
    // Fuzz: invariant I-1 holds for any valid amounts
    // =========================================================================

    function testFuzz_InvariantBalance(uint96 a0, uint96 a1, uint96 a2) public {
        vm.assume(a0 > 0 && a1 > 0 && a2 > 0);
        vm.assume(uint256(a0) + a1 + a2 < type(uint96).max);

        uint256[] memory amounts = new uint256[](3);
        amounts[0] = a0; amounts[1] = a1; amounts[2] = a2;
        bytes32[] memory hashes = new bytes32[](3);
        hashes[0] = bytes32("a"); hashes[1] = bytes32("b"); hashes[2] = bytes32("c");

        uint256 total = uint256(a0) + a1 + a2;
        usdc.mint(client, total);

        uint256 cid = _createAndFund(amounts, hashes);
        _start(cid);

        for (uint256 i; i < 3; i++) {
            _submit(cid, i);
            _approve(cid, i);

            MilestoneEscrow.EscrowContract memory c = escrow.getContract(cid);
            assertEq(
                c.lockedBalance + c.totalReleased,
                c.fundedAmount,
                "Invariant I-1 violated"
            );
        }
    }

    // =========================================================================
    // Reentrancy guard (behaviour: revert on reentrant call)
    // =========================================================================

    function test_OnlyPartyCanOpenDispute() public {
        uint256 cid = _createAndFund(threeAmounts, threeHashes);
        _start(cid);

        vm.prank(attacker);
        vm.expectRevert(MilestoneEscrow.OnlyParty.selector);
        escrow.openDispute(cid);
    }

    function test_CannotOpenDisputeTwice() public {
        uint256 cid = _createAndFund(threeAmounts, threeHashes);
        _start(cid);

        vm.prank(client);
        escrow.openDispute(cid);

        vm.prank(client);
        vm.expectRevert(MilestoneEscrow.DisputeAlreadyOpen.selector);
        escrow.openDispute(cid);
    }

    // =========================================================================
    // Cancel before funding
    // =========================================================================

    function test_CancelDraftContract() public {
        vm.prank(client);
        uint256 cid = escrow.createContract(freelancer, address(usdc), threeAmounts, threeHashes);

        vm.prank(client);
        escrow.cancelContract(cid);

        MilestoneEscrow.EscrowContract memory c = escrow.getContract(cid);
        assertEq(uint(c.state), uint(MilestoneEscrow.ContractState.Cancelled));
    }

    function test_CannotCancelFundedContract() public {
        uint256 cid = _createAndFund(threeAmounts, threeHashes);

        vm.prank(client);
        vm.expectRevert();
        escrow.cancelContract(cid);
    }

    // =========================================================================
    // Platform fee withdrawal — only admin, only fees not user funds
    // =========================================================================

    function test_AdminWithdrawsPlatformFees() public {
        uint256 cid = _createAndFund(threeAmounts, threeHashes);
        _start(cid);
        _submit(cid, 0);
        _approve(cid, 0);

        uint256 fee = (300e6 * 250) / 10_000;
        assertEq(escrow.platformFees(address(usdc)), fee);

        uint256 adminBefore = usdc.balanceOf(admin);
        vm.prank(admin);
        escrow.withdrawPlatformFees(address(usdc), admin);
        assertEq(usdc.balanceOf(admin) - adminBefore, fee);
        assertEq(escrow.platformFees(address(usdc)), 0);
    }
}
