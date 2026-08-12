// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "forge-std/Script.sol";
import "../contracts/ProfileRegistry.sol";
import "../contracts/ProjectRegistry.sol";
import "../contracts/LicenseRegistry.sol";
import "../contracts/MilestoneEscrow.sol";
import "../contracts/ReputationAttestation.sol";
import "../contracts/ReferralRegistry.sol";

/// @notice Phase 1 deployment: ProfileRegistry + ProjectRegistry + MilestoneEscrow
/// @dev Run with:
///      forge script scripts/Deploy.s.sol --rpc-url $RPC_URL --broadcast --verify
///
/// Required env vars:
///   DEPLOYER_PRIVATE_KEY  — deployer wallet
///   ADMIN_MULTISIG        — multisig that will hold admin roles (Gnosis Safe etc.)
///   ARBITRATOR_ADDRESS    — wallet/multisig for dispute resolution
///   USDC_ADDRESS          — USDC token address on the target network
contract DeployPhase1 is Script {

    // -------------------------------------------------------------------------
    // Governance config (adjust before deploying)
    // -------------------------------------------------------------------------
    uint48  constant ADMIN_TRANSFER_DELAY = 2 days;  // two-step admin transfer delay
    uint256 constant DEFAULT_FEE_BPS      = 250;     // 2.5%

    function run() external {
        address adminMultisig  = vm.envAddress("ADMIN_MULTISIG");
        address arbitrator     = vm.envAddress("ARBITRATOR_ADDRESS");
        address usdcAddress    = vm.envAddress("USDC_ADDRESS");
        uint256 deployerKey    = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer       = vm.addr(deployerKey);

        console.log("=== Web3LinkedIn Phase 1 Deployment ===");
        console.log("Deployer:     ", deployer);
        console.log("Admin multisig:", adminMultisig);
        console.log("Arbitrator:   ", arbitrator);
        console.log("USDC:         ", usdcAddress);

        vm.startBroadcast(deployerKey);

        // 1. ProfileRegistry
        ProfileRegistry profile = new ProfileRegistry(ADMIN_TRANSFER_DELAY, adminMultisig);
        console.log("ProfileRegistry:", address(profile));

        // 2. ProjectRegistry
        ProjectRegistry project = new ProjectRegistry(ADMIN_TRANSFER_DELAY, adminMultisig);
        console.log("ProjectRegistry:", address(project));

        // 3. MilestoneEscrow
        MilestoneEscrow escrow = new MilestoneEscrow(ADMIN_TRANSFER_DELAY, adminMultisig);
        escrow.allowToken(usdcAddress);
        // Grant arbitrator role
        escrow.grantRole(escrow.ARBITRATOR_ROLE(), arbitrator);
        console.log("MilestoneEscrow:", address(escrow));

        // 4. LicenseRegistry (Phase 2 — deploy address already known for linking)
        LicenseRegistry license = new LicenseRegistry(
            address(project),
            ADMIN_TRANSFER_DELAY,
            adminMultisig
        );
        // Link LicenseRegistry into ProjectRegistry (one-time, irreversible)
        project.setLicenseRegistry(address(license));
        // Allow USDC in LicenseRegistry (via timelock — must wait FEE_TIMELOCK_DELAY)
        // NOTE: propose first, then apply after delay on a second tx
        license.proposeTokenChange(usdcAddress, true);
        console.log("LicenseRegistry:", address(license));
        console.log(">>> LicenseRegistry token allowlist change proposed.");
        console.log(">>> Run applyTokenChange() after", uint(license.FEE_TIMELOCK_DELAY()), "seconds.");

        // 5. ReputationAttestation
        ReputationAttestation reputation = new ReputationAttestation(ADMIN_TRANSFER_DELAY, adminMultisig);
        console.log("ReputationAttestation:", address(reputation));

        // 6. ReferralRegistry
        ReferralRegistry referral = new ReferralRegistry(ADMIN_TRANSFER_DELAY, adminMultisig);
        console.log("ReferralRegistry:", address(referral));

        vm.stopBroadcast();

        console.log("\n=== Post-deployment checklist ===");
        console.log("[ ] Transfer VERIFIER_ROLE in ProfileRegistry to backend wallet");
        console.log("[ ] Transfer ATTESTER_ROLE in ReputationAttestation to backend wallet");
        console.log("[ ] Transfer REGISTRAR_ROLE in ReferralRegistry to backend wallet");
        console.log("[ ] Apply LicenseRegistry token allowlist after timelock expires");
        console.log("[ ] Verify all contracts on block explorer");
        console.log("[ ] Configure Gnosis Safe with all admin multisig roles");
        console.log("[ ] Run full test suite against deployed addresses");
        console.log("[ ] Complete independent security audit before mainnet");
    }
}

/// @notice Phase 2 (run after Phase 1 is audited and stable)
contract ApplyLicenseTokenAllowlist is Script {
    function run() external {
        address licenseRegistry = vm.envAddress("LICENSE_REGISTRY");
        uint256 deployerKey     = vm.envUint("DEPLOYER_PRIVATE_KEY");

        vm.startBroadcast(deployerKey);
        LicenseRegistry(licenseRegistry).applyTokenChange();
        vm.stopBroadcast();

        console.log("Token allowlist applied to LicenseRegistry:", licenseRegistry);
    }
}
