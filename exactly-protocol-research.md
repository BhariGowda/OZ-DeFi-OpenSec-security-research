# Exactly Protocol Security Research
Date: June 2026
Protocol: Exactly Protocol (fixed/variable lending, Optimism/Base)
Bounty: HackenProof $25K max Critical

## Methodology
- 12-agent dlt-auditor sweep on asset-managers (InstallmentsRouter)
- Manual review of high-signal files
- Live fork PoC for highest-signal lead

## Contracts audited
- InstallmentsRouter.sol (2024, already audited)
- DeadAllower.sol, FlashLoanAdapter.sol, DebtRoller.sol (Oct-Nov 2025, newest)

## Findings
All leads dead:
- Mid-loop reentrancy: standard ERC20s, no callback to borrower
- Deferred slippage: self-affecting only, maxAssets cap
- borrowETH WETH accounting: principal only, fees are debt-only, no shortfall
- Permit front-running: try/catch documented mitigation, not DoS
- checkMarket: correctly reads isListed, spoofed market holds nothing

## Conclusion
InstallmentsRouter is small, well-constructed, borrower==msg.sender
invariant holds everywhere. No Critical/High found.
