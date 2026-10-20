# ForeverGold — in-game tests

The offline tests use mocks and do **not** prove the server's behavior.
This checklist turns the entries in `docs/API-AUDIT.md` into evidence. No
test needs real purchases except session 3, which spends a small amount of
gold and only on your clicks.

## Installing the alpha

1. Close the game or stay at the character screen.
2. Back up `World of Warcraft\_classic_beta_\WTF\Account\<account>\SavedVariables\ForeverGold.lua` if it exists.
3. Extract `release\ForeverGold-0.1.0-alpha.2.zip` into
   `World of Warcraft\_classic_beta_\Interface\AddOns\` (the result must be
   `AddOns\ForeverGold\ForeverGold.toc`).
4. Launch, enable **ForeverGold** in the addon list, log in with a character.

**Rollback:** close the game, delete `Interface\AddOns\ForeverGold\` and, if
you want to go back to the previous data, restore the backup of `ForeverGold.lua`
(or delete it to start from scratch).

## Session 1 — loading and diagnostics (no AH)

| # | Action | Expected result | To record |
| --- | --- | --- | --- |
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
| 2.2 | During the scan | no noticeable game freeze | FPS before/during (even approximate) |
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
| 4.1 | AH open, Settings → "Fee and deposit test" (or `/fg feetest`) | chat: deposit quoted for 12/24/48 h and a suggested price | quotes |
| 4.2 | Post **all** the bars from the AH window (Sell tab), any duration | chat: "Deposit paid: X … It matches the N h quote: deposit verified" | deposit and duration |
| 4.3 | Wait for the sale (may take hours; `/fg feetest status` shows the stage) | — | — |
| 4.4 | Open any mailbox (no need to take the mail) | chat: "Sale invoices read … fee X%. Fee verified" | fee |
| 4.5 | `/reload`, then send the file for the audit | fee and deposit recorded in `ForeverGoldDB.verifiedRuntime` | — |
