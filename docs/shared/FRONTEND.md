# USDR Frontend/Integrator Requirements Doc

> Contract set: `feature/rate-accrual` @ `017b36a` (branched from `main`, which contains the End + rev-4 remediations).
> Supersedes the `f881aff`/`9a9c81a` doc. Changes in this revision: **(1) stability fees exist** — `rate` is no longer fixed at RAY; debt = `art × rate` with `rate` live-growing per ilk; **(2) `ilks()` tuple gained `duty` and `rho`** — every decoder of the old 6-tuple breaks; **(3) new permissionless `VaultEngine.drip(ilkId)`** + `Drip` event + `feeRecipient` wiring; **(4) position cards must VIRTUALIZE debt between drips; (5) NEW @ `017b36a` — the solvency gate is now self-enforcing at every risk-increasing entry point:** borrow/withdraw `frob`s recompute the invariant on-chain (like `buyStable` already did) and revert `SolvencyGateActive` on breach — `isBreached()` reads are for pre-disabling buttons only, never a guarantee; simulate every gated tx. Everything from the prior revision (multi-vault, auction breaker, self-checking redemption gate, End, immutable timelock delay) carries over.

> **What this document is.** The previous revisions of this file were a requirements doc written from the contract side. This revision rewrites it to describe **how the `rain-usdr` frontend is actually integrated** against the deployed contracts, with file references so code and doc can be checked against each other. Contract facts that were stated but turned out not to match the deployment are corrected inline and marked **[corrected]**.
>
> Auctions have their own document: see `FRONTEND-AUCTION.md`. This file covers units, the account model, mint, redeem, borrow, solvency, data sources and polling.
>
> Deployment audited: **Arbitrum One (42161)**, `NEXT_PUBLIC_ENV=development`. All on-chain values re-read 2026-09-09.

---

## 0. Conventions

### 0.0 Units

| Unit | Decimals | Used for |
| --- | --- | --- |
| `wad` | 1e18 | token quantities, normalized debt (`art`, `globalArt`), collateral (`ink`, `globalInk`), reserve figures |
| `ray` | 1e27 | rates and price factors (`rate`, `duty`, `spot`, `mat`, auction prices, `buf`, `cusp`) |
| `rad` | 1e45 | internal USDR values (`debt`, `globalLine`, `line`, `dust`, `hole`, `tab`, internal `usdr`/`sin`) = wad x ray |

Token decimals: **USDR 18, USDT 6, USDC 6, RAIN 18.** The adapter/PSM convert 6→18 internally (`to18ConversionFactor = 1e12`); external calls always pass the token's native decimals.

**As built.** `src/lib/contracts.ts` holds `TOKEN_DECIMALS` and treats USDT/USDC/USDR as $1-pegged constants. RAIN has no static price — it comes from `useRainPrice()`, a server-side CoinGecko proxy at `/api/rain-price`.

Fixed-point arithmetic is `BigInt` throughout the auction path (`src/lib/auctionQuote.ts`). Elsewhere — mint, redeem, borrow, solvency — values are converted to `number` for display after the bounds have been computed in `BigInt`. The one rule enforced everywhere: **a balance check or a submitted amount never round-trips through a `number`.**

### 0.1 The vault model

Positions are identified by a sequential `uint256 vaultId` from `VaultEngine.open(ilkId, usr)`.

- One user can hold any number of vaults per ilk; each is liquidated independently.
- A vault is permanently bound to one ilk and one owner. No transfer; ids never reused.
- `ownerOf(vaultId)`, `ilkOf(vaultId)`, `vaultCount()`, `urns(vaultId) -> (ink, art)`.
- `hope`/`nope` are **address-level**: an operator approved via `hope` can manage all of that address's vaults. There is no per-vault approval.

**As built.** One position card = one `vaultId`. A card disappears at `ink == 0 && art == 0`. `vaultId` is used directly as the React key.

### 0.2 Stability fees — `duty` is live **[corrected]**

Previous revisions stated: *"All launch duties are `RAY` (zero fee) until governance files otherwise."* **This is no longer true.** Read live from `VaultEngine.ilks("RAIN-A")`:

```
duty = 1000000003022265980097387650   ->  10.00% APY
```

Governance has filed a duty on RAIN-A. Any integrator who read the old line and skipped virtualization is understating every debt figure on screen and rendering liquidation prices that are too low.

Mechanics:

- **`rate`** [ray] is live-growing; `rho` is the last accrual timestamp.
- `VaultEngine.drip(ilkId)` is permissionless. `frob` auto-drips when `dart != 0`; `bark` drips before liquidating; filing a new `duty` drips at the old duty first.
- Accrued fees mint internal USDR to `feeRecipient()` as surplus, with `debt()` up equally.
- Interest accrues on the **debt side only**. Collateral (`ink`) is untouched — repaying the full grown debt always frees exactly the RAIN that was locked.

**Debt must be virtualized between drips:**

```
rate_now = rpow(duty, now - rho, RAY) * rate / RAY      // ray
debt_wad = art * rate_now / 1e27
```

**As built.** `src/utils/rateAccrual.ts` exports `virtualizeRate`, used by **seven** hooks: `useBorrowMarket`, `useMintCapacity`, `usePositionLimits`, `useOpenPosition`, `useManagePosition`, `useSolvencyOnChain`, and via them every position card and borrow form. No screen displays a debt figure computed from the stored `rate`.

The frontend **never calls `drip()`** — it is a write, and `frob` drips implicitly on every borrow/repay. Accrual is therefore driven by user activity, not by the UI.

### 0.3 This is a smart-account app — read before any tx flow below

The single largest difference from a conventional wagmi integration, and the reason every "tx flow" in this document is shaped the way it is.

1. The user connects an **EOA** (injected / WalletConnect / Coinbase, via RainbowKit).
2. `src/utils/getAlchemySmartAccount.ts` derives a **counterfactual Alchemy Account Kit smart account** from that EOA. The address is deterministic, so it is memoised per owner.
3. `SmartAccountInitializer` writes the client into a module-level store (`src/utils/smartClientStore.ts`).
4. **Every balance read and every write uses the smart-account address, not the EOA.** `balanceOf`, `urns`, `collateral`, `usdr`, `can` — all keyed on the smart account.
5. Writes go out as **EIP-5792 `sendCalls` batches** via `src/utils/sendGaslessCall.ts`, through the connector — **not** through the wagmi HTTP transport.

Consequences that contradict the older tx-flow descriptions:

- **`hope` is one-time per smart account, not per EOA.** Wiring it to the connected wallet address is a silent bug: `can(smartAccount, adapter)` stays 0 and `frob` reverts `NotAllowed()`.
- Sequences described as "three txs, strictly sequential" are **one batch** here, except where a later call depends on a value only knowable after an earlier one lands (see §3 and `FRONTEND-AUCTION.md` §9.1).
- **Gas is sponsored** via an Alchemy gas policy, and the app then charges the user the equivalent **in USDT**, appended as an extra transfer call in the same batch (`src/utils/gasFee.ts`, `FEE_BUFFER_MULTIPLIER = 1.2`). `estimateGasFeeUsd` dry-runs the batch through `prepareCalls` to read real gas limits, then prices them with `useEthPrice`. A user with no USDT sees *"Insufficient USDT to cover the network fee."*
- A **session key** signs batches silently after a one-time grant (`grantGaslessPermission`, `sessionSigner.ts`). On expiry the code re-grants, then falls back to the owner signer, which prompts the wallet.
- `sendGaslessCall` waits for `waitForCallsStatus` and throws on `status === "failure"`, so callers never show a false-positive success.

The one exception: `useTransfer` (sending tokens out of the connected EOA) uses plain wagmi `writeContract`. Everything else — mint, redeem, borrow, manage, withdraw, auction buy — goes through the gasless batch path.

### 0.4 ABI shapes in use

