# ForeverGold — in-game tests

The offline tests use mocks and do **not** prove the server's behavior.
This checklist turns the entries in `docs/API-AUDIT.md` into evidence. No
test needs real purchases except session 3, which spends a small amount of
gold and only on your clicks.

## One round for everything not yet seen in game (2026-11-07)

Everything since the last check at 12:44 (commits `0168fd3` to `3fd76eb`)
in one visit to the auction house, about 20 minutes. Only step R8 spends
gold, and only on your clicks; skip it if you prefer. One screenshot per
step is enough; `/reload` once at the end so the evidence is saved.

Before: have in the bags at least 5 different sellable, unbound items
(cloth, bars, food, gear) and a few reagents of a known recipe (e.g.
Copper Bars for Copper Rod).

| # | Where | Action | Expected | Feature |
| --- | --- | --- | --- | --- |
| R1 | AH | Open the AH (auto-scan on) | within ~15 min an automatic scan; if it finds offers: chat "automatic scan: N offers ..." and a sound | auto-scan, alert |
| R2 | AH | Wait 3 s after opening | nothing visible (deposit quotes are read for items in the bags) | deposit check |
| R3 | `/fg` → Crafting | Look at the known recipes | "To spend" column; in green when reagents come from your bags | owned reagents |
| R4 | Crafting | Hover Copper Rod | reagents with "(N in your bags)", "gold to spend now ...", "AH deposit about ... (8 h)", estimated or "formula checked on your items" | owned reagents, deposit |
| R5 | Bags | Hover a Copper Rod, a Copper Bar, a Weak Flux | "craft: +X for N (your recipe ...)" on the rod, "sold by a merchant for 1s 0c" on the flux | tooltips |
| R6 | `/fg` → History | Click an item in the prices table, then click the chart | bars per scan with dates and low/high; the click goes back to the scans | price chart |
| R7 | Crafting | Buy or loot a reagent, wait 10 s | the Crafting tab updates "To spend" by itself | bag refresh |
| R8 | Opportunities (optional) | "Buy all" with a small limit, at a quiet hour | each search/quote answered or the run stops after two silences with "the server stopped answering" | Buy all (open since 2026-11-06) |
| R10 | Trainer of a profession you have | Open the trainer window, then `/fg` → Crafting | hovering a recipe to learn shows "Requires <profession> N (read at the trainer)" and the cost; the summary says how many recipes need more skill | trainer requirements (D53) |
| R9 | anywhere | `/reload` | — (saves deposit checks, auto-scan and Buy all traces) | evidence |

## Installing the alpha

