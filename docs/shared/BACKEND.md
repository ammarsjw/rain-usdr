# USDR Keeper Automation Spec — Backend Integration

> **Contract set: the current repo head.** The body of this document describes HEAD as the single
> authoritative surface — HEAD is assumed deployable at any moment, so this doc must be ready to
> hand over as-is and never describes superseded builds.
>
> **How the delta is communicated.** Because each revision of this doc mirrors the contracts of
> its time, diffing revisions tells an integrator exactly what changed for them — and we spell
> that out rather than making them derive it. The section **§Changes since `v1.0.0-alpha.4`**
> below is produced mechanically from `git diff v1.0.0-alpha.4..HEAD -- contracts/` (the last
> tagged baseline, which is what the running backend was built against) and enumerates every
> breaking or actionable item as old shape → new shape → required action, in the integrator's
> own consumption medium: if you consume raw logs, the event shapes; if you consume the squid's
> Postgres database, the resulting table/column changes.
>
> **Maintenance rule:** when a new tag is cut (e.g. at a deployment), re-baseline the migration
> section to that tag and drop absorbed items. The body always tracks HEAD.

---

## Changes since `v1.0.0-alpha.4` — what the backend must change

### B1. SolvencyEngine — exposure cap removed

- **Was:** `exposureCap()` view; every report clamped to the cap; `ExposureClamped(reported, cap)`
  emitted on clamp; `ExposureCapNotSet` error; deploy ordering required the cap filed before the
  reporter.
- **Now:** all of it is gone. `reportedExposure()` enters `worstCaseLoss()` at face value. A
  REVERTING reporter substitutes total outstanding debt (`VaultEngine.debt() / RAY`, the
  structural bound) and emits `ExposureReportFailed(substituted)`.
- **Action:** delete `exposureCap()` reads (they now revert) and the cap-filing deploy step; move
  alerting from `ExposureClamped` to `ExposureReportFailed` (new topic0); page on it — the
  substitution almost certainly flips the invariant into breach.

### B2. OracleSecurityModule — staleness cutoff + rolling poke windows

- **Was:** `peek`/`read` never expired; poke windows snapped to :00/:30.
- **Now:** governable `maxAge` (new `file("maxAge", …)` + `File(what, data)` event on the OSM;
  deploy files 21600 s): `peek`/`read` fail CLOSED once `block.timestamp > delay(ilkId) + maxAge`.
  Windows are rolling: the poke timestamp is stored unsnapped in `delay(ilkId)` and `HOP` (1800 s)
  is a minimum interval, not a boundary.
- **Action:** reschedule Job 1 without fixed boundaries (late pokes shift all later windows);
  escalate missed-window alerting — ~12 missed windows now means frozen minting + a solvency
  spike, not just stale prices (see Job 1).

### B3. CircuitBreaker — one multi-ilk singleton

- **Was:** one breaker per ilk: `ILK_ID()`, `PIP()`, `trendPrice()`; events
  `Activated(deviation)`, `Checked(deviation, active)`.
- **Now:** ONE instance with a governance-managed registry — `addIlk`/`removeIlk`,
  `watchedIlks(i)`, `isWatched(ilkId)`, `ilkCount()`; `trendPrice(bytes32 ilkId)`;
  `VAULT_ENGINE()` / `ORACLE_SECURITY_MODULE()` constants; deactivation is time-based
  (`calmPeriod`, 1800 s) rather than calm-block-counted. Events reshaped:
  `Activated(bytes32 indexed ilkId, uint256 deviation)`,
  `Checked(bytes32 indexed worstIlk, uint256 maxDeviation, bool active)`, plus new
  `AddIlk(ilkId)` / `RemoveIlk(ilkId)`.
- **Action:** point Job 3 at the single instance; re-derive `Activated`/`Checked` topic0 and
  decoders; verify the one breaker address holds READER_ROLE on the OSM and every liquidatable
  volatile ilk is `addIlk`ed.

### B4. DutchAuction — one multi-ilk singleton

- **Was:** one auction house per ilk, resolved from `LiquidationTrigger.ilks(ilkId).clip`;
  `sales(id)` 7-tuple `(pos, tab, lot, vaultId, usr, tic, top)`; global
  `buf()`/`tail()`/`cusp()`/`chost()`; `upchost()`; `kick(tab, lot, vaultId, usr, kpr)`;
  price-curve getter `calc()`. Events:
  `Kick(id idx, top, tab, lot, vaultId idx, usr, kpr idx, coin)`,
  `Take(id idx, max, price, owe, tab, lot, usr idx)`,
  `Redo(id idx, top, tab, lot, usr idx, kpr idx, coin)`, `Upchost(chost)`.