- **`VaultEngine.ilks(ilkId)` returns an 8-tuple:** `(globalArt, globalInk, rate, spot, line, dust, duty, rho)`. Every destructure in this repo expects 8.
- `VaultEngine.frob(vaultId, v, w, dink, dart)`; `urns(vaultId)`; `open(ilkId, usr)`.
- `PSM.ilks(ilkId) -> (token, to18ConversionFactor, vaultId)` — the third field is the PSM's own dedicated vault for that ilk.
- `LiquidationTrigger.ilks(ilkId) -> (clip, chop, hole, dirt, barkFactor)`.
- `PriceConverter.ilks(ilkId) -> (pip, mat, fixedPrice)`.
- `DutchAuction.sales(id) -> (pos, tab, lot, vaultId, usr, tic, top)`.
- No PSM fees: `tin`/`tout` do not exist.

Errors are decoded from 4-byte selectors, never string-matched — `src/utils/txError.ts` (`describeTxError`) builds a selector map from six ABIs and is wired into 16 call sites across 9 files. Nothing surfaces a raw RPC error object to the user.

**Gated reads.** `OracleSecurityModule.peek/peep/read` are `onlyRole(_READER_ROLE)` and revert for any browser wallet. The frontend never calls them. Mark price is derived from public state instead — §3.

---

## 1. Mint USDR (PSM sell side)

**As built** — `src/hooks/useMint.ts`, one gasless batch:

1. `USDT.approve(PSM, stableAmt)` — approve the **PSM**, not the adapter. Included only when the current allowance is short. USDT's approve-to-zero-first quirk is handled.
2. `PegStabilityModule.sellStable(ilkId, user, stableAmt)` — `ilkId` = `"USDT-A"` / `"USDC-A"`, `stableAmt` in **6 decimals**, `user` = the smart account.
3. USDT gas-fee transfer appended by `submitWithFee`.

Output: **`usdrAmt = stableAmt x 1e12`, exactly. There is no fee** — no fee line is rendered, and `tin`/`tout` are not read.

**Reads** — `src/hooks/useMintCapacity.ts`:

- Wallet balance: `balanceOf(smartAccount)` (6-dec).
- Mint capacity = min of:
  1. per-ilk `line - globalArt * rate_now`, summed over `USDT-A` + `USDC-A`;
  2. global `globalLine() - debt()`.

The rate is virtualized uniformly even though PSM ilks realistically stay at `duty == RAY`.

**Availability.** `sellStable` is never blocked by the solvency gate — it increases the reserve and is the operation that heals a breach. It *is* blocked by `Governor.paused()`. Preflight: `stableAmt > 0`, capacity >= amount, ilk registered. PSM ilks have `dust = 0`.

---

## 2. Redeem (PSM buy side)

Two routes, both in `src/hooks/useRedeem.ts`, selected in the UI.

**Route A — PSM redeem**, one gasless batch:

1. `USDR.approve(PSM, stableAmt x 1e12)` — face amount exactly, no fee.
2. `PegStabilityModule.buyStable(ilkId, user, stableAmt)` — `stableAmt` in **6 decimals**.

**Route B — Uniswap V3 swap**, one gasless batch:

1. `USDR.approve(SwapRouter02, amount)`
2. `exactInputSingle` through this deploy's own USDR/token pool (`ENV.uniswap.usdrUsdtPool` / `usdrUsdcPool`, fee tier 3000).

`src/hooks/useSwapQuote.ts` prices route B live via canonical QuoterV2 (`0x61fFE014bA17989E743c5F6cB21bF9697530B21e`) — `quoteExactInputSingle`, real price plus fee plus slippage. The router and quoter are chain-wide infra and hardcoded; the pools are deployment-specific and live in `ENV`.

**Capacity** — `src/hooks/useRedeemCapacity.ts`, two independent limits:

- `ReserveAccounting.freeSlack()` — the protocol-wide buffer, a single shared pool.
- Per-token PSM inventory: `PSM.ilks(ilkId).vaultId` → `VaultEngine.urns(vaultId).ink`.

Effective per-token redeemable = `min(freeSlack, psmInk)`.

**Two hard gates, distinct copy for each:**

