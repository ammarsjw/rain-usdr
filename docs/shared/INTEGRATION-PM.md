> Updated for stability fees: `feature/rate-accrual` @ `b850750`.

Here's the updated doc in full:

---

# USDR ↔ Prediction Market Layer — Integration Guide

Audience: the RAIN prediction-market team. Covers (1) the exposure-reporting contract you must implement, and (2) how to read the solvency state of USDR from your side.

Contracts referenced: `SolvencyEngine`, `ReserveAccounting`, `IExternalExposure` (all in `rain-usdr`, v1.0).

---

## 1. What you implement: `IExternalExposure`

The Solvency Engine consumes your layer's risk through exactly one function:

```solidity
interface IExternalExposure {
    /// @return exposure The reported exposure [wad, 18 decimals, USD terms].
    function reportedExposure() external view returns (uint256);
}
```

You deploy a contract implementing this; USDR governance wires it with `SolvencyEngine.file("externalExposure", yourContract)`.

### Semantics

- **What the number means:** the worst-case USD amount the prediction-market layer could draw from the shared reserve. It is *added directly* to USDR's own stressed collateral loss — there is no further markdown applied on our side. Report your already-stressed worst case, not your notional.
- **Units:** wad (1e18 = $1).
- **Must be a `view`** and should be cheap: it is read once per `checkInvariant()` and by anyone simulating the invariant.

### Defensive handling on our side (know this so you aren't surprised)

There is no ceiling on the reported number — whatever you return is what the invariant charges:

| Your reporter's behavior | What the engine does |
|---|---|
| Returns `x` | Uses `x` at face value. No clamp, no markdown, no governance ceiling |
| Reverts | **Substitutes total USDR outstanding** (`VaultEngine.debt() / 1e27`) and emits `ExposureReportFailed(substituted)` |

The fallback needs no parameter because your layer settles in USDR and cannot mint it: every dollar you could possibly be exposed to was issued by this system, so total outstanding debt is the structural ceiling on your exposure. Consequences:

1. A reverting or broken reporter does **not** brick USDR — it charges the entire USDR supply against the reserve, which will almost certainly flip USDR into breach. Keep the function total (no reverts) — return a stored value, don't compute live over unbounded loops.
2. Every dollar you report is counted, so accuracy is entirely on you in both directions. Over-reporting gates USDR borrowing directly (see §2); under-reporting is the failure mode we cannot defend against.
3. Do not report sentinel values. With no clamp to absorb them, a `type(uint256).max` report overflows the loss sum and makes `worstCaseLoss()` revert.
4. Monitor the `ExposureReportFailed(substituted)` event on SolvencyEngine — it firing means your reporter is unreachable. It is your pager.

### Recommended reporter shape

Keep it dumb on-chain: a stored `uint256` updated by your own risk engine (keeper/bot with your own access control), so `reportedExposure()` is an SLOAD. Update on every material position change and on a heartbeat. Stale-low reporting is the one failure mode USDR *cannot* defend against — that is the trust you carry.

---

## 2. How to check whether USDR's solvency rule is broken

### The rule

```
worstCaseLoss > totalReserve × reserveFactor        (reserveFactor = 0.90 at launch)
```

- `worstCaseLoss` = Σ over volatile ilks of `max(0, ilkDebt − ink × osmPrice × stressMarkdown × stressDepth)` `+ reportedExposure`.
  Launch stress params: markdown 50%, depth 35% → collateral is credited at **17.5%** of its delayed-oracle value.
  An unavailable OSM price values that collateral at **zero** (fails closed).
- `totalReserve` = `ReserveAccounting.totalReserve()` — all USDT + USDC held (wad).

