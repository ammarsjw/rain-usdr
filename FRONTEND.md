# USDR Frontend/Integrator Requirements Doc

> Contract set: `fix/audit-rev2` @ `2f0c1f9` (multi-vault revision).
> Supersedes the doc written against `rework/usdr-join` @ `e2e3cb4`. **Two structural changes since then: (1) PSM fees are gone — conversions are exactly 1:1, `tin`/`tout` no longer exist; (2) positions are now keyed by numeric `vaultId`, not by owner address — one user may hold any number of vaults per collateral type.**

## 0. Conventions used in this doc

**Units.** Every number in the protocol is one of:

| Unit | Decimals | Used for |
| --- | --- | --- |
| `wad` | 1e18 | token quantities, normalized debt (`art`, `globalArt`), collateral (`ink`, `globalInk`), reserve figures |
| `ray` | 1e27 | rates and price factors (`rate`, `spot`, `mat`, auction prices `top`/`price`/`max`, `buf`, `cusp`) |
| `rad` | 1e45 | internal USDR debt values (`debt`, `globalLine`, `line`, `dust`, `hole`, `globalHole`, `tab`, internal `usdr`/`sin` balances) = wad × ray |

Token decimals: **USDR = 18. USDT/USDC = 6. RAIN = 18.** The adapter/PSM convert 6→18 internally (`to18ConversionFactor = 1e12`); *external* calls always pass amounts in the **token's native decimals**.

Conversions you will use constantly:
- rad → USDR (18-dec display): `x / 1e27`
- rad → whole dollars: `x / 1e45`
- wad × ray → rad; rad / ray → wad; rad / wad → ray

### 0.1 The vault model (NEW — read before anything else)

Positions ("vaults") are identified by a **sequential `uint256 vaultId`**, allocated by `VaultEngine.open(ilkId, usr)`. Key facts:

- **One user can hold any number of vaults per ilk.** Each vault has its own `ink`/`art`, its own health, and is liquidated independently.
- A vault is **permanently bound** to one ilk and one owner at open time. There is **no transfer** (`give` does not exist) and ids are never reused.
- `VaultEngine.ownerOf(vaultId)` → owner address; `ilkOf(vaultId)` → ilk; `vaultCount()` → latest id; `urns(vaultId)` → `(ink, art)`.
- `open` is **permissionless** and takes an explicit `usr`: a future router can open vaults on behalf of users. When the frontend calls it directly, pass the connected wallet as `usr`.
- `hope`/`nope` (operator permissions) remain **address-level**: an operator approved via `hope` can manage **all** of the owner's vaults. There is no per-vault approval.

**Frontend mapping: one position card = one `vaultId`.** "Open a position" = `open()` + `frob(newVaultId, …)`. Depositing into an existing position = `frob(existingVaultId, …)` — same card updates, never a new card. A card disappears when its vault reaches `ink == 0 && art == 0` (fully closed or fully liquidated).

### 0.2 Renames & ABI changes (old → current, all ABI-visible)

Carried over from the previous doc:
- `Art` → **`globalArt`**; `Line` → **`globalLine`**; `Hole/Dirt` → **`globalHole`/`globalDirt`**; `gem(...)` → **`collateral(ilkId, user)`**; `sellGem`/`buyGem` → **`sellStable`/`buyStable`**; `rely`/`deny` → OZ AccessControl (`RoleGranted`/`RoleRevoked`); `reserve()` → **`totalReserve()`**; custom errors everywhere (decode 4-byte selectors, not strings).