- **No queue.** `stableAmt18 > freeSlack()` reverts `InsufficientFreeSlack`. The UI clamps to slack and offers the market route. Any "your redemption will wait" copy is wrong.
- **Solvency breach closes redemptions.** `buyStable` reverts `SolvencyGateActive` regardless of slack. `isBreached()` pre-disables the button (`src/components/dashboard/Redeem/RedeemView.tsx:96`) and is **re-checked against a fresh read immediately before submitting** (`:149`), because the flag can go stale (§5.1). Copy: *"Redemptions are paused while the reserve invariant is restored."*

`buyStable` recomputes the invariant in-tx, so a stale-healthy flag is a UX hint, never a guarantee.

---

## 3. Borrow / positions (RAIN-A only)

**Open a new position** — `src/hooks/useOpenPosition.ts`. **Two sequential batches**, and this one genuinely cannot be collapsed: the `vaultId` is only knowable from the first receipt.

```
batch 1:  VaultEngine.open("RAIN-A", smartAccount)
          -> read vaultId from the Open event in the receipt

batch 2:  RAIN.approve(CollateralAdapter, amount)      // only if allowance short
          CollateralAdapter.join("RAIN-A", user, amount)
          VaultEngine.hope(CollateralAdapter)          // only if can(...) == 0
          VaultEngine.frob(vaultId, user, user, +dink, +dart)
          CollateralAdapter.exit("USDR", user, usdrWad)
          + USDT gas-fee transfer
```

To draw X USDR: **`dart = X * 1e27 / rate_now`** with the virtualized rate, rounded **down**.

**Manage** — `src/hooks/useManagePosition.ts`, one batch per action:

- deposit = `join("RAIN-A")` then `frob(+dink, 0)`
- withdraw = `frob(-dink, 0)` then `exit("RAIN-A")`
- borrow = `frob(0, +dart)` then `exit("USDR")`
- repay = `join("USDR", user, usdrWad)` then `frob(0, -dart)` — no USDR approval needed (the adapter burns via `_BURNER_ROLE`). Repaying does **not** move collateral.
- close = `join("USDR", user, debt + buffer)` → `frob(-ink, -art)` → `exit("RAIN-A")`

Repay-all computes the wipe as `dart = -art` read from `urns`, and quotes the USDR cost as `art * rate_now / 1e27` plus a buffer, since debt grows until the tx lands. Excess internal USDR stays in `VaultEngine.usdr(user)` and is reusable, not lost.

**Reads per card:**

- `urns(vaultId) -> (ink, art)`; **debt = `art * rate_now / 1e27`**, virtualized.
- APR line from `duty` — hidden when `duty == RAY`, shown as 10.00% today.
- **Mark price:** `markPrice_wad = spot * mat / 1e27 / 1e9` (`src/hooks/useBorrowMarket.ts:125`). `spot` is index 3 of `VaultEngine.ilks`, `mat` is index 1 of `PriceConverter.ilks`. This inverts `PriceConverter.poke`; it is the delayed OSM value, not a live quote.
> The auction path uses the fuller `(spot * mat * par) / RAY^2`. `par` is `1 ray` today so the two agree exactly; if `par` moves they diverge.
- **Liquidation ratio uses `barkFactor`:** liquidation fires when `ink * spot < (art * rate_now / 1e18) * barkFactor`, so the effective ratio is `mat * barkFactor` — **260%** at a 400% `mat` and `barkFactor = 0.65e18`. The frontend renders `liqPrice = markPrice * liquidationRatio / ratio`. Using `mat` alone overstates liquidation prices by ~1.54x and shows every position as "at risk" prematurely.
- **Liquidation price creeps upward over time** at nonzero duty even if the user does nothing. Since `duty` is live at 10% APY, health bars tick down on their own and at-risk alerts are computed against `rate_now`.
- **Position discovery: REST, not squid** **[corrected]**. `GET /api/v1/positions?owner=<smartAccount>&includeClosed=false` (`src/hooks/useMyPositions.ts`), and `GET /api/v1/positions/{id}` for detail. No squid query is issued anywhere in this app.

**Caveats:**