1. Close the game or stay at the character screen.
2. Back up `World of Warcraft\_forever_\WTF\Account\<account>\SavedVariables\ForeverGold.lua` if it exists.
3. Extract `release\ForeverGold-0.1.0-alpha.3.zip` into
   `World of Warcraft\_forever_\Interface\AddOns\` (the result must be
   `AddOns\ForeverGold\ForeverGold.toc`).
4. Launch, enable **ForeverGold** in the addon list, log in with a character.

**Rollback:** close the game, delete `Interface\AddOns\ForeverGold\` and, if
you want to go back to the previous data, restore the backup of `ForeverGold.lua`
(or delete it to start from scratch).

## Session 1 — loading and diagnostics (no AH)

| # | Action | Expected result | To record |
| --- | --- | --- | --- |
| 1.0 | Full client restart, AddOns list at character selection | "Forever Gold" with the gold infinity icon instead of the question mark | screenshot |
| 1.1 | Login | no Lua errors | any errors (with `/console scriptErrors 1`) |
| 1.2 | `/fg diagnostics` | summary in chat: build, symbols present, events registered/rejected | chat text (or screenshot) |
| 1.3 | `/fg` | window with 5 tabs; resizable; ESC closes it | screenshot at two resolutions/UI scales |
| 1.4 | `/fg demo` | table with data labelled DEMO; clicking a row opens the detail view | screenshot |
| 1.5 | `/reload`, then `/fg diagnostics` | "Loads of saved data" increases by 1 | number |
| 1.6 | Logout/login and full restart, then `/fg diagnostics` | the counter keeps growing | numbers → flag `persistence` |

After the session: send `WTF\...\SavedVariables\ForeverGold.lua` (it contains
only build, symbols, events, counts and trace; no seller names).

## Session 2 — read-only AH

| # | Action | Expected result | To record |
| --- | --- | --- | --- |
| 2.1 | Open the AH, `/fg scan` | state: requested → receiving → reading → "partial observation (completeness not yet verified)" | total time, rows, keys, units shown in the status bar |
| 2.2 | During the scan | no noticeable game freeze | FPS before/during (even approximate); `/reload` then read `diagnostics.timings` (longest frame per phase) |

Live server 1.60.1.70790, 2026-11-06 (API-AUDIT rows 19–21): 2.1 passed
three times with the AH kept open (answers after 171–203 s, about 158,000
rows, read in 35 s). 2.2 measured: replica read and grouping stay at most
11 ms per frame; one or two frames of 50–70 ms remain per scan on the items
with 3,000–4,500 auctions.
| 2.3 | `/fg scan` right after | refusal or `no_response`: shows whether a cooldown exists | message and elapsed time |
| 2.4 | After the scan, `/reload` | every scan saves 8 multi-unit rows and 6 raw item strings with the snapshot | compare 2–3 rows (which I will point out from the file) with the AH window: total or per-unit price? → flag `replicateBuyoutIsTotal` |
| 2.5 | Search a material by hand in the native AH | the Opportunities tab updates the item (passive observation) | whether the item is a commodity or an individual auction |
| 2.6 | Close the AH during a scan | state cancelled or partial "AH closed", no errors | screenshot |
| 2.7 | Detail view of a vendor opportunity | expanded formula; compare the vendor price with the merchant's real one | real price → flag `sellPrice` |
| 2.8 | Detail view → "Refresh quote" | "quote still valid/changed" | result |
| 2.9 | With a popular AH addon active (e.g. Auctionator), repeat 2.1 and 2.5 | no errors; possible `search_changed` suspension | result |

## Required measurements

- Frame time during reading with a 2 ms budget (Settings does not expose it
  yet: default value).
- Addon memory after a scan (`/run UpdateAddOnMemoryUsage() print(GetAddOnMemoryUsage("ForeverGold"))`, if available on Forever).
- Size of `ForeverGold.lua` after 1, 3 and 7 days.

## Not required for the alpha

Purchases, auctions, cancellations: not implemented. The mutating checks of
phase 6 will use a cheap item chosen by the owner.

## Session 3 — assisted purchase with a small budget

Requires `0.1.0-alpha.2`. Spends real gold, but only with your click.

| # | Action | Expected result | To record |
| --- | --- | --- | --- |
| 3.1 | Settings: tick "Assisted purchases (experimental, one click per purchase)", cap per purchase 20 (silver), Save | — | — |
| 3.2 | AH open, scan (if the cooldown allows it) | "Probable gain" banner if there are vendor margins | banner text |
| 3.3 | Click the cheapest vendor row | detail view with "How to:" and "Plan: buy N x … for …" | screenshot |
| 3.4 | "1. Get quote" (commodity) or "1. Find auction" | quote within the plan, "2. Buy: spend X" button active; if the price went up: "Stopped:" and nothing spent | text |
| 3.5 | "2. Buy: spend X" | in chat "bought N x …"; items in bags | gold before/after |
| 3.6 | Go to any merchant, sell **only** those items, close the merchant window | in chat "merchant: gained …" and "Matches: realised gain …"; the first time "Vendor price now verified" | text |
| 3.7 | Reopen `/fg` | the vendor opportunities switch to "VERIFIED" and the banner turns green | screenshot |

Do not sell anything else during the same merchant visit and do not repair: the
gold comparison must be exact.

## Session 4 — AH fee and deposit (guided)

Uses an item the owner chooses (default: 20 Copper Bars). ForeverGold does
not post: you post from the native AH window.

| # | Action | Expected result | To record |
| --- | --- | --- | --- |
| 4.1 | AH open, Settings → "Fee and deposit test" (or `/fg feetest`) | chat: deposit quoted for 2/8/24 h and a suggested price (indicative: only the quote at posting is reliable) | quotes |
| 4.2 | Post **all** the bars from the AH window (Sell tab), any duration (2/8/24 h, default 8 h) | chat: "Deposit paid: X … It matches the N h quote: deposit verified" | deposit and duration |
| 4.3 | Wait for the sale (may take hours; `/fg feetest status` shows the stage) | — | — |
| 4.4 | Open any mailbox (no need to take the mail) | chat: "Sale invoices read … fee X%. Fee verified" | fee |
| 4.5 | `/reload`, then send the file for the audit | fee and deposit recorded in `ForeverGoldDB.verifiedRuntime` | — |

## Session 5 — Crafting tab (read-only)

Nothing is crafted, learned or changed. Character professions: Mining
(Smelting window), Blacksmithing, Cooking, First Aid. The recipes are read
once per window and kept; after that the tab needs no command.

| # | Action | Expected result | To record |
| --- | --- | --- | --- |
| 5.1 | First time only: open each profession window once | nothing visible | — |
| 5.2 | Scan the AH, then open `/fg` → **Crafting** | professions with skill; "N recipes, M priced"; two tables: recipes you know, recipes you could learn | screenshot |
| 5.3 | Hover a row | reagents with their cost, exits, listings already on the AH | — |
| 5.4 | Open a few merchant windows (trade goods, general goods, cooking and blacksmithing suppliers), then the Crafting tab | "Merchant prices known: N items" grows; recipes with thread, flux or spices appear, hovering shows "(merchant)" on those reagents | screenshot |
| 5.5 | Learn a recipe from a trainer (optional) | the recipe moves to "recipes you know" by itself | — |


## Session 6 — automatic scan (read-only)

Whether the game accepts the AH request without a click is not known on
Forever: this session is the test. Nothing is bought.

| # | Action | Expected result | To record |
| --- | --- | --- | --- |
| 6.1 | Settings: tick "Scan the AH by itself when the cooldown ends", open the AH window | status line: "auto-scan in N min" (or a scan starts at once if the cooldown is over) | screenshot |
| 6.2 | Stay at the auctioneer until the countdown ends | chat: scan finished, as with the button; or status "auto-scan off: the game blocked the request" | screenshot |
| 6.3 | Stay away for a while (optional) | further scans every cooldown until the game disconnects for inactivity | time of the disconnect |


## Session 7 — deposit check (read-only, automatic)

Needs at least 5 different sellable, unbound items in the bags (trade
goods, cloth, food, gear). Nothing is posted.

| # | Action | Expected result | To record |
| --- | --- | --- | --- |
| 7.1 | Open the AH and wait 3 s | nothing visible; `ForeverGoldDB.depositChecks` gets up to 8 items with the quotes for 2/8/24 h | `/reload` when asked |
| 7.2 | Crafting tab, hover a row sold on the AH | "AH deposit about X (8 h) ... (formula checked on your items)" once 5 items matched, "(estimated)" before | screenshot |
