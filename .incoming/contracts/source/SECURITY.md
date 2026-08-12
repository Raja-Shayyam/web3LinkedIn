# Web3LinkedIn — Security Notes & Architecture Decisions

## What Changed from Doc-2 Contracts (and Why)

| Issue in Doc-2 | Fix in These Contracts |
|---|---|
| `ReputationAttestation` stored mutable `totalScore` (spec: forbidden) | Replaced with immutable append-only `Attestation` records + summary counters that only increment |
| `LicenseMarketplace` transferred NFT on every purchase (license ≠ ownership) | `LicenseRegistry` records exact license type; NFT transfer only happens on `FullIPTransfer` type |
| `ProjectRegistry` ERC-721 freely transferable via standard `transferFrom` | `transferFrom` / `safeTransferFrom` are blocked; only `LicenseRegistry.transferProject()` can move it |
| Single `onlyOwner` admin resolves disputes (no separate arbitrator role) | `ARBITRATOR_ROLE` is separate from `DEFAULT_ADMIN_ROLE`; arbitrator cannot withdraw funds |
| No `Pausable`, no `SafeERC20`, no token allowlist, no timelock on fees | All added; fee changes and token allowlist changes both timelocked 2 days |
| No fee hard-cap enforcement | `FEE_CAP_BPS = 1000` (10%) hard-coded constant, cannot be overridden |
| Admin `onlyOwner` (single key) everywhere | `AccessControlDefaultAdminRules` — 2-step, timelocked admin transfer |
| `resolveDispute` could re-pay already-paid milestones | Now operates only on `lockedBalance`, never touches already-paid amounts |

---

## Invariants (machine-checked in test suite)

- **I-1** `lockedBalance + totalReleased == fundedAmount` after every state change
- **I-2** A paid milestone's `paid` flag is set to `true` permanently; cannot be paid again
- **I-3** Payment per milestone == exactly `milestone.amount`; never more
- **I-4** `platformFeeBps <= FEE_CAP_BPS` always; timelocked changes cannot exceed cap
- **I-5** Only `client` calls `approveMilestone`; only `freelancer` calls `submitMilestone`
- **I-6** `client != freelancer` enforced at `createContract` time
- **I-7** In `Disputed` state, `lockedBalance` is untouchable except by arbitrator via `resolveDispute`
- **I-8** `DEFAULT_ADMIN_ROLE` has no path to user escrow funds
- **I-9** Arbitrator can only distribute `lockedBalance` of the specific disputed contract
- **I-10** `milestoneIndex == currentMilestone` enforced on every submit/approve/reject
- **I-11** `requestRefund` refunds exactly `lockedBalance`, never more

---

## Role Summary

| Role | Contract | What it can do | What it CANNOT do |
|---|---|---|---|
| `DEFAULT_ADMIN_ROLE` | All | Grant/revoke roles, withdraw platform fees, allow tokens | Touch user escrow, approve milestones, resolve disputes |
| `VERIFIER_ROLE` | ProfileRegistry | Grant/revoke student & recruiter badges, platform-controlled wallet recovery | Move user funds, create profiles for other users |
| `ARBITRATOR_ROLE` | MilestoneEscrow | `resolveDispute()` on a Disputed contract | Withdraw platform fees, create/cancel contracts |
| `FEE_MANAGER_ROLE` | MilestoneEscrow, LicenseRegistry | Propose fee and token allowlist changes (timelocked) | Apply changes before timelock, touch user funds |
| `ATTESTER_ROLE` | ReputationAttestation | Submit attestations | Delete or modify past attestations |
| `REGISTRAR_ROLE` | ReferralRegistry | Record referrals | Mark referrals as rewarded (that's `DEFAULT_ADMIN_ROLE`) |
| `PAUSER_ROLE` | All | Pause/unpause | Any fund movement |

**Recommended deployment:** All admin roles → Gnosis Safe multisig (3-of-5 minimum). `ARBITRATOR_ROLE` → separate multisig or eventually Kleros.

---

## What Is NOT in Contracts (intentionally)

- Platform token / tokenomics
- DAO governance
- Upgradeability (non-upgradeable by design for escrow trust)
- Google OAuth / email addresses
- GitHub access control (backend event listener only)
- AI reputation scores
- Any PII (names, bios, emails) — only hashes
- ETH native payment (add later if needed via separate tested path)
- Gasless / paymaster logic (backend/Paymaster concern)

---

## Before Testnet Deployment

- [ ] Run `forge test -vvv` — all tests green
- [ ] Run `forge coverage` — target > 90%
- [ ] Run Slither: `slither . --config-file slither.config.json`
- [ ] Run Echidna or Foundry invariant tests
- [ ] Generate gas report: `forge test --gas-report`
- [ ] Pin exact OpenZeppelin version in `foundry.toml` remappings

## Before Mainnet

- [ ] Independent security audit (Spearbit, Code4rena, Sherlock, or equivalent)
- [ ] Multisig operational security review
- [ ] Legal review of license terms and IP-transfer language in contract comments
- [ ] Formal disclosure: arbitration is centralized (MVP) — publish in platform ToS

---

## Legal Notes (Important)

Transferring the project NFT (`FullIPTransfer` license type) does NOT automatically constitute a legally binding copyright transfer in most jurisdictions. The NFT is an on-chain record and timestamp anchor. Actual IP transfer requires off-chain legal agreements. The contract comments make this explicit but the platform ToS must reinforce it.
