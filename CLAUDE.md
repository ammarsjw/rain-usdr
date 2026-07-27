# CLAUDE.md

Guidance for Claude Code when working in this repository.

## Project Overview

**USDR (Rain Dollar)** — a multi-collateral, over-collateralized stablecoin on **Arbitrum One**,
directly adapted from MakerDAO's Multi-Collateral Dai. USDR targets $1 and is backed by USDT,
USDC, and RAIN. Core invariant enforced at every block: **the protocol's maximum possible loss
can never exceed its stable reserves.**

## Build & Test Commands

Dual toolchain: **Hardhat** (compile, deploy, sizing) + **Foundry** (tests). Both must stay green.

```bash
npm install --include=dev     # devDependencies required (Hardhat lives there)
npm run compile               # Hardhat compile
npm run build                 # forge build
npm run test                  # forge test (all tests are Foundry)
npm run test-log              # forge test -vv
npm run test-fork             # FOUNDRY_PROFILE=testing (forked RPC from .env)
npm run format-lint           # prettier + solhint (max-warnings 0)
npm run check-size            # hardhat contract sizer
```

- Run a single test: `forge test --match-test <name>` or `--match-contract <Contract>`.
- `forge` must be installed (foundryup); `hardhat-foundry` bridges the two.
- forge-std is a **git submodule** under `lib/` — clone with `--recurse-submodules` or run
  `git submodule update --init`.

## Toolchain Settings (do not change casually)

- Solidity **0.8.30**, optimizer 1,000,000 runs, **viaIR = true**, evmVersion **cancun**
  (mirrored in `hardhat.config.js` and `foundry.toml` — keep them in sync).
- viaIR + deep call graphs can trigger stack-too-deep in assembly; all assembly blocks must be
  annotated `assembly ("memory-safe")` (see `_revert` in `contracts/shared/Globals.sol`).
- OpenZeppelin Contracts pinned at **5.4.0**.

## Architecture

Thirteen contracts, each adapting a battle-tested MakerDAO contract (see README table for the
full mapping):

- `contracts/core/` — `VaultEngine` (Vat: immutable ledger), `USDR` (Dai), `CollateralAdapter`
  (GemJoin + DaiJoin merged; the immutable `isUsdrAdapter` flag selects collateral custody or
  USDR mint/burn per instance)
- `contracts/oracle/` — `OracleSecurityModule` (OSM, 30-min price delay), `PriceConverter` (Spot)
- `contracts/psm/` — `PegStabilityModule` (1:1 USDT/USDC ↔ USDR)
- `contracts/reserve/` — `ReserveAccounting`, `SolvencyEngine` (worst-case loss / solvency
  invariant), `BalanceSheet` (Vow)
- `contracts/liquidation/` — `PriceCurve` (Abacus), `LiquidationTrigger` (Dog), `DutchAuction`
  (Clipper), `CircuitBreaker` (custom: slows liquidations on suspicious oracle moves)
- `contracts/governance/` — `Governor` (timelocked param changes + emergency pause)
- `contracts/interfaces/` — one interface per contract (`I<Name>.sol`); `IExternalExposure` is
  the hook for the external prediction-market exposure feed
- `contracts/extensions/` — home for all abstract contracts; currently `Auth.sol` (abstract
  AccessControl-based authorization base)
- `contracts/shared/` — `Constants.sol` (WAD/RAY/RAD + AccessControl role ids), `Errors.sol`
  (custom errors), `Globals.sol` (`_revert` helper)

### MakerDAO conventions preserved

- Units: **wad** (1e18), **ray** (1e27), **rad** (1e45). Ilk `rate` is fixed at RAY (no
  stability fee) and never changes.
- Parameter setting via `file`; vault permissions (user delegation) via `can`/`hope`/`nope` on
  the Vault Engine — this is unchanged and is **not** admin auth.
- Ilk identifiers: `"RAIN-A"`, `"USDT-A"`, `"USDC-A"`.

### Authorization (diverges from MakerDAO)