> **Stability fees (rate accrual):** `ilkDebt` is `globalArt × rate`, and `rate` is no longer fixed at RAY — it grows as stability fees accrue (permissionless `VaultEngine.drip(ilkId)`; `frob`/`bark` drip automatically). Between drips the *stored* rate slightly understates true accrued debt, so any off-chain mirror of the solvency math should use the virtualized rate `rpow(duty, now − rho, RAY) × rate / RAY`, taking `duty`/`rho` from the `ilks(ilkId)` **8-tuple** `(globalArt, globalInk, rate, spot, line, dust, duty, rho)` — decoders written for the old 6-tuple will break.

### Reads (all on `SolvencyEngine` unless noted)

| Question | Call | Notes |
|---|---|---|
| Is USDR currently gated? | `isBreached() → bool` | **Stored flag** — reflects the last `checkInvariant()` call, not live state |
| What would the flag be *right now*? | `worstCaseLoss()` vs `breachThreshold()` | Both `view`; breach iff `worstCaseLoss() > breachThreshold()` |
| Breach threshold | `breachThreshold() → uint256` | `totalReserve × reserveFactor / 1e18`, live |
| Reserve size | `ReserveAccounting.totalReserve()` | wad |
| Free (uncommitted) reserve | `ReserveAccounting.freeSlack()` | `totalReserve − committedEscrow`; escrow is set to `min(loss, reserve)` each check |
| Refresh the flag | `checkInvariant() → (loss, reserve)` | **Permissionless, state-changing, never reverts on breach.** Emits `InvariantChecked(reserve, worstCaseLoss, passed)` |
| Committed escrow | `ReserveAccounting.committedEscrow()` | `min(worstCaseLoss, totalReserve)` as of the last check — the slice of reserve your exposure reserves away from redeemers |
| Is an ilk gated on breach? | `isVolatile(bytes32 ilkId) → bool` | Only volatile ilks are blocked by the solvency gate |

⚠️ **`isBreached()` can be stale.** A keeper is expected to call `checkInvariant()` regularly, but if you need the truth *now*, compare `worstCaseLoss() > breachThreshold()` yourself (pure views), or call `checkInvariant()` — it is permissionless and idempotent.

### Events to index

- `InvariantChecked(reserve, worstCaseLoss, passed)` — every check.
- `ExposureReportFailed(substituted)` — your reporter reverted and `substituted` was charged in its place.

### What a breach does (why you care)

While `breached == true`:

- `VaultEngine.frob` reverts `SolvencyGateActive` for **risk-increasing** changes (`dart > 0` or `dink < 0`) on **volatile** ilks. Repayments and top-ups always pass. Stable/PSM ilks are exempt (PSM inflows heal the reserve).
- PSM redemptions are gated inside the PSM separately.
- The gate clears automatically on the next `checkInvariant()` where `loss ≤ reserve × reserveFactor` — no governance action needed.

Because *your* reported exposure is a direct, unclamped addend to `loss`, a spike in `reportedExposure()` can single-handedly gate USDR borrowing. Expect USDR monitoring to attribute breaches: the exposure term in `worstCaseLoss()` *is* `reportedExposure()` — keep your own dashboards on the same number.

---

## 3. Parameter summary (launch values, governance-tunable)

| Param | Value | Setter |
|---|---|---|
| `reserveFactor` | 0.90e18 | `file("reserveFactor", …)`, (0, 1e18] |
| `stressMarkdown` | 0.50e18 | `file("stressMarkdown", …)`, (0, 1e18] |
| `stressDepth` | 0.35e18 | `file("stressDepth", …)`, (0, 1e18] |
| `externalExposure` | your reporter | `file("externalExposure", …)`; `address(0)` drops the exposure term entirely |

## 4. Integration checklist

- [ ] Deploy `IExternalExposure` reporter (stored-value pattern, never reverts, no sentinel values)
- [ ] Bot updates reported exposure on position changes + heartbeat
- [ ] Alert on `ExposureReportFailed`
- [ ] Alert on `InvariantChecked.passed == false`
- [ ] (Optional) run a keeper calling `checkInvariant()` on your own cadence — it's permissionless and you have skin in the freshness of the flag
