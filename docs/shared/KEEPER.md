# Solvency flag freshness — keeper specification

## Policy

`SolvencyEngine.breached` is a cached value. It is written only by `checkInvariant()`, and it is not guaranteed to describe the current state of the protocol. The keeper's job is to keep it accurate.

The check is three free `eth_call`s and needs no role or whitelisting — `worstCaseLoss()` and `breachThreshold()` are both `public view`, and the `_READER_ROLE` requirement on OSM price reads applies to the engine, not to you:

```
verdict = worstCaseLoss() > breachThreshold()
if (verdict != isBreached()) sendTx(checkInvariant())
```

**Run this edge-triggered on disagreement, not on any particular event.** `checkInvariant()` is permissionless and idempotent; send it only when the computed verdict and the stored flag differ. Because the comparison is bidirectional, one job covers both the solvent-to-breached and breached-to-solvent transitions, and the event list below needs no direction filtering.

The events are a **latency optimization only** — they tell you when to run the comparison sooner than the next poll, not what to react to. Keep a per-block or short-interval poll as the baseline so the job stays correct for any mover not enumerated here.

## Why the flag goes stale

Two distinct reasons, both covered by the same job:

The three solvency-gated functions — `VaultEngine.frob` (risk-increasing, volatile ilks), `PegStabilityModule.buyStable`, and `BalanceSheet.distributeSurplus` — recompute the invariant *before* they write state. This is deliberate: the gate blocks operations that are unsafe given the state they start from, and an operation that itself moves the protocol into breach is allowed to complete. The consequence is that such a transaction leaves the flag describing the pre-transaction state, so it reads healthy immediately after the breach occurred.

Separately, several state changes that move the invariant perform no recompute at all.

## Events to trigger the comparison

| Event | Contract | Filter |
|---|---|---|
| `Frob(ilkId, vaultId, v, w, dink, dart)` | VaultEngine | `ilkId` in `volatileIlks()`, and `dink != 0 \|\| dart != 0` |
| `RecordIncrease(wad, totalReserve)` / `RecordDecrease(wad, totalReserve)` | ReserveAccounting | none |
| `Grab(ilkId, vaultId, v, w, dink, dart)` | VaultEngine | `ilkId` in `volatileIlks()` |
| `Void(ilkId)` | OracleSecurityModule | none |
| `File(what, data)` | SolvencyEngine | none — covers both overloads |
| `AddVolatileIlk(ilkId)` / `RemoveVolatileIlk(ilkId)` | SolvencyEngine | none |

Notes on three of these:

`RecordIncrease`/`RecordDecrease` fire on both PSM legs and are the input-level hook — `totalReserve` is the denominator of the breach threshold, so any reserve movement shifts the verdict. Prefer these over `SellStable`/`BuyStable`; they are equivalent today and remain correct if another recorder is ever wired.

`Grab` supersedes `Bark`. Liquidation moves debt and collateral out of the volatile ilk through `VaultEngine.grab`, so the `Grab` listener covers every bark, plus emergency-settlement seizures. Do not listen to `Bark` separately.

`Void` is the highest-severity entry. It zeroes the ilk's stored price, which values that collateral at zero in `worstCaseLoss()` (the invariant fails closed on missing prices), and it simultaneously sets `stopped = 1`, disabling the only automatic post-state publisher for that ilk. Recompute immediately and alert.

## Deliberately not on this list

**Self-publishing.** `OracleSecurityModule.poke` and `VaultEngine.drip` both place a soft `checkInvariant()` call *after* their own state writes, so the flag is already correct when `Poke` or `Drip` is observed. `PokeFailed` needs no action either — it means the price source refused to report and `cur` was left unchanged, so the verdict has not moved. `Drip` with `rad == 0` skips its refresh, but a zero fee means the rate did not change, so again nothing moved.

**Not invariant inputs.** These look relevant and are not. `worstCaseLoss()` reads only per-ilk `globalArt`, `rate`, `globalInk`, the OSM price, the two stress parameters, the volatile-ilk set, and the external exposure term:

- `BalanceSheet.distributeSurplus` — solvency-gated, but it moves internal USDR only and changes no input. It cannot cause the breach it checks for.
- `PriceConverter.poke` — writes `spot`, which the engine deliberately does not read. Collateral is priced directly from the OSM.
- `DutchAuction.kick`/`take`/`redo`/`yank` — collateral and debt left the ilk at `grab` time; auction proceeds are internal USDR and `sin`, neither of which the invariant measures.
- `BalanceSheet.heal`/`fess`/`flog`/`suck` — `vice` and `sin` only.
- `CollateralAdapter.join`/`exit`, `VaultEngine.slip`/`flux`/`move`/`hope` — free-collateral and balance movements; `globalInk` and `globalArt` change only in `frob` and `grab`.
- `VaultEngine.file` for `line`, `dust`, `globalLine` — ceilings, not invariant inputs.

## External exposure

The prediction-market exposure reporter calls `checkInvariant()` itself when its `reportedExposure()` value changes, so no listener is required. Two operational notes:

Keep a low-frequency poll of the comparison as a backstop — it is the only thing that detects the reporter being paused, upgraded, or calling out of order.

Alert on `ExposureReportFailed(substituted)`. It means the reporter reverted and the loss term has silently fallen back to `substituted` — total USDR outstanding, the structural ceiling on what the layer could be exposed to. That substitution is large enough to force a breach on its own, so treat the event as a reporter outage first and a solvency signal second. Honest reports are never clamped: whatever the reporter returns is charged in full.

## Submission policy

**Make hysteresis asymmetric.** Near the threshold the verdict will oscillate, and you do not want a transaction per flip. Publish the toward-breach direction immediately with no debounce; apply any dead-band or minimum interval only to the clearing direction. This preserves the fail-closed behaviour the contracts have on-chain.

**Watch for degraded mode.** While an ilk is stopped (`Stop(ilkId)`, or after a `Void`), that ilk's automatic post-state publisher is off and `pass(ilkId)` cannot open, so the polling baseline carries the whole job until `Start(ilkId)` is observed and the next `poke` lands. Alert on `Stop` and `Void`, and raise poll frequency while either is in effect.

**Alert on `InvariantChecked(reserve, worstCaseLoss, passed)`** with `passed == false`, from any source. This gives push-based breach detection independently of your own comparison, since the gated functions and the self-publishing sites all emit it.
