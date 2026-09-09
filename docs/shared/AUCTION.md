# Dutch Auction — Integration Guide

Reference for anyone building a UI, keeper bot or aggregator on top of `DutchAuction`
(`contracts/liquidation/DutchAuction.sol`). It covers every state an auction can be in, every way a
purchase can fail, the values a front end should display, and the exact formula for each of them.

Everything here is derived from the contract, not from documentation. Where a number is quoted it is
the exact integer result of the contract's own arithmetic.

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

---

## 2. Parameters currently filed for `RAIN-A`

From `scripts/deploy-liquidation.js` and `scripts/deploy-governance.js`, asserted by
`scripts/verify-config.js`. Read them on-chain rather than hardcoding — they are governable.

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

Keeper reward on `kick` / `redo` is `tip + (tab * chip) / WAD`. With `tip = 0` that is just
`2% of tab`, but anyone quoting the reward must still include `tip` — governance can file it later.

`chost` is a **cache**. It only changes when someone calls the permissionless `upchost()` after
governance changes `dust` or `chop`. Re-read it rather than caching it client-side indefinitely.

---

## 3. State to read

```
DutchAuction.getStatus(id) -> (needsRedo, price [ray], lot [wad], tab [rad])
DutchAuction.sales(id)     -> (pos, tab, lot, vaultId, usr, tic, top [ray])
DutchAuction.chost()       -> [rad]
DutchAuction.chip(), tip() -> keeper reward parameters
DutchAuction.stopped()     -> 0 | 1 | 2 | 3
DutchAuction.live()        -> 1 while running
DutchAuction.tail(), cusp(), buf()
PriceCurve.tau()
Governor.paused()          -> bool
VaultEngine.ilks(ilk)      -> (..., spot [ray], ...)   // last poked price factor
PriceConverter.ilks(ilk)   -> (pip, mat [ray], fixedPrice)
PriceConverter.par()       -> [ray]
VaultEngine.usdr(buyer)    -> [rad]  internal USDR balance
VaultEngine.can(buyer, dutchAuction) -> 1 if the auction may pull the buyer's USDR
```

`price` decays every second, so every derived bound below decays with it. Recompute per block; a
bound computed at page load is stale immediately.

### Market price — do not call `OSM.peek` from a browser

`OracleSecurityModule.peek`, `peep` and `read` are all `onlyRole(_READER_ROLE)`. An unprivileged
caller — including every browser wallet — reverts with `AccessControlUnauthorizedAccount`. Do **not**
call them from the front end.

Derive the delayed market price from the public poke outputs instead:

```
feedPrice [ray] = (spot * mat * par) / (RAY * RAY)
```

where `spot` is `VaultEngine.ilks(ilk).spot`, `mat` is `PriceConverter.ilks(ilk).mat`, and `par` is
`PriceConverter.par()`. This inverts `PriceConverter.poke` and recovers the OSM value as of the last
successful `poke`. It is not a live OSM `cur` read: if the OSM has updated and `poke` has not yet
run, `feedPrice` lags. That is the sanctioned public path for market price, discount, lot market
value and savings. A live DEX quote is still the wrong reference — the auction was priced from the
delayed OSM, not from spot.

---

## 4. The four quantities everything follows from

With `tab`, `lot`, `price` and `chost` in hand, compute these once per refresh:

```
available     = min(lot, tab / price)            // floor; most collateral anyone can receive
partialCap    = (tab - chost) / price            // floor; only defined when tab > chost
clearAt       = ceilDiv(tab, price)              // amt to ENTER to pay the whole tab
allOrNothing  = min(lot, clearAt)                // below this, no partial buy is legal
```

- **`available`** is the maximum collateral the auction can ever hand out, and it is **not** `lot`.
  The auction never sells more collateral than the debt is worth, so when `lot * price > tab` the
  payment is capped at `tab` and delivery is capped at `tab / price`. See §4.1.
