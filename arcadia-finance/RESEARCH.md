# Arcadia Finance Security Research
Date: June 2026
Protocol: Arcadia Finance (margin protocol, Base/Optimism/Unichain)
Bounty: HackenProof $25K max Critical

## Methodology
- 12-agent dlt-auditor sweep on asset-managers repo
- Manual review of 14/33 files
- Live Base mainnet fork PoC for highest-signal lead

## Finding: Slipstream._unstake overwrite vs accumulate (DISPROVEN)
File: src/cl-managers/base/Slipstream.sol:276
Result: DEAD. claimReward() and burn() both derive rewards from
AERO.balanceOf(address(this)) after draining the gauge in same block.
No per-tx window where both return non-zero.