- `dust` = **100 USDR (rad) on RAIN-A, per vault**. Each vault independently carries 0 or
> = 100 USDR of debt. The UI enforces "repay all or leave >= 100" per card.
- **`frob` self-checks solvency.** With `dart > 0 || dink < 0` on a volatile ilk, `VaultEngine.frob` calls `checkInvariant()` and reverts `SolvencyGateActive` on breach (`VaultEngine.sol` lines 463-471). A healthy `isBreached()` read is not a promise — simulate. Repay/top-up skip the recompute entirely and are always available.
- `PositionCard` uses the **API's** `markPrice` field for its at-risk trigger, not `useBorrowMarket`'s on-chain figure, because the trigger compares against a stable snapshot. Two mark prices therefore exist in the borrow UI, from two sources.

---

## 4. Liquidation auctions

Covered in full by **`FRONTEND-AUCTION.md`**. Summary of the integration points:

- **Listing** from `GET /api/v1/auctions?status=active`. `DutchAuction.list()` is wired up in `useAuctionIds()` but unused.
- **Buy screen** is fully on-chain (`useAuctionLiveStatus`, 6 s poll): `getStatus`, `sales`, `chost`, `tail`, `cusp`, `buf`, `live`, `stopped`, `calc`, `governor`, plus `PriceCurve.tau` and `Governor.paused` as a dependent second stage.
- **Buy flow is two batches** and cannot be one: `join` + `hope` + `take`, then read the collateral delta, then `exit`. The exit amount is not knowable until `take` executes.
- Partial buys that would leave `tab - owe < chost` are **silently resized** to leave exactly `chost`; only `tab <= chost` reverts `NoPartialPurchase`. The UI blocks the clamped band and shows the true delivered figures.
- `needsRedo` replaces the form with a Reset button and states that a reset moves the price **up**.
- `stopped >= 2` or a live pause disables Buy; `stopped >= 3` also disables Reset.
- `tab` is snapshotted at bark time post-drip and fixed for the auction's life — **auction cards never virtualize**. Pre-bark risk warnings *do*, since a vault can become barkable through fee accrual alone.

**Not implemented:** the "you're being liquidated" per-vault banner keyed on `Bark.vaultId`, and any claimable-leftover-collateral indicator. `LiquidationBanner` exists but is driven off the REST position list, not `Bark` events.

---

## 5. Solvency dashboard

`src/hooks/useSolvencyOnChain.ts` (chain, 4 s poll) and `src/hooks/useSolvency.ts` (REST, 60 s poll). **Every live figure on the page comes from the chain hook**; the REST payload supplies only reserve composition, USDR backing, the collateral table and the page title.

Read on-chain in one multicall:

```
SolvencyEngine.worstCaseLoss()     [wad]
SolvencyEngine.breached()          [bool]
SolvencyEngine.reserveFactor()     [wad]  -- 0.9
SolvencyEngine.externalExposure()  [address]
SolvencyEngine.exposureCap()       [wad]
ReserveAccounting.totalReserve()   [wad]
RainExposureReporter.reportedExposure() [wad]
```

plus a per-volatile-ilk second stage (`VaultEngine.ilks`, `PriceConverter.ilks`) used to derive a live "current shortfall" separate from the stressed figure.

### Displayed figures and their formulas

| Card | Formula |
| --- | --- |
| Worst-case payout | `worstCaseLoss()` |
| Cash reserve | `totalReserve()` |
| **Safety buffer** | `max(0, (breachThreshold - worstCaseLoss) / totalReserve) * 100`, where `breachThreshold = totalReserve * reserveFactor` |
| Gauge "of reserve used" | `worstCaseLoss / totalReserve * 100`, capped at `reserveFactor * 100` |
| **Spare cushion** | `totalReserve - min(worstCaseLoss, totalReserve)` |
| Reserved for traders | `RainExposureReporter.reportedExposure()` |

Two properties of the Safety buffer worth stating, because both surprise readers:

- **It caps at `reserveFactor`, not 100%.** The breach condition is `worstCaseLoss > totalReserve * reserveFactor`, so the buffer is measured against 90% of the reserve. A perfectly healthy protocol reads 90.0%, never 100%.
- **It is clamped at zero.** Once breached the true value is negative; the card shows 0.0% whether the protocol is $1 or $20,000 past the floor. Consequently "used %" plus "buffer %" sums to 90%, not 100%.

