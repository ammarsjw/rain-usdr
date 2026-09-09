# USDR Keeper Automation Spec — Backend Integration

> Contract set: `feature/rate-accrual` @ `017b36a` (branched from `main`, which contains the
> End + rev-4 remediations).
> Changes vs the prior spec: **(a) stability fees** — each ilk now has a per-second
> compounding `duty` [ray]; `rate` grows via the new permissionless
> `VaultEngine.drip(ilkId)`, fees are credited to the Balance Sheet (`feeRecipient`) as
> surplus at accrual time; **(b) new Job 0** — periodic drip per ilk; **(c) gas bump**
> on `frob` (debt changes) and `bark` from auto-drip; **(d) solvency/liquidation
> formulas now use the live rate** — anything assuming `rate == RAY` is wrong;
> **(e) NEW @ `017b36a` — solvency gate hooks**: `frob` (risk-increasing, volatile ilks)
> and `BalanceSheet.distributeSurplus` now RECOMPUTE `checkInvariant()` on-chain and
> revert `SolvencyGateActive` on breach (same lazy gate `buyStable` already had);
> `OSM.poke` and `drip` refresh the breach flag SOFTLY (never revert). The cached
> `breached` flag is **not load-bearing for the hard gates** (those recompute on-chain),
> but it **does go stale** after gated txs and on movers that never recompute — Job 7
> must still edge-trigger `checkInvariant()` to keep it accurate for monitors and any
> off-chain `isBreached()` reads (see [`BACKEND-SOLVENCY.md`]). Expect additional
> gas on all five paths.
> Carried over from the previous revision: multi-vault `vaultId` model, DutchAuction
> `stopped()` breaker + Governor pause, H-1 (solvency reads OSM), End settlement.

*Scope:* all recurring on-chain actions required for the protocol to operate without admin
intervention. Governance/file actions and emergency settlement (End) are out of scope as keeper
*actions*, but §8 tells the keeper how to detect settlement and stand down.

