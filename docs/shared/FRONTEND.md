# USDR Frontend/Integrator Requirements Doc

> Contract set: `feature/rate-accrual` @ `017b36a` (branched from `main`, which contains the End + rev-4 remediations).
> Supersedes the `f881aff`/`9a9c81a` doc. Changes in this revision: **(1) stability fees exist** — `rate` is no longer fixed at RAY; debt = `art × rate` with `rate` live-growing per ilk; **(2) `ilks()` tuple gained `duty` and `rho`** — every decoder of the old 6-tuple breaks; **(3) new permissionless `VaultEngine.drip(ilkId)`** + `Drip` event + `feeRecipient` wiring; **(4) position cards must VIRTUALIZE debt between drips; (5) NEW @ `017b36a` — the solvency gate is now self-enforcing at every risk-increasing entry point:** borrow/withdraw `frob`s recompute the invariant on-chain (like `buyStable` already did) and revert `SolvencyGateActive` on breach — `isBreached()` reads are for pre-disabling buttons only, never a guarantee; simulate every gated tx. Everything from the prior revision (multi-vault, auction breaker, self-checking redemption gate, End, immutable timelock delay) carries over.

## 0. Conventions used in this doc

**Units.** Every number in the protocol is one of:

| Unit | Decimals | Used for |
| --- | --- | --- |
| `wad` | 1e18 | token quantities, normalized debt (`art`, `globalArt`), collateral (`ink`, `globalInk`), reserve figures |
| `ray` | 1e27 | rates and price factors (`rate`, `duty`, `spot`, `mat`, auction prices `top`/`price`/`max`, `buf`, `cusp`) |
| `rad` | 1e45 | internal USDR debt values (`debt`, `globalLine`, `line`, `dust`, `hole`, `globalHole`, `tab`, internal `usdr`/`sin` balances) = wad × ray |

Token decimals: **USDR = 18. USDT/USDC = 6. RAIN = 18.** The adapter/PSM convert 6→18 internally (`to18ConversionFactor = 1e12`); *external* calls always pass amounts in the **token's native decimals**.

Conversions you will use constantly:
- rad → USDR (18-dec display): `x / 1e27`
- rad → whole dollars: `x / 1e45`
- wad × ray → rad; rad / ray → wad; rad / wad → ray

### 0.1 The vault model (read before anything else)

Positions ("vaults") are identified by a **sequential `uint256 vaultId`**, allocated by `VaultEngine.open(ilkId, usr)`. Key facts:

- **One user can hold any number of vaults per ilk.** Each vault has its own `ink`/`art`, its own health, and is liquidated independently.
- A vault is **permanently bound** to one ilk and one owner at open time. There is **no transfer** (`give` does not exist) and ids are never reused.
- `VaultEngine.ownerOf(vaultId)` → owner address; `ilkOf(vaultId)` → ilk; `vaultCount()` → latest id; `urns(vaultId)` → `(ink, art)`.
- `open` is **permissionless** and takes an explicit `usr`: a future router can open vaults on behalf of users. When the frontend calls it directly, pass the connected wallet as `usr`.
- `hope`/`nope` (operator permissions) remain **address-level**: an operator approved via `hope` can manage **all** of the owner's vaults. There is no per-vault approval.

**Frontend mapping: one position card = one `vaultId`.** "Open a position" = `open()` + `frob(newVaultId, …)`. Depositing into an existing position = `frob(existingVaultId, …)` — same card updates, never a new card. A card disappears when its vault reaches `ink == 0 && art == 0` (fully closed or fully liquidated).

### 0.15 Stability fees (NEW — read before rendering any debt number)

Each ilk now carries:
- **`duty`** [ray] — per-second compounding factor. `RAY` (1e27) = zero fee. E.g. 2% APY ≈ `1.000000000627937192491029810e27`.
- **`rho`** — timestamp of the last accrual.
- **`rate`** [ray] — the debt multiplier, now **live-growing**: starts at RAY and increases every time `drip(ilkId)` runs.

Mechanics that matter to the frontend:
- **`VaultEngine.drip(bytes32 ilkId) returns (uint256)` is public and permissionless** — anyone can accrue. Emits `Drip(ilkId indexed, rate, rad)`.
- **`frob` auto-drips whenever `dart != 0`**, `bark` drips before liquidating, and filing a new `duty` drips at the old duty first — users never get charged retroactively and never escape accrued fees. Gas estimate for borrow/repay txs is higher than before (rpow + fee-credit inside).
- Accrued fees are minted as internal USDR to **`feeRecipient()`** (the Balance Sheet) as surplus, with `debt()` increased equally.
- After `cage()`, `drip` is a no-op — rates freeze for settlement.
- **What interest means for the user (the number-one support question):** interest accrues on the **debt side only**. Collateral (`ink`) is untouched — repaying the full (grown) debt always frees **exactly the RAIN that was locked**, never less. A user who borrows 1,950 USDR at 8%/yr owes ~2,106 USDR a year later and gets 100% of their RAIN back on close. Render the growing delta explicitly ("+X USDR interest" on the card, as in the design mocks) so the repay quote > original draw is never a surprise.
- **NEW @ `017b36a`: `drip` softly refreshes the solvency flag** — when a nonzero fee accrues it also runs `checkInvariant()` (never reverts). Practical effect for the UI: `isBreached()` and `InvariantChecked` events now update from ordinary user activity and 30-min pokes, so the solvency badge is near-real-time without any keeper.