New in this revision:
- **`VaultEngine.frob(uint256 vaultId, address v, address w, int256 dink, int256 dart)`** — was `frob(ilkId, u, v, w, dink, dart)`. The ilk is implied by the vault; `u` is gone.
- **`VaultEngine.grab(uint256 vaultId, address v, address w, int256 dink, int256 dart)`** — same reshape (ward-only, listed for indexers).
- **`VaultEngine.urns(uint256 vaultId)`** — was `urns(ilkId, owner)`. Single-key lookup.
- **New: `VaultEngine.open(bytes32 ilkId, address usr) returns (uint256 vaultId)`** + event **`Open(ilkId, owner, vaultId)`** + getters `ownerOf`/`ilkOf`/`vaultCount`.
- **`LiquidationTrigger.bark(uint256 vaultId, address kpr)`** — was `bark(ilkId, urn, kpr)`.
- **`Frob`/`Grab` events** now `(ilkId indexed, vaultId indexed, v, w, dink, dart)`; **`Bark`** now `(ilkId indexed, vaultId indexed, urn indexed, ink, art, due, clip, id)` where `urn` is the **owner address** (leftover-collateral recipient).
- **PSM fees removed**: `tin`/`tout` no longer exist anywhere in the ABI. `PSM.ilks(ilkId)` now returns `(token, to18ConversionFactor, vaultId)` — the third field is the PSM's own dedicated vault for that stable ilk (useful, see §2).
- New errors to decode: `VaultNotFound()` (frob/grab/bark on an unopened id), `SolvencyGateActive()` (see §5.1), `SystemPaused()` (governance emergency pause), `InvalidBarkFactor()`, `NoPartialPurchase()`, `NeedsReset()`, `InsufficientFreeSlack()`, `DustAmount()`, `CeilingExceeded()`.

**Ilks at launch:** `"RAIN-A"`, `"USDT-A"`, `"USDC-A"` (bytes32). Never hardcode the picker — drive it from adapter `Init` events (see §7).

**⚠️ Gated reads (unchanged):** `OracleSecurityModule.peek/peep/read` are `onlyRole(_READER_ROLE)` — an arbitrary frontend `eth_call` will revert. Prefer: (a) derive the delayed price from public state: `price_wad = ilks(ilkId).spot × mat / 1e27 / 1e9` (`spot` from `VaultEngine.ilks`, `mat` from `PriceConverter.ilks`); (b) index `Poke(ilkId, current, next)` events (wad, uint128); (c) governance `kiss` on a dedicated read-proxy. Do **not** design around calling `peek` from user wallets.

---

## 1. Mint USDR (PSM sell side)

**Tx flow (per mint):**
1. `USDT.approve(PSM, stableAmt)` — approve the **PSM**, not the adapter. (USDT quirk: approve-to-zero-first when a nonzero allowance exists.)
2. `PegStabilityModule.sellStable(ilkId, user, stableAmt)` — `ilkId` = `"USDT-A"` or `"USDC-A"`; `stableAmt` in **6 decimals**; `user` = recipient of USDR.

Output: **`usdrAmt = stableAmt × 1e12`, exactly. There is no fee** — do not render a fee line, do not read `tin`/`tout` (they no longer exist; such a call reverts on decode).

**Reads:**
- *Wallet balance:* `ERC20.balanceOf(user)` (6-dec).
- *"Mint capacity left":* min of two constraints, both enforced in `frob`:
 1. Per-ilk: `VaultEngine.ilks(ilkId)` → `(globalArt [wad], globalInk [wad], rate [ray], spot [ray], line [rad], dust [rad])` — **note the tuple gained `globalInk` at index 1**; ilk capacity `= line − globalArt × rate` [rad]. Sum over `USDT-A` + `USDC-A`.
 2. Global: `VaultEngine.globalLine()` − `VaultEngine.debt()` [rad].
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

## 3. Borrow / positions (CDP — RAIN-A only)

**Open a new position:**
1. `RAIN.approve(CollateralAdapter, amount)` — CDP flow approves the adapter directly (contrast §1).
2. `CollateralAdapter.join("RAIN-A", user, amount)` — credits free collateral (18-dec).
3. `VaultEngine.hope(CollateralAdapter)` — **one-time per wallet** (not per vault), required before step 6.
4. **`VaultEngine.open("RAIN-A", user)` → `vaultId`** — read the id from the tx receipt's `Open` event (or `vaultCount()` in the same multicall). **Persist it: it is the position's identity everywhere.**
5. `VaultEngine.frob(vaultId, user, user, +dink, +dart)` — `dink` [wad] collateral to lock, `dart` [wad] normalized debt. To draw X USDR: `dart = X × 1e27 / rate` (rate is 1e27 today, so `dart = X`, but compute it).
6. `CollateralAdapter.exit("USDR", user, usdrWad)` — converts internal USDR to ERC-20.