- **`partialCap`** is the largest amount that fills at exactly the size requested. Above it, the
  contract resizes the purchase downward. The raw `(tab - chost) / price` can exceed `lot` whenever
  `lot * price <= tab - chost` — in which case no resize is reachable and every amount fills exactly.
  Always use `min(lot, (tab - chost) / price)` (as `bounds()` in §10 does).
- **`clearAt`** is the amount a buyer must **enter** to pay the entire `tab`. It is one wei above
  `available` whenever `tab` is not an exact multiple of `price` — which is almost always.
- **`allOrNothing`** is the threshold that matters when `tab == chost`: nothing below it is legal.
  It is also the amount Max should put in the input field; Max may then submit `lot` (see §4.1).

`allOrNothing` equals `lot` when the collateral is worth less than the debt, and `clearAt` when it
is worth more.

### 4.1 `total` and `available` are different numbers

`lot` is what the auction holds. `available` is what a buyer can actually walk away with:

```
total      = lot / 1e18
available  = min(lot, tab / price) / 1e18       // floor division
payForAll  = min(lot * price, tab) / 1e45       // what taking `available` costs
```

They diverge exactly when `lot * price > tab` — the collateral is worth more than the debt. The
excess is `flux`'d back to the liquidated borrower, never to the buyer. In the screenshot auction
the lot is worth 95.53 USDR against a 195.49 USDR tab, so `lot` binds and both rows read 50,000
RAIN; that is a coincidence of that auction being underwater, not the general case.

> **The one-wei trap.** To *receive* `available` a buyer must *enter* `clearAt`, which is
> `available + 1 wei`. Entering `available` itself is one wei short of tipping `owe` past `tab`, so
> it lands in the clamped branch instead and delivers only `partialCap`. The gap is exactly
> `chost / price` of collateral.
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
>
> Preferred Max behaviour: fill the amount input with `allOrNothing` for display, but **submit
> `lot`**. When the debt binds, `S = min(lot, amt)` plus the `owe > tab` cap makes delivery and cost
> identical to entering `clearAt`, leftover collateral still goes to the borrower, and the call
> cannot hit `NoPartialPurchase` (that branch requires `slice < lot`). Submitting the whole lot is
> also immune to price decay between quote and signature: a stale `clearAt` at a lower live price can
> fall into the clamped band, while `amt = lot` always takes branch 1 or 3.

---

## 5. What `take` actually does

`take(id, amt, max, who, data)` walks four mutually exclusive branches **in this order**, with
`S = min(lot, amt)` and `owe = S * price`:

| # | Condition | Behaviour | USDR debited | Collateral delivered |
| --- | --- | --- | --- | --- |
| 1 | `owe > tab` | Payment capped at the outstanding debt, size back-solved | `tab` | `floor(tab / price)` (= `available`) — within 1 wei of the maximum payable, **not** of the amount asked |
| 2 | `owe == tab` | Exact clear | `tab` | `S` |
| 3 | `owe < tab` and `S == lot` | Entire remaining lot sold; shortfall becomes bad debt | `lot * price` | `lot` |
| 4a | `owe < tab`, `S < lot`, `tab - owe >= chost` | Ordinary partial fill | `owe` | `S` |
| 4b | `owe < tab`, `S < lot`, `tab - owe < chost`, `tab > chost` | **Silently clamped** so exactly `chost` is left behind | `tab - chost` | `floor((tab - chost) / price)` |
| 4c | `owe < tab`, `S < lot`, `tab - owe < chost`, `tab <= chost` | **Reverts** `NoPartialPurchase()` | — | — |

Branch **4b is the one to guard against**: it does not revert. The transaction succeeds while
delivering less collateral for less USDR than the confirmation screen showed.

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
rejecting the call. Reverting requires branch 4c, which requires `tab <= chost`. The only risk here
is a fill smaller than requested.

Whether that substitution can even trigger depends on a single comparison:

```
a clamped fill is possible  <=>  lot * price > tab - chost
```

If the whole remaining lot is worth no more than `tab - chost`, then even buying all of it cannot
push the remainder below `chost`, and **every amount fills exactly as requested**.

#### A1 — `lot * price <= tab - chost`: nothing can clamp

| Amount entered | Result | Debited | Delivered |
| --- | --- | --- | --- |
| `0` | No-op | 0 | 0 |
| `1 wei … lot - 1 wei` | Exact fill, auction stays open | `amt * price` | `amt` |
| `>= lot` | Exact fill, auction closes with `tab - lot * price` unrecovered | `lot * price` | `lot` |

`partialCap` exceeds `lot` in this case and is meaningless — display `min(lot, partialCap)`.

#### A2 — `lot * price > tab - chost`: the clamped band exists

| Amount entered | Result | Debited | Delivered |
| --- | --- | --- | --- |
| `0` | No-op | 0 | 0 |
| `1 wei … partialCap` | Exact fill | `amt * price` | `amt` |
| `partialCap + 1 wei … allOrNothing - 1 wei` | **Succeeds, clamped** | `tab - chost` | `partialCap` |
| `>= allOrNothing` | Auction closes | branch 1 or 3 | see branch table |

Any clamped fill leaves `tab` at **exactly `chost`**, which moves the auction into Scenario B for
everyone who comes after.

#### Worked contrast

Same `chost` of 113, same price of 0.0019106, two different auctions:

| | `tab` | `lot * price` | `tab - chost` | Clamped band? |
| --- | --- | --- | --- | --- |
| A2 | 195.49 | 95.53 | 82.49 | **Yes** — `95.53 > 82.49` |
| A1 | 190 | 40 | 77 | No — `40 < 77`, every amount fills exactly |

In the A1 row `partialCap` computes to 40,301.475976133151889458 RAIN against a `lot` of only
20,935.831675913325656861 RAIN — 1.925x the entire lot. A UI that prints `partialCap` raw would
offer an amount that does not exist.

### Scenario B — `tab == chost`

**Only one purchase is legal: the whole remaining position.** The band from `1 wei` to
`allOrNothing - 1 wei` reverts with `NoPartialPurchase()`.

| Amount entered | Result |
| --- | --- |
| `0` | Succeeds as a no-op (`tab - 0` is not *strictly* below `chost`) |
| `1 wei … allOrNothing - 1 wei` | **Reverts** `NoPartialPurchase()` |
| `>= allOrNothing` | Succeeds, auction closes |

Two ways to reach this state: a clamped fill (branch 4b) leaves `tab` at exactly `chost`, or
governance raises `dust`/`chop` and someone calls `upchost()`, lifting `chost` above the `tab` of
auctions already in flight.

> Defensive note: if `upchost()` ever raises `chost` **above** an in-flight `tab`, then `amt = 0`
> also reverts. That is the only behavioural difference between `tab == chost` and `tab < chost`.
> Deriving your validation from `tab <= chost` rather than `tab == chost` covers both for free.

### Worked example

The values below reproduce a real auction: `lot` 50,000 RAIN, `tab` 195.49 USDR (173 USDR of
principal plus the 13% penalty), `price` 0.0019106 USDR/RAIN, `chost` 113 USDR. Note that the lot is
worth 95.53 USDR against 195.49 USDR of debt — this auction is underwater and cannot be paid off at
any price it will reach.

```
partialCap   = (195.49 - 113) / 0.0019106 = 43,174.918873652255835863 RAIN
clearAt      = ceil(195.49 / 0.0019106)   = 102,318.643358107400816498 RAIN
allOrNothing = min(50,000, 102,318.64…)   = 50,000 RAIN
```

