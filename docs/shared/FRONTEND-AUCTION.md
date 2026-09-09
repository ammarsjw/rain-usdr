# Dutch Auction — Integration Guide (as built)

Reference for `DutchAuction` (`contracts/liquidation/DutchAuction.sol`) **and a record of how the
USDR frontend actually integrates it**. Contract behaviour is described first; every place the
shipped UI differs from the original recommendation is called out explicitly and justified.

Everything in §1–§6 is derived from the contract. Everything in §7–§12 describes the live frontend
(`rain-usdr`, branch `dev`), with file references so the code and this document can be checked
against each other.

> **Status:** implemented. Auction parameters re-read from Arbitrum One 2026-09-09 and matching the
> values filed below.

---

## 1. Units

The three fixed-point scales are used consistently and mixing them up is the most common integration
bug. There is no floating point anywhere — do all of this in `BigInt` / `uint256`, never in
JavaScript `number`.

| Scale | Decimals | Used for |
| --- | --- | --- |
| `wad` | 18 | Collateral amounts (`lot`, `amt`, `slice`) |
| `ray` | 27 | Prices (`price`, `top`, `buf`, `cusp`) |
| `rad` | 45 | USDR amounts (`tab`, `chost`, `owe`) |

The only conversion the contract performs is `owe [rad] = slice [wad] * price [ray]`, which is exact
by construction. RAIN is an 18-decimal token, so `wad` amounts map 1:1 onto RAIN token units.

