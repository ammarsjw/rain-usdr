# Rain USDR

This repository contains the smart contracts for **USDR (Rain Dollar)** — a multi-collateral,
over-collateralized stablecoin deployed on Arbitrum One. USDR targets one US dollar and is backed
by a diversified basket of collateral (USDT, USDC and RAIN). The design is a direct adaptation of
MakerDAO's Multi-Collateral Dai, enforcing a single rule at every block: **the protocol's maximum
possible loss can never exceed its stable reserves.**

## Architecture

The system is built from thirteen contracts, each adapting a battle-tested MakerDAO contract (or
adding a USDR-specific safety component):

| Contract | Directory | MakerDAO Original | Responsibility |
| --- | --- | --- | --- |
| `USDR` | `contracts/core` | Dai | The ERC-20 token. Minted only by the Vault Engine adapter and the PSM. |
| `VaultEngine` | `contracts/core` | Vat | Immutable core ledger; tracks all collateral and debt. |
| `CollateralAdapter` | `contracts/core` | GemJoin + DaiJoin | Doorway for tokens entering/leaving the system. Single instance; ilks register dynamically — collateral ilks custody tokens, the USDR ilk mints/burns. |
| `OracleSecurityModule` | `contracts/oracle` | OSM | Delays price updates by 30 minutes. Single instance; volatile collaterals register dynamically, each with its own price source (Uniswap TWAP or Chainlink wrapper). Supported stablecoins bypass it entirely (fixed $1 on the Price Converter). |
| `PriceConverter` | `contracts/oracle` | Spot | Turns a raw price into the maximum USDR mintable per unit of collateral. |
| `PegStabilityModule` | `contracts/psm` | PSM | Swaps USDT/USDC for USDR at 1:1; best-effort redemption. Single instance; stablecoin ilks register dynamically. |
| `ReserveAccounting` | `contracts/reserve` | (custom) | Tracks the stable reserve, escrow and free slack. |
| `SolvencyEngine` | `contracts/reserve` | (custom) | Computes worst-case loss and enforces the solvency invariant. |
| `BalanceSheet` | `contracts/reserve` | Vow | Holds surplus, tracks bad debt, manages the absorption waterfall. |
| `PriceCurve` | `contracts/liquidation` | Abacus | Calculates the descending auction price over time. |
| `LiquidationTrigger` | `contracts/liquidation` | Dog | Detects unsafe vaults and starts auctions. |
| `DutchAuction` | `contracts/liquidation` | Clipper | Sells seized collateral at a descending price. |
| `CircuitBreaker` | `contracts/liquidation` | (custom) | Slows liquidations when the oracle price moves suspiciously fast. |
| `Governor` | `contracts/governance` | Spell + Pause | Executes timelocked parameter changes and the emergency pause. |

The **immutable core** (the Vault Engine, the liquidation logic and the solvency rule) cannot be
changed after deployment. Only risk parameters can be tuned, and only through the Governor's
timelock.

## Tooling

- **Hardhat 2** (JavaScript) — compilation and deployment scripts.
- **Foundry (forge)** — test suite.
- **hardhat-foundry** — shared compilation/remappings between the two.

## How do I get set up?

1. `git clone https://github.com/ammarsjw/rain-usdr.git`
2. `cd rain-usdr`
3. `git submodule update --init --recursive`
4. `npm i`

## Compilation

```bash
npm run compile   # hardhat
npm run build     # forge
```

## Deployment

Set the network variables in a `.env` file (copy from `.env.example`). Then deploy the system in
order:

```bash
npm run deploy-core-staging          # USDR, Vault Engine, joins
npm run deploy-oracles-staging       # OSM, Price Converter
npm run deploy-reserve-staging       # Reserve Accounting, Solvency Engine, Balance Sheet
npm run deploy-liquidation-staging   # Price Curve, Liquidation Trigger, Dutch Auctions, Circuit Breaker
npm run deploy-governance-staging    # Governor
```

Replace `-staging` with `-local` for a local Hardhat network or drop the suffix for production.

## Test

Tests are written with Foundry. The scaffolding lives under `tests/` (mocks and a shared base
harness). Run:

```bash
npm run test
```

> **Note:** the contracts require an independent security audit before any mainnet deployment.
> This repository is an engineering implementation of the USDR specification, not audited code.