**⚠️ VIRTUALIZE DEBT.** Between drips, the stored `rate` is stale. Any debt number you display must be computed as:

```
rate_now = rpow(duty, now − rho, RAY) × rate / RAY      // ray
debt_wad = art × rate_now / 1e27
```

with `rpow` = fixed-point binary exponentiation (same as Maker; a bigint JS implementation is ~10 lines — square-and-multiply with RAY rounding). At `duty == RAY` this degrades to `rate_now = rate`, so ship it unconditionally. Re-evaluate per block or on a timer; a repay of "the full debt" should be quoted at the **next block's** virtualized rate plus a small buffer, since debt keeps growing until the tx lands (the excess `dart` simply isn't needed — compute `dart = art` for a full close instead of converting from USDR).

### 0.2 Renames & ABI changes (old → current, all ABI-visible)

Carried over from the previous doc:
- `Art` → **`globalArt`**; `Line` → **`globalLine`**; `Hole/Dirt` → **`globalHole`/`globalDirt`**; `gem(...)` → **`collateral(ilkId, user)`**; `sellGem`/`buyGem` → **`sellStable`/`buyStable`**; `rely`/`deny` → OZ AccessControl (`RoleGranted`/`RoleRevoked`); `reserve()` → **`totalReserve()`**; custom errors everywhere (decode 4-byte selectors, not strings).

Carried over from the previous revision (multi-vault):
- **`VaultEngine.frob(uint256 vaultId, address v, address w, int256 dink, int256 dart)`** — was `frob(ilkId, u, v, w, dink, dart)`. The ilk is implied by the vault; `u` is gone.
- **`VaultEngine.grab(uint256 vaultId, address v, address w, int256 dink, int256 dart)`** — same reshape (ward-only, listed for indexers).
- **`VaultEngine.urns(uint256 vaultId)`** — was `urns(ilkId, owner)`. Single-key lookup.
- **`VaultEngine.open(bytes32 ilkId, address usr) returns (uint256 vaultId)`** + event **`Open(ilkId, owner, vaultId)`** + getters `ownerOf`/`ilkOf`/`vaultCount`.
- **`LiquidationTrigger.bark(uint256 vaultId, address kpr)`** — was `bark(ilkId, urn, kpr)`.
- **`Frob`/`Grab` events** now `(ilkId indexed, vaultId indexed, v, w, dink, dart)`; **`Bark`** now `(ilkId indexed, vaultId indexed, urn indexed, ink, art, due, clip, id)` where `urn` is the **owner address** (leftover-collateral recipient).
- **PSM fees removed**: `tin`/`tout` no longer exist anywhere in the ABI. `PSM.ilks(ilkId)` now returns `(token, to18ConversionFactor, vaultId)` — the third field is the PSM's own dedicated vault for that stable ilk (useful, see §2).
- Errors to decode: `VaultNotFound()` (frob/grab/bark on an unopened id), `SolvencyGateActive()` (see §5.1), `SystemPaused()` (governance emergency pause), `InvalidBarkFactor()`, `NoPartialPurchase()`, `NeedsReset()`, `InsufficientFreeSlack()`, `DustAmount()`, `CeilingExceeded()`.

New in this revision (stability fees):
- **`VaultEngine.ilks(ilkId)` now returns an 8-tuple:** `(uint256 globalArt, uint256 globalInk, uint256 rate, uint256 spot, uint256 line, uint256 dust, uint256 duty, uint256 rho)` — **the two new fields are appended at the end.** Every existing 6-tuple destructure breaks. This is the single most breaking change in this revision; grep every `ilks(` call site.
- **New: `VaultEngine.drip(bytes32 ilkId) returns (uint256 newRate)`** — permissionless, plus event **`Drip(bytes32 indexed ilkId, uint256 rate, uint256 rad)`**.
- **New: `VaultEngine.feeRecipient()`** address getter; new address File key `"feeRecipient"`.
- **New per-ilk File key `"duty"`** (`File(ilkId, "duty", data)`): must be ≥ RAY, and the contract drips at the *old* duty before applying — parameter-history UIs should render `Drip` and `File("duty")` in the same timeline.
- New errors to decode: **`InvalidDuty()`** (duty < RAY filed), **`FeeRecipientNotSet()`** (fees would accrue with no recipient wired — deploy-wiring bug, should never surface in production).
- `init` now also sets `duty = RAY` and `rho = now` (indexers deriving ilk state from `Init` should initialize the new fields).

