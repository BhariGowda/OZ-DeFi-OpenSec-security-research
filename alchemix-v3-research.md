# Alchemix v3 Security Research
Date: June 2026
Protocol: Alchemix v3 (self-repaying loans, Ethereum)
Bounty: Immunefi $300K max Critical

## Methodology
- 12-agent dlt-auditor sweep (2 rounds, session limits hit)
- Manual deep dive on Transmuter.sol + AlchemistV3.sol core
- Mainnet fork PoC for earmark/redemption drift hypothesis

## Leads investigated

### Lead 1: MYT-share-price fee-vault drain (DEAD)
Hypothesis: deflate IVaultV2(myt).convertToAssets to trigger
artificial global undercollateralization + fee-vault payout.
Result: Not permissionlessly achievable. MYT bounded by maxRate cap
and frozen via transient firstTotalAssets per-tx. All strategy
realAssets() non-spot-manipulable.

### Lead 2: claimRedemption NFT burned before redeem reverts (DEAD)
Result: CEI pattern correctly implemented. No stuck-funds path.

### Lead 3: Earmark/redemption survival accounting drift (DISPROVEN)
File: src/test/PoCEarmarkDrift.t.sol
Test: test_PoC_DriftAmplification — 10 adversarial cycles
MAX DRIFT: 0 wei. SOLVENCY held every cycle.
Team's own HardenedInvariants suite covers this surface.

## Conclusion
Alchemix v3 is unusually well-defended. 112 AI-rejected findings
already swept shallow water. No Critical/High found.