USDR is also an 18-decimal token, but internal USDR balances are tracked in `rad`. A `rad` value is
therefore **not** generally representable as a USDR token amount — see [§8](#8-rounding-rules).

**As built.** `src/lib/auctionQuote.ts` is `BigInt`-only by construction: its module header forbids
any `number` in or out, and every bound, gate and submitted amount in the buy screen flows from it.
Conversion to a display string happens at the render boundary only, through the formatters in that
same file.

---

## 2. Parameters currently filed for `RAIN-A`

Read them on-chain rather than hardcoding — they are governable. Values below were read live on
2026-09-09.

| Parameter | Value | Where | Meaning |
| --- | --- | --- | --- |
| `dust` | 100 rad | `VaultEngine.ilks(ilk)` | Minimum vault debt |
| `chop` | 1.13 wad | `LiquidationTrigger.ilks(ilk)` | Liquidation penalty, 13% |
| `chost` | **113 rad** | `DutchAuction.chost()` | Cached `dust * chop`. The dust floor for partial buys |
| `buf` | 1.05 ray | `DutchAuction.buf()` | Opening price markup, 5% over market |
| `tau` | 3600 s | `PriceCurve.tau()` | Time for the price to decay linearly to **zero** |
| `tail` | 1800 s | `DutchAuction.tail()` | After this, `take` stops working and `redo` opens |
| `cusp` | 0.40 ray | `DutchAuction.cusp()` | Price-ratio reset trigger |
| `chip` | 0.02 wad | `DutchAuction.chip()` | Keeper reward as a fraction of `tab`, 2% |
| `tip` | **0 rad** | `DutchAuction.tip()` | Flat keeper reward. Deploy never files it, so it stays zero |

Keeper reward on `kick` / `redo` is `tip + (tab * chip) / WAD`.

`chost` is a **cache**. It only changes when someone calls the permissionless `upchost()` after
governance changes `dust` or `chop`. Re-read it rather than caching it client-side indefinitely.

**As built.** `chost`, `tail`, `cusp` and `buf` are re-read every poll cycle alongside `getStatus`,
so an `upchost()` is picked up within one refresh. **`chip` and `tip` are not read** — the UI
surfaces no keeper reward, so the reward formula above is currently unused by the frontend. Add both
reads if a "reset this auction and earn X" affordance is ever built.

---

## 3. State the frontend reads

`src/hooks/useAuctionLiveStatus.ts` reads all of the following for the auction on screen, on a
6-second poll (roughly two Arbitrum blocks):

```
DutchAuction.getStatus(id) -> (needsRedo, price [ray], lot [wad], tab [rad])
DutchAuction.sales(id)     -> (pos, tab, lot, vaultId, usr, tic, top [ray])
DutchAuction.chost()       -> [rad]
DutchAuction.tail(), cusp(), buf()
DutchAuction.live()        -> 1 while running
DutchAuction.stopped()     -> 0 | 1 | 2 | 3
DutchAuction.calc()        -> PriceCurve address
DutchAuction.governor()    -> Governor address
PriceCurve.tau()                                   // second stage, once calc() resolves
Governor.paused()          -> bool                 // second stage, once governor() resolves
VaultEngine.ilks(ilk)      -> (..., spot [ray], ...)
PriceConverter.ilks(ilk)   -> (pip, mat [ray], fixedPrice)
PriceConverter.par()       -> [ray]
```

`calc()` and `governor()` are read rather than hardcoded, and `tau()` / `paused()` are issued as a
dependent second stage once those addresses resolve.

Two further reads happen at submit time in `src/hooks/useAuctionActions.ts`, against state read that
instant rather than the polled cache:

```
VaultEngine.can(buyer, dutchAuction) -> 1 if the auction may pull the buyer's USDR
USDR.balanceOf(buyer)                -> checked against ceilDiv(owe, RAY)
```

`price` decays every second, so every derived bound decays with it. Recompute per block; a bound
computed at page load is stale immediately.

### Market price — the frontend never calls `OSM.peek`

`OracleSecurityModule.peek`, `peep` and `read` are all `onlyRole(_READER_ROLE)`. An unprivileged
caller — including every browser wallet — reverts with `AccessControlUnauthorizedAccount`.

The delayed market price is derived from the public poke outputs instead:

```
feedPrice [ray] = (spot * mat * par) / (RAY * RAY)
```

This inverts `PriceConverter.poke` and recovers the OSM value as of the last successful `poke`. It
is not a live OSM `cur` read: if the OSM has updated and `poke` has not yet run, `feedPrice` lags.
That is the sanctioned public path for market price, discount, lot market value and savings.

> The borrow screen derives the same quantity as `spot * mat` without `par`
> (`src/hooks/useBorrowMarket.ts`). `par` is `1 ray` today so the two agree exactly; if `par` ever
> moves off 1.0 the borrow mark and the auction feed price will diverge.

---

## 4. The four quantities everything follows from

With `tab`, `lot`, `price` and `chost` in hand, compute these once per refresh:

```
available     = min(lot, tab / price)            // floor; most collateral anyone can receive
partialCap    = min(lot, (tab - chost) / price)  // floor; only defined when tab > chost
clearAt       = ceilDiv(tab, price)              // amt to ENTER to pay the whole tab
allOrNothing  = min(lot, clearAt)                // below this, no partial buy is legal
```

- **`available`** is the maximum collateral the auction can ever hand out, and it is **not** `lot`.
  When `lot * price > tab` the payment is capped at `tab` and delivery at `tab / price`. See §4.1.
- **`partialCap`** is the largest amount that fills at exactly the size requested. The raw `(tab -
  chost) / price` can exceed `lot` whenever `lot * price <= tab - chost`, so it is always clamped to
  `lot`.
- **`clearAt`** is the amount a buyer must **enter** to pay the entire `tab`. It is one wei above
  `available` whenever `tab` is not an exact multiple of `price` — almost always.
- **`allOrNothing`** is the threshold that matters when `tab <= chost`: nothing below it is legal.

`allOrNothing` equals `lot` when the collateral is worth less than the debt, and `clearAt` when it
is worth more.

**As built.** `bounds()` in `src/lib/auctionQuote.ts` returns exactly these four, plus one addition
the original reference implementation lacked:

```ts
clampBandExists: tab > chost ? lot * price > tab - chost : true
```

This drives whether the "amounts in between are resized" warning appears at all. When the band does
not exist the whole range `0…lot` fills exactly and no warning belongs on screen (§6 A1).

### 4.1 `total` and `available` are different numbers

`lot` is what the auction holds. `available` is what a buyer can actually walk away with:

```
total      = lot / 1e18
available  = min(lot, tab / price) / 1e18       // floor division
payForAll  = min(lot * price, tab) / 1e45       // what taking `available` costs
```

They diverge exactly when `lot * price > tab` — the collateral is worth more than the debt. The
excess is `flux`'d back to the liquidated borrower, never to the buyer.

The frontend shows **Total** and **Available** as separate rows on the buy screen, per this section.

> **The one-wei trap.** To *receive* `available` a buyer must *enter* `clearAt`, which is `available
> + 1 wei`. Entering `available` itself is one wei short of tipping `owe` past `tab`, so it lands in
> the clamped branch instead and delivers only `partialCap`. The gap is exactly `chost / price` of
> collateral.
>
> With `tab` 200 USDR, `lot` 200,000 RAIN and `price` 0.0019106:
>
> | Amount entered | Branch | Delivered | Paid |
> | --- | --- | --- | --- |
> | `104,679.158379566628284308` (`available`) | clamped | `45,535.433895111483303674` | `87` |
> | `104,679.158379566628284309` (`clearAt`) | capped at debt | `104,679.158379566628284308` | `200` |
> | `200,000` (whole `lot`) | capped at debt | `104,679.158379566628284308` | `200` |
>
> One wei of input swings delivery by 59,143.724484455144980634 RAIN. **Never wire Max to
> `available`.** Displaying `available` as the available balance is correct; submitting it as the
> amount is not.

### 4.2 What the frontend actually submits — and why it is not `lot`

The earlier revision of this guide recommended filling the input with `allOrNothing` and
**submitting `lot`**. The shipped frontend submits the **all-or-nothing amount sized against a price
1% below the one just read** (`src/hooks/useAuctionActions.ts`):

```ts
const guardPrice = (price * 99n) / 100n;
const clearAt = guardPrice > 0n ? ceilDiv(tab, guardPrice) : lot;
amtWad = clearAt < lot ? clearAt : lot;
```

**Why not `lot`.** Submitting `lot` is correct and safe — it takes branch 1 or 3 and cannot hit
`NoPartialPurchase`. It was rejected on product grounds: the calldata should carry the same number
the confirmation screen showed. On a lot of 39,878 RAIN where only 172 RAIN is purchasable, `amt =
39,878` reads like a 39,878-RAIN purchase in every wallet and explorer that renders the call.

**Why the 1% margin is load-bearing.** `take` prices at *execution*, not submission, and the curve
keeps decaying in between. An all-or-nothing amount computed even seconds early no longer covers the
whole `tab`: `slice < lot` drops it into the partial branch, and with the remainder under `chost`,
branch 4b silently resizes it. Fuzzing 100,000 random `{tab, lot, price, chost}` states with the
execution price 0–0.40% below the quoted price (0–12 s of decay at the observed rate):

| Submitted | Clamped (4b) | Auction left open |
| --- | ---: | ---: |
| `allOrNothing`, no margin | 34,397 | 48,691 |
| `allOrNothing`, 1% margin | 0 | 0 |
| whole `lot` | 0 | 0 |

1% is roughly 32 s of decay at the observed rate against an Arbitrum inclusion time of a second or
two. Overshooting costs the buyer nothing — `take` caps `owe` at `tab` and refunds the surplus
collateral to the borrower — so every amount in `[clearAt, lot]` settles identically.

**If you are building a keeper rather than a UI, submit `lot`.** It is simpler and strictly safer.
The margin exists only to keep a human-readable number in the calldata.

---

## 5. What `take` actually does

`take(id, amt, max, who, data)` walks four mutually exclusive branches **in this order**, with
`S = min(lot, amt)` and `owe = S * price`:

| # | Condition | Behaviour | USDR debited | Collateral delivered |
| --- | --- | --- | --- | --- |
| 1 | `owe > tab` | Payment capped at the outstanding debt, size back-solved | `tab` | `floor(tab / price)` (= `available`) |
| 2 | `owe == tab` | Exact clear | `tab` | `S` |
| 3 | `owe < tab` and `S == lot` | Entire remaining lot sold; shortfall becomes bad debt | `lot * price` | `lot` |
| 4a | `owe < tab`, `S < lot`, `tab - owe >= chost` | Ordinary partial fill | `owe` | `S` |
| 4b | `owe < tab`, `S < lot`, `tab - owe < chost`, `tab > chost` | **Silently clamped** so exactly `chost` is left behind | `tab - chost` | `floor((tab - chost) / price)` |
| 4c | `owe < tab`, `S < lot`, `tab - owe < chost`, `tab <= chost` | **Reverts** `NoPartialPurchase()` | — | — |

Branch **4b is the one to guard against**: it does not revert. The transaction succeeds while
delivering less collateral for less USDR than the confirmation screen showed.

**Both 4b and 4c are guarded by `slice < lot`.** A full-lot take can reach neither. This is the
property the frontend's Full lot mode relies on for its safety.

After the branches resolve:

- `lot` fully consumed → the auction is removed; any `tab` left over is **never recovered**.
- `tab` fully paid with collateral left → the leftover `lot` is returned to the **liquidated
  borrower**, not the buyer.

---

## 6. The two scenarios

`bark` can never open an auction with `tab < chost`: `frob` forces every vault above `dust`, and
`tab = due * chop >= dust * chop = chost`. So there are exactly two states to validate against.

### Scenario A — `tab > chost`

**No amount can revert on the dust rule.** `tab - chost > 0` means a legal smaller purchase always
exists — the one that leaves exactly `chost` behind — so the contract substitutes it instead of
rejecting the call. The only risk here is a fill smaller than requested.

Whether that substitution can even trigger depends on a single comparison:

```
a clamped fill is possible  <=>  lot * price > tab - chost
```

#### A1 — `lot * price <= tab - chost`: nothing can clamp

Every amount from `1 wei` to `lot` fills exactly. `partialCap` exceeds `lot` in this case and is
meaningless — the frontend clamps it to `lot` and suppresses the resize warning entirely via
`clampBandExists`.

#### A2 — `lot * price > tab - chost`: the clamped band exists

| Amount entered | Result | Debited | Delivered |
| --- | --- | --- | --- |
| `1 wei … partialCap` | Exact fill | `amt * price` | `amt` |
| `partialCap + 1 wei … allOrNothing - 1 wei` | **Succeeds, clamped** | `tab - chost` | `partialCap` |
| `>= allOrNothing` | Auction closes | branch 1 or 3 | see branch table |

Any clamped fill leaves `tab` at **exactly `chost`**, which moves the auction into Scenario B for
everyone who comes after.

### Scenario B — `tab <= chost`

**Only one purchase is legal: the whole remaining position.** The band from `1 wei` to
`allOrNothing - 1 wei` reverts with `NoPartialPurchase()`.

Derive validation from `tab <= chost` rather than `tab == chost`: if `upchost()` ever raises `chost`
above an in-flight `tab`, `amt = 0` reverts too.

**As built.** The frontend does not warn here — it **disables the Partial option outright** and
forces Full lot, because every partial amount in this state is a guaranteed revert. If `tab` crosses
under `chost` while the screen is open (someone else's clamped fill), the mode switches itself to
Full lot during render.

### `chost` guards the debt remainder, not the collateral remainder

Nothing in `take` inspects `lot - slice`. A buyer in Scenario A1 can buy `lot - 1 wei` and leave an
auction holding one wei of collateral against the full remaining `tab`.

Consequences, and how the frontend handles them:

- The auction stays in `active` and `sales`. **Dust lots are not filtered from the listing** — the
  frontend shows them. They are real open auctions with a remaining `tab`, and hiding them conceals
  locked liquidation capacity.
- Lots below `0.0001 RAIN` render a dedicated explanation on the buy screen rather than being
  hidden: *"Only a dust remainder is left … it can only be taken in full."*
- Amount formatting is adaptive (`toAmountFloor` / `toAmountCeil`): a non-zero amount is never
  displayed as `"0"`. A lot ground down to a few thousand wei falls back to full precision instead
  of truncating to nothing, because rendering it as zero is what made such auctions look sold out.
- `LiquidationTrigger.dirt` and `globalDirt` keep the remaining `tab` booked against `hole` /
  `globalHole` until the auction ends.
- Nobody is paid to clear it: `redo` only pays the keeper reward when `tab >= chost` **and** `lot *
  feedPrice >= chost`.

---

## 7. What the buy screen displays

`src/components/dashboard/Auctions/AuctionBuy.tsx`. Every figure below comes from `quote()` or
`bounds()`, never from the entered amount or `amt * price`.

### Shown

| Field | Formula | Notes |
| --- | --- | --- |
| Current price | `price / 1e27` | 8 significant digits |
| Market price | `feedPrice / 1e27` | Last poked OSM value via §3 |
| Opening price | `sales(id).top / 1e27` | |
| Discount now | `1 - price / feedPrice` | Fixed point; `—` when `price == 0` |
| **Total** | `lot / 1e18` | Collateral the auction holds |
| **Available** | `min(lot, tab / price) / 1e18`, floored | Most a buyer can receive |
| Cost to take available | `min(lot * price, tab) / 1e45` | `tab` exactly when the debt binds |
| **Max partial buy** | `min(lot, (tab - chost) / price)`, floored | `"None — full lot only"` when `tab <= chost` |
| **All-or-nothing amount** | `min(lot, ceilDiv(tab, price))`, ceiled | |
| You pay | `quote.pay / 1e45` | |
| You receive | `quote.receive / 1e18` | |
| Market value | `quote.receive * feedPrice / 1e45` | |
| Your savings | `quote.receive * feedPrice - quote.pay` | Uses the **delivered** amount |
| Unrecovered debt | `quote.unrecoveredDebt / 1e45` | Only when the buy closes an underwater auction |
| Returned to borrower | `quote.returnedToBorrower / 1e18` | Goes to the vault owner, not the buyer |
| Floor price | `top * (tau - deadline) / tau` | **not** `cusp * top` |
| Buying closes in | `tic + deadline - now` | |

### Deliberately not shown

| Field | Why |
| --- | --- |
| **Remaining debt** (`tab`) | Removed after user testing. It drives every bound but reads as a number the buyer owes |
| **Lot value now** (`lot * price`) | Removed — duplicated Cost to take available in every realistic case |
| **Lot market value** (`lot * feedPrice`) | Removed from the schedule card; still used for the header subtitle *"Liquidation Lot — Market $X"* |
| **USDR you must hold** (`ceilDiv(owe, RAY)`) | Removed as a row. **Still enforced**: it is what the balance check and the `join` amount use (§8.2) |
| **Amount that clears the debt** (`clearAt`) | Never built — the All-or-nothing row is the same number in every case a user can act on |
| Keeper reward | `chip` / `tip` are not read (§2) |

### The price schedule

`PriceCurve` is a straight-line decay to **zero** over `tau`. There is no floor-price parameter
anywhere in the system. The lowest price at which `take` can still succeed is set by whichever reset
condition fires first:

```
deadline = min(tail, tau * (RAY - cusp) / RAY)
minPrice = top * (tau - deadline) / tau
```

With `tau = 3600`, `tail = 1800` and `cusp = 0.40`, the `cusp` condition would not fire until
2160 s, so `tail` always wins: `deadline = 1800 s` and `minPrice = top / 2`. **`cusp` is unreachable
under the current parameters** — resets are always triggered by time, never by price.

The frontend's schedule bar is anchored to `minPrice` and driven off elapsed time against
`deadline`, not to `cusp * top`.

Past `deadline`, `take` reverts `NeedsReset()` until someone calls `redo(id, kpr)`, which resets
`tic` to now and lifts `top` back to `1.05 x` the current market price. The buy screen replaces the
form with a **Reset auction** button and states plainly that a reset moves the price **up**.

---

## 8. Rounding rules

1. **Floor the partial cap, never round it.** Rounding up puts the value above the cap and into the
   clamped band.
2. **Ceiling the USDR requirement.** `CollateralAdapter.join(USDR_ILK, user, amount)` credits
   `amount * 1e27` rad, so the buyer must join at least `ceilDiv(owe, 1e27)` USDR token units, or
   `VaultEngine.move` underflows with a bare arithmetic panic and no readable error. The frontend
   uses `quote.payWei` for both the balance check and the `join`.
3. **Never round a bound in the direction that widens it.** Floor maxima, ceil minima.
   `toFixedFloor` / `toFixedCeil` in `auctionQuote.ts` exist for exactly this.
4. **A displayed balance is not a submittable amount.** `available` is the most a buyer can
   *receive*; submitting it clamps the fill.
5. **Prices need more digits than you think.** At `$0.0019106` a 4-decimal display is a 0.6% error.
   The frontend renders prices at 8 decimals.
6. **A non-zero amount must never display as `0`.** Below the requested precision the adaptive
   formatters fall back to the exact value.

---

## 9. Preflight checks

Only one of these failures is about the amount. All are validated before the buy button is enabled.

| Condition | Reverts with | Frontend check |
| --- | --- | --- |
| `live != 1` | `NotLive()` | `DutchAuction.live()` — gate reason rendered, form disabled |
| `stopped >= 2` | `Stopped()` | `DutchAuction.stopped()`; `>= 3` also hides Reset |
| Governance pause | `SystemPaused()` | `Governor.paused()`, address read from `DutchAuction.governor()` |
| `sales[id].usr == 0` | `AuctionNotRunning()` | Dedicated "this auction has ended" screen |
| `now - tic > tail`, or `price/top < cusp` | `NeedsReset()` | Form replaced by Reset button |
| `max < price` | `TooExpensive()` | `max` sent as the quoted `price` in ray |
| Partial below the dust rule | `NoPartialPurchase()` | Partial mode disabled when `tab <= chost` |
| Internal USDR balance `< owe` | **arithmetic panic, no custom error** | Checked against `ceilDiv(owe, RAY)` twice: on screen before the click, and against a fresh read at submit |
| Auction not authorised to pull USDR | `NotAllowed()` | `VaultEngine.can(buyer, dutchAuction)`; `hope` appended to the same batch when missing |

Gate reasons are rendered as self-contained sentences, e.g. *"Buying is paused by the circuit
breaker, which stops purchases during an oracle incident. It resumes when governance lifts the
halt."*

**Choosing `max`.** The price only falls with time, so a quote-time `price` is a safe `max` against
decay. It is *not* safe against a `redo`, which raises `top` — a front-run reset makes the buy
revert rather than execute at a worse price, which is what you want. The frontend passes the quoted
`price`, never `type(uint256).max`.

**Front-running changes the band, not the outcome.** If another buyer lands first, `tab` and `lot`
shrink and a previously exact amount can fall into branch 4b. `useAuctionActions.buy` therefore
re-reads `getStatus` and `chost` and re-quotes immediately before building the batch, and rejects
the submission outright if the fresh quote comes back `clampedToChost`.

**`data` and `who`.** The frontend passes empty `data` and its own smart-account address as `who`.

### 9.1 The buy is two batches, not one — and it cannot be one

`take` credits collateral on the internal ledger via `flux`; the buyer holds no RAIN tokens until
`CollateralAdapter.exit(RAIN_ILK, user, amount)`.

**These cannot be bundled.** The `exit` amount is the on-chain collateral delta, which is not known
until `take` has executed — and `take` can legitimately deliver less than requested (branches 1 and
4b). The frontend therefore submits:

1. `join(USDR_ILK, buyer, payWei)` + `hope(dutchAuction)` if needed + `take(id, amt, price, buyer,
   "")`
2. read `VaultEngine.collateral(RAIN_ILK, buyer)` before and after, retrying up to 5 times
3. `exit(RAIN_ILK, buyer, delta)`

A periphery `takeAndExit` would collapse this into one batch. Until then there is a multi-second
window in which the sale struct is already deleted on-chain while the receipt is still being
assembled. **Any UI that treats `sales[id].usr == 0` as "auction over" will flash an error over a
successful purchase** — the frontend suppresses its ended-state screen while a buy is in flight for
exactly this reason.

### 9.2 The collateral delta is not the purchase when the buyer is the borrower

When a take clears the `tab` and collateral remains, the leftover is `flux`'d to the liquidated
vault owner. If the buyer **is** that owner, both credits land on the same address and a delta-based
"you purchased" figure reports the entire original lot.

Observed on `0xb9c1da21bfe7fa4d6f303a9cb5d29c68c0817aed0d22248ea9b099a712eb4350` (auction 95) — two
`Flux` events, same recipient:

```
Flux RAIN-A -> 0x49B7…09B9      581.025791545583752961   (purchased)
Flux RAIN-A -> 0x49B7…09B9   90,305.974208454416247039   (borrower refund)
                             --------------------------
                             90,887.000000000000000000   (the pre-take lot)
```

The `exit` of the full delta is correct — the buyer owns all of it. Only the *label* is wrong. An
integrator who needs the true fill should read `owe` and `price` from the `Take` event and compute
`slice = owe / price`, which reproduces the contract's own arithmetic exactly. The frontend
currently reports the delta and accepts this quirk, since the refund can only ever reach the vault
owner.

---

## 10. The amount control, as built

The original guide assumed one amount field plus a Max button. The shipped UI is a **two-mode
control**, because storing a number was the bug:

Max used to write `allOrNothing` into the input. The price then decayed, `allOrNothing` grew, and
the stored figure fell below the new clearing amount — landing in the clamped band and silently
executing as a partial buy on a screen that had just quoted a full clear.

| Mode | Input | Max fills | Submits |
| --- | --- | --- | --- |
| **Full lot** | none | — | guarded all-or-nothing (§4.2) |
| **Partial** | free text | `partialCap` | the typed amount |

- **Full lot holds no number at all.** The amount is re-derived from live state on every render, so
  it cannot go stale.
- **Partial's Max fills `partialCap`, not `allOrNothing`.** `partialCap` can never clamp, and as the
  price falls it only grows — so a stale value stays valid instead of becoming dangerous.
- The two options are mutually exclusive by construction: there is no state in which both or neither
  is selected, and no amount to reconcile between them.
- Partial is disabled when `tab <= chost` (§6 Scenario B).
- When an amount does land in the clamped band, the UI blocks submission **and** shows the real
  figures: *"This amount would be silently resized … it would deliver only X RAIN for $Y — not what
  you entered."*

---

## 11. Reference implementation

`src/lib/auctionQuote.ts` is a line-for-line port of §5. Feed it live `getStatus(id)` and `chost()`
readings. Differences from the original reference in this guide, all deliberate:

- `partialCap` is clamped to `lot` (the prose mandated it; the original code omitted it).
- `bounds()` returns `clampBandExists` so the resize warning can be suppressed in case A1.
- `bounds()` and `quote()` both guard `price <= 0`; past the reset deadline the curve reads zero and
  every derived figure would otherwise be `$0` or `100%`.
- Formatting helpers (`toFixedFloor`, `toFixedCeil`, `toAmountFloor`, `toAmountCeil`,
  `toInputString`, `parseInputAmount`) live in the same module so no caller is tempted to round a
  bound through a `number`.

`quote()` is used in three places, and all three agree by construction: the buy screen's preview,
the pre-submit re-quote in `useAuctionActions`, and the balance check.

---

## 12. Data sources

| Surface | Source | Why |
| --- | --- | --- |
| Auctions listing | `GET /api/v1/auctions?status=active` | Measured 1.5 s typical; a batched on-chain `list()` + `getStatus` is ~240 ms and remains the better option, deferred |
| Buy screen | **Chain only** | `useAuctionLiveStatus`, 6 s poll. `/auctions/{id}` was removed — it cost ~7 s for data this screen no longer displays |
| Submission | **Chain, re-read at submit** | Never quoted from cached or API state |

Known consequence of the API-only listing: an auction that has settled on-chain can keep appearing
in the list for a while, still advertising its original size. The buy screen detects this and shows
its ended state. **Never gate a transaction on API data.**

`DutchAuction.list()` is wired up in `useAuctionIds()` but no component currently calls it.

---

## 13. Validation checklist — current status

- [x] `tab`, `lot`, `price` and `chost` re-read every poll; all bounds recomputed from them.
- [x] `total` and `available` shown as separate rows.
- [x] Max never submits `available`.
- [~] Max submits a guarded all-or-nothing rather than `lot` — see §4.2 for the rationale and the
  fuzz results. Keepers should still submit `lot`.
- [x] Amounts in the clamped band are blocked **and** shown with the true delivered size.
- [x] Input is not hard-capped at `partialCap`; Full lot remains reachable.
- [x] When `tab <= chost`, partial is disabled and Full lot is forced.
- [x] Clamped band only advertised when `lot * price > tab - chost`.
- [x] Dust lots are not filtered from the listing, and are labelled on the buy screen.
- [x] "You pay" / "you receive" / "your savings" all sourced from the quote.
- [x] Market price / discount / savings use `feedPrice = (spot * mat * par) / (RAY * RAY)`.
- [x] USDR balance check and `join` amount use `ceilDiv(owe, 1e27)`.
- [x] `VaultEngine.hope(dutchAuction)` appended to the batch when `can(...) != 1`.
- [x] `live`, `stopped`, `Governor.paused()` gate the buy button, with readable reasons.
- [x] Countdown to `deadline = min(tail, tau * (RAY - cusp) / RAY)`; buying disabled past it.
- [x] Price bar anchored to `top * (tau - deadline) / tau`.
- [x] `max` sent as the quoted `price` in ray.
- [x] Empty `data`.
- [x] `CollateralAdapter.exit` bundled into the flow as a second batch (§9.1).
- [x] Unrecovered debt disclosed when a buy closes an underwater auction.
- [ ] **Not done:** `chip` / `tip` reads; no keeper reward is surfaced.
- [ ] **Not done:** dust labelling in the *listing* — it needs the live `lot`, which the API-only
  listing does not carry (§12).