**Spare cushion reproduces `ReserveAccounting.freeSlack()` exactly** — verified to the cent (`freeSlack() = totalReserve - committedEscrow`, and `committedEscrow` is set to `min(worstCaseLoss, totalReserve)` inside `checkInvariant`). The frontend derives it rather than calling `freeSlack()`, which makes it *more* current than the contract value whenever a keeper is behind. While breached, the card greys out and states that the slack cannot be availed, because redemptions are gated (§2).

### The breach threshold — 90% of the cash reserve

```solidity
// constructor, line 87
reserveFactor = (_WAD * 9) / 10;                              // 0.9

// line 240
function breachThreshold() external view returns (uint256) {
    return (RESERVE_ACCOUNTING.totalReserve() * reserveFactor) / _WAD;
}
```

So the threshold is **`totalReserve x reserveFactor`, i.e. 90% of the cash reserve** at the filed `reserveFactor` of `0.9`. `reserveFactor` is governable (`file`, lines 110-117), so read it rather than hardcoding 0.9 — but 90% is the value live today.

Verified 2026-09-09: `totalReserve` `75,836.71` x `0.9` = `68,253.04`, byte-identical to `breachThreshold()`.

**As built.** The frontend computes `(totalReserve * reserveFactor) / WAD` from reads it already makes, rather than calling `breachThreshold()`. Same value to the wei, and it costs no extra call. The one thing calling `breachThreshold()` would buy is atomicity if governance refiled `reserveFactor` between two reads inside the same multicall — a race we judged not worth an eighth call.

### 5.1 The `breached` flag goes stale **[corrected]**

Previous revisions stated: *"refreshed by the protocol itself: every successful OSM poke (~30 min), every fee-bearing drip, every gated frob/redemption/distribution … near-real-time without any keeper."*

Measured 2026-09-08, live:

```
worstCaseLoss()    64,282.60
breachThreshold()  63,864.50    <- worst case is 418.10 ABOVE the threshold
breached()         false
isBreached()       false
```

The invariant was violated and both flags read healthy; the dashboard rendered a green "Solvent" badge over numbers that read `64.3 > 63.9`.

Cause: one of the three claimed refresh paths does not exist on the deployed contracts.

| Claimed refresh source | Deployed reality |
| --- | --- |
| every successful OSM poke (~30 min) | **Does not happen.** The verified `PriceConverter` contains no reference to `checkInvariant` and no `solvencyEngine` address at all. `poke` cannot refresh the flag. |
| every fee-bearing drip | Works — `VaultEngine.drip` calls `checkInvariant()` when `rad != 0`, and `duty` is nonzero. But `drip` is triggered only by user activity, never on a timer. |
| every gated frob/redemption/distribution | Works, and is likewise user-activity-driven. |

Every surviving path needs someone to transact. On a quiet protocol the flag drifts. `SolvencyEngine.sol` line 22 is the accurate description: *"A keeper bot is expected to call `{checkInvariant}` regularly to keep the flag fresh."*

**As built — the frontend no longer reads the flag for any decision.** Solvency is derived from the two figures the dashboard already displays:

```ts
const breachThreshold = (totalReserve * reserveFactor) / WAD;   // 90% of cash reserve
const breached = totalReserve > 0n
  ? worstCaseLoss > breachThreshold
  : breachedFlag;                                               // first-render fallback only
```

This is the same comparison `checkInvariant()` makes (`SolvencyEngine.sol:221`) against two live `view` calls, so the badge is accurate at every block, agrees with the numbers printed beside it, and matches what a gated `frob` or `buyStable` will decide in-tx.

Applied in three places, sharing one derivation so they cannot diverge:

| Hook | Drives |
| --- | --- |
| `useSolvencyOnChain` | the Solvent/Breached banner and the Spare Cushion card |
| `useSystemBreach` | Borrow / Withdraw / ManagePosition button gating |
| `useRedeemCapacity` | the Redeem button **and** its pre-submit re-check |