- **Now:** ONE house for all ilks, resolved once from `liquidationTrigger.dutchAuction()`;
  `sales(id)` is an **8-tuple led by `ilkId`**; per-ilk params via
  `ilks(ilkId) -> (buf, tail, cusp, chost)` (global getters gone); `upchost(bytes32 ilkId)`;
  `kick(ilkId, tab, lot, vaultId, usr, kpr)`; getter renamed `priceCurve()`; new per-ilk
  `list(bytes32 ilkId)` view; per-ilk `file(ilkId, what, data)` + `File(ilkId, what, data)`.
  Events: `Kick(id idx, ilkId idx, top, tab, lot, vaultId, usr, kpr idx, coin)`,
  `Take(id idx, ilkId idx, max, price, owe, tab, lot, usr idx)`,
  `Redo(id idx, ilkId idx, top, tab, lot, usr, kpr idx, coin)`,
  `Upchost(ilkId idx, chost)` — note `vaultId` is no longer a topic on `Kick` and `usr` no
  longer a topic on `Redo`.
- **Action:** re-derive ALL four topic0 filters and decoders (every one changed); resolve the
  house once, not per ilk; read curve params per ilk; call `upchost(ilkId)` per ilk after any
  `dust`/`chop` change; flash-callback buyers must read the sale's `ilkId` to know which
  collateral they receive.

### B5. LiquidationTrigger — auction address hoisted

- **Was:** `ilks(ilkId) -> (clip, chop, hole, dirt, barkFactor)` 5-tuple; per-ilk
  `file(ilkId, "clip", addr)` + `File(ilkId, what, addr)` event; `Bark` event's auction param
  named `clip`.
- **Now:** `ilks(ilkId) -> (chop, hole, dirt, barkFactor)` 4-tuple; single global
  `dutchAuction()` filed via `file("dutchAuction", addr)`; `Bark` param renamed `dutchAuction`
  (same position/type, topic unchanged).
- **Action:** update the tuple decoder and the deploy wiring check.

### B6. PriceConverter — one global OSM

- **Was:** `ilks(ilkId) -> (pip, mat, fixedPrice)` 3-tuple; per-ilk `file(ilkId, "pip", addr)` +
  `File(ilkId, what, pip)` event; `WouldOrphanIlk` error.
- **Now:** `ilks(ilkId) -> (mat, fixedPrice)` 2-tuple; single global `oracleSecurityModule()`
  filed via `file("oracleSecurityModule", addr)` + `File(what, addr)` event; `IlkNotConfigured`
  error.
- **Action:** update decoder (`mat` moved from index 1 to 0) and wiring checks.

### B7. VaultEngine + BalanceSheet — dynamic liquidity ceilings and RAIN backstop

- **New (additive):** `liquidityCeilings(ilkId) -> (fSafety, liquidity, laggedLiquidity,
  laggedLiquidityAt)`, `effectiveLine(ilkId) = min(line, liquidity × fSafety)`, permissionless
  `snapshotLiquidity(ilkId)` — the dynamic cap gates minting once governance files a nonzero
  `fSafety` (dormant at launch: `fSafety = 0`). BalanceSheet: `backstop(uint256 rad)` sells
  treasury RAIN for USDR at an OSM-priced discount (`backstopHaircut`), capped by `backstopCap`
  (`backstopUsed` tracks consumption), configured via `file("rainIlk", …)` (new
  `file(what, bytes32)` overload + `File(what, dataBytes32)` event); emits
  `Backstop(buyer idx, rad, rainWad)`; new errors `BackstopNotConfigured` / `BackstopNotNeeded` /
  `BackstopCapExceeded` / `BackstopPriceInvalid` / `InsufficientBackstopRain`.
- **Action:** capacity math should read `effectiveLine(ilkId)` (equal to `line` while dormant,
  correct forever); if operating the backstop, wire `rainIlk`/OSM/`backstopCap` at deploy and
  monitor `Backstop`.

### B8. Governor — scoped pause + cooldown

- **Was:** `pause()` (full stop), `paused()`, `Pause(pausedAt)`, timelock getter `delay()`.
- **Now:** `pause(uint256 scope)` with bit flags (`_PAUSE_FROB` 1<<0, `_PAUSE_PSM` 1<<1,
  `_PAUSE_BARK` 1<<2, `_PAUSE_AUCTION` 1<<3, `_PAUSE_ALL` = all four); `paused()` (any scope
  live) plus `paused(uint256 scope)` per-scope; `Pause(pausedAt, scope)` carries the bitmask;
  new `PAUSE_COOLDOWN` (259200 s, equal to `PAUSE_MAX`) enforced via `lastPauseEnd` — a new
  pause cannot start during the cooldown after the previous one ends; timelock getter renamed
  `DELAY()`.
