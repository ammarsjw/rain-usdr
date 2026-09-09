# Solvency flag freshness — keeper specification

> This is the canonical policy for **Job 7** in the keeper catalog
> ([`BACKEND.md`]. Jobs 0–6 and 8 (drip, OSM, spot, breaker,
> liquidations, auctions, treasury, End stand-down) live there.

## Policy

`SolvencyEngine.breached` is a cached value. It is written only by `checkInvariant()`, and it is not guaranteed to describe the current state of the protocol. The keeper's job is to keep it accurate.

The hard solvency gates (`frob` / `buyStable` / `distributeSurplus`) recompute on-chain before acting and do **not** depend on this cached flag. The flag still matters for monitors, `InvariantChecked` dashboards, and any off-chain logic that reads `isBreached()` without recomputing — and it **does go stale** (see below). Soft `poke`/`drip` refreshes are not enough by themselves.

The check is three free `eth_call`s and needs no role or whitelisting — `worstCaseLoss()` and `breachThreshold()` are both `public view`, and the `_READER_ROLE` requirement on OSM price reads applies to the engine, not to you:

```
verdict = worstCaseLoss() > breachThreshold()
if (verdict != isBreached()) sendTx(checkInvariant())
```

**Run this edge-triggered on disagreement, not on any particular event.** `checkInvariant()` is permissionless and idempotent; send it only when the computed verdict and the stored flag differ. Because the comparison is bidirectional, one job covers both the solvent-to-breached and breached-to-solvent transitions, and the event list below needs no direction filtering.

Do **not** call `checkInvariant()` on a blind timer every N minutes — that contradicts edge-triggering, wastes gas near the threshold, and is the wording that previously conflicted with older BACKEND Job 7 text (now corrected to point here).

The events are a **latency optimization only** — they tell you when to run the comparison sooner than the next poll, not what to react to. Keep a per-block or short-interval poll as the baseline so the job stays correct for any mover not enumerated here.

## Why the flag goes stale

Two distinct reasons, both covered by the same job:

The three solvency-gated functions — `VaultEngine.frob` (risk-increasing, volatile ilks), `PegStabilityModule.buyStable`, and `BalanceSheet.distributeSurplus` — recompute the invariant *before* they write state. This is deliberate: the gate blocks operations that are unsafe given the state they start from, and an operation that itself moves the protocol into breach is allowed to complete. The consequence is that such a transaction leaves the flag describing the pre-transaction state, so it reads healthy immediately after the breach occurred.

Separately, several state changes that move the invariant perform no recompute at all.

## Events to trigger the comparison

| Event | Contract | Filter |
|---|---|---|
| `Frob(ilkId, vaultId, v, w, dink, dart)` | VaultEngine | `isVolatile(ilkId)` (or configured volatile set), and `dink != 0 \|\| dart != 0` |
| `RecordIncrease(wad, totalReserve)` / `RecordDecrease(wad, totalReserve)` | ReserveAccounting | none |
| `Grab(ilkId, vaultId, v, w, dink, dart)` | VaultEngine | `isVolatile(ilkId)` (or configured volatile set) |
| `Void(ilkId)` | OracleSecurityModule | none |
| `Stop(ilkId)` / `Start(ilkId)` | OracleSecurityModule | none — degraded-mode / recover poll cadence |
| `File(what, data)` | SolvencyEngine | none — covers both overloads |
| `AddVolatileIlk(ilkId)` / `RemoveVolatileIlk(ilkId)` | SolvencyEngine | none |

Notes on filters and three of these:

**Volatile set.** Prefer `SolvencyEngine.isVolatile(bytes32 ilkId)` per known ilk (Open / config registry). There is no reliable requirement for a bulk `volatileIlks()` list getter on all deploys; cache the set and refresh on `AddVolatileIlk` / `RemoveVolatileIlk` (and periodically).

`RecordIncrease`/`RecordDecrease` fire on both PSM legs and are the input-level hook — `totalReserve` is the denominator of the breach threshold, so any reserve movement shifts the verdict. Prefer these over `SellStable`/`BuyStable`; they are equivalent today and remain correct if another recorder is ever wired.

`Grab` supersedes `Bark`. Liquidation moves debt and collateral out of the volatile ilk through `VaultEngine.grab`, so the `Grab` listener covers every bark, plus emergency-settlement seizures. Do not listen to `Bark` separately.

`Void` is the highest-severity entry. It zeroes the ilk's stored price, which values that collateral at zero in `worstCaseLoss()` (the invariant fails closed on missing prices), and it simultaneously sets `stopped = 1`, disabling the only automatic post-state publisher for that ilk. Recompute immediately and alert.

## Deliberately not on this list

**Self-publishing.** `OracleSecurityModule.poke` and `VaultEngine.drip` both place a soft `checkInvariant()` call *after* their own state writes, so the flag is already correct when `Poke` or `Drip` is observed. `PokeFailed` needs no action either — it means the price source refused to report and `cur` was left unchanged, so the verdict has not moved. `Drip` with `rad == 0` skips its refresh, but a zero fee means the rate did not change, so again nothing moved. (Matches BACKEND Jobs 0–1 solvency side-effects.)

**Not invariant inputs.** These look relevant and are not. `worstCaseLoss()` reads only per-ilk `globalArt`, `rate`, `globalInk`, the OSM price, the two stress parameters, the volatile-ilk set, and the clamped external exposure term:

- `BalanceSheet.distributeSurplus` — solvency-gated, but it moves internal USDR only and changes no input. It cannot cause the breach it checks for.
- `PriceConverter.poke` — writes `spot`, which the engine deliberately does not read. Collateral is priced directly from the OSM.
- `DutchAuction.kick`/`take`/`redo`/`yank` — collateral and debt left the ilk at `grab` time; auction proceeds are internal USDR and `sin`, neither of which the invariant measures.
- `BalanceSheet.heal`/`fess`/`flog`/`suck` — `vice` and `sin` only.
- `CollateralAdapter.join`/`exit`, `VaultEngine.slip`/`flux`/`move`/`hope` — free-collateral and balance movements; `globalInk` and `globalArt` change only in `frob` and `grab`.
- `VaultEngine.file` for `line`, `dust`, `globalLine` — ceilings, not invariant inputs.

## External exposure

The prediction-market exposure reporter calls `checkInvariant()` itself when its `reportedExposure()` value changes, so no listener is required. Two operational notes:

Keep a low-frequency poll of the comparison as a backstop — it is the only thing that detects the reporter being paused, upgraded, or calling out of order.

Alert on `ExposureClamped(reported, cap)`. A `reported` value of `type(uint256).max` means the reporter reverted and the loss term has silently fallen back to the full `exposureCap`, which is the conservative maximum. A `reported` above `cap` means an honest report is being clamped.

## Submission policy

**Make hysteresis asymmetric.** Near the threshold the verdict will oscillate, and you do not want a transaction per flip. Publish the toward-breach direction immediately with no debounce; apply any dead-band or minimum interval only to the clearing direction. This preserves the fail-closed behaviour the contracts have on-chain.

**Watch for degraded mode.** While an ilk is stopped (`Stop(ilkId)`, or after a `Void`), that ilk's automatic post-state publisher is off and `pass(ilkId)` cannot open, so the polling baseline carries the whole job until `Start(ilkId)` is observed and the next `poke` lands. Alert on `Stop` and `Void`, and raise poll frequency while either is in effect.

**Alert on `InvariantChecked(reserve, worstCaseLoss, passed)`** with `passed == false`, from any source. This gives push-based breach detection independently of your own comparison, since the gated functions and the self-publishing sites all emit it. Also page if `loss/reserve > 0.9` (BACKEND Job 7 alert band), classifying OSM-zero spikes as oracle-degraded when appropriate.

**Stand down with Job 8.** When `VaultEngine.live() == 0` / End cage is detected, stop this job with the rest of the keeper loop (BACKEND Job 8).