The third matters as much as the first: `RedeemView` re-checks breach state immediately before submitting, so leaving that path on the stored flag would have disabled the button live while still waving through a redemption that `buyStable` reverts.

`isBreached()` is still read, used only when `totalReserve` is zero — the window before the reads land, where comparing two zeroes would report a healthy protocol regardless.

### 5.2 External exposure is capped on the deployed contract **[corrected]**

Previous revisions stated: *"There is no cap on external exposure — `reportedExposure()` enters `worstCaseLoss()` at face value, so never display a clamped or capped figure"*, and that `ExposureClamped` was replaced by `ExposureReportFailed`.

The verified source at `0x2484d495258C3e281217995D30Bda16BeF6192dF` says otherwise:

| Symbol | Deployed source |
| --- | --- |
| `exposureCap` | present (lines 49, 118, 126, 141, 210, 211) |
| `ExposureClamped` | present, emitted at lines 211 and 214 |
| `ExposureReportFailed` | **not present** |

The frontend therefore clamps: `exposure = min(reportedExposure, exposureCap)`. The doc describes a build newer than what is deployed.

### 5.3 Chart and history

The 30-day chart is **not** indexed from `InvariantChecked`. It comes from `GET /api/v1/solvency/history/daily?from=&to=` (`useSolvencyHistory`, fetched once on mount, no polling).

The snapshot payload comes from **`GET /api/v1/solvency/implied`**, not `/api/v1/solvency`. The plain endpoint reported RAIN at `$0.017517` where the chain implies `$0.959066` via `spot * mat`; `/implied` returns the chain-consistent value and self-describes as `markMode: "vaultEngine.spot"`. Any other consumer still on the plain endpoint has the same bug.

### 5.4 Breach-mode matrix

| Operation | State when breached | Error |
| --- | --- | --- |
| PSM mint (`sellStable`) | open — heals the breach | — |
| PSM redeem (`buyStable`) | blocked | `SolvencyGateActive` |
| Borrow / withdraw collateral (volatile ilks) | blocked | `SolvencyGateActive` |
| Repay / deposit collateral | open | — |
| Liquidations (`bark`/`take`/`redo`) | open | — |
| `open` (new vault, no debt) | open | — |
| `drip` | open | — |
| OSM `poke` | open | — |

All three hard gates (`frob`, `buyStable`, `distributeSurplus`) recompute the invariant in-tx, so the matrix is enforced against live state, not the stored flag. Button-disabling is driven from the **derived** comparison in §5.1 — which is the same test those gates apply — so the hint and the outcome now agree. The revert remains the authority; callers still simulate.

`Governor.paused()` is a separate, stricter stop: it blocks `frob`, PSM both directions and `bark`, with `SystemPaused`. It auto-expires after 72h — poll it, do not cache the event.

**Not implemented:** `CircuitBreaker.active()` is not read anywhere in the app.

---

## 6. Reserve composition & ceilings

Per-ilk rows come from `VaultEngine.ilks(ilkId)` (8-tuple) plus `PriceConverter.ilks(ilkId)`: ratio = `mat` (`/1e25` = %), mark = the derived price above, minted = `globalArt * rate_now`, ceiling = `line`, locked collateral = `globalInk`, stability fee = `duty` as APY.

Global ceiling = `globalLine()`; global minted = `debt()`.

The composition and backing tables on the solvency page are **served by the REST API** (`/api/v1/solvency/implied`), not assembled client-side from these reads.

> Known cosmetic mismatch: the Cash Reserve card's headline is on-chain `totalReserve()` while its sub-line breakdown ("held in USDT $X · USDC $Y") comes from the REST payload. The two can disagree by a small amount.

---

## 7. Indexer

**The frontend does not use a squid.** All list data — positions, auctions, solvency history, platform stats — comes from the REST API at `usdr-api.rain.one`. No GraphQL query is issued anywhere in this app, and no event is indexed client-side.