- **Action:** decode `scope` before assuming a full stop — gate each job on its own scope
  (`_PAUSE_BARK` for Job 4, `_PAUSE_AUCTION` for Job 5, etc.); rename `delay()` reads to
  `DELAY()`; update the `Pause` decoder.

### B9. VaultEngine — fee exemption via file

- **Was:** dedicated `exemptFee(bytes32 ilkId)` + `ExemptFee(ilkId)` event.
- **Now:** filed through the per-ilk path — `file(ilkId, "noFee", 1)`; the `noFee(ilkId)` view
  remains; the dedicated function and event are gone (the generic per-ilk `File` event covers
  it). Filing a duty on a `noFee` ilk reverts unless the duty is exactly RAY.
- **Action:** drop `ExemptFee` from event decoders; update any governance runbook.

### B10. Getter renames (ABI-breaking selector changes, mechanical)

| Contract | Was | Now |
|---|---|---|
| DutchAuction | `calc()` | `priceCurve()` |
| DutchAuction | `dog()` | `liquidationTrigger()` |
| DutchAuction | `vow()` | `balanceSheet()` |
| DutchAuction | `pip()` | `oracleSecurityModule()` |
| SolvencyEngine | `osm()` | `oracleSecurityModule()` |
| Governor | `delay()` | `DELAY()` |

Several `address` returns are now typed interfaces (`governor() -> IGovernor`,
`solvencyEngine() -> ISolvencyEngine`, …) — no ABI change, decoder-irrelevant. BalanceSheet
gained public `solvencyEngine()` / `reserveAccounting()` / `oracleSecurityModule()` views.

---

## Indexer (rain-usdr-sqd) — Postgres schema deltas

The squid decodes events straight into Postgres: one table per entity, table/column names are the
snake_case of the entity/field names below, and every table carries
`id, block_number, block_timestamp, transaction_hash, contract_address, event_log_index`.
**If you consume the DB rather than raw logs, this table — not the event list above — is your
migration surface.** Deltas at sqd HEAD (`b1cc96b`) vs the tag-era squid (`9620327`):

| Entity (→ table) | Change |
|---|---|
| `ExposureClamped` | **table removed** — replaced by `ExposureReportFailed` (`substituted`) |
| `Kick` / `Take` / `Redo` / `Upchost` | new column `ilkId` |
| `Bark` | column `clip` → `dutchAuction` |
| `Activated` | new column `ilkId` |
| `Checked` | column `deviation` → `worstIlk` (bytes) + `maxDeviation` |
| `Pause` | `scope` retyped bytes → numeric (the pause bitmask) |
| `File` | new nullable column `dataBytes32` (the `file(what, bytes32)` overload) |
| `AddIlk`, `RemoveIlk` | **new tables** (CircuitBreaker registry) |
| `Backstop` | **new table**: `buyer` (indexed), `rad`, `rainWad` |
| `SnapshotReserve` | **new table**: `reserve` — BalanceSheet reserve snapshots, previously unindexed |

Squids older than sqd `5725638` miss **every** DutchAuction event after the multi-ilk refactor
(all four topic0 hashes changed). Upgrading requires `squid-typeorm-migration generate` + apply;
where columns were renamed (`Bark.clip`, `Checked.deviation`), plan a re-index from the deployment
block, not an in-place patch.

*Scope:* all recurring on-chain actions required for the protocol to operate without admin
intervention. Governance/file actions and emergency settlement (End) are out of scope as keeper
*actions*, but §8 tells the keeper how to detect settlement and stand down.

