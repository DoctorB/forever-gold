# ForeverGold — status

Updated: 2026-10-20 · version `0.1.0-alpha.2` · **alpha partly tested in game**

## Current phase

| Phase | State | Gate |
| --- | --- | --- |
| 0 — Discovery | done | audit in `docs/API-AUDIT.md`, decisions in `docs/DECISIONS.md`; no invented API; capabilities checked with `/fg diagnostics` on the client |
| 1 — Foundations | done | economic and migration tests green |
| 2 — Scanner | done, used in game | robust replays green; full scans read in game; completeness still declared "not verified" |
| 3 — MVP | tested in game (scan, history, UI) | explainable data; no automatic spending (static test) |
| 6 — Assistance | **brought forward, experimental** (alpha.2) | assisted purchase one click at a time, verified in game for commodities and individual auctions; "Buy all" not yet tested in game |
| 4, 5, 7 | not started | contracts and pure functions ready for disenchant, crafting, conversions |

In-game sessions on 2026-10-20 (build 1.60.1.70450): loading, diagnostics
(26/26 symbols, 8/8 events), UI and demo, **persistence verified**
(`/reload`, relog, restart), full scans (up to 31,198 rows, 4,077 item keys,
0 discarded, 38–47 s), 0-based replicate index verified, replicate cooldown
measured between 14 min 27 s and 15 min 38 s, variants as bonus IDs,
replicate buyout = stack total (verified), modern commodity AH. Details in
`docs/API-AUDIT.md`.

**Real gains (2026-10-20, 13:59–14:37):** four assisted purchases (three
commodities, one individual auction), 4/4 merchant checks exact, realized
gain +3s 30c on 19s 45c spent. Both purchase paths (commodity quote and
individual auction) and the vendor price are verified in game.

Next gate: a "Buy all" run in game, then the first AH resale once three days
of price history exist (needs the real AH fee and deposit).

## Implemented

- `Economy/`: Money (integer copper, `nil` never zero, safe range, costs
  rounded up and revenue down), Depth (divisible levels and whole lots),
  Costs (spec §8), MarketValue (robust interval price, daily sample, 1/7/30-day
  windows, prudent price with liquidity), Risk (gates and labelled score).
- `Data/`: Schema (MarketKey, ItemKey with variant and bonus IDs, Listing,
  Snapshot), Store (SavedVariables, session mode), Migrations (on a copy,
  recovery; schema 2), History (stepwise, retention, capped details, size
  budget), Exchange (validated import/export), empty versioned DE/recipe
  datasets, Demo.
- `Strategies/`: Vendor and Resale active; Disenchant (EV, distribution,
  probability of loss), Crafting (plan, money vs opportunity cost),
  Conversion (bounded search on a resource ledger, cycles blocked) with
  ranking disabled.
- `Compat/`: ClientAdapter (symbol presence, build, market, validated
  events, money, bag counts), AuctionHouse (read-only, seller names dropped,
  commodity status), Items (asynchronous, bounded queue, timeout),
  Professions (presence only), Purchase (the only file with spending calls).
- `Services/`: Scanner (states, generations, timeouts, measured cooldown,
  chunked reading, deduplicated passive observation, targeted search),
  Opportunities (stepwise, variants merged, thresholds, ranking, allocation,
  stale offers hidden), Purchases (plan, quote/locate, one-click confirm,
  outcome, ledger), Batch ("Buy all" queue), VendorCheck (gold received vs
  units sold), Portfolio (realized gains), Transactions, Diagnostics.
- `UI/`: resizable window with 5 tabs, plain-language opportunities table
  with gain banner and hint line, details with "How to" and the purchase
  panel, "Buy all" button, History and Portfolio as tables, validated
  settings, tooltips, scan feedback and progress bar, `/fg`, enUS + itIT.

## Tests run (2026-10-20, Windows, Lua 5.1.5; GitHub Actions on Ubuntu)

- `lua5.1 tests/runner.lua` → **146 passed, 0 failed**: deterministic cases
  of spec §13 (vendor 300, unit 500, depth 600, §8 example 900/11,053, missing
  price, deposit, DE 100/50%, crafting 2 crafts/4 outputs, separate history,
  conversion cycle, malformed/oversize import), properties (cost not
  decreasing in q, profit not increasing with the fee, vendor independent of
  the fee, a partial scan never raises confidence), scanner replays
  (duplicates, delays, missing and out-of-order events, throttle, AH closed
  while receiving and reading, reopen, cold cache, foreign search, timeout,
  cancel, measured cooldown), assisted purchase and "Buy all" (no spend
  without a click, price up, expired quote, no answer, uncertain outcome,
  limit), merchant check, portfolio, app end to end on a fake client, UI on
  frame mocks, locales, package (TOC, forbidden calls, spending calls only in
  `Compat/Purchase.lua` and only from a button, bytecode globals lint,
  versions, verified flags ↔ audit).
- `lua5.1 tests/bench.lua` (desktop order of magnitude, not in game):
  history 0.29 s per 30,000-row snapshot; evaluation 0.30 s for 3,000 item
  keys → both run stepwise within 2 ms per frame; estimated history 11.8 MB
  after 10 days (20 MB budget).
- `scripts/build.ps1` → `release/ForeverGold-0.1.0-alpha.2.zip`, 54 files,
  SHA-256 `8afd996eebe647f0893f68c638c8f5543b860f08a1facd00de0be876c7cc45de`.

Mocks prove our logic only; in-game evidence is listed in `docs/API-AUDIT.md`.

## Limits

- Replicate completeness, AH fee and deposits not verified: scans end as
  "partial observation"; resale is always "speculative".
- "Buy all" not yet tested in game.
- No price chart yet (History shows tables).
- TGA icon generated but not referenced by the TOC.
- luacheck not available locally: informational in CI; the blocking lint is
  the bytecode globals check.

## Blockers and the minimum data to unblock them

| Blocker | Minimum data or test |
| --- | --- |
| Replicate completeness | rows read compared with what the AH window shows for a few items |
| AH fee and deposit | one real AH sale by the owner (posted price, deposit, gold received) |
| Resale ranking | three days of price history (collected automatically by regular scans) |
| "Buy all" | one run in game with a small spending limit |