The indexer requirements from previous revisions still apply to whoever runs the backend; they are simply not this frontend's concern. The one thing worth carrying forward is that the API is the frontend's only view of historical data, so anything the indexer stops writing disappears from the UI silently — see §8.

---

## 8. Data sources, polling and rate limits

Two independent sources, and they can disagree.

| Surface | Source | Cadence |
| --- | --- | --- |
| Auctions listing | REST `/api/v1/auctions?status=active` | on demand |
| Auction buy screen | **chain** | 6 s |
| Positions list | REST `/api/v1/positions?owner=` | 60 s |
| Position limits / borrow market | **chain** | 6 s |
| Solvency figures | **chain** | 4 s |
| Solvency composition / backing | REST `/api/v1/solvency/implied` | 60 s |
| Solvency history | REST `/api/v1/solvency/history/daily` | once on mount |
| Platform stats | REST `/platform-stats` | 60 s |

**Never gate a transaction on API data.** Prices, lots and debts move every block. Every write path re-reads the values it depends on from the chain immediately before building the batch.

**The REST API rate-limits at 120 requests per 60 seconds** (`RateLimit-Policy: 120;w=60`). The REST hooks are plain `useState` + `setInterval`, **not** react-query, so multiple mounted instances do not dedupe and each spends its own budget. All three were moved to 60 s after a QA session hit 429s; at 6 s a single open solvency tab cost ~21 req/min and five tabs exhausted the limit.

A 429 currently surfaces as *"Failed to load solvency data"*, indistinguishable from a real outage, and discards the last good payload. **Open improvement:** back off and retain.

**RPC batching** (`src/lib/wagmi/config.ts`):

```ts
batch: { multicall: { wait: 250 } },
transports: { [arbitrum.id]: http(rpcUrl, { batch: { wait: 250, batchSize: 20 } }) },
```

`batch.multicall` is read-only — it lives inside viem's `call` action and folds separate `eth_call`s into multicall3 `aggregate3`. The transport `batch` is not read-scoped, but in this app only reads travel that path because writes go through the connector (§0.3). `batchSize` is capped at 20, far below viem's default of 1000: a batch is one HTTP response, so a 429 fails every call inside it together. `wait: 250` rather than ~16 ms because each hook's interval starts at its own mount time and the cadences differ, so fires spread across the cycle.

`QueryClient` sets `staleTime: 5_000`. `refetchOnWindowFocus` is deliberately left **on**: react-query pauses `refetchInterval` while the tab is hidden, so disabling it would show stale numbers for up to a full poll interval on return.

---

## 9. Standing caveats

- USDT approve-to-zero-first; simulate before send; decode custom-error selectors (`describeTxError`).
- **`rate` is live** — never display raw `art`; always `art * rate_now`. `duty` on RAIN-A is 10.00% APY today (§0.2).
- **`hope` is per smart account**, not per EOA, and covers all that account's vaults.
- Vaults are not transferable and ids are never reused; `vaultId` is a safe permanent key.
- One `DutchAuction` per collateral type — resolve the clip per ilk from `LiquidationTrigger.ilks(ilkId).clip`, not a constant.
- SCSS is global and page-scoped: a class nested under one page's parent selector does not apply in another component tree. This has caused the same bug three times.

---

## 10. Not implemented

Present in the contracts and in previous revisions of this document, absent from the frontend:

| Feature | Status |
| --- | --- |
| **Emergency settlement (`End`)** | ABI present, `END_ADDRESS` in `ENV`; **no hook or component uses it.** There is no settlement mode. If `End.cage()` ever fires, the app has no UI for `skim`/`free`/`pack`/`cash`. |
| `CircuitBreaker.active()` | not read anywhere |
| `Bark`-driven per-vault liquidation banner | `LiquidationBanner` is driven off the REST position list instead |
| Claimable leftover collateral indicator | not built |
| `chip` / `tip` keeper reward display | not read (see `FRONTEND-AUCTION.md` §2) |
| `drip()` call | never called — `frob` drips implicitly |
| Squid / GraphQL | not used; REST only (§7) |
| Dust labelling in the auctions listing | needs the live `lot`, which the API-only listing does not carry |