**Ilks at launch:** `"RAIN-A"`, `"USDT-A"`, `"USDC-A"` (bytes32). Never hardcode the picker — drive it from adapter `Init` events (see §7). All launch duties are `RAY` (zero fee) until governance files otherwise.

**⚠️ Gated reads (unchanged):** `OracleSecurityModule.peek/peep/read` are `onlyRole(_READER_ROLE)` — an arbitrary frontend `eth_call` will revert. Prefer: (a) derive the delayed price from public state: `price_wad = ilks(ilkId).spot × mat / 1e27 / 1e9` (`spot` from `VaultEngine.ilks`, `mat` from `PriceConverter.ilks`); (b) index `Poke(ilkId, current, next)` events (wad, uint128); (c) governance `kiss` on a dedicated read-proxy. Do **not** design around calling `peek` from user wallets.

**Carried over from the previous revision (End + rev-4):**
- **`DutchAuction.kick(tab, lot, vaultId, usr, kpr)`** and **`Kick(id, top, tab, lot, vaultId indexed, usr, kpr, coin)`** — `usr` is no longer indexed; `vaultId` is. `sales(id)` now returns `(pos, tab, lot, vaultId, usr, tic, top)` — anything destructuring the old 6-tuple breaks.
- **`DutchAuction.yank`** sends leftover collateral to the **caller** (governance/End), no longer to the vault owner. `take`-path refunds to the owner are unchanged.
- **On DutchAuction:** `stopped()` (0–3 breaker), `governor()`, `cage()`, error `Stopped()`. File keys `"stopped"`, `"governor"`.
- **Governor:** `file` removed entirely; `delay()` is immutable. `paused()` now auto-expires — after 72h it returns false with no unpause tx (poll it, don't cache the Pause event).
- **SolvencyEngine:** `priceConverter()` getter is gone → `osm()`. Error `ParameterOutOfBounds()`.
- **Contract: `End`** (address in `.env` as `END_ADDRESS`) — see §9.
- Adapter error: `FeeOnTransferToken()`. Zero-amount `join`/`exit`/`burn` now revert `InvalidAmount` — disable buttons at 0 instead of letting a no-op tx through.

---

## 1. Mint USDR (PSM sell side)

**Tx flow (per mint):**
1. `USDT.approve(PSM, stableAmt)` — approve the **PSM**, not the adapter. (USDT quirk: approve-to-zero-first when a nonzero allowance exists.)
2. `PegStabilityModule.sellStable(ilkId, user, stableAmt)` — `ilkId` = `"USDT-A"` or `"USDC-A"`; `stableAmt` in **6 decimals**; `user` = recipient of USDR.

Output: **`usdrAmt = stableAmt × 1e12`, exactly. There is no fee** — do not render a fee line, do not read `tin`/`tout` (they no longer exist). The stability fee is a CDP-side concept; the PSM remains fee-less 1:1.

**Reads:**
- *Wallet balance:* `ERC20.balanceOf(user)` (6-dec).
- *"Mint capacity left":* min of two constraints, both enforced in `frob`:
 1. Per-ilk: `VaultEngine.ilks(ilkId)` → `(globalArt [wad], globalInk [wad], rate [ray], spot [ray], line [rad], dust [rad], duty [ray], rho)` — **note the tuple is now an 8-tuple, see §0.2**; ilk capacity `= line − globalArt × rate` [rad]. **Use the live (virtualized) rate for volatile ilks with nonzero duty** (§0.15); for the PSM stable ilks duty will realistically stay RAY, but compute uniformly. Sum over `USDT-A` + `USDC-A`.
 2. Global: `VaultEngine.globalLine()` − `VaultEngine.debt()` [rad]. Note `debt()` now also grows on every drip (fee surplus is real debt).
 Header `= min(sum_of_ilk_capacities, global_capacity) / 1e45` dollars; per-toggle uses that ilk's capacity.
- *Rate line:* "1 USDT = 1 USDR" is exact by construction. *Peg $1.00:* constant by design; a "live" number is a DEX quote — label it market data.

**Availability:** `sellStable` is **never** blocked by the solvency gate (it increases the reserve — it's the operation that heals a breach). It IS blocked by the governance emergency pause (`SystemPaused`). Preflight: `stableAmt > 0` (`InvalidAmount`), capacity ≥ amount (`CeilingExceeded`), ilk registered (`InvalidAddress`). PSM ilks have `dust = 0`, no dust concern.

## 2. Redeem (PSM buy side)

**Tx flow:**
1. `USDR.approve(PSM, stableAmt × 1e12)` — **face amount exactly; there is no fee.**
2. `PegStabilityModule.buyStable(ilkId, user, stableAmt)` — `stableAmt` in **6 decimals** (what the user receives).

**Reads:**
- *"Redemption slack":* `ReserveAccounting.freeSlack()` → wad dollars, display `/1e18`.
- *Per-token PSM inventory:* the PSM can only release what it holds for that ilk. Read `PSM.ilks(ilkId)` → third field `vaultId`, then `VaultEngine.urns(vaultId)` → `ink` [wad]. Effective per-token redeemable `= min(freeSlack, psmInk)`. **Do not** try `urns(ilkId, PSM_address)` — that signature is gone.
- *Swap route / price impact card:* DEX/aggregator data — label as such.

**⚠️ Behavior — two hard gates, distinct copy for each:**
- **No queue.** `stableAmt18 > freeSlack()` → revert `InsufficientFreeSlack`. Offer "redeem what's available" (clamp to slack) + "use market route". Any "your redemption will wait" copy is wrong.
- **Solvency breach = redemptions closed.** When `SolvencyEngine.isBreached()` is true, `buyStable` reverts `SolvencyGateActive` regardless of slack. Surface this distinctly ("redemptions paused while the reserve invariant is restored — minting remains open"), and check `isBreached()` (public view) before enabling the redeem button.

**Carried over from the previous revision:**
The stale-flag caveat is gone: **`buyStable` recomputes the solvency invariant itself on every call.** You can still read `isBreached()` to pre-disable the button, but do not treat a stale healthy flag as a guarantee — simulate the tx (you should be simulating anyway) and map `SolvencyGateActive` to the "redemptions paused" copy. Gas for `buyStable` is meaningfully higher than before (invariant recompute inside); reflect it in gas estimates.

## 3. Borrow / positions (CDP — RAIN-A only)

**Open a new position:**
1. `RAIN.approve(CollateralAdapter, amount)` — CDP flow approves the adapter directly (contrast §1).
2. `CollateralAdapter.join("RAIN-A", user, amount)` — credits free collateral (18-dec).
3. `VaultEngine.hope(CollateralAdapter)` — **one-time per wallet** (not per vault), required before step 6.
4. **`VaultEngine.open("RAIN-A", user)` → `vaultId`** — read the id from the tx receipt's `Open` event (or `vaultCount()` in the same multicall). **Persist it: it is the position's identity everywhere.**
5. `VaultEngine.frob(vaultId, user, user, +dink, +dart)` — `dink` [wad] collateral to lock, `dart` [wad] normalized debt. To draw X USDR: **`dart = X × 1e27 / rate_now`** where `rate_now` is the *virtualized* rate (§0.15). The old note "rate is 1e27 today, so `dart = X`" is dead — at nonzero duty, `dart` is strictly less than X and shrinks as fees accrue. Round `dart` **down** (the safety check will pass; the user just draws a hair less).
6. `CollateralAdapter.exit("USDR", user, usdrWad)` — converts internal USDR to ERC-20.

**Deposit into an EXISTING position:** steps 1–2, then `frob(existingVaultId, user, user, +dink, 0)`. **Same `vaultId` ⇒ update the same card.** Never call `open` for a deposit/borrow/repay/withdraw on an existing position.

**Manage:** withdraw = `frob(vaultId, user, user, −dink, 0)` then `CollateralAdapter.exit("RAIN-A", user, amount)`; repay = `CollateralAdapter.join("USDR", user, usdrWad)` then `frob(vaultId, user, user, 0, −dart)`. Repay needs **no** USDR approval (adapter burns via `_BURNER_ROLE`).
**Manage:** all four actions are the same `frob(vaultId, user, user, dink, dart)` with different signs:
- deposit = `join("RAIN-A")` then `frob(+dink, 0)`
- withdraw = `frob(−dink, 0)` then `exit("RAIN-A", user, amount)` — the only path that returns RAIN,
  and only passes if the remaining debt stays safe at spot.
- borrow = `frob(0, +dart)` then `exit("USDR")`
- repay = `join("USDR", user, usdrWad)` then `frob(0, −dart)` — no USDR approval needed (adapter
  burns via `_BURNER_ROLE`). ⚠️ Repaying does NOT move collateral: `ink` stays locked in the vault.
- close = `join("USDR", user, debt)` → `frob(−ink, −art)` (one frob: wipe + unlock together) →
  `exit("RAIN-A", user, ink)`. Three txs, strictly sequential.

Two fee-aware adjustments to the above:
- **repay-all:** compute the wipe as `dart = −art` (read `art` from `urns`), and quote the USDR cost as `art × rate_now / 1e27` **plus a small buffer** (debt grows every second; the `join` amount must cover the rate at inclusion time — excess internal USDR stays in `VaultEngine.usdr(user)` and is reusable/exitable, not lost).
- **close:** `join("USDR", user, debt+buffer)` → `frob(−ink, −art)` → `exit("RAIN-A", user, ink)` — same three txs.

No multicall/router exists in the repo — 1-click UX still needs a periphery contract (open item; `open(ilkId, usr)` was designed so a router can open vaults for users).

**Reads (per position card, all keyed by `vaultId`):**
- *Position:* `VaultEngine.urns(vaultId)` → `(ink [wad], art [wad])`. **Debt = `art × rate_now / 1e27`** (18-dec) — virtualized (§0.15), NOT the stored rate, or the number visibly freezes between drips and jumps on each one. Filter out `ink == 0 && art == 0` (closed).
- *New reads for the fee UI:* `ilks(ilkId).duty` → APR line: `apr = duty^31536000 − 1` (compute in bigint/log space: `APY = exp(31536000 × ln(duty/1e27)) − 1`). Show "Stability fee: X% APY" on the borrow form and each card; hide the line when `duty == RAY`.
- *Owner / ilk:* `ownerOf(vaultId)`, `ilkOf(vaultId)` — sanity-check ownership before rendering.
- *Mark price (delayed):* `price_wad = spot × mat / 1e27 / 1e9` (§0 gated-reads note).
- *Liquidation price — ⚠️ formula changed with `barkFactor`, and now uses the live rate:* liquidation no longer triggers at mat. It triggers when `ink × spot < (art × rate_now / 1e18) × barkFactor` (the trigger drips before checking, so on-chain always sees the accrued rate — your display must too). So:
 `liqPrice_wad = art × rate_now × mat × barkFactor / (ink × 1e27 × 1e9 × 1e18)`
 with `barkFactor` [wad] from `LiquidationTrigger.ilks(ilkId)` (struct field after `dirt`; launch value `0.65e18`). At launch: mint gate 400%, **liquidation at 260%** (65% of 400%). The previous doc's formula (without `barkFactor`) overstates liquidation prices by ~1.54× — fix it or every position shows "at risk" prematurely. Health slider: anchor "min" at mat (400%, can't mint below) and "liquidation" at `mat × barkFactor` (260%). **The liquidation price now creeps upward over time** at nonzero duty even if the user does nothing — the health bar must tick down with accrual, and "at risk" alerts must be computed against `rate_now`, not the last-drip rate.
- *Positions list / discovery:* squid — query **`Open` entities filtered by `owner`**, hydrate each `vaultId` live from `urns(vaultId)`. This replaces Frob-scan discovery and is exact. (On-chain alone can't enumerate an owner's vaults; there is deliberately no `ownerVaults[]` array.)
- *Available to borrow:* min(per-ilk `line − globalArt × rate_now`, `globalLine − debt`) plus the vault's own `ink × spot − art × rate_now` headroom [rad] — **all terms at the live rate**.

**Caveats:**
- dust = **100 USDR (rad) on RAIN-A, per vault** — each vault must independently carry 0 or ≥ 100 USDR debt. Splitting across many vaults multiplies the minimum. Enforce "repay all or leave ≥ 100" per card, and require ≥ 100 USDR initial draw on open. The comparison is `art × rate ≥ dust` **in rad**, unchanged in kind; but since debt grows, a position repaid to exactly 100 USDR today drifts above dust naturally (fine) — the dust check only binds on the repay tx itself. The displayed threshold in USDR terms is still `dust / 1e45`.
- **⚠️ UPDATED @ `017b36a` — the frob gate is now self-checking.** `frob` with `dart > 0 || dink < 0` on volatile ilks **recomputes `checkInvariant()` on-chain** and reverts `SolvencyGateActive` if the recomputed state is breached — exactly like `buyStable`. Consequences for the UI: (a) a stale-healthy `isBreached()` no longer means the tx will pass — a price crash one block ago gates the very next borrow, keeperless; **always simulate** and map `SolvencyGateActive` to the "borrowing paused" copy. (b) Borrow/Withdraw gas is meaningfully higher (invariant recompute inside: one OSM read per volatile ilk + escrow update) — reflect it in estimates. (c) Repay/top-up (`dart ≤ 0 && dink ≥ 0`) skip the recompute entirely — no gate, no extra gas, always available. Keep pre-disabling Borrow/Withdraw off `isBreached()` for UX, but treat simulation as the truth.
- Collateral picker driven by `Init` events — today only RAIN-A is borrowable.

## 4. Liquidation auctions (RAIN-A)

**Reads:**
- Grid: `DutchAuction.list()` → active ids; per id `getStatus(id)` → `(needsRedo, price [ray], lot [wad], tab [rad])`; poll per block (linear decay to zero over `tau` = 3600s).
- Discount badge: `getStatus.price / 1e9` vs derived mark price (§3), client-side.
- **"You're being liquidated" banner:** index `Bark` — it now carries **both** `vaultId` and `urn` (owner address), both indexed. Match on `urn == connectedWallet` for the wallet-level banner and use `vaultId` to badge the **specific position card** ("Position #7 is being liquidated") while the owner's other cards stay clean — liquidation is per-vault. Countdown from `sales(id).tic` + `tail` (1800s) / `cusp` (40%).
- Leftover collateral from an auction (`take` closing with `tab == 0`, or `yank`) is `flux`ed to the **owner address** captured at bark time — it lands in `VaultEngine.collateral("RAIN-A", owner)` as free collateral, and needs `CollateralAdapter.exit` to withdraw. Worth a "claimable collateral" indicator.
- History: index `Kick`/`Take`/`Redo`/`Yank`.
- Keepers calling `bark` directly: signature is now `bark(vaultId, kpr)`.

**Buy flow (unchanged, still the most integrator-hostile path):**
1. `CollateralAdapter.join("USDR", buyer, usdrWad)` → internal USDR at `VaultEngine.usdr(buyer)` [rad].
2. `VaultEngine.hope(DutchAuction)` — one-time.
3. `DutchAuction.take(id, amt, max, who, data)` — `amt` [wad], `max` [ray], `data` empty unless flash-callback.
4. `CollateralAdapter.exit("RAIN-A", buyer, amount)`.
- Partial buys: a partial that would leave `tab − owe < chost` is **adjusted down to leave exactly chost** (no revert) — only when the whole `tab ≤ chost` does it revert `NoPartialPurchase`. Show the adjusted quantity in the confirm dialog (`chost` is a public getter).
- `needsRedo == true` → hide Buy (`NeedsReset`); keepers call `redo(id, kpr)` for `chip` (2% of tab) — reward pays only when `tab ≥ chost` and `lot × price ≥ chost`.

**Carried over from the previous revision:**
- Auction grid: also read **`stopped()`** and **`governor().paused()`**. `stopped >= 2` or a live pause ⇒ hide/disable Buy (`take` reverts `Stopped()`/`SystemPaused()`); `stopped >= 3` ⇒ hide Reset too. Show a "market halted by governance" banner — prices keep decaying on the clock during a halt, so most auctions will need a `redo` right after it lifts (keeper opportunity, user-visible price refresh).
- `Kick.vaultId` is now indexed: the auction grid can badge the exact position card without joining through Bark.

**Update (stability fees):**
- `tab` is snapshotted at bark time **post-drip** and fixed for the auction's life — auction cards never virtualize.
- "You're being liquidated" risk *warnings* (pre-bark) must use the virtualized rate (§3) — a vault can become barkable purely through fee accrual with no price move.

## 5. Solvency dashboard

- *Stressed max loss:* `SolvencyEngine.worstCaseLoss()` → wad, view, callable by anyone. Priced from **collateral** (`globalInk × spot × mat` with stress params `stressMarkdown = 0.5e18`, `stressDepth = 0.35e18`, public getters). One scalar; derive any "unstressed" figure client-side and label it.
- *Reserve:* `ReserveAccounting.totalReserve()`; *Escrow:* `committedEscrow()`; *Free slack:* `freeSlack()` (all wad).
- *Solvent badge:* `!SolvencyEngine.breached()` — public flag, now refreshed **by the protocol itself**: every successful OSM poke (≈30 min), every fee-bearing drip, every gated frob/redemption/distribution recomputes it. It is near-real-time without any keeper; still never prompt users to call `checkInvariant()` (a write). The threshold is `reserveFactor` (launch 0.9e18): breach when `worstCaseLoss > totalReserve × reserveFactor`.
- *30-day chart:* index `InvariantChecked(reserve, worstCaseLoss, passed)`; cadence is now ≥ poke cadence (≈30 min) plus a burst per gated user tx — expect many more data points than the old keeper-only cadence; downsample for the chart.
- The Circuit Breaker is about **oracle deviation**, not solvency — `CircuitBreaker.active()` belongs on the liquidation page if anywhere.

**Carried over from the previous revision:**
- The mark price the engine uses is now **the OSM price directly** (same value §3 derives) — the `spot × mat` reconstruction warning is obsolete; the numbers you display and the numbers the engine uses can no longer disagree after a `mat` refile.
- If the OSM has no valid price for a volatile ilk, `worstCaseLoss()` counts that collateral at **zero** (fail closed) — expect the dashboard to jump to breach during an oracle outage; label it "oracle unavailable — conservative mode", not a bug.
- Parameter displays: `stressMarkdown`/`stressDepth`/`reserveFactor` are guaranteed in (0, 1]. There is no cap on external exposure — `reportedExposure()` enters `worstCaseLoss()` at face value, so never display a clamped or capped figure alongside it.

**Update (stability fees):** `worstCaseLoss()` computes ilk debt as `globalArt × rate` with the **stored** rate — between drips this marginally understates accrued debt. The protocol keeper drips hourly, so the skew is bounded and conservative-adjacent; do not "correct" the on-chain figure in the UI, but a tooltip may note the accrual lag.

### 5.1 Breach-mode matrix (drive ALL button-disabling from this)

When `SolvencyEngine.isBreached()`:

| Operation | State | Error if attempted |
| --- | --- | --- |
| PSM mint (`sellStable`) | ✅ open (heals the breach) | — |
| PSM redeem (`buyStable`) | ❌ blocked | `SolvencyGateActive` |
| Borrow / withdraw collateral (volatile ilks) | ❌ blocked | `SolvencyGateActive` |
| Repay / deposit collateral | ✅ open | — |
| Liquidations (`bark`/`take`/`redo`) | ✅ open | — |
| `open` (new vault, no debt) | ✅ open (drawing into it is what's gated) | — |
| `drip` (fee accrual) | ✅ open (never gated by breach or pause; refreshes the flag softly) | — |
| Surplus buyback (`distributeSurplus`, NEW @ `017b36a`) | ❌ blocked (keeper-facing, listed for completeness) | `SolvencyGateActive` |
| OSM `poke` (price updates) | ✅ open (never gated; refreshes the flag softly) | — |

**All three hard gates (`frob`, `buyStable`, `distributeSurplus`) recompute the invariant in-tx** — the matrix is enforced against live state, not the stored flag. Drive button-disabling from `isBreached()` as a hint, but the revert is the authority.

The governance emergency pause (`Governor.paused()`) is a separate, stricter stop: it blocks frob, PSM both directions, and bark, with `SystemPaused`.

## 6. Reserve composition & ceilings table

- Per-ilk rows from `VaultEngine.ilks(ilkId)` (**8-tuple, §0.2**) + `PriceConverter.ilks(ilkId)`: ratio → `mat` [ray] (`/1e25` = %); mark → derived price (§3) or "$1.00 fixed" when `fixedPrice`; minted → `globalArt × rate_now` [rad] `/1e45` (virtualized, §0.15); ceiling → `line`; **total locked collateral → `globalInk`** [wad] (tuple field, index 1); **NEW column: stability fee** → `duty` rendered as APY (§3), "—" when RAY.
- Global ceiling → `globalLine()`; global minted → `debt()`.
- "Shared ARB/RAIN ceiling": still **no shared-ceiling primitive** — governance convention only; flag to product.
- Protocol-held stables: per stable ilk, `PSM.ilks(ilkId).vaultId` → `VaultEngine.urns(vaultId).ink`; ERC-20s custody at the **CollateralAdapter** address.
- Ceiling change history → `File` events (`"globalLine"` global, `"line"` per-ilk). Liquidation-parameter history: `File` on LiquidationTrigger includes `"barkFactor"`. Parameter change history now also tracks **`"duty"`** (per-ilk) and **`"feeRecipient"`** (address). Fee accrual history → `Drip` entities (`rad` = fees minted per accrual; summable into a "protocol fee revenue" chart).

## 7. Indexer (squid) checklist — deltas for the multi-vault revision

- **New entity: `Open`** `(ilkId, owner, vaultId)` — the position-discovery primitive. Strongly recommended: a derived **`Position`** entity (`id = vaultId`, fields `ilkId`, `owner`, `ink`, `art`, `liquidated`, `lastUpdated`) upserted from `Open`/`Frob`/`Grab`, flagged by `Bark`. Then position lists are one query; only debt pricing (`rate`) and prices need RPC.
- **`Frob`/`Grab` schema change:** `u: address` is replaced by `vaultId: BigInt` (indexed). `v`/`w` unchanged. **Sum `dink`/`dart` from BOTH Frob and Grab** when deriving balances, or liquidated vaults will show stale collateral.
- **`Bark` schema change:** gains `vaultId` (indexed); `urn` remains and is now the owner address.
- **`Kick`'s `usr`** is now the vault owner (was the urn address — same value only in the old model).
- PSM entities (`SellStable`/`BuyStable`): unchanged shape; fee fields never existed in events. `File` on PSM no longer has `tin`/`tout` keys.
- **`ExposureClamped(reported, cap)` is removed** and replaced by **`ExposureReportFailed(substituted)`** on SolvencyEngine. Drop the old handler; the new one fires only when the exposure reporter is unreachable, and `substituted` is the total USDR outstanding charged in its place. There is no cap and honest reports are never clamped, so absence of this event now means the exposure term is exactly `reportedExposure()`.
- Unchanged: `RoleGranted`/`RoleRevoked`, `File` keys (`"globalLine"`, `"globalHole"`), adapter `Init`/`Join`/`Exit`, OSM `Poke`/`PokeFailed`, `Take`/`Redo`/`Yank`/`Digs`, `Fess`/`Flog`, `Heal`/`Suck`, `DistributeSurplus`, `InvariantChecked`, `Upchost`, breaker + governor events, `Cage`.

**Carried over from the previous revision:**
- `Open`/`Frob`/`Grab`/`Bark` deltas as in the previous doc, live since `rain-usdr-sqd@ac36106`, plus: `Kick.vaultId`, the 8 End entities, and `END_ADDRESS` in the env block. Governor `File` no longer exists on the ABI (delay immutable).
- The multi-vault migration is **not** backward-compatible with pre-multi-vault data: clean DB + re-backfill.

**New in this revision — stability-fee deltas, live in `rain-usdr-sqd@9bda126`:**
- **New entity: `Drip`** `(ilkId, rate, rad, blockNumber, blockTimestamp, …)` — indexed from `VaultEngine.Drip`. Use it to (a) update a derived `Ilk.rate` field so hydration doesn't need an RPC call for the stored rate, and (b) chart fee revenue (`sum(rad)` per period).
- **VaultEngine ABI refreshed** (Drip event, drip function, feeRecipient, 8-field ilks getter). `File` entities need no schema change — the new `"duty"`/`"feeRecipient"` keys flow through the existing generic File decoding.
- If you maintain a derived `Position` entity: its debt field must either store `art` only (price at query time with the virtualized rate) or be updated on every `Drip` — storing a pre-multiplied debt number without a rate version will go stale silently. Recommendation: store `art`, virtualize in the API/frontend layer.
- Migration for the fee delta is additive (new entity + ABI) — no re-backfill required for existing data, but a re-backfill is needed if you want `Drip` history from before the processor update was deployed (there is none before contracts ship, so in practice: none).

## 8. Standing caveats

- USDT approve-to-zero-first; always simulate before send; decode custom-error selectors for UX messages (add **`InvalidDuty`, `FeeRecipientNotSet`** to the map alongside `VaultNotFound`, `SolvencyGateActive`, `SystemPaused`).
- **`rate` is live now** (was: "fixed at 1e27 today") — never display raw `art`; always `art × rate_now` with the virtualized rate (§0.15). Anything that cached "rate = 1" — sliders, max-borrow math, repay quotes, liquidation prices — must be found and fixed; this is the doc's single biggest action item.
- **Simulate every gated tx (`frob` borrow/withdraw, `buyStable`)** — @ `017b36a` these self-check the solvency invariant in-tx; a healthy `isBreached()` read is a UX hint, not a promise. Map `SolvencyGateActive` to action-specific copy: "borrowing/withdrawals paused while the reserve invariant is restored" vs "redemptions paused — minting remains open".
- One DutchAuction instance per collateral type — resolve the clip per ilk from `LiquidationTrigger.ilks(ilkId).clip`, not a constant.
- **Persist `vaultId`s client-side but treat the squid (`Open` by owner) as the source of truth** — the user may have opened vaults from another device or via a future router.
- `hope` is per-wallet and covers all the wallet's vaults, current and future — the one-time setup tx does not repeat per position.
- Vaults are not transferable and ids are never reused; `vaultId` is safe as a permanent React key / DB primary key.

## 9. Emergency settlement (End)

If governance ever triggers `End.cage()`, the protocol enters a terminal state and the frontend should switch to a dedicated settlement mode:

**Detection:** index the free `Cage()` event from `END_ADDRESS`, or poll `End.live() == 0`. Also: `VaultEngine.live() == 0` with `End.when() != 0`.

**Vault-holder flow (per position card):**
1. Wait for `CageIlk(ilkId, tag, art)` — the ilk's settlement price is fixed (`tag` = collateral per USDR of debt, ray).
2. Anyone may call `skim(vaultId)` — debt is cancelled, owed collateral confiscated. Card shows "settled at $X".
3. Owner calls `End.free(vaultId)` (owner-only, must have zero debt) — leftover collateral lands as free collateral → `CollateralAdapter.exit` to withdraw. This is the only vault action that remains.

**USDR-holder flow (redemption):**
1. After `Thaw(debt)`: redemption opens. Per ilk, `Flow(ilkId, fix)` fixes collateral-per-USDR (ray).
2. `CollateralAdapter.join("USDR", user, wad)` (ERC-20 → internal), `VaultEngine.hope(END_ADDRESS)` (one-time), `End.pack(wad)` → bag.
3. Per ilk: `End.cash(ilkId, wad)` → pro-rata collateral → `CollateralAdapter.exit`. Show expected amounts as `wad × fix / 1e27`.

**Squid entities for all of this:** `CageIlk`, `Skip`, `Skim`, `Free`, `Thaw`, `Flow`, `Pack`, `Cash` (all live in the schema as of `ac36106`; `vaultId`/`usr`/`owner` indexed where relevant).

**In-flight auctions at settlement:** `Skip(ilkId, auctionId, vaultId, ...)` means the auction was reclaimed into the vault — close the auction card, restore the position card (debt includes the liquidation penalty), let it follow the normal skim/free flow.

**Update (stability fees):** after `End.cage()`, **rates freeze** — `drip` becomes a no-op returning the frozen rate, and all settlement math (`tab / rate`, `art × rate × tag`) uses the cage-time rates. Settlement-mode UIs should stop virtualizing debt: from cage onward, `art × rate` with the stored rate is exact and final.