**Deposit into an EXISTING position** (the image-#2 case): steps 1–2, then `frob(existingVaultId, user, user, +dink, 0)`. **Same `vaultId` ⇒ update the same card.** Never call `open` for a deposit/borrow/repay/withdraw on an existing position.

**Manage:** withdraw = `frob(vaultId, user, user, −dink, 0)` then `CollateralAdapter.exit("RAIN-A", user, amount)`; repay = `CollateralAdapter.join("USDR", user, usdrWad)` then `frob(vaultId, user, user, 0, −dart)`. Repay needs **no** USDR approval (adapter burns via `_BURNER_ROLE`).

No multicall/router exists in the repo — 1-click UX still needs a periphery contract (open item; `open(ilkId, usr)` was designed so a router can open vaults for users).

**Reads (per position card, all keyed by `vaultId`):**
- *Position:* `VaultEngine.urns(vaultId)` → `(ink [wad], art [wad])`. Debt = `art × rate / 1e27` (18-dec). Filter out `ink == 0 && art == 0` (closed).
- *Owner / ilk:* `ownerOf(vaultId)`, `ilkOf(vaultId)` — sanity-check ownership before rendering.
- *Mark price (delayed):* `price_wad = spot × mat / 1e27 / 1e9` (§0 gated-reads note).
- *Liquidation price — ⚠️ formula changed with `barkFactor`:* liquidation no longer triggers at mat. It triggers when `ink × spot < (art × rate / 1e18) × barkFactor`. So:
 `liqPrice_wad = art × rate × mat × barkFactor / (ink × 1e27 × 1e9 × 1e18)`
 with `barkFactor` [wad] from `LiquidationTrigger.ilks(ilkId)` (struct field after `dirt`; launch value `0.65e18`). At launch: mint gate 400%, **liquidation at 260%** (65% of 400%). The previous doc's formula (without `barkFactor`) overstates liquidation prices by ~1.54× — fix it or every position shows "at risk" prematurely. Health slider: anchor "min" at mat (400%, can't mint below) and "liquidation" at `mat × barkFactor` (260%).
- *Positions list / discovery:* squid — query **`Open` entities filtered by `owner`**, hydrate each `vaultId` live from `urns(vaultId)`. This replaces the old Frob-scan discovery and is exact, not heuristic. (On-chain alone can't enumerate an owner's vaults; there is deliberately no `ownerVaults[]` array.)
- *Available to borrow:* min(per-ilk `line − globalArt × rate`, `globalLine − debt`) plus the vault's own `ink × spot − art × rate` headroom [rad].

**Caveats:**
- dust = **100 USDR (rad) on RAIN-A, per vault** — each vault must independently carry 0 or ≥ 100 USDR debt. Splitting across many vaults multiplies the minimum. Enforce "repay all or leave ≥ 100" per card, and require ≥ 100 USDR initial draw on open.
- During a solvency breach (§5.1), `frob` with `dart > 0 || dink < 0` on volatile ilks reverts `SolvencyGateActive`; repay/top-up always work. Disable Borrow/Withdraw buttons when `isBreached()`, keep Deposit/Repay enabled.
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

## 5. Solvency dashboard

- *Stressed max loss:* `SolvencyEngine.worstCaseLoss()` → wad, view, callable by anyone. Priced from **collateral** (`globalInk × spot × mat` with stress params `stressMarkdown = 0.5e18`, `stressDepth = 0.35e18`, public getters). One scalar; derive any "unstressed" figure client-side and label it.
- *Reserve:* `ReserveAccounting.totalReserve()`; *Escrow:* `committedEscrow()`; *Free slack:* `freeSlack()` (all wad).
- *Solvent badge:* `!SolvencyEngine.breached()` (public flag, refreshed by keeper `checkInvariant()` calls — a write; never prompt users to call it). The threshold is `reserveFactor` (launch 0.9e18): breach when `worstCaseLoss > totalReserve × reserveFactor`.
- *30-day chart:* index `InvariantChecked(reserve, worstCaseLoss, passed)`; cadence = keeper cadence.
- The Circuit Breaker is about **oracle deviation**, not solvency — `CircuitBreaker.active()` belongs on the liquidation page if anywhere.

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