*General notes for the integrator:*
- All jobs are permissionless *except reading OSM prices* (peek/peep require READER_ROLE — the
  keeper's read address must be whitelisted via `kiss`, one-time governance action; alternatively
  read the underlying IPriceSource directly, it's public).
- Suggested architecture: one *event-driven watcher* (WebSocket subscription to contract events +
  new blocks) feeding a *tx dispatcher* with a funded EOA. Jobs 0–3 and 6 run from the
  protocol-operated keeper; jobs 4–5 are profit-bearing and may run in a separate wallet/pipeline
  with private-mempool submission.
- The rain-usdr-sqd squid indexer is the recommended vault/auction registry data source. **Vaults
  are now discovered from `Open(ilkId, owner, vaultId)` events, not from `frob` sender addresses**
  (see Job 4). The squid now also indexes the new **`Drip`** entity (`ilkId`, `rate`, `rad`).

---

## Job 0 (NEW) — Stability fee drip

| | |
|---|---|
| *Contract* | VaultEngine |
| *Method* | `drip(bytes32 ilkId)` — one call per ilk with `duty > RAY` |
| *Trigger type* | *Time-based* (e.g. hourly), plus opportunistically before large operations |
| *Proceed if* | `live() == 1` and `block.timestamp > ilks(ilkId).rho` (else no-op) and `ilks(ilkId).duty > RAY` (zero-fee ilks accrue nothing — skip to save gas) |
| *Data source* | `ilks(ilkId)` → new tuple fields `duty` (slot 7) and `rho` (slot 8); `Drip(ilkId, rate, rad)` event |
| *Freshness, not correctness* | **`frob` (on any debt change) and `bark` auto-drip**, and filing a new `duty` drips first — so no user or liquidation path can ever see a stale rate. This job exists for (a) UX freshness — on-chain `rate`/`debt`/Balance-Sheet surplus stay near-real-time for dashboards, and (b) bounding the size of any single accrual fold. Idempotent within a block |
| *Solvency side-effect (NEW)* | When a nonzero fee accrues, `drip` also **softly refreshes the solvency flag** — it calls `checkInvariant()` in a try/catch (never reverts, even on breach or a mis-wired engine) and emits `InvariantChecked` alongside `Drip`. Gas is therefore higher than a bare rpow+SSTORE fold: budget for the volatile-ilk loop (one OSM `peek` per volatile ilk) + escrow update on every fee-bearing drip. A drip that accrues nothing (same-block, or `duty == RAY`) skips the refresh |
| *Post-cage* | `drip` becomes a no-op returning the frozen rate — stop scheduling it after cage (Job 8) |
| *Failure mode if missed* | None on-chain. Displayed (unvirtualized) debt and surplus lag reality; first frob/bark pays the accrual gas |

## Job 1 — OSM price update

| | |
|---|---|
| *Contract* | OracleSecurityModule |
| *Method* | `poke(bytes32 ilkId)` — one call per registered ilk |
| *Trigger type* | *Time-based* (30-min windows) |
| *Proceed if* | `pass(ilkId) == true` (block.timestamp ≥ `zzz(ilkId)` + 1800) *and* `stopped(ilkId) == 0` |
| *Data source* | `pass()`, `zzz()`, `stopped()` — all public views |
| *Schedule* | `zzz` is rounded down to the 30-min boundary; windows open at fixed times (:00/:30). Fire at window open + small jitter; retry until `Poke` event observed |
| *Note (L-10)* | If the price source returns zero/invalid, `poke` emits `PokeFailed` (not `Poke`) and does **not** advance — treat a `PokeFailed` as a missed window and alert; do not chain Job 2 off it |
| *Solvency side-effect (NEW)* | After a successful advance (`Poke`, not `PokeFailed`), `poke` **softly refreshes the solvency flag** via `checkInvariant()` in a try/catch — a price crash flips `breached` in the same tx that lands the price, keeperless. Never reverts; the feed can never be blocked by the engine. Gas per poke is higher (volatile-ilk loop + escrow SSTORE); `InvariantChecked` is emitted per successful poke — dashboards charting it will see the cadence jump |
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

## Job 3 — Circuit breaker check

| | |
|---|---|
| *Contract* | CircuitBreaker (one instance per watched ilk) |
| *Method* | `check()` |
| *Trigger type* | *Hybrid*: event-chained after every Job 1/2 bundle, *plus per-block while `active() == true`* (deactivation needs `calmBlocks` (3) consecutive calm blocks, each in a distinct block) |
| *Proceed if* | Always safe to call (no revert path; no-ops if feed invalid). Gate on `active()` for the per-block loop to bound gas spend |
| *Data source* | `active()` public view; `Activated`/`Deactivated`/`Checked` events |
| *:warning: Prereq* | CircuitBreaker calls `pip.peek()` — the breaker contract address must be `kiss`ed on the OSM at deployment. Verify in the deploy checklist |

## Job 4 — Liquidation trigger  ⚠️ THRESHOLD NOW USES LIVE RATE

| | |
|---|---|
| *Contract* | LiquidationTrigger |
| *Method* | **`bark(bytes32 ilkId, uint256 vaultId, address kpr)`** — `kpr` = keeper's reward address. **The 2nd arg is now the `vaultId`, not the owner address.** |
| *Trigger type* | *Event-driven* — evaluate affected vaults in the block a new `spot` lands (after Job 2), and on every `VaultEngine.Frob`/`Grab` event (both now carry `vaultId`), **plus on a time schedule even without events**: with `duty > RAY`, vault debt drifts up between blocks, so vaults become barkable purely through fee accrual with no price move. Re-scan the near-threshold cohort at least once per drip interval |
| *Proceed if (all):* | 1. **`ink × spot < (art × rate_virtual / WAD) × barkFactor(ilkId)`** where **`rate_virtual = rpow(duty, now − rho, RAY) × rate / RAY`** — the on-chain `rate` may be stale between drips; `bark` itself drips first, so simulate against the virtualized rate or your off-chain check will lag the on-chain truth. A vault is barkable at the **`barkFactor` threshold (0.65e18 = 65%)**, i.e. RAIN-A liquidates at ~260% collateralization, not at the 400% mint floor. Read `ink`/`art` from `vaultEngine.urns(vaultId)`, `spot`/`rate`/`duty`/`rho` from `vaultEngine.ilks(ilkId)` (**8-tuple now** — see below), `barkFactor` from `liquidationTrigger` |
| | 2. `Hole() > Dirt()` **and** `ilks(ilkId).hole > ilks(ilkId).dirt` (per-ilk auction capacity) |
| | 3. Simulated `dink > 0` and no dusty-partial revert (replicate `bark`'s dart/dust math off-chain **at the accrued rate**, or `eth_call` simulate — simulation is now strongly preferred since the exact rate depends on the inclusion block's timestamp) |
| | 4. `live() == 1` |
| | 5. Economic: `tip + chip × tab > gasCost × safetyFactor` — note `tab` includes accrued fees, and **`bark` gas is higher now** (it drips first: rpow + fee-credit SSTOREs). Recompute `tab` on throttled room if `circuitBreaker.active()` |
| *Vault registry* | **Index `Open(ilkId, owner, vaultId)` events** (or use the squid `Open` entity) to maintain the set of `vaultId`s per ilk. One owner can hold many vaults; each is evaluated independently — a healthy vault does not shield a sibling. `Bark` now emits `(ilkId, vaultId, urn=owner, …)` |
| *Submission* | Private bundle / priority fee — winner-takes-all race. Always `eth_call`-simulate first |

## Job 5 — Auction execution  ⚠️ NOW GATED BY BREAKER + PAUSE

Before `take`/`redo`, the keeper MUST check both **`auction.stopped()`** (0–3) and
**`auction.governor().paused()`** — a nonzero stop level or a live pause makes these revert
`Stopped()`/`SystemPaused()`. `stopped >= 2` disables `take`; `stopped >= 3` also disables `redo`.
`yank` is never gated. Prices keep decaying during a halt, so expect a `redo` wave when it lifts.
Note the Governor pause **auto-expires after 72h** (L-6) — poll `paused()`, don't cache the event.

Stability-fee note: **`tab` is snapshotted at bark time (post-drip) and fixed for the
auction's life** — no rate math inside Job 5 changes. `upchost`/`chost` (dust × chop) are
rate-independent (both rad) and unchanged.

*5a. take*

| | |
|---|---|
| *Contract* | DutchAuction (per ilk) |
| *Method* | `take(uint256 id, uint256 amt, uint256 max, address who, bytes data)` — use a clipperCall flash-callback contract as `who` for atomic buy→DEX-sell→pay |
| *Trigger type* | *Computed-time + event-driven* — subscribe to `Kick`/`Redo`; the linear curve `price = top × (1 − dur/tau)` makes the target timestamp exactly computable |
| *Proceed if* | `stopped() < 2` ∧ `!paused()` ∧ `getStatus(id).needsRedo == false` ∧ `price_ > 0` ∧ `price_ ≤ dexExecPrice × (1 − fees − margin)` |
| *Params* | `max` = break-even price (slippage guard — never `uint.max`); `amt` sized to DEX depth; if partial, ensure `tab − owe ≥ chost` (per-ilk dust floor) |
| *Data source* | `getStatus(id)`, **`sales(id)` now returns a 7-tuple `(pos, tab, lot, vaultId, usr, tic, top)`** — update any decoder expecting the old 6-tuple. `Kick`/`Redo` events now carry `vaultId` (indexed) |

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

*6b. distributeSurplus* ⚠️ NOW SOLVENCY-GATED

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

A broken role silently disables a whole job — `verify-roles.js` now asserts all of these:

1. Keeper read address `kiss`ed on OSM (if reading `peek` directly); CircuitBreaker `kiss`ed on OSM.
2. **SolvencyEngine has READER_ROLE on the OSM** (H-1 — it reads prices there now).
3. **`exposureCap` filed (`$250k`) BEFORE any exposure reporter is wired** — the contract enforces
   ordering (`ExposureCapNotSet`).
4. Liquidation wiring: trigger→auction `kick`, auction→trigger `digs`, auction/balanceSheet→
   vaultEngine `suck`; **Governor pause wired into DutchAuction** (M-6).
5. **End wiring:** WARD on VaultEngine / LiquidationTrigger / PriceConverter / DutchAuction, plus
   READER on the OSM; `END_WAIT` set (default 7d, must exceed the sin-queue `wait`).
6. Governor `delay` is **immutable** — chosen once at deploy, changing it means redeploying the Governor.
7. **NEW — `feeRecipient` filed on VaultEngine** (must be the BalanceSheet address; `verify-roles.js`
   asserts it). **`drip` reverts `FeeRecipientNotSet` if fees would accrue while it is unset** —
   with the wiring order in `deploy-reserve.js` (feeRecipient filed right after BalanceSheet
   deploy, duties defaulting to RAY) this cannot bite, but never file a nonzero `duty` before
   `feeRecipient` is set. New File keys: per-ilk `"duty"` (≥ RAY, auto-drips at the old duty
   first — never retroactive), address `"feeRecipient"`. Example duty: 2% APY ≈
   `1.000000000627937192491029810e27`.
8. **NEW @ `017b36a` — solvency gate wiring on two more contracts:** file `"solvencyEngine"` on the
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
  N min**, **`End.live()==0`**, RPC/WS disconnects, **NEW: no `Drip` observed for an ilk with
  `duty > RAY` for > 2× the drip interval** (freshness canary), **`FeeRecipientNotSet` in any
  simulation** (wiring regression).
- Every tx `eth_call`-simulated in the target-block context first; log all reverts with reason
  strings (`NotSafe`, `NeedsReset`, `Stopped`, `SystemPaused`, `LiquidationLimitHit`,
  `FeeRecipientNotSet`, `InvalidDuty`, etc. — free telemetry).

Main things to flag to whoever owns the keeper: **the `ilks()` tuple grew to 8 fields**
`(globalArt, globalInk, rate, spot, line, dust, duty, rho)` — any decoder of the old 6-tuple
breaks; **`rate` is live** — every solvency/liquidation formula that hardcoded `rate = RAY`
must switch to the stored (or virtualized) rate; **`frob` (debt changes) and `bark` cost more
gas** from the auto-drip; the new **Job 0 drip is a freshness job, not a correctness
job** — nothing breaks if it's missed, but dashboards and the near-threshold bark scanner lag;
and **@ `017b36a` the solvency gate is self-enforcing** — risk-increasing `frob`s,
`buyStable` and `distributeSurplus` recompute the invariant on-chain (revert
`SolvencyGateActive` on breach, add that selector to every simulation decoder), `poke`/`drip`
refresh the flag as a side effect, and gas went up accordingly on all five paths (one OSM
`peek` per volatile ilk + escrow SSTORE per recompute). Liquidations (`bark`/`take`/`redo`)
remain deliberately ungated. **Job 7 flag freshness** remains a keeper duty — see
[`BACKEND-SOLVENCY.md`].
