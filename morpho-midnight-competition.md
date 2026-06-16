# Morpho Midnight Cantina Competition
Date: May-June 2026
Protocol: Morpho Midnight (fixed-rate lending, Ethereum)
Prize Pool: $400K | Status: Judging

## Findings Submitted (4 total)

### #188 Duplicate High (CONFIRMED)
Post-maturity seizedAssets liquidation underflows on bad debt positions
- liquidate() post-maturity: repaidUnits > _position.debt causes underflow
- Panic(0x11) instead of descriptive revert
- PoC: test/PocFinding01.sol [PASS] 3 tests

### #219 Duplicate Medium (CONFIRMED)
continuousFeeCredit can exceed withdrawable, blocking fee claims
- _updatePosition accrues fees without token movement
- claimContinuousFee debits withdrawable, reverts if credit > withdrawable
- PoC: test/PocFinding05FeeBlock.sol [PASS] 3 tests

### #218 New Informational
Referral fee under-budgeting in repayAndWithdrawCollateral
- referralFeeAssets computed from post-fee units, causing under-budget

### #2816 Duplicate Medium (submitted Jun 10)
liquidate() seizedAssets branch allows free collateral seizure at price==0
- Certora Reverts.spec covers repaidUnits path but NOT seizedAssets path
- PoC: test/PocFinding07ZeroPriceSeizure.sol [PASS] 3 tests
- Note: canonical finding #17 marked Rejected (oracle trust model)

## Competition Stats
- Total findings: 3,890
- Your findings: 4 (3 confirmed valid by judges)
- #188 upgraded: Informational → High by judge silverologist
