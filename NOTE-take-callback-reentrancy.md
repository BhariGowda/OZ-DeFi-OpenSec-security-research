# NOTE: `take` onBuy/onSell callback reentrancy — Certora gap acknowledged, runtime safe, no exploit found

**Target:** `src/Midnight.sol` — `take()` callbacks (`onBuy` @445, `onSell` @458)
**PoC:** `test/PocReentrancy.sol` (5 vectors, all pass)
**Status:** NOT A FINDING. Formal-verification gap is real; runtime is safe.

## The gap (real)

`take` commits all state effects (positions, `totalUnits`, `claimableSettlementFee`, `consumed`)
*before* `onBuy` (445), the inbound transfers (455–456), and `onSell` (458). The CEI ordering is
inverted, and there is no global reentrancy guard.

Certora stubs `onBuy`/`onSell` as `NONDET` in **every** spec that touches them, including
`Solvency.spec` (which DISPATCHes `onLiquidate`/`onRepay`/`onFlashLoan` but not the two `take`
callbacks). `OnlyAuthorizedCanChange`, `BalanceEffects`, `ContinuousFee`, `LossFactor`,
`SettlementFeeSpread` all state the assumption explicitly. So reentrancy through `take`'s callbacks
is **formally unmodeled** — the central solvency invariant is proven only under an assumption the
contract does not enforce for callbacks (it is enforced for *token transfers* via the token-safety
requirement, but `onBuy`/`onSell` are arbitrary attacker contracts).

## The harness

`test/PocReentrancy.sol` drives a malicious `Attacker` that implements all five callbacks and
re-enters Midnight exactly once inside `onBuy`/`onSell`, then checks three invariants on the FINAL
state:

1. **tokenBalanceCorrect** — `loanToken.balanceOf(midnight) >= withdrawable + claimableSettlementFee`
2. **creditXORdebt** — no user has `credit > 0 && debt > 0`
3. **totalUnits** — `Σ updatePositionView(credit) + continuousFeeCredit == totalUnits`

Vectors: re-enter `take` (onBuy), `withdraw` (onBuy), `repay` (onSell), `liquidate` (onBuy),
`flashLoan` (onBuy).

## Result: all invariants hold

| Vector | Re-entered call | Outcome |
|--------|-----------------|---------|
| A | `take` during `onBuy` | All 3 hold. Attacker just stacks a second legitimate buy. |
| B | `withdraw` during `onBuy` | All 3 hold. Attacker nets +50 wei — see below. |
| C | `repay` during `onSell` | All 3 hold. Attacker repays its own fresh debt. |
| D | `liquidate` during `onBuy` | INV1/INV2 hold; INV3 off by **1 wei**, see below. |
| E | `flashLoan` during `onBuy` | All 3 hold. |

### Vector D — the only "break" was documented rounding, proven by a control

INV3 with strict equality fails by 1 wei because `liquidate` realizes bad debt, and the code
rounds `lossFactor` up so "lenders collectively lose a bit more than badDebt" (Midnight.sol:117).
The true invariant is `Σ credit <= totalUnits`, which holds. **Control:** the harness runs the
identical operations reentrantly vs. sequentially (`take` fully, then `liquidate`) and asserts the
end states are equal:

```
[reentrant]  totalUnits: 23   sumCredit: 22   gap: 1
[sequential] totalUnits: 23   sumCredit: 22   gap: 1   (identical)
```

The reentrancy changes nothing — the 1-wei gap is pre-existing, reentrancy-independent rounding.

### Vector B — the +50 wei is not theft

Attacker buys 100 units of credit for 50 (sell offer at price 0.5) and withdraws 100 from a
pre-seeded `withdrawable` pool during `onBuy`, before its own payment lands. It nets +50. But this
is the **documented** "race to withdraw resting sell offers with price < 1" (Midnight.sol:27–29):
the maker (`borrower`) willingly took 50 now against 100 of debt, the withdrawn 100 is now backed
by that new 100 debt, `totalUnits == Σ credit == 500` afterward, and the system stays fully solvent
(INV1 holds with a 100-wei margin). It is also reproducible with two sequential calls
(`take` then `withdraw`) — reentrancy adds nothing.

## Why reentrancy can't break it (root cause)

1. **`take` never increases `withdrawable`** — the only liquid pool. Credit minted in `take` needs a
   counterparty repayment/maturity to become withdrawable, so unpaid-for credit can't be drained.
2. **Payment is atomic** — whatever a callback does, `safeTransferFrom` at 455–456 must still
   succeed or the whole tx reverts. Every reentrant sequence settles to a state reachable by some
   sequence of ordinary calls.
3. **Seller liquidation-lock + final health check** (444/475/476) — correct under nesting: the
   outermost `take` that touched `(id, seller)` is the one that unlocks and runs the health check
   last, against cumulative state.
4. **At `onBuy`, contract balance is still the pre-take balance** (no transfer yet) and
   `withdrawable` is unchanged, so a reentrant `withdraw` is bounded by pre-take withdrawable that
   already satisfied INV1.

## Recommendation (defense-in-depth, not a bug fix)

The contract is safe today but the safety rests on emergent reasoning (#1–#4), not an enforced
guard, and the proofs don't cover it. Either:
- add `Solvency.spec` rules with `onBuy`/`onSell` as `DISPATCHER` against a reentering helper (as is
  already done for `onLiquidate`/`onRepay`/`onFlashLoan`), to close the verification gap; or
- document the non-reentrancy of `onBuy`/`onSell` as a relied-upon property rather than only an
  assumption convenient for the prover.

Run: `forge test --match-contract PocReentrancy -vv`