- Admin auth uses **OpenZeppelin AccessControl**, not the `wards` mapping. Every privileged
  contract inherits `contracts/extensions/Auth.sol`, which defines `WARD_ROLE` (role ids live in
  `Constants.sol`), performs setup in its own constructor via a private `_initAuth()` (so events
  are never emitted directly inside a constructor body), and keeps `rely`/`deny` as thin
  wrappers over `_grantRole`/`_revokeRole`. Gate privileged functions with
  `onlyRole(WARD_ROLE)` (never a hand-rolled `auth` modifier). `WARD_ROLE` self-administers, so
  any ward can `rely`/`deny` another — matching the old semantics.
- Specialized ACLs are also roles: `RECORDER_ROLE`/`COMMITTER_ROLE` (Reserve Accounting) and
  `READER_ROLE` (OSM `bud` whitelist, granted via `kiss`/`diss`). Their management wrappers keep
  their old names and stay `onlyRole(WARD_ROLE)`.
- The two token adapters (GemJoin/DaiJoin) **are merged** into `core/CollateralAdapter.sol`.
  The immutable `isUsdrAdapter` flag chooses the code path per instance. This does not leak
  USDR mint authority: mint rights are granted per-instance on the token (`usdr.rely(...)`) and
  only the single USDR instance ever receives them.
- Collateral vocabulary: the Vault Engine's free-collateral mapping is `collateral` (was `gem`);
  the adapter's bridged token is `token`; the PSM entrypoints are
  `sellStable`/`buyStable` (were `sellGem`/`buyGem`). The word `gem` no longer appears.
- Interface naming: one interface per contract, named `I<ContractName>` — unless an interface
  is shared by more than one contract.

## Code Style

- MIT license header + `pragma solidity 0.8.30;` on every file.
- Full NATSPEC on contracts and public/external members (`@title`, `@author Rain Team.`,
  `@notice`, `@dev`); note unit annotations like `[wad]`/`[rad]` on state vars.
- Section banners: `/* ===== STATE VARIABLES ===== */`, `/* ===== MODIFIERS ===== */`, etc.
- Errors: custom errors in `shared/Errors.sol`, reverted via `_revert(Selector.selector)` —
  never `require` with string messages.
- Named imports only: `import { X } from "...";`.
- Formatting/linting enforced by prettier-plugin-solidity + solhint (zero warnings allowed).
- These conventions come from the cash-casino repo — match existing files exactly when adding
  new ones.

## Tests

- All tests are **Foundry** (`tests/`, `*.t.sol`). `tests/Base.t.sol` is the shared harness
  that deploys and wires the full 14-contract system; concrete tests inherit from `BaseTest`.
- Mocks live in `tests/mocks/` (`MockERC20`, `MockPriceSource`).

## Deployment

Five staged scripts in `scripts/` (run in order): `deploy-core.js` → `deploy-oracles.js` →
`deploy-reserve.js` → `deploy-liquidation.js` → `deploy-governance.js`. Each has npm variants:
plain (production), `-staging`, `-local` (in-memory hardhat), `-fork` (`HARDHAT_FORK=true`).

- Shared deploy framework under `scripts/helpers/` (config, workflows, actions, env utils) —
  reuse it; don't hand-roll ethers calls in deploy scripts.
- Launch parameters from the spec are baked into `scripts/helpers/config/config.js`
  (e.g. 400% RAIN collateral ratio, $1.1M global ceiling, 13% chop, 2% chip, 5% buf).
- All env vars documented in `.env.example`; deployed addresses are fed back into `.env` for
  later stages. Never commit `.env` or private keys.

## Known Gaps / Open Items

- **RAIN price source**: spec requires a Uniswap V3 30-min TWAP wrapper implementing
  `IPriceSource`; only `MockPriceSource` exists until the RAIN token + pool addresses are known.
- **`IExternalExposure`** consumer address (other team's prediction-market feed) not yet wired
  into the Solvency Engine.
- The spec's liquidity-based ceiling formula (ceiling = liquidity × safety factor) is an
  off-chain governance process — deliberately not implemented on-chain.