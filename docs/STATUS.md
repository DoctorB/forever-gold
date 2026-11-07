# ForeverGold — status

Updated: 2026-11-06 · version `0.1.0-alpha.3` · **alpha.3 verified in game** on the live build 1.60.1.70790 (scan, history, `/reload`); "Buy all" still untested

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
of price history exist. AH fee (5.00%) and deposit verified on 2026-10-21
(20 Copper Bars); resale still needs a per-item deposit source.

## alpha.3 in-game check (live client 1.60.1.70790) — closed

Opened 2026-11-06. Background in `docs/API-AUDIT.md` rows 17–19: on the live
server the replica answers up to about 3 min late (timeout now 300 s) and
scans are about 160,000 rows, 5× the beta.

The game now runs on the home PC: install to and read SavedVariables from
`\\ARIANOLOVER\World of Warcraft\_forever_\` (account `DOTTORB`).

Checked on 2026-11-06 at 19:24 (API-AUDIT row 19):
- [x] Request answered inside the timeout: 171 s, AH kept open.
- [x] Timings read: replica read fine (8 ms longest frame); hitches in
      grouping before history (214 ms), history finish (83 ms), single history
      steps (69 ms) and evaluation steps (53 ms).
- [x] Saved file: 3.37 MB, +287 KB per scan.
- [x] The first request after login was answered, so a login cooldown is
      unlikely; the 17:27 silence (AH closed after 169 s, before a late answer
      could arrive) is most likely just the late answer.

Checked on 2026-11-06 at 20:01 (API-AUDIT row 20), with grouping chunked
(`8eefe9a`):
- [x] `history_begin` 0 ms, `group` longest frame 5.3 ms, `history_finish`
      37 ms (was 83).
- [x] Remaining hitches are single heavy item keys, not garbage collection:
      58 ms for 3,002 auctions (history), 50–54 ms for 4,479 auctions
      (evaluation). One or two frames per scan; **accepted for now**,
      splitting the work inside one item is the next step only if the owner
      notices it.
- [x] Saved file 5.24 MB: 2.3 MB of it was the view kept for `/reload`
      (all auctions of each item with an opportunity).

Changed after that check (not yet seen in game): the saved view keeps only
the auctions in an opportunity's lots plus the 50 cheapest per item.

Checked on 2026-11-06 at 20:28 (API-AUDIT row 21), owner away from the PC:
- [x] Answered after 203 s (longest so far, still inside 300 s), pipeline
      completed unattended.
- [x] Saved view 1.1 MB (was 2.3), file 4.21 MB (was 5.24).
- [x] `docs/TESTING-IN-GAME.md` 2.1/2.2 updated.

Closed on 2026-11-06 by the owner:
- [x] The Opportunities tab lists the same gains after `/reload`.
- [x] The remaining 50–70 ms frames on the heaviest items are accepted;
      revisit only if they are noticed while playing.
- [x] **alpha.3 done.**

"Buy all" first try on live (API-AUDIT row 23): safe (nothing spent), but
13 of 15 searches and quotes got no answer within 10 s. The saved trace
(read 2026-11-07) shows the silent requests were **never answered, not even
late**: no `ITEM_SEARCH_RESULTS_UPDATED` or quote event arrived in the 47 s
to 2.5 min before the AH was closed. The only two answers came 128 s apart
(21:04:03 and 21:06:11), each within 1 s of its request. Possible cause: a
per-player request limit on live, or evening server load (the next morning,
2026-11-07 08:18, the replica answered in 8 s instead of 150–330 s).

Changed after that (not yet seen in game):
- search and quote timeouts 10 → 30 s;
- "Buy all" stops after two unanswered requests in a row (`server_silent`);
- every request is traced with the throttle state, every answer with its
  delay, late ones included (trace 400 entries);
- an unanswered search no longer hides the offer as gone.

Next try in game: "Buy all" with a small limit, ideally at a quiet hour,
then read the `request` / `item_results` / `purchase_event` trace entries.

Watch list: `evaluate_finish` grew to 40–45 ms (sorting for the saved
view), still below 50 ms; answer delays reached 327 s, past the 300 s
timeout (read as a late answer; the cooldown error this caused is fixed,
API-AUDIT row 22).

## Phase 4 started — professions (2026-11-07)

Professions of the character: Mining, Blacksmithing, Cooking, First Aid.
The read-only probe (API-AUDIT row 24, build 70862) showed the client
exposes the whole recipe catalogue of each profession through the modern
`C_TradeSkillUI` (no classic globals). Since then (not yet seen in game):
- each profession window opened stores the compact catalogue in
  `ForeverGoldDB.recipes[profession]` (learned and unlearned recipes);
- after every scan, and when a window is opened, every recipe is priced:
  reagents at AH depth, result to a merchant or the AH, best exit;
- `/fg crafting` lists the best known recipes and the best learnable ones.

Limits: reagents sold only by merchants (e.g. water, flux) have no price yet
(the recipe is left out); AH exits have no deposit estimate (speculative);
one craft only (no depth for many crafts); no profession skill-up planning.
Checked in game 2026-11-07 08:49: catalogue saved for the four professions
(learned 5/4/2/1), `profession_observe` 36 ms for Blacksmithing (507
recipes), under 6 ms for the others; **pricing all recipes in one frame took
360-380 ms** after a scan, so it now runs one recipe per step (bench: 16 ms
slowest step on desktop). Checked in game 2026-11-07 09:41: 688 recipes priced over 109 frames,
longest 28 ms (Copper Rod, 2,851 listings); known recipes that pay: Copper
Rod +50 c, Basic Campfire +21 c, Copper Bracers +10 c, Rough Sharpening
Stone +3 c; 338 recipes unpriced because a reagent is sold only by
merchants. Unlearned weapons and armour showed 100-250 gold gains from
single overpriced listings: the "current lowest" price now needs 3
listings. Crafting tab added (replaces the Professions status page);
recipes learned in game are picked up through `NEW_RECIPE_LEARNED`.
Merchant prices for reagents added (not yet seen in game): read from any
open merchant window, lowest unlimited gold price per unit, used by
crafting when cheaper than the AH. The merchant API shape on Forever is
not verified: both `C_MerchantFrame.GetItemInfo` and `GetMerchantItemInfo`
are tried and the first rows are kept in `diagnostics.merchant`.
Merchant prices checked in game 2026-11-07 10:55-11:02 (build 70862): only
`C_MerchantFrame.GetItemInfo` exists (table: `name`, `price`, `stackCount`,
`numAvailable` -1 for unlimited, `hasExtendedCost`, `isPurchasable`), item
IDs from `GetMerchantItemID`; 82 prices from four merchants. Unpriced
recipes went only from 338 to 336: the blocking reagents are high-level
materials not on the AH yet (Thorium Bar 114 recipes, Arcanite Bar 82,
Solid Grinding Stone 52). Reagents the player can make are now costed by
their recipe (up to three levels; on the real catalogue: 338 -> 317
blocked).
Next: several crafts at real depth, deposit.

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

- `lua5.1 tests/runner.lua` → **163 passed, 0 failed**: deterministic cases
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
  SHA-256 `e979106eb6b040918d5ba505f2e67b9bf99983345a1c1dace5ce126cb0000e84`.

Mocks prove our logic only; in-game evidence is listed in `docs/API-AUDIT.md`.

## Limits

- Replicate completeness not verified: scans end as
  "partial observation"; resale stays "speculative" until a per-item deposit
  is known (`depositPerUnit` is not filled yet; deposits scale with the hours
  above a 100 copper minimum, and only the quote at posting time is reliable).
- "Buy all" not yet tested in game.
- No price chart yet (History shows tables).
- luacheck not available locally: informational in CI; the blocking lint is
  the bytecode globals check.

## Blockers and the minimum data to unblock them

| Blocker | Minimum data or test |
| --- | --- |
| Replicate completeness | rows read compared with what the AH window shows for a few items |
| Resale ranking | three days of price history (collected automatically by regular scans) |
| Resale deposit | a per-item deposit estimate (e.g. quotes at posting for a few items and durations) |
| "Buy all" | one run in game with a small spending limit |