The governance emergency pause (`Governor.paused()`) is a separate, stricter stop: it blocks frob, PSM both directions, and bark, with `SystemPaused`.

## 6. Reserve composition & ceilings table

- Per-ilk rows from `VaultEngine.ilks(ilkId)` + `PriceConverter.ilks(ilkId)`: ratio → `mat` [ray] (`/1e25` = %); mark → derived price (§3) or "$1.00 fixed" when `fixedPrice`; minted → `globalArt × rate` [rad] `/1e45`; ceiling → `line`; **total locked collateral → `globalInk`** [wad] (new tuple field, index 1).
- Global ceiling → `globalLine()`; global minted → `debt()`.
- "Shared ARB/RAIN ceiling": still **no shared-ceiling primitive** — governance convention only; flag to product.
- Protocol-held stables: per stable ilk, `PSM.ilks(ilkId).vaultId` → `VaultEngine.urns(vaultId).ink`; ERC-20s custody at the **CollateralAdapter** address.
- Ceiling change history → `File` events (`"globalLine"` global, `"line"` per-ilk). Liquidation-parameter history: `File` on LiquidationTrigger includes `"barkFactor"`.

## 7. Indexer (squid) checklist — deltas for the multi-vault revision

- **New entity: `Open`** `(ilkId, owner, vaultId)` — the position-discovery primitive. Strongly recommended: a derived **`Position`** entity (`id = vaultId`, fields `ilkId`, `owner`, `ink`, `art`, `liquidated`, `lastUpdated`) upserted from `Open`/`Frob`/`Grab`, flagged by `Bark`. Then position lists are one query; only debt pricing (`rate`) and prices need RPC.
- **`Frob`/`Grab` schema change:** `u: address` is replaced by `vaultId: BigInt` (indexed). `v`/`w` unchanged. **Sum `dink`/`dart` from BOTH Frob and Grab** when deriving balances, or liquidated vaults will show stale collateral.
- **`Bark` schema change:** gains `vaultId` (indexed); `urn` remains and is now the owner address.
- **`Kick`'s `usr`** is now the vault owner (was the urn address — same value only in the old model).
- PSM entities (`SellStable`/`BuyStable`): unchanged shape; fee fields never existed in events. `File` on PSM no longer has `tin`/`tout` keys.
- Unchanged: `RoleGranted`/`RoleRevoked`, `File` keys (`"globalLine"`, `"globalHole"`), adapter `Init`/`Join`/`Exit`, OSM `Poke`/`PokeFailed`, `Take`/`Redo`/`Yank`/`Digs`, `Fess`/`Flog`, `Heal`/`Suck`, `DistributeSurplus`, `InvariantChecked`, `Upchost`, `ExposureClamped`, breaker + governor events, `Cage`.

## 8. Standing caveats

- USDT approve-to-zero-first; always simulate before send; decode custom-error selectors for UX messages (add `VaultNotFound`, `SolvencyGateActive`, `SystemPaused` to the map).
- `rate` fixed at 1e27 today — still compute `art × rate`, never display raw `art`.
- One DutchAuction instance per collateral type — resolve the clip per ilk from `LiquidationTrigger.ilks(ilkId).clip`, not a constant.
- **Persist `vaultId`s client-side but treat the squid (`Open` by owner) as the source of truth** — the user may have opened vaults from another device or via a future router.
- `hope` is per-wallet and covers all the wallet's vaults, current and future — the one-time setup tx does not repeat per position.
- Vaults are not transferable and ids are never reused; `vaultId` is safe as a permanent React key / DB primary key.
