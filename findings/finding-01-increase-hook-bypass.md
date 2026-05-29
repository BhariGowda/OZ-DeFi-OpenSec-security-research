# Finding 01 — `PermissionedPositionManager._increase()` not overridden; `isAllowedHooks` check bypassed for existing positions

**Status:** Draft — awaiting Foundry PoC  
**Date:** 2026-05-29  
**Target contracts:** `PermissionedPositionManager.sol`, `PositionManager.sol`  
**Severity (draft):** High  
**CVSS 3.1 (draft):** AV:N/AC:L/PR:L/UI:N/S:U/C:N/I:H/A:N → 6.5

---

## Summary

`PermissionedPositionManager` overrides `_mint()` to enforce `isAllowedHooks` before any new
position is opened, but **does not override `_increase()`**. The base
`PositionManager._increase()` is therefore called for `INCREASE_LIQUIDITY` actions, and it
contains no hook-allowance check. An admin who de-lists a compromised hook via `setAllowedHook`
stops new mints through that hook, but every holder of an existing position can still add
liquidity into it — feeding tokens directly into the compromised hook's `modifyLiquidity`
callback with no on-chain gate.

---

## Root cause

### What `_mint()` does (correctly guarded)

```solidity
// PermissionedPositionManager.sol
function _mint(
    PoolKey calldata poolKey,
    int24 tickLower,
    int24 tickUpper,
    uint256 liquidity,
    uint128 amount0Max,
    uint128 amount1Max,
    address owner,
    bytes calldata hookData
) internal override {
    if (!_checkAllowedHooks(poolKey)) revert InvalidHook();      // ← hook check
    _checkRecipientAllowed(poolKey.currency0, owner);
    _checkRecipientAllowed(poolKey.currency1, owner);
    super._mint(...);
}
```

`_checkAllowedHooks` consults `isAllowedHooks[currency][hooks]` for each permissioned currency
in the pool key. If the hook has been de-listed, `_mint()` reverts.

### What `_increase()` does (missing override)

`PermissionedPositionManager` has **no `_increase()` override**.
Execution falls through to `PositionManager._increase()`:

```solidity
// PositionManager.sol  (base class — unchanged)
function _increase(
    uint256 tokenId,
    uint256 liquidity,
    uint128 amount0Max,
    uint128 amount1Max,
    bytes calldata hookData
) internal onlyIfApproved(msgSender(), tokenId) {
    (PoolKey memory poolKey, PositionInfo info) = getPoolAndPositionInfo(tokenId);
    // ← NO isAllowedHooks check, NO _checkRecipientAllowed check
    (BalanceDelta liquidityDelta, BalanceDelta feesAccrued) =
        _modifyLiquidity(info, poolKey, liquidity.toInt256(), bytes32(tokenId), hookData);
    (liquidityDelta - feesAccrued).validateMaxIn(amount0Max, amount1Max);
}
```

`_modifyLiquidity` calls `poolManager.modifyLiquidity(poolKey, ...)`, which invokes the
pool's hook — even if that hook has been de-listed by the admin.

---

## Attack scenario

**Preconditions:**
- A permissioned pool exists with hook `H` on a permissioned currency.
- Alice holds an existing LP position (tokenId N) in that pool.
- Admin discovers hook `H` is compromised and calls `setAllowedHook(currency, H, false)`.

| Step | Actor | Action |
|------|-------|--------|
| 1 | Admin | `setAllowedHook(currency, H, false)` — de-lists `H` |
| 2 | Alice (attacker) | Calls `modifyLiquidities([INCREASE_LIQUIDITY], [tokenId=N, liquidity=X, ...])` |
| 3 | Dispatch | Routes to `PositionManager._increase()` (no override in subclass) |
| 4 | `_increase` | Loads `poolKey` from storage — hook field is still `H` |
| 5 | `poolManager.modifyLiquidity` | Invokes `H.beforeModifyLiquidity` / `afterModifyLiquidity` callbacks |
| 6 | Hook `H` | Executes malicious logic (drain, price manipulation, re-entrancy) |
| 7 | Check | No `isAllowedHooks` gate was consulted — call succeeds |

New mints are blocked (step 1 makes `_mint` revert), but **the de-listing has zero effect on
`INCREASE_LIQUIDITY`**.

The same gap exists for `_decrease()` and `_burn()`, but those withdraw liquidity rather than
deposit it, so the financial risk is lower. The critical case is increase: the user is
*sending fresh tokens into the compromised hook*.

---

## Impact

After an admin emergency de-listing of a compromised hook:

1. Any position holder can call `INCREASE_LIQUIDITY` on a position that uses the de-listed hook.
2. The compromised hook's `afterModifyLiquidity` callback executes with full access to the
   delta, potentially stealing the deposited tokens.
3. The admin's emergency action is rendered ineffective until every holder has been individually
   notified and stops using the contract.

This defeats the primary security invariant of the permissioned pools system: that admin
de-listing of a hook prevents all further liquidity flow through it.

---

## Severity rationale

| Factor | Value |
|--------|-------|
| Attack vector | Network — any position holder |
| Complexity | Low — standard `INCREASE_LIQUIDITY` action |
| Privileges | Low — only own position required |
| User interaction | None |
| Impact | High — tokens sent directly into a hook that admin marked compromised |

High severity because it negates an admin emergency control and can cause direct loss of
tokens for any LP who increases liquidity after a de-listing event.

---

## Recommended fix

Override `_increase()` in `PermissionedPositionManager` with the same hook and recipient
checks used in `_mint()`:

```solidity
function _increase(
    uint256 tokenId,
    uint256 liquidity,
    uint128 amount0Max,
    uint128 amount1Max,
    bytes calldata hookData
) internal override {
    (PoolKey memory poolKey,) = getPoolAndPositionInfo(tokenId);
    if (!_checkAllowedHooks(poolKey)) revert InvalidHook();
    _checkRecipientAllowed(poolKey.currency0, msgSender());
    _checkRecipientAllowed(poolKey.currency1, msgSender());
    super._increase(tokenId, liquidity, amount0Max, amount1Max, hookData);
}
```

Consider whether `_decrease()` and `_burn()` also need the hook check — de-listing a
compromised hook should arguably prevent the hook from running on *any* liquidity action,
not just adds.

---

## Evidence needed (Gate 0 TODO)

- [ ] Foundry fork test:
  1. Deploy `PermissionedPositionManager` + permissioned pool with hook `H`.
  2. Mint a position (passes).
  3. Admin calls `setAllowedHook(currency, H, false)`.
  4. Assert that `MINT_POSITION` now reverts with `InvalidHook`.
  5. Assert that `INCREASE_LIQUIDITY` on the existing position **does not** revert and
     invokes `H`'s callbacks — confirming the bypass.

---

## References

- `PermissionedPositionManager.sol` — `_mint()` override with `_checkAllowedHooks` guard
- `PermissionedPositionManager.sol` — absence of `_increase()` override
- `PermissionedPositionManager.sol` — `setAllowedHook()` admin control
- `PermissionedPositionManager.sol` — `_checkAllowedHook()` / `_checkAllowedHooks()` helpers
- `PositionManager.sol` — base `_increase()` with no hook validation
