# Shared Docs — Authoring & Maintenance Rules

These rules govern every document in `docs/shared/`. They exist so that any doc can be handed
to its consumer team at a moment's notice, and so that a returning consumer can see exactly
what changed for them without deriving it from git history.

## 1. The body always tracks HEAD

- The body of every doc describes **the current repo head as the single authoritative
  surface** — never a past deployment, never a superseded build. HEAD is assumed deployable at
  any moment.
- No changelog archaeology in the body: past shapes live only in the migration section (§2).
- When shipped consumer code is known to lag the head contracts, mark the exact spot
  **[frontend-pending]** (or an analogous consumer-specific marker) in the body rather than
  describing the stale integration as current.
- Parameter values quoted in a body are development-environment snapshots; docs must say so
  and instruct consumers to re-read on-chain.
- **Do not quote deploy-default / env-overridable example values** (e.g. a default `duty`):
  they rot silently when the deploy config changes. Point at the live getter instead
  ("read `VaultEngine.ilks(ilk)`"). Contract **constants** (`_RESERVE_LAG = 86400`,
  `OBS_COUNT = 12`, hardcoded constructor defaults) may be quoted — they can only change with
  a contract change, which §4 already forces through the docs.

## 2. Docs are diff-communication devices

- Each doc carries a section **"Changes since `<latest tag>`"** near the top, produced
  mechanically from `git diff <tag>..HEAD -- contracts/`, where `<tag>` is the latest release
  tag (the baseline the running consumer system was built against). Release tags include
  tags with `alpha` and `rc` pre-release identifiers or no pre-release identifiers at all.
  Tags with `beta` pre-release identifiers must be ignored.
- Every entry is spelled out as **old shape → new shape → required action**. Never make the
  consumer derive the action; state explicitly what THEY must change.
- Scope each doc's migration list to its consumer: only items that affect that consumer's
  reads, decodes, writes, or flows. (Example: the frontend consumes REST, not Postgres, so
  squid schema deltas belong in BACKEND.md's §Indexer, not FRONTEND.md — with a cross-ref.)

## 3. Cater to the consumer's medium

- Communicate deltas in the representation the consumer actually touches:
  - raw-log consumers → event signatures, topic0 changes, indexed-param layouts;
  - squid/Postgres consumers → **table/column deltas** (renamed column = re-index, not patch);
  - REST consumers → endpoint/field changes;
  - direct-call consumers → function selectors and tuple shapes.
- ABI-breaking getter renames are listed as a mechanical table.

## 4. Maintenance rule (re-baselining)

- When a new tag is cut (e.g. at a deployment): **re-baseline** every migration section to the
  new tag and **drop absorbed items**. The body needs no change at that moment (it already
  tracked HEAD).
- When contracts change on HEAD: update the body in the same PR, and append the delta to each
  affected doc's migration section — old shape → new shape → required action, in the
  consumer's medium.
- Keep the indexer (`rain-usdr-sqd`) deltas pinned to explicit commit hashes on both sides
  (contracts HEAD vs squid HEAD).

## 5. Verification discipline

- Every claim about a contract surface must be verified against the actual interfaces/source
  at HEAD before it lands in a doc (tuple field order, indexed params, error selectors,
  getter names). Do not trust older doc revisions — they have been wrong before (e.g. the
  `kpr`-index claim on `Kick`/`Redo`).
- Keeper-facing statements distinguish **routine no-ops** (retry silently) from **alarms**
  (page, never retry-loop) — a doc that doesn't make this split causes either alert fatigue
  or missed incidents.

## 6. Document inventory & consumers

| Doc | Consumer | Medium |
|---|---|---|
| `BACKEND.md` | Keeper/backend team | raw logs, direct calls, squid Postgres (§Indexer) |
| `BACKEND-SOLVENCY.md` | Keeper/backend team | canonical Job 7 write policy |
| `FRONTEND.md` | Frontend team | direct reads/writes + REST (never Postgres) |
| `FRONTEND-AUCTION.md` | Frontend team | auction UI integration |
| `CONTRACTS.md` | Exposure reporter / PM team | direct calls, their own events |
