# Finding 02 — `createPermissionsAdapter` is permissionless; `verifyPermissionsAdapter` passes on 1 wei balance

**Status:** Draft — awaiting Foundry PoC  
**Date:** 2026-05-29  
**Target contract:** `PermissionsAdapterFactory.sol`  
**Severity (draft):** High  
**CVSS 3.1 (draft):** AV:N/AC:L/PR:N/UI:R/S:C/C:H/I:H/A:N → 8.7

---

## Summary

`PermissionsAdapterFactory.createPermissionsAdapter()` has no access control — any address
can deploy a `PermissionsAdapter` for any ERC-20 token and set themselves as the adapter's
`owner`. `verifyPermissionsAdapter()` then marks that adapter as "verified" based solely on
the condition `permissionedToken.balanceOf(adapter) > 0`, which costs 1 wei of the target
token.

A verified adapter is the root-of-trust for a permissioned pool: `PermissionedPositionManager`
uses `verifiedPermissionsAdapterOf[currency]` to decide whether a currency is "permissioned"
and, if so, delegates all access decisions (who may add liquidity, which hooks are allowed) to
the adapter's `owner`. An attacker who owns a verified adapter for e.g. USDC can therefore:

1. Set a malicious `allowListChecker` (blocking all legitimate users, or allowing only the attacker).
2. Call `setAllowedHook` on the `PermissionedPositionManager` for their adapter's currency
   (ownership check passes because they own the adapter).
3. Allow a malicious hook, draw users into that pool, and drain deposited tokens.

---

## Root cause

### `createPermissionsAdapter` — no access control

```solidity
// PermissionsAdapterFactory.sol
function createPermissionsAdapter(
    IERC20 permissionedToken,
    address initialOwner,          // ← caller sets themselves as owner
    IAllowlistChecker allowListChecker
) external returns (address permissionsAdapter) {
    permissionsAdapter = address(
        new PermissionsAdapter(permissionedToken, POOL_MANAGER, initialOwner, allowListChecker)
    );
    permissionsAdapterOf[permissionsAdapter] = address(permissionedToken);
    emit PermissionsAdapterCreated(permissionsAdapter, address(permissionedToken));
}
```

There is no `onlyOwner`, no whitelist, no signature — any EOA or contract may call this.

### `verifyPermissionsAdapter` — balance of 1 is sufficient

```solidity
// PermissionsAdapterFactory.sol
function verifyPermissionsAdapter(address permissionsAdapter) external {
    IERC20 permissionedToken = IERC20(permissionsAdapterOf[permissionsAdapter]);
    if (address(permissionedToken) == address(0)) revert PermissionsAdapterNotFound(permissionsAdapter);
    if (verifiedPermissionsAdapterOf[permissionsAdapter] != address(0)) {
        revert PemissionsAdapterAlreadyVerified(permissionsAdapter);
    }
    // this requires that the verifier has some control or ownership of the permissioned token
    if (permissionedToken.balanceOf(permissionsAdapter) == 0) {   // ← trivial to satisfy
        revert PemissionsAdapterNotVerified(permissionsAdapter);
    }
    verifiedPermissionsAdapterOf[permissionsAdapter] = address(permissionedToken);
    emit PemissionsAdapterVerified(permissionsAdapter, address(permissionedToken));
}
```

The comment says *"requires that the verifier has some control or ownership of the permissioned
token"* but the actual check only requires that the adapter contract holds ≥ 1 wei of the
token — a condition anyone can satisfy with a `transfer(adapter, 1)`.

### How the `PermissionedPositionManager` uses verified adapters

```solidity
// PermissionedPositionManager.sol
function _verifiedPermissionedTokenOf(Currency currency) internal view returns (address) {
    return PERMISSIONS_ADAPTER_FACTORY.verifiedPermissionsAdapterOf(Currency.unwrap(currency));
}

function _getOwner(Currency currency) internal view returns (address) {
    address permissionsAdapter = Currency.unwrap(currency);
    address permissionedToken = _verifiedPermissionedTokenOf(currency);
    if (permissionedToken == address(0)) return address(0);
    return IPermissionsAdapter(permissionsAdapter).owner();    // ← adapter owner is trusted unconditionally
}
```

`_getOwner` is the guard on `setAllowedHook`. Whoever owns a verified adapter can set which
hooks are allowed for that currency. There is no independent check that the adapter owner is
the legitimate issuer of the underlying token.

---

## Attack scenario

**Cost:** 1 wei of the target ERC-20 (e.g. 1 wei USDC ≈ $0.000001).  
**Precondition:** Target ERC-20 does not yet have a verified adapter, **or** attacker is
content creating a parallel fraudulent one.