| Amount entered | Result | USDR debited | RAIN delivered |
| --- | --- | --- | --- |
| `43,174.918873652255835863` | Exact fill | `82.4899999999999999999998478` | `43,174.918873652255835863` |
| `43,174.918873652255835864` | Clamped | `82.49` exactly | `43,174.918873652255835863` |
| `45,000` | Clamped | `82.49` exactly | `43,174.918873652255835863` |
| `50,000` | Auction closes | `95.53` | `50,000` |

Entering 45,000 delivers **1,825.08 RAIN less** than requested, with no error raised. Note also that
in the clamped branch the payment is exactly `tab - chost` (82.49), while at the cap itself it is
`amt * price` (82.4899999999999999999998478) — the two are close but not the same number, and only
the first is a round figure.

Buying the full 50,000 closes the auction with **99.96 USDR of debt never recovered**. It is a good
trade for the buyer, but "clears the auction" should not be read as "repays the debt".

The leftover after a clamped fill is `lot` 6,825.081126347744164137 RAIN against `tab` 113 USDR —
worth 13.04 USDR. That is Scenario B: the only legal non-zero buy is the entire
6,825.081126347744164137 RAIN.

### `chost` guards the debt remainder, not the collateral remainder

Nothing in `take` inspects `lot - slice`. A buyer in Scenario A1 can therefore buy `lot - 1 wei` and
leave an auction holding one wei of collateral against the full remaining `tab`. Using the A1 numbers
above, buying 20,935.831675913325656860 RAIN for 39.999999999999999999996716 USDR leaves `lot` at
1 wei and `tab` at 150.000000000000000000003284 USDR.

Consequences integrators should expect:

- The auction stays in `active` and `sales`, so `list()` and `count()` keep returning it. **Do not
  filter dusty lots out of the default view** — show them. They are real open auctions with a
  remaining `tab`, and hiding them conceals locked liquidation capacity. Label them clearly (e.g.
  “dust lot”) so users understand the economics, but leave them visible.
- `LiquidationTrigger.dirt` and `globalDirt` keep the remaining `tab` booked against `hole` /
  `globalHole`, throttling how much new liquidation can be kicked. That room is only released when
  the auction ends — `digs` is called with `tab + owe` on the buy that consumes the last of the lot.
- Nobody is paid to clear it. `redo` only pays the keeper reward when `tab >= chost` **and**
  `lot * feedPrice >= chost`, and one wei of RAIN is worth roughly `2e-21` USDR.
- Cleanup is permissionless but not profitable: buying the last wei costs `0.0000000000000000000019106`
  USDR and closes the auction, booking the remaining `tab` as unrecovered. Gas will always exceed the
  value, so this needs a protocol-run sweeper rather than a profit-motivated keeper.

Leaving the wei is not profitable for the buyer either — taking the full lot costs `1 wei * price`
more and delivers one more wei of collateral. It is a griefing option with near-zero cost and no
gain beyond keeping the slot occupied.

---

## 7. Values to display, and how to compute them