*General notes for the integrator:*
- All jobs are permissionless *except reading OSM prices* (peek/peep require READER_ROLE — the
  keeper's read address must be whitelisted via `grantRole(READER_ROLE, addr)`, one-time
  governance action; alternatively read the underlying IPriceSource directly, it's public).
- Suggested architecture: one *event-driven watcher* (WebSocket subscription to contract events +
  new blocks) feeding a *tx dispatcher* with a funded EOA. Jobs 0–3 and 6 run from the
  protocol-operated keeper; jobs 4–5 are profit-bearing and may run in a separate wallet/pipeline
  with private-mempool submission.
- The rain-usdr-sqd squid indexer is the recommended vault/auction registry data source. Vaults
  are discovered from `Open(ilkId, owner, vaultId)` events, never from `frob` sender addresses
  (see Job 4). The squid at its current head indexes every protocol event in this doc (including
  `Drip`, the multi-ilk auction/breaker events, `Backstop` and `SnapshotReserve`) — see
  §Indexer above for the Postgres schema and its migration deltas.

---

## Job 0 — Stability fee drip

| | |
|---|---|
| *Contract* | VaultEngine |
| *Method* | `drip(bytes32 ilkId)` — one call per ilk with `duty > RAY` |
| *Trigger type* | *Time-based* (e.g. hourly), plus opportunistically before large operations |
| *Proceed if* | `live() == 1` and `block.timestamp > ilks(ilkId).rho` (else no-op) and `ilks(ilkId).duty > RAY` (zero-fee ilks accrue nothing — skip to save gas) |
| *Data source* | `ilks(ilkId)` → new tuple fields `duty` (slot 7) and `rho` (slot 8); `Drip(ilkId, rate, rad)` event |
| *Freshness, not correctness* | **`frob` (on any debt change) and `bark` auto-drip**, and filing a new `duty` drips first — so no user or liquidation path can ever see a stale rate. This job exists for (a) UX freshness — on-chain `rate`/`debt`/Balance-Sheet surplus stay near-real-time for dashboards, and (b) bounding the size of any single accrual fold. Idempotent within a block |
| *Solvency side-effect* | When a nonzero fee accrues, `drip` also **softly refreshes the solvency flag** — it calls `checkInvariant()` in a try/catch (never reverts, even on breach or a mis-wired engine) and emits `InvariantChecked` alongside `Drip`. Gas is therefore higher than a bare rpow+SSTORE fold: budget for the volatile-ilk loop (one OSM `peek` per volatile ilk) + escrow update on every fee-bearing drip. A drip that accrues nothing (same-block, or `duty == RAY`) skips the refresh |
| *Post-cage* | `drip` becomes a no-op returning the frozen rate — stop scheduling it after cage (Job 8) |
| *Failure mode if missed* | None on-chain. Displayed (unvirtualized) debt and surplus lag reality; first frob/bark pays the accrual gas |

## Job 1 — OSM price update

| | |
|---|---|
| *Contract* | OracleSecurityModule |
| *Method* | `poke(bytes32 ilkId)` — one call per registered ilk |
| *Trigger type* | *Time-based* (rolling 30-min minimum interval — windows are NO LONGER snapped to :00/:30) |
| *Proceed if* | `pass(ilkId) == true` (block.timestamp ≥ `delay(ilkId)` + `HOP`) *and* `stopped(ilkId) == 0` |
| *Data source* | `pass()`, `delay()`, `stopped()` — all public views. `delay(ilkId)` stores the UNSNAPPED timestamp of the last successful poke, so each poke opens the next window exactly `HOP` (1800 s) later |
| *Schedule* | Fire as soon as `pass()` opens + small jitter; retry until `Poke` event observed. **Late pokes shift all subsequent windows late** — there is no fixed boundary to catch up to, so cumulative drift is the cost of a slow keeper |
| *Staleness* | Governance files `maxAge` on the OSM (deploy default 21600 s = 6 h). Once `block.timestamp > delay(ilkId) + maxAge`, `peek`/`read` fail CLOSED: `PriceConverter.poke` zeroes `spot`, and `worstCaseLoss()` values that collateral at zero. **Missing ~12 consecutive windows escalates from "stale prices" to "minting frozen + solvency spike"** — set the alerting bar accordingly |
| *Note (L-10)* | If the price source returns zero/invalid, `poke` emits `PokeFailed` (not `Poke`) and does **not** advance — treat a `PokeFailed` as a missed window and alert; do not chain Job 2 off it |
| *Solvency side-effect* | After a successful advance (`Poke`, not `PokeFailed`), `poke` **softly refreshes the solvency flag** via `checkInvariant()` in a try/catch — a price crash flips `breached` in the same tx that lands the price, keeperless. Never reverts; the feed can never be blocked by the engine. Gas per poke is higher (volatile-ilk loop + escrow SSTORE); `InvariantChecked` is emitted per successful poke — dashboards charting it will see the cadence jump |
| *Failure mode if missed* | Entire downstream stack (spot, liquidations, solvency) runs on stale prices — *highest-priority job* |

## Job 2 — Push price to ledger

| | |
|---|---|
| *Contract* | PriceConverter |
| *Method* | `poke(bytes32 ilkId)` |
| *Trigger type* | *Event-chained* — immediately after Job 1's `Poke` event (same tx bundle preferred: `OSM.poke(); PriceConverter.poke();`) |
| *Proceed if* | Job 1 emitted `Poke` this window (NOT `PokeFailed`) |
| *Data source* | OSM `Poke(ilkId, current, next)` event |
| *Effect* | Writes `spot` into `VaultEngine.ilks(ilkId)` — this is what makes new prices actionable for liquidations |

## Job 3 — Circuit breaker check (single multi-ilk instance)

| | |
|---|---|
| *Contract* | CircuitBreaker — **ONE instance for the whole system**. It iterates a governance-managed registry of watched ilks (`addIlk`/`removeIlk`, `watchedIlks(i)`, `isWatched(ilkId)`, `ilkCount()`), computes each ilk's deviation from its own per-ilk trailing trend, and takes the MAX — one global `active()` verdict. A dislocation in ANY watched ilk throttles liquidations of ALL ilks |
| *Method* | `check()` — still parameterless; one call samples every watched ilk |
| *Trigger type* | *Hybrid*: event-chained after every Job 1/2 bundle, *plus periodic while `active() == true`* — **deactivation is TIME-based, not calm-block-counted**: it requires a full `calmPeriod` (1800 s) elapsed since the last above-threshold reading AND the max deviation back under `threshold` (0.25e18) at that check. An above-threshold reading re-anchors the calm clock. Call at least once per `obsInterval` (300 s) to keep the per-ilk trend buffers fresh |
| *Proceed if* | Always safe to call (no revert path; a dark feed skips that ilk — fail-open per ilk). Gate on `active()` for the tighter loop to bound gas spend |
| *Data source* | `active()`, `activatedAt()`, `trendPrice(ilkId)` (now takes the ilk), `lastObsTimestamp()`. Events reshaped: `Activated(ilkId, deviation)` (culprit ilk, indexed), `Checked(worstIlk, maxDeviation, active)`, `Deactivated()`, plus new `AddIlk(ilkId)`/`RemoveIlk(ilkId)` — update decoders and subgraph handlers |
| *:warning: Prereq* | The breaker reads `ORACLE_SECURITY_MODULE.peek(ilkId)` — the single breaker address must hold READER_ROLE on the OSM, and every liquidatable volatile ilk must be `addIlk`ed (deploy wires RAIN-A). An un-watched ilk contributes no deviation and is never protected |

## Job 4 — Liquidation trigger (threshold uses the LIVE rate)

| | |
|---|---|
| *Contract* | LiquidationTrigger |
| *Method* | **`bark(uint256 vaultId, address kpr)`** — `kpr` = keeper's reward address. **No ilk argument: the ilk is read from the vault (`ilkOf(vaultId)`), and the 1st arg is the `vaultId`, not the owner address.** |
| *Trigger type* | *Event-driven* — evaluate affected vaults in the block a new `spot` lands (after Job 2), and on every `VaultEngine.Frob`/`Grab` event (both now carry `vaultId`), **plus on a time schedule even without events**: with `duty > RAY`, vault debt drifts up between blocks, so vaults become barkable purely through fee accrual with no price move. Re-scan the near-threshold cohort at least once per drip interval |
| *Proceed if (all):* | 1. **`ink × spot < (art × rate_virtual / WAD) × barkFactor(ilkId)`** where **`rate_virtual = rpow(duty, now − rho, RAY) × rate / RAY`** — the on-chain `rate` may be stale between drips; `bark` itself drips first, so simulate against the virtualized rate or your off-chain check will lag the on-chain truth. A vault is barkable at the **`barkFactor` threshold (0.65e18 = 65%)**, i.e. RAIN-A liquidates at ~260% collateralization, not at the 400% mint floor. Read `ink`/`art` from `vaultEngine.urns(vaultId)`, `spot`/`rate`/`duty`/`rho` from the `vaultEngine.ilks(ilkId)` 8-tuple, `barkFactor` from the `liquidationTrigger.ilks(ilkId)` 4-tuple `(chop, hole, dirt, barkFactor)`; the auction house is the global `liquidationTrigger.dutchAuction()` |
| | 2. `globalHole() > globalDirt()` **and** `ilks(ilkId).hole > ilks(ilkId).dirt` (per-ilk auction capacity) |
| | 3. Simulated `dink > 0` and no dusty-partial revert (replicate `bark`'s dart/dust math off-chain **at the accrued rate**, or `eth_call` simulate — simulation is now strongly preferred since the exact rate depends on the inclusion block's timestamp) |
| | 4. `live() == 1` |
| | 5. Economic: `tip + chip × tab > gasCost × safetyFactor` — note `tab` includes accrued fees, and **`bark` gas is higher now** (it drips first: rpow + fee-credit SSTOREs). Recompute `tab` on throttled room if `circuitBreaker.active()` |
| *Vault registry* | **Index `Open(ilkId, owner, vaultId)` events** (or use the squid `Open` entity) to maintain the set of `vaultId`s per ilk. One owner can hold many vaults; each is evaluated independently — a healthy vault does not shield a sibling. `Bark` now emits `(ilkId, vaultId, urn=owner, …)` |
| *Submission* | Private bundle / priority fee — winner-takes-all race. Always `eth_call`-simulate first |

## Job 5 — Auction execution (gated by breaker + pause)

Before `take`/`redo`, the keeper MUST check both **`auction.stopped()`** (0–3) and
**`auction.governor().paused()`** — a nonzero stop level or a live pause makes these revert
`Stopped()`/`SystemPaused()`. `stopped >= 2` disables `take`; `stopped >= 3` also disables `redo`.
`yank` is never gated. Prices keep decaying during a halt, so expect a `redo` wave when it lifts.
Note the Governor pause **auto-expires after 72h** (L-6) — poll `paused()`, don't cache the event.

**The auction house is ONE contract for all ilks**: resolve it once
from `liquidationTrigger.dutchAuction()` instead of per-ilk. Every sale records its ilk —
**`sales(id)` returns an 8-tuple `(ilkId, pos, tab, lot, vaultId, usr, tic, top)`** — and the
curve parameters moved per-ilk: read `buf`/`tail`/`cusp`/`chost` from
**`auction.ilks(ilkId)` (4-tuple)**, not from globals. `chip`/`tip`/`stopped`/`live` stay
global. `upchost` takes the ilk: **`upchost(bytes32 ilkId)`**, one call per ilk after a `dust`
or `chop` change. `list()` is still global; a per-ilk **`list(bytes32 ilkId)`** filter view
exists for per-collateral keepers. Flash-callback buyers (`clipperCall`) MUST read the sale's
`ilkId` to know which collateral they are receiving — assuming one collateral per auction
address is now wrong.

Stability-fee note: **`tab` is snapshotted at bark time (post-drip) and fixed for the
auction's life** — no rate math inside Job 5 changes. `upchost(ilkId)`/`chost` (dust × chop)
are rate-independent (both rad) and unchanged in formula.

*5a. take*

| | |
|---|---|
| *Contract* | DutchAuction (single, all ilks) |
| *Method* | `take(uint256 id, uint256 amt, uint256 max, address who, bytes data)` — signature unchanged (the ilk is read from the sale); use a clipperCall flash-callback contract as `who` for atomic buy→DEX-sell→pay |
| *Trigger type* | *Computed-time + event-driven* — subscribe to `Kick`/`Redo`; the linear curve `price = top × (1 − dur/tau)` makes the target timestamp exactly computable |
| *Proceed if* | `stopped() < 2` ∧ `!paused()` ∧ `getStatus(id).needsRedo == false` ∧ `price_ > 0` ∧ `price_ ≤ dexExecPrice × (1 − fees − margin)` |
| *Params* | `max` = break-even price (slippage guard — never `uint.max`); `amt` sized to DEX depth; if partial, ensure `tab − owe ≥ ilks(ilkId).chost` (per-ilk dust floor) |
| *Data source* | `getStatus(id)`; `sales(id)` — the 8-tuple `(ilkId, pos, tab, lot, vaultId, usr, tic, top)`. Events: `Kick(id, ilkId, top, tab, lot, vaultId, usr, kpr, coin)`, `Take(id, ilkId, max, price, owe, tab, lot, usr)`, `Redo(id, ilkId, top, tab, lot, usr, kpr, coin)`, `Upchost(ilkId, chost)` — `ilkId` indexed on all four; `id` and `kpr` stay indexed; `vaultId` (`Kick`) and `usr` (`Redo`) are not (see §B4 for the old→new topic0 migration) |

*5b. redo*

| | |
|---|---|
| *Method* | `redo(uint256 id, address kpr)` |
| *Trigger type* | *Event/state-driven* — poll `getStatus(id)` for all active ids (`list()`) each block or on price updates |
| *Proceed if* | `stopped() < 3` ∧ `!paused()` ∧ `needsRedo == true` ∧ `tip + chip × tab > gasCost × safetyFactor` |

## Job 6 — Treasury housekeeping

Stability-fee note: **fee revenue now flows into the Balance Sheet continuously** — every
`drip` (explicit or auto) credits `vaultEngine.usdr(balanceSheet)`. The heal /
distributeSurplus cadence is unchanged, but there is now a steady revenue source on top of
liquidation proceeds, so expect 6b to fire more often once duties are nonzero. Chain 6a/6b
checks off `Drip` events too, not just `Take`/`Kick`/`Redo`.

*6a. heal*

| | |
|---|---|
| *Contract* | BalanceSheet |
| *Method* | `heal(uint256 rad)` with `rad = min(vaultEngine.usdr(balanceSheet), vaultEngine.sin(balanceSheet))` |
| *Trigger type* | *Event-driven with periodic fallback* — after every `Take`/`Kick`/`Redo`/`Drip` event, plus hourly cron |
| *Proceed if* | `min(usdr, sin) > 0` |

*6b. distributeSurplus* (solvency-gated)

| | |
|---|---|
| *Method* | `distributeSurplus()` |
| *Trigger type* | *Periodic* (e.g. hourly, after 6a) |
| *Proceed if (all)* | `vaultEngine.sin(balanceSheet) == 0` ∧ `vaultEngine.usdr(balanceSheet) > hump()` ∧ `buybackReceiver() != address(0)` ∧ **`!solvencyEngine.isBreached()` after a fresh recompute** — the contract itself recomputes `checkInvariant()` and reverts `SolvencyGateActive` while breached (surplus must not ship out toward buyback against an uncovered stressed loss). Simulate first; on `SolvencyGateActive`, back off and retry after the reserve recovers rather than burning gas per hour |

## Job 7 — Solvency flag freshness + watchdog

> **Canonical write policy:** [`BACKEND-SOLVENCY.md`] (edge-triggered `checkInvariant`,
> event list, asymmetric hysteresis, degraded mode). This section summarizes Job 7 in the
> Jobs 0–8 catalog and adds alerting. Do **not** follow the older “monitoring only / never
> call `checkInvariant`” wording — that understated stale-after-gate behaviour.

| | |
|---|---|
| *Contract* | SolvencyEngine |
| *Method (writes)* | **`checkInvariant()`** — permissionless; send **only** when `worstCaseLoss() > breachThreshold()` disagrees with `isBreached()` (see BACKEND-SOLVENCY.md). Toward-breach: immediate. Clearing: debounce / dead-band |
| *Method (reads / alert)* | `worstCaseLoss()` vs `breachThreshold()` (or `reserveAccounting.totalReserve()` × gate); page if `loss/reserve > 0.9` |
| *Prices* | **`worstCaseLoss()` reads collateral marks directly from the OSM** (H-1), not `spot × mat`. If an ilk's OSM price is missing/zero, that collateral is marked at **zero** (fail-closed) — expect `worstCaseLoss` to spike during an oracle outage; classify that as "oracle degraded", not insolvency |
| *Rates* | The engine computes ilk debt as `globalArt × rate` with the **stored** rate — between drips this slightly understates true accrued debt. Job 0's hourly drip bounds the staleness; if you reimplement the check off-chain, virtualize the rate as in Job 4 |
| *Do NOT* | call `checkInvariant()` **blindly on a timer**. The 90% gate is enforced **on-chain** at load-bearing sites (`buyStable`, risk-increasing volatile `frob`, `distributeSurplus`), and `OSM.poke` / fee-bearing `drip` soft-refresh after acting — but gated txs leave a **pre-tx** flag, and several movers never recompute. Blind scheduled writes waste gas and thrash near the threshold; **edge-triggered** writes (BACKEND-SOLVENCY.md) are required for flag freshness |
| *Trigger type* | Short-interval / per-block **compare** poll as baseline + event-driven early compares (BACKEND-SOLVENCY.md). Separately: alert on `InvariantChecked(passed=false)` and on `loss/reserve > 0.9` |

---

## Job 8 (settlement mode) — detect End and stand down

Emergency settlement is governance-triggered, not a keeper action, but the keeper must **detect it
and halt the normal loop**, because most flows revert once the system is caged.

| | |
|---|---|
| *Detect* | `VaultEngine.live() == 0`, or index `End`'s `Cage()` event / poll `End.live() == 0` |
| *On detection* | Stop Jobs 0–7 (including solvency flag freshness). After cage: `drip` no-ops (rates are **frozen at their cage-time values** — settlement math uses them as-is), `frob` risk-increasing paths revert, `bark` reverts (`live()==0`), auctions are `yank`ed by End, `distributeSurplus` reverts. Poking the OSM is harmless but pointless |
| *Optional assist* | The End lifecycle (`cage(ilk)` → `skim(vaultId)` → `thaw()` → `flow(ilk)`) is permissionless and can be driven by anyone; a keeper MAY batch `skim` over all open `vaultId`s to speed settlement, but this is unrewarded — coordinate with governance before automating |
| *Alert* | Cage is a page-everyone event |

---

## Deploy-time prerequisites (one-off role/wiring checklist)

A broken role silently disables a whole job — `scripts/verify/verify-roles.js` asserts these:

1. Keeper read address granted READER_ROLE on OSM (if reading `peek` directly); the single
   CircuitBreaker granted READER_ROLE on OSM, and **every liquidatable ilk `addIlk`ed on it**.
2. **SolvencyEngine has READER_ROLE on the OSM** (H-1 — it reads prices there now).
3. **There is no exposure cap** — no `exposureCap` filing, no ordering constraint. The
   reporter is wired directly via `file("externalExposure", addr)`; a reverting reporter
   substitutes total outstanding debt (fail-closed) rather than reverting the invariant.
4. Liquidation wiring: trigger→auction `kick`, auction→trigger `digs`, auction/balanceSheet→
   vaultEngine `suck`; **Governor pause wired into DutchAuction** (M-6); **the global auction
   address filed on the trigger via `file("dutchAuction", addr)`** (per-ilk filing is gone).
5. **End wiring:** WARD on VaultEngine / LiquidationTrigger / PriceConverter / DutchAuction, plus
   READER on the OSM; `END_WAIT` set (default 7d, must exceed the sin-queue `wait`).
6. Governor `delay` is **immutable** — chosen once at deploy, changing it means redeploying the Governor.
   The pause is scoped (`_PAUSE_FROB`/`_PAUSE_PSM`/`_PAUSE_BARK`/`_PAUSE_AUCTION` bit flags);
   `Pause(pausedAt, scope)` carries the scope — decode it before assuming a full stop.
6b. **OSM `maxAge` filed** (deploy: 21600 s) — without it stale prices never expire; with it a
   silent keeper outage freezes minting after `maxAge` (see Job 1). **`backstopCap` filed** if
   the RAIN backstop is to be usable (`BalanceSheet.backstop` reverts `BackstopNotConfigured`
   without `rainIlk`/OSM wiring, and sells nothing once `backstopUsed` reaches the cap).
7. **`feeRecipient` filed on VaultEngine** (must be the BalanceSheet address; `verify-roles.js`
   asserts it). **`drip` reverts `FeeRecipientNotSet` if fees would accrue while it is unset** —
   with the wiring order in `deploy-reserve.js` (feeRecipient filed right after BalanceSheet
   deploy, duties defaulting to RAY) this cannot bite, but never file a nonzero `duty` before
   `feeRecipient` is set. New File keys: per-ilk `"duty"` (≥ RAY, auto-drips at the old duty
   first — never retroactive), address `"feeRecipient"`.
8. **Solvency gate wiring on four contracts:** file `"solvencyEngine"` on the
   **OracleSecurityModule** (soft poke refresh) and on the **BalanceSheet** (hard distributeSurplus
   gate), in addition to the existing VaultEngine + PSM wiring. All are zero-address-tolerant
   (unset ⇒ hook skipped), and the soft sites are try/catch-wrapped — but wire them at deploy or
   breaches surface only through the hard gates. `deploy-reserve.js` files all four.

## Ops hygiene / Alerting / Simulation

(unchanged from prior spec:)
- Gas-tank monitoring + auto-top-up for the keeper EOA; nonce management for same-block bundles;
  run Jobs 0–3 and 6 on two independent infrastructures (own bot + Gelato/Chainlink fallback).
- Alert on: missed OSM window (> 35 min since last `Poke`, or a `PokeFailed`), breaker active > N
  hours, auction stale > tail without redo, `sin > 0` for > 24h, **`stopped()`/`paused()` active >
  N min**, **`End.live()==0`**, RPC/WS disconnects, **no `Drip` observed for an ilk with
  `duty > RAY` for > 2× the drip interval** (freshness canary), **`FeeRecipientNotSet` in any
  simulation** (wiring regression).
- Every tx `eth_call`-simulated in the target-block context first; log all reverts with reason
  strings (`NotSafe`, `NeedsReset`, `Stopped`, `SystemPaused`, `LiquidationLimitHit`,
  `FeeRecipientNotSet`, `InvalidDuty`, etc. — free telemetry).

Main things to flag to whoever owns the keeper: **the `VaultEngine.ilks()` tuple is 8 fields**
`(globalArt, globalInk, rate, spot, line, dust, duty, rho)`; **`rate` is live** — every
solvency/liquidation formula must use the stored (or virtualized) rate, never a hardcoded
`rate = RAY`; **`frob` (debt changes) and `bark` carry auto-drip gas**; **Job 0 drip is a
freshness job, not a correctness job** — nothing breaks if it's missed, but dashboards and the
near-threshold bark scanner lag; **the solvency gate is self-enforcing** — risk-increasing
`frob`s, `buyStable` and `distributeSurplus` recompute the invariant on-chain (revert
`SolvencyGateActive` on breach; add that selector to every simulation decoder), `poke`/`drip`
refresh the flag as a side effect, and all five paths carry the recompute gas (one OSM `peek`
per volatile ilk + escrow SSTORE). Liquidations (`bark`/`take`/`redo`) remain deliberately
ungated. **Job 7 flag freshness** remains a keeper duty — see [`BACKEND-SOLVENCY.md`]. For the
complete old→new migration from the last tagged baseline, see §Changes since `v1.0.0-alpha.4`
at the top — every tuple/topic break lives there with its required action.