| Step | Actor | Action |
|------|-------|--------|
| 1 | Attacker | Deploys `MaliciousChecker` implementing `IAllowlistChecker` — returns `LIQUIDITY_ALLOWED` for attacker only, zero for everyone else |
| 2 | Attacker | Calls `factory.createPermissionsAdapter(USDC, attacker, MaliciousChecker)` — deploys `evilAdapter` with attacker as `owner` |
| 3 | Attacker | Sends 1 wei USDC to `evilAdapter` |
| 4 | Attacker | Calls `factory.verifyPermissionsAdapter(evilAdapter)` — passes; `verifiedPermissionsAdapterOf[evilAdapter] = USDC` |
| 5 | Attacker | Creates a v4 pool with `currency0 = evilAdapter` (a valid ERC-20 wrapping USDC) |
| 6 | Attacker | Calls `posManager.setAllowedHook(evilAdapter, maliciousHook, true)` — passes because `_getOwner(evilAdapter) == attacker` |
| 7 | Victim | Sees a "verified" USDC pool with high APR and adds liquidity via `MINT_POSITION` |
| 8 | `_mint` | `_checkAllowedHooks` passes (hook is on attacker's allow-list); `_checkRecipientAllowed` passes (victim has `LIQUIDITY_ALLOWED` from `MaliciousChecker` if attacker chose to grant it) |
| 9 | `maliciousHook` | `afterAddLiquidity` drains deposited tokens |

**Alternative impact (no victim needed — denial of service):**

- Attacker sets `MaliciousChecker` to return zero permissions for everyone including the
  legitimate token issuer.
- If the legitimate issuer has not yet verified their own adapter, attacker's adapter is
  the only "verified" entry for USDC.
- Legitimate issuer deploys and verifies their own adapter — but now TWO "verified" adapters
  exist for USDC. Any pool using the attacker's adapter as currency enforces attacker's
  access policy.

---

## Impact

| Scenario | Impact |
|----------|--------|
| Malicious hook + victim interaction | Direct loss of deposited permissioned tokens (Critical chain) |
| Permissioned pool for target token not yet created | Attacker squats, blocks legitimate issuer from being the sole authority |
| Attacker-controlled `allowListChecker` | Arbitrary allow/deny of any address across all pools using the fraudulent adapter |
| `swappingEnabled` flag | Attacker can toggle permissioned-token swapping on/off for their pools |

---

## Severity rationale

The `verifyPermissionsAdapter` check was clearly intended to verify that the caller has
*meaningful* control over the permissioned token (e.g. is the token issuer or a delegated
admin). A 1 wei transfer achieves no such thing — any token holder, including an attacker
with a dust balance, satisfies the check.

Combined with the permissionless `createPermissionsAdapter`, the intended trust anchor
(only the legitimate token issuer can create an authoritative adapter) is entirely absent.

CVSS notes: Scope is Changed because the vulnerable contract (factory) grants control over
a separate security domain (the permissioned position manager's access policy).

---

## Recommended fixes

**Fix A — Access-control `createPermissionsAdapter`:**

Only the token issuer (or an admin role) should be able to create an adapter for a given
token. One approach: require a signature from `Ownable.owner()` of the ERC-20, or restrict
creation to a protocol-governed registry.

```solidity
// Minimal example: require caller to own the permissioned token contract
function createPermissionsAdapter(IERC20 permissionedToken, ...) external {
    if (Ownable(address(permissionedToken)).owner() != msg.sender) revert Unauthorized();
    ...
}
```

**Fix B — Strengthen `verifyPermissionsAdapter`:**

A meaningful ownership proof should be required, not a trivial balance check. Options:

- Require a signed message from the token contract's `owner()`.
- Require the adapter contract itself to have been deployed by the token's deployer (use
  `CREATE2` with a salt derived from the token address and a factory-controlled nonce).
- Remove the permissionless factory entirely and use a governance-gated deployment path.

**Fix C — Scope `setAllowedHook` to a protocol-level admin, not adapter owner.**

Decoupling hook governance from adapter ownership would limit the blast radius of a
compromised or fraudulent adapter.

---

## Evidence needed (Gate 0 TODO)

- [ ] Foundry test:
  1. Deploy factory + `PermissionedPositionManager`.
  2. Attacker calls `createPermissionsAdapter(USDC, attacker, maliciousChecker)`.
  3. Attacker transfers 1 wei USDC to the new adapter.
  4. Attacker calls `verifyPermissionsAdapter(adapter)` — assert it succeeds.
  5. Assert `verifiedPermissionsAdapterOf[adapter] == USDC`.
  6. Attacker calls `setAllowedHook(adapter, maliciousHook, true)` — assert it succeeds.
  7. Victim attempts `MINT_POSITION` in the attacker's pool — confirm hook receives callback.

---

## References

- `PermissionsAdapterFactory.sol` — `createPermissionsAdapter()`: no access control
- `PermissionsAdapterFactory.sol` — `verifyPermissionsAdapter()`: `balanceOf > 0` only
- `PermissionedPositionManager.sol` — `_getOwner()`: adapter owner trusted unconditionally
- `PermissionedPositionManager.sol` — `setAllowedHook()`: gated only by `_getOwner`
- `PermissionedPositionManager.sol` — `_verifiedPermissionedTokenOf()`: lookup path
- `PermissionsAdapter.sol` — `isAllowed()`: delegates entirely to caller-supplied `allowListChecker`