`quote` refers to the reference implementation in [§10](#10-reference-implementation).
`feedPrice = (spot * mat * par) / (RAY * RAY)` is the sanctioned public market price — see §3. Do
**not** call `OSM.peek` from the browser.

| Field | Formula | Notes |
| --- | --- | --- |
| Current price | `price / 1e27` | Show ≥ 7 significant digits |
| Market price | `feedPrice / 1e27` | Last poked OSM value via the public derivation in §3 |
| Opening price | `sales(id).top / 1e27` | |
| Discount now | `1 - price / feedPrice` | Both in `ray`; do the division in fixed point |
| **Total** | `lot / 1e18` | Collateral the auction holds |
| **Available** | `min(lot, tab / price) / 1e18`, **floored** | Most a buyer can receive. Equals `total` only while `lot * price <= tab`. See §4.1 |
| **Remaining debt** | `tab / 1e45` | Currently missing from most panels; it drives every bound |
| Cost to take `available` | `min(lot * price, tab) / 1e45` | `tab` exactly when the debt binds |
| Lot value now | `lot * price / 1e45` | Value of `total`, not of `available` |
| Lot market value | `lot * feedPrice / 1e45` | |
| **Max partial buy** | `min(lot, (tab - chost) / price)`, **floored** | Only when `tab > chost`; otherwise there is no partial. Clamp to `lot` — the raw `partialCap` exceeds `lot` whenever `lot * price <= tab - chost` |
| **All-or-nothing amount** | `min(lot, ceilDiv(tab, price))` | When `tab == chost`, this is both the min and the max |
| Amount that clears the debt | `ceilDiv(tab, price)` | Only reachable if `<= lot` |
| You pay | `quote.pay / 1e45` | From the quote, never `amt * price` |
| USDR you must hold | `quote.payWei / 1e18` | Ceiling at 18 dp — see §8 |
| You receive | `quote.receive / 1e18` | From the quote, never the entered amount |
| Your savings | `quote.receive * feedPrice - quote.pay` | In `rad`. Must use the **delivered** amount |
| Unrecovered debt | `tab - lot * price` when positive | Shown when the buy closes the auction |
| Returned to borrower | `quote.returnedToBorrower / 1e18` | Goes to the vault owner, not the buyer |
| Floor price | `top * (tau - deadline) / tau` | `deadline` below — **not** `cusp * top` |
| Buying closes in | `tic + deadline - now` seconds | `take` works while `now - tic <= deadline` |
| Reset available in | `tic + deadline + 1 - now` seconds | `redo` opens the second after `take` closes — there is no gap |

### Floor price and the reset clock

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

A price-schedule bar anchored to `cusp * top` (40% of opening) therefore has an unreachable
right-hand fifth, and understates how close the auction is to needing a reset. Anchor it to
`minPrice` and drive it off elapsed time against `deadline`.

Past `deadline`, `take` reverts `NeedsReset()` until someone calls `redo(id, kpr)`, which resets
`tic` to now and lifts `top` back to `1.05 x` the current market price. **The price goes up on a
reset** — surface that, and do not let a stale `max` ride through it.

---

## 8. Rounding rules

1. **Floor the partial cap, never round it.** The cap in the worked example is
   `43,174.918873652255835863`. Displayed at 6 dp it must be `43,174.918873`; rounding it to
   `43,174.918874` puts the value *above* the cap and into the clamped band.
2. **Ceiling the USDR requirement.** `owe` is a 45-decimal integer and is almost never a round
   number. `CollateralAdapter.join(USDR_ILK, user, amount)` credits `amount * 1e27` rad, so the
   buyer must join at least `ceilDiv(owe, 1e27)` USDR token units. Round the *displayed* figure
   however you like, but the balance check and the `join`/`approve` amount must use the ceiling, or
   `VaultEngine.move` underflows.
3. **Never round a bound in the direction that widens it.** Floor maxima, ceil minima. A UI that
   rounds `allOrNothing` down by one wei produces a guaranteed revert.
4. **A displayed balance is not a submittable amount.** `available` is floored — it is the most a
   buyer can *receive*. Submitting it asks for one wei less than `clearAt` and clamps the fill. The
   two numbers serve different purposes and must not be wired to the same variable.
5. **Prices need more digits than you think.** At `$0.0019106`, a 4-decimal display (`$0.0019`) is a
   0.6% error, and a market price of `$0.0022725` shown as `$0.0023` is 1.2% off — material when the
   headline claim is a 15.9% discount.

---

## 9. Preflight checks

Only one of these failures is about the amount. Validate all of them before enabling a buy button.

| Condition | Reverts with | What to check |
| --- | --- | --- |
| `live != 1` | `NotLive()` | `DutchAuction.live()`. Stop listing auctions once caged |
| `stopped >= 2` | `Stopped()` | `DutchAuction.stopped()`. Level 1 only blocks new auctions; level 2 blocks buys; level 3 also blocks resets |
| Governance pause | `SystemPaused()` | `Governor.paused()` |
| `sales[id].usr == 0` | `AuctionNotRunning()` | Already bought out, yanked, or never existed. Refresh from `list()` |
| `now - tic > tail`, or `price/top < cusp` | `NeedsReset()` | Disable buying once `now - tic > deadline`; offer `redo()` instead |
| `max < price` | `TooExpensive()` | `max` is in `ray`. See below |
| Partial below the dust rule | `NoPartialPurchase()` | §6 |
| Internal USDR balance `< owe` | **arithmetic panic, no custom error** | `VaultEngine.usdr(buyer) >= owe`. Fund via `CollateralAdapter.join(USDR_ILK, …)` |
| Auction not authorised to pull USDR | `NotAllowed()` | `VaultEngine.can(buyer, dutchAuction) == 1`, set once via `VaultEngine.hope(dutchAuction)` |

The last two live outside `DutchAuction`, revert without a readable error, and are the most common
first-time failures. `hope` is a separate transaction.

**Choosing `max`.** The price only falls with time, so a quote-time `price` is a safe `max` against
decay. It is *not* safe against a `redo`, which raises `top`. Passing `max = quotedPrice` means a
front-run reset makes the buy revert rather than execute at a worse price — that is usually what you
want. Do not pass `type(uint256).max`.

**Front-running changes the band, not the outcome.** If another buyer lands first, `tab` and `lot`
shrink and a previously exact amount can fall into branch 4b — succeeding at a smaller size instead
of reverting. Re-read state and re-quote immediately before signing.

**`data` and `who`.** Pass empty `data` for an ordinary buy. Non-empty `data` invokes
`clipperCall(msg.sender, owe, slice, data)` on `who`, which only makes sense when `who` is a
contract implementing `IDutchAuctionCallee`.

**The buy is two transactions.** `take` credits collateral on the internal ledger via `flux`. The
buyer holds no RAIN tokens until they call `CollateralAdapter.exit(RAIN_ILK, user, amount)`. RAIN is
an 18-decimal token, so nothing is lost in that conversion.

---

## 10. Reference implementation

A line-for-line port of the branches in §5. Feed it live `getStatus(id)` and `chost()` readings.

```ts
const RAY = 10n ** 27n;

type AuctionState = {
  tab: bigint;   // rad
  lot: bigint;   // wad
  price: bigint; // ray
  chost: bigint; // rad
};

type Bounds = {
  available: bigint;         // most collateral a buyer can receive; <= lot
  partialCap: bigint | null; // null when no partial buy is legal; always <= lot when set
  clearAt: bigint;           // amount to ENTER to pay the whole tab
  allOrNothing: bigint;      // fill the input with this; Max may submit `lot` instead
};

type Quote =
  | { ok: false; reason: "NoPartialPurchase" | "NeedsReset" }
  | {
      ok: true;
      fill: "exact" | "cappedAtDebt" | "clampedToChost";
      pay: bigint;                // rad debited from the buyer
      payWei: bigint;             // USDR token units the buyer must hold
      receive: bigint;            // wad credited to the buyer
      tabAfter: bigint;
      lotAfter: bigint;
      closesAuction: boolean;
      returnedToBorrower: bigint; // wad, to the liquidated vault owner
      unrecoveredDebt: bigint;    // rad, never recovered
    };

const ceilDiv = (a: bigint, b: bigint) => (a + b - 1n) / b;
const min = (a: bigint, b: bigint) => (a < b ? a : b);

export function bounds(s: AuctionState): Bounds {
  const clearAt = ceilDiv(s.tab, s.price);
  return {
    available: min(s.lot, s.tab / s.price),
    // Clamp to lot — the raw (tab - chost) / price can exceed lot whenever
    // lot * price <= tab - chost (§6 A1). Offering the unclamped value is wrong.
    partialCap: s.tab > s.chost ? min(s.lot, (s.tab - s.chost) / s.price) : null,
    clearAt,
    allOrNothing: min(s.lot, clearAt),
  };
}

export function quote(s: AuctionState, amt: bigint): Quote {
  if (s.price <= 0n) return { ok: false, reason: "NeedsReset" };

  const requested = min(s.lot, amt);
  let slice = requested;
  let owe = slice * s.price;
  let fill: "exact" | "cappedAtDebt" | "clampedToChost" = "exact";

  if (owe > s.tab) {
    owe = s.tab;
    slice = owe / s.price; // floors to available — within 1 wei of max payable, not of `requested`
    if (slice < requested) fill = "cappedAtDebt";
  } else if (owe < s.tab && slice < s.lot) {
    if (s.tab - owe < s.chost) {
      if (s.tab <= s.chost) return { ok: false, reason: "NoPartialPurchase" };
      owe = s.tab - s.chost;
      slice = owe / s.price;
      fill = "clampedToChost";
    }
  }

  const tabAfter = s.tab - owe;
  const lotAfter = s.lot - slice;

  return {
    ok: true,
    fill,
    pay: owe,
    payWei: ceilDiv(owe, RAY),
    receive: slice,
    tabAfter,
    lotAfter,
    closesAuction: lotAfter === 0n || tabAfter === 0n,
    returnedToBorrower: lotAfter > 0n && tabAfter === 0n ? lotAfter : 0n,
    unrecoveredDebt: lotAfter === 0n ? tabAfter : 0n,
  };
}
```

Display `quote.receive` and `quote.pay` — never the entered amount or `amt * price`. When
`quote.fill !== "exact"`, the user is getting less than they asked for: either block submission or
show the real figures and say why.

---

## 11. Validation checklist

- [ ] `tab`, `lot`, `price` and `chost` re-read every block; all bounds recomputed from them.
- [ ] `total` and `available` shown as separate rows: `lot` versus `min(lot, tab / price)`.
- [ ] Max never submits `available`. Preferred: fill the input with `allOrNothing`, submit `lot`
      (identical delivery when the debt binds; immune to price decay and `NoPartialPurchase`).
- [ ] Amounts in the clamped band (`partialCap + 1 … allOrNothing - 1`) blocked or shown with the
      true delivered size and payment. Do **not** hard-cap the input at `partialCap` — that makes
      `allOrNothing` (and Max) unenterable whenever the clamped band exists.
- [ ] When `tab <= chost`, only `allOrNothing` (or `lot`) is a legal non-zero buy; warn or force it.
- [ ] Clamped band only advertised when `lot * price > tab - chost`; when it is not, the whole range
      `0 … lot` fills exactly and no warning belongs on screen.
- [ ] **Do not filter dusty lots** out of the listing. Show them (optionally labelled); they remain
      real open auctions with locked `dirt` / `hole` capacity.
- [ ] "You pay" / "you receive" / "your savings" all sourced from the quote, not the input.
- [ ] Market price / discount / savings use `feedPrice = (spot * mat * par) / (RAY * RAY)` — never
      `OSM.peek` from the browser.
- [ ] USDR balance check and `join` amount use `ceilDiv(owe, 1e27)`.
- [ ] `VaultEngine.hope(dutchAuction)` prompted when `can(buyer, dutchAuction) != 1`.
- [ ] `live`, `stopped`, `Governor.paused()` gate the buy button.
- [ ] Countdown to `deadline = min(tail, tau * (RAY - cusp) / RAY)`; buying disabled past it.
- [ ] Price bar anchored to `top * (tau - deadline) / tau`, not to `cusp * top`.
- [ ] `max` (the price ceiling argument to `take`) sent as the quoted `price` in `ray`.
- [ ] Empty `data` unless `who` implements `IDutchAuctionCallee`.
- [ ] Buyer ends holding RAIN tokens — either surface `CollateralAdapter.exit` as a second step or
      bundle it in the same flow; do not leave the credit stranded on the internal ledger.
- [ ] Unrecovered debt disclosed when a buy closes an underwater auction.
