# [HIGH] Borrower can socialize "phantom" bad debt to lenders on a solvent position via `liquidate(0,0)`, stealing up to ~30% of collateral value

**Target:** `src/Midnight.sol` — `liquidate()` (bad-debt realization block, lines 605–641)
**Commit:** `7538c438513622721e23a94676b93a335b83dace`

## Summary

`liquidate` realizes bad debt **unconditionally** at the start of the call (whenever the
computed `badDebt > 0`), independently of whether any collateral is seized. The protocol also
allows a "zero" liquidation (`seizedAssets == 0 && repaidUnits == 0`) which runs *only* the
bad-debt block and transfers no tokens.

`badDebt` is computed with the worst-case liquidation incentive `maxLif`:

```solidity
// Midnight.sol:613-616
maxDebt += _collateral.mulDivDown(price, ORACLE_PRICE_SCALE).mulDivDown(_collateralParam.lltv, WAD);
badDebt = badDebt.zeroFloorSub(
    _collateral.mulDivUp(price, ORACLE_PRICE_SCALE).mulDivUp(WAD, _collateralParam.maxLif)
);
```

i.e. `badDebt = debt − Σ collateralValueᵢ / maxLifᵢ`.

Because `maxLif > 1`, `badDebt` is strictly positive on **solvent** positions whenever

```
collateralValue / maxLif  <  debt  <  collateralValue
```

This band always sits *above* the liquidation threshold (`debt > maxDebt = collateralValue·lltv`),
so it is reachable by any position whose collateral price has fallen past its LLTV trigger but not
yet below the debt. A borrower in this band can call `liquidate(market, i, 0, 0, self, false, …)`
on **their own position** to wipe `badDebt` units of debt for free — no collateral leaves the
position — and the loss is socialized to all lenders through `lossFactor`. They then repay the
reduced debt at par and reclaim 100% of their collateral, having paid `badDebt` less than they
owed. The stolen amount equals the lenders' loss.

## Why this is wrong

A solvent position (`collateralValue ≥ debt`) has, by definition, **zero** genuine bad debt — a
partial liquidation or a repayment fully covers the lenders. The `maxLif` worst-case term is a
conservatism that is only justified when the corresponding collateral is actually seized (normal
coupled liquidation, where the borrower loses the collateral and does not benefit). Realizing it
**standalone**, while the borrower keeps every token of collateral, turns a conservative estimate
into a direct, attacker-triggered transfer of value from lenders to the borrower.

`lossFactor` only ever slashes lender **credit**; a borrower holds **debt** (never both), so the
borrower bears none of the socialized loss — it is pure profit for them.

## Impact

- **Direct theft from lenders**, triggerable by any borrower with no special role and **0 token
  cost** for the realization step (the repay-to-health step uses ordinary capital the borrower
  would have spent anyway).
- Magnitude = `badDebt`, bounded by `collateralValue · cursor · (1 − lltv)`:

  | LLTV  | maxLif (cursor 0.5) | max stolen (% of collateral value) |
  |-------|---------------------|------------------------------------|
  | 0.385 | 1.444 | **30.75%** |
  | 0.625 | 1.231 | 18.75% |
  | 0.77  | 1.130 | 11.50% |
  | 0.86  | 1.075 | 7.00% |
  | 0.915 | 1.044 | 4.25% |

- The same loss is also inflicted on lenders by a *normal third-party liquidation* of a solvent
  position (the bad-debt block runs first regardless), so it is a general accounting defect; the
  self-liquidation is the cleanest weaponization.

## Proof of Concept

`test/PocSelfBadDebt.sol` (passes). lltv = 0.77, single collateral. Borrower opens at the LLTV
boundary, the oracle price then drops so collateral is worth 100 units against a 98-unit debt
(solvent: 100 ≥ 98, but unhealthy: maxDebt = 77 < 98). The borrower self-calls `liquidate(0,0)`:

```
debt wiped for free (units):            3.749999999999999945
lender loss (units):                    3.749999999999999946
borrower saved / lender lost (units):   3.749999999999999945
```

The borrower's collateral is untouched, the position is even more solvent afterwards, and the
borrower then repays the *reduced* debt at par and reclaims **all** collateral — having paid 94.25
to clear a 98 obligation. The 3.75 difference is taken directly from the lender's credit.

Run:
```
forge test --match-contract PocSelfBadDebt -vv
```

## Recommended fix

Do not realize bad debt that is not backed by an actual collateral shortfall / seizure. Options:

1. Only realize bad debt **after** the position's collateral has been (fully) seized in the same
   call — i.e. compute residual bad debt against *remaining* collateral after the seize, not as a
   precondition; or gate the standalone `(0,0)` realization on the position having genuinely
   insufficient collateral (`collateralValue < debt`, not `collateralValue/maxLif < debt`).
2. Compute the bad-debt threshold using the *actual* applied `lif` for the seized collateral
   rather than the global `maxLif`, and only on the seized portion.
3. At minimum, forbid `liquidate` from reducing debt via bad-debt realization when no collateral is
   seized and the position is solvent (`Σ collateralValue ≥ debt`).
