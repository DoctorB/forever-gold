# ForeverGold — API audit

Status as of 2026-10-20, after session 1. All symbols in the matrix are
`present` on build 70450; no semantics are `runtime_verified` yet
(the AH tests in `docs/TESTING-IN-GAME.md` are required).

<!-- verified: replicate=false replicateBuyoutIsTotal=true replicateIndexBase=true commoditySearch=false itemSearch=false itemSearchBuyoutIsTotal=false sellPrice=true persistence=true fee=true deposit=true -->

The comment above is read by `tests/test_package.lua`: every flag must
match `Capabilities.VERIFIED` in `ForeverGold/Core/Capabilities.lua`
and becomes `true` only together with the evidence recorded here.

Allowed statuses: `documented` (present in the client documentation),
`present` (symbol found by `/fg diagnostics` on the target client),
`runtime_verified` (behavior observed and recorded), `unsupported`,
`unknown`.

## Verification sessions

| Date | Build | Method | Outcome |
| --- | --- | --- | --- |
| 2026-10-20 (1) | 1.60.1.70450 (`GetBuildInfo`, compiled on October 15, 2026) | ForeverGold 0.1.0-alpha.1, `/fg diagnostics`, realm `ClassicBetaPvE`, faction Alliance; file `ForeverGold.lua` written by the client at 12:51 | addon loaded with `Interface 16001`; 26/26 symbols present; 8/8 events accepted by `C_EventUtils.IsEventValid` and registered; `SupportsCopperValues()` → `true`; `GetCurrentRegion()` → 110; SavedVariables **written** (reload not yet tested: `loads = 1`) |
| 2026-10-20 (2) | 1.60.1.70450 | `/reload` + `/fg diagnostics`; file rewritten at 12:53 | `loads = 2`, `previousLoad` = first load (12:47:54), `created` unchanged: data **read back after `/reload`** and not reset. Logout/login and full restart still missing |
| 2026-10-20 (3) | 1.60.1.70450 | relog and full client restart | `loads` 3 (relog 12:53:12), 4 (12:54:16), 5 after the restart (12:56:55, `previousLoad` = 12:54:16): **persistence verified** across all three steps |
| 2026-10-20 (4) | 1.60.1.70450 | AH open, `/fg scan` at 12:57:19, second `/fg scan` at 12:58:09, AH closed at 12:59:25 | first replica read in ~31 s: 2,081 item keys, 29,449 buyable auctions, 204,636 units; partial outcome `rows_incomplete`. During the read the client sent **hundreds of `REPLICATE_ITEM_LIST_UPDATE`** (≥ 190 in ~1 s). The second request, 19 s after the end of the first, **received no response for 76 s** (retry included): replica cooldown > 76 s, duration unknown. No key with a suffix other than 0 out of 2,081. Index base and row count lost because the trace was saturated |
| 2026-10-20 (5) | 1.60.1.70450 | ForeverGold with feedback; `/fg scan` at 13:03:29 (+2 automatic retries), 13:06:19 (+1 retry) | **no response** to any of the 7 requests between 12:58:09 and 13:07:25: replica cooldown **≥ 10 min 6 s** from the last successful scan (12:57:19). We do not know whether requests during the cooldown extend it: from now on no automatic retry and a 5 min pause after every unanswered request. `AUCTION_HOUSE_THROTTLED_SYSTEM_READY` arrives during the wait (it does not indicate the end of the cooldown). A manual search (itemID 2516, commodity) produced `COMMODITY_SEARCH_RESULTS_UPDATED` |
| 2026-10-20 (6) | 1.60.1.70450 | ForeverGold with non-repeated requests; `/fg scan` at 13:13:19, AH closed at 13:14:23 | **response** after 6 s (13:13:25); 31,058 rows read with index base **0**, 0 discarded, 0 incomplete after 2 re-reads; 2,575 keys, 210,676 units; scan complete in 38 s; 3,084 `REPLICATE_ITEM_LIST_UPDATE` during the read. Cooldown: silence at +13 min 34 s, response at +16 min from the last successful scan; a request 4 min 11 s after a silent one stayed silent, so unanswered requests do **not** restart the cooldown. Links: the suffix field is empty, variants arrive as **bonus IDs** (`item:15268::::::::20:1486::1:1:12730:1:28:5256`) |
| 2026-10-20 (7) | 1.60.1.70450 | Comparison of the replica samples (13:13) with the native AH window (screenshots 13:20 and 13:21) | Forever's AH UI is the **modern commodity** one ("Browse Auctions": minimum price per unit, aggregated available quantity). Samples read as the stack total → unit price consistent with the displayed minimum: Goretusk Liver 7 × 3s 98c (minimum 2s 99c), Goretusk Liver Pie 5 × 1s (minimum 79c), Murloc Eye 6 × 39c (minimum 16c); read as unit prices they would be 6–15 times the minimum. In addition **8/8 samples are exact multiples of the quantity** (2786 = 7 × 398, 234 = 6 × 39, 3995 = 5 × 799…). → `replicateBuyoutIsTotal` **verified** |
| 2026-10-20 (8) | 1.60.1.70450 | ForeverGold 0.1.0-alpha.2, assisted purchase: scan 13:55, Pyrite detail (commodity), "1. Quote", "2. Buy", sale to the vendor | `GetItemKeyInfo().isCommodity` = true for Pyrite; `StartCommoditiesPurchase` → `COMMODITY_PRICE_UPDATED`; `ConfirmCommoditiesPurchase` called from the button click **accepted** → `COMMODITY_PURCHASE_SUCCEEDED` (13:59:17): 8 Pyrite, gold spent 640 = quote. At the vendor (14:00:12): 8 sold, 800 expected, 800 received → **`sellPrice` verified**, realized profit 160 copper. `GetMoney` and `GetItemCount` work |
| 2026-10-20 (9) | 1.60.1.70450 | Three more assisted purchases and vendor sales (14:19–14:37); scans 14:18 and 14:34 | Murloc Eye 27 (commodity, 405 → 432), Copper Tube 5 (commodity, 500 → 600), Shadow Wand 1 (**single auction**: targeted search with 23 results, 1 matching; `PlaceBid` from the accepted click, outcome received; 400 → 443). **4/4 vendor checks exact**; total realized profit 330 copper on 1,945 spent. A quote higher than the plan (itemID 814) was rejected and cancelled with no spending. Replica cooldown narrowed to **14 min 27 s – 15 min 38 s**. Scan 14:34: 31,198 rows, 4,077 keys, 0 discarded, 47 s |
| 2026-10-20 (10) | 1.60.1.70450 | "AH search test" (`/fg probe`) 15:45–15:46 on 4 random-variant items (Shimmering Robe, Defender Bracers, Ivycloth Robe, Ivycloth Tunic) | Direct search with `MakeItemKey(itemID, itemLevel, 0)` returns 0 rows. `SendBrowseQuery` by name returns one key per variant; **itemSuffix = bonus ID + 1580** with itemLevel = effective level, in all 13 keys checked (e.g. 25/14322 ↔ bonus 12742, 22/14308 ↔ 12728, 29/14328 ↔ 12748); a search with that key returns exactly the auctions of that variant. No multi-unit non-commodity lot was available, so the item-search price meaning for lots stays open |
| 2026-10-20 (11) | 1.60.1.70450 | "Buy all" after the key fix, 15:48 | Edged Bastard Sword bought and sold (1300 → 1377): the built key (level 18, suffix 14300 for bonus 12720) found no row (that variant was gone); the browse found the item under 5 keys and an equivalent variant at 1300. That variant has bonus **12919** and key suffix **14315**: the +1580 rule holds for the 127xx bonus range only, so the browse fallback stays required. A commodity quote (itemID 3172, 17 units) got no answer three times (neither price nor unavailable); purchase events are now traced to find out why |
| 2026-10-20 (12) | 1.60.1.70450 | AH search test 16:02:10–16:02:34, then `/reload` | Probe finished cleanly (4 variant items, browse keys again consistent; 0 multi-unit lot candidates). At 16:03:04 the AH closed, at 16:03:04–05 the client wrote every add-on's SavedVariables completely, at 16:03:08 the **client crashed** (`Errors6-10-20_16.03.08_Error_31268.txt`: exception 0x80000003 BREAKPOINT at an unknown address, no Lua or add-on frame). Not attributable to ForeverGold from the report; as a mitigation the saved data (7.9 MB) is reduced |
| 2026-10-20 (13) | 1.60.1.70450 | AH search test 16:16:41–16:17:24 after a restart (4 variant items, 8 lot candidates) | **Multi-unit item-search rows are per unit:** *Recipe: Westfall Stew* has many single 1×100 auctions in the replicate and the item search returns one row **58 × 100** (single auctions grouped at one price); the other 7 items return one row per auction. `itemSearchBuyoutIsTotal = false` is therefore verified; grouped rows are priced as quantity × buyoutAmount and stay unbuyable until what `PlaceBid` buys on a grouped row is known. Variant keys: Beaded Wraps bonus 12720 ↔ suffix 14299 (not 14300), so the +1580 rule is only a first guess. Saved file 2.6 MB after pruning (was 7.9 MB); no further crash |
| 2026-10-20 (14) | 1.60.1.70450 | ForeverGold 0.1.0-alpha.2, guided fee test (`/fg feetest`) 16:25:49, then 20 Copper Bars posted by the owner from the native AH window at 16:27:26, default duration (8 h), 58 copper per unit | **Forever AH durations are 2 / 8 / 24 h** (indexes 1/2/3; 8 h is the UI default; the add-on had assumed 12/24/48). Gold paid at posting **100 copper** = `CalculateCommodityDeposit` for the posted quantity (100 / 100 / 120 for 2 / 8 / 24 h): **deposit verified**; 2 h and 8 h share the 100 minimum, so the duration comes from the owner. The quotes taken when arming the test, for the same 20 bars, were 100 / 168 / 504: both sets scale with the hours above a 100 minimum, but at different rates, so only the quote at posting time is trusted |
| 2026-10-21 (15) | 1.60.1.70450 | Mailbox opened 07:51:40 (mail not taken), `/reload` | One seller invoice "Auction successful: Copper Bar (20)": sale 1,160, `consignment` 58, money 1,202 = 1,160 − 58 + **100 deposit refunded**: **AH fee 5.00% verified**, deposit returned on a sale. `GetInboxInvoiceInfo` returned `count = 0` for 20 units sold: that field is not used |

## Target client

| Item | Value | Status | Evidence |
| --- | --- | --- | --- |
| Product | WoW Forever, flavor `wow_classic_beta`, folder `_classic_beta_`, `WOW_PROJECT_ID` 18 | verified | `.build.info`, `.flavor.info`; diagnostics 2026-10-20 |
| Build | 1.60.1.70450 | verified | `GetBuildInfo()` → `"1.60.1", "70450", "Oct 15 2026", 16001` |
| Interface TOC | `16001` | verified | `GetBuildInfo()` on 70450; ForeverGold loaded with that value |
| Market | product `p18`, region `110`, realm `ClassicBetaPvE`, faction `Alliance` | observed | diagnostics; region 110 is not one of the Retail codes 1–5: it remains only part of the key |
| Lua runtime | 5.1 (no `goto`, `//`, bitwise) | verified on 70374 (same source) | same |
| UI templates used | `UIPanelButtonTemplate`, `UICheckButtonTemplate`, `InputBoxTemplate`, `BasicFrameTemplateWithInset` | verified on 70374 (same source) | same |
| SavedVariables | written by the client to `WTF\Account\<account>\SavedVariables\` | **verified** (flag `persistence`) | `ForeverGold.lua`: `loads` 1 → 5 after `/reload`, relog and restart, 2026-10-20 |

## Documentation sources

| Source | Immutable reference | Use |
| --- | --- | --- |
| Forever API extraction (Atraeau/WoW-Addons) | commit `d8c9be3635e756fd90284e02b5a800c796b337a0` (2026-10-03), build 70170, interface 16001 | signatures, types, events; autogenerated examples **ignored** |
| `docs/api/Auction-Mail-Trade/C_AuctionHouse.md` | same commit | AH |
| `docs/api/Items-Inventory/C_Item.md` | same commit | item, `sellPrice` |
| Blizzard Retail mirror (Gethe/wow-ui-source, branch `live`) | moving branch: comparison only | not used as evidence |

## Functions

Expected currency unit: copper. `BigUInteger` fields are treated as
`number` only if they arrive as finite, integer numbers ≤ 2^53−1; otherwise the
row is discarded with a reason (`Money.Normalize`), never converted lossily.

| Function | Documented signature (70170) | Use in ForeverGold | Status | To verify in game | Fallback |
| --- | --- | --- | --- | --- | --- |
| `GetBuildInfo` | `() → version, build, date, interface` | diagnostics, `MarketKey` | documented | real values on 70450 | unknown field = isolated partition |
| `C_AuctionHouse.ReplicateItems` | `()`; "to be used instead of the allItem query" | scan on user request | documented | following event, delay, cooldown, data with AH closed | FAILED state `no_response` after limited retries; passive observation |
| `C_AuctionHouse.GetNumReplicateItems` | `() → number` | row count | documented | value before/after the event | FAILED `count_unavailable` |
| `C_AuctionHouse.GetReplicateItemInfo` | `(index: number)` → 18 values: name, texture, count, qualityID, usable, level, levelType, minBid, minIncrement, buyoutPrice, bidAmount, highBidder, bidderFullName, owner, ownerFullName, saleStatus, itemID, hasAllInfo | auction rows | documented | **index base** (0 or 1: detected by reading index 0), **buyoutPrice as stack total or per unit**, value 0 without buyout, `hasAllInfo` | index: automatic detection; buyout: assumed total, confidence penalized (`semanticsUnverified`) |
| `C_AuctionHouse.GetReplicateItemLink` | `(index) → itemLink?` | variant (bonus ID; empty suffix on Forever) | runtime_verified (format) | link available with `hasAllInfo` false? | unknown variant → excluded from resale |
| `C_AuctionHouse.IsThrottledMessageSystemReady` | `() → bool` | readiness | documented | behavior during/after the replica | absent → proceed and record |
| `C_AuctionHouse.SendSearchQuery` | `(itemKey, sorts, separateOwnerItems, minLevel?, maxLevel?)`; 100 calls/minute | only "Refresh quote" on request | documented | empty `sorts` accepted? response event | rejection with reason |
| `C_AuctionHouse.MakeItemKey` | `(itemID, itemLevel?, itemSuffix?, battlePetSpeciesID?) → ItemKey` | key for the targeted search | documented | suffix in the Forever ruleset | — |
| `C_AuctionHouse.GetCommoditySearchResultInfo` | `(itemID, index: luaIndex) → CommoditySearchResultInfo?` (quantity, unitPrice, auctionID, containsOwnerItem…) | passive observation and quote | documented | do commodities exist on Forever? `unitPrice` per unit? | no commodities → replica only |
| `C_AuctionHouse.GetItemSearchResultInfo` | `(itemKey, index: luaIndex) → ItemSearchResultInfo?` (quantity, buyoutAmount?, auctionID…) | passive observation, quote, assisted purchase | **runtime_verified**: quantity > 1 = grouped single auctions, buyoutAmount per unit (session 13) | `buyoutAmount` total or per unit for quantity > 1 | rows with quantity > 1 not buyable until verified |
| `HasFull{Commodity,Item}SearchResults` | `(key) → bool` | per-item completeness | documented | — | nil → partial observation |
| `CalculateItemDeposit` / `CalculateCommodityDeposit` | `(…, duration, quantity) → depositCost?` (duration 1/2/3 = 2/8/24 h) | fee test only (they require the item) | runtime verified at posting (session 14) | duration, refund | unknown deposit → excluded from profit and flagged |
| `StartCommoditiesPurchase(itemID, quantity)` | quote → `COMMODITY_PRICE_UPDATED(unit, total)` / `COMMODITY_PRICE_UNAVAILABLE` | assisted purchase, step 1 (does not spend) | **runtime_verified** (session 8) | quote event and values | no quote within 10 s → aborted |
| `ConfirmCommoditiesPurchase(itemID, quantity)` | → `COMMODITY_PURCHASE_SUCCEEDED` / `_FAILED` | assisted purchase, step 2, click only | **runtime_verified** from click (session 8) | requires hardware event? outcome | no response within 20 s → "uncertain", never retried |
| `PlaceBid(auctionID, bidAmount)` | → `AUCTION_HOUSE_PURCHASE_COMPLETED(auctionID)` / `ITEM_PURCHASED(itemID)` | assisted purchase of an individual auction, click only, at buyout | **runtime_verified** from click (session 9) | outcome and errors | same |
| `CancelCommoditiesPurchase`, `GetQuoteDurationRemaining` | — | cancels a rejected quote; quote expiry | present (from alpha.2 diagnostics) | quote duration | expired quote → new quote |
| `GetItemKeyInfo(itemKey)` | → `ItemKeyInfo.isCommodity`; may arrive after `ITEM_KEY_ITEM_INFO_RECEIVED` | commodity recognition | **runtime_verified** (Pyrite) | value for a known material | unknown → rows treated as whole lots |
| `GetMoney`, `GetItemCount` | — | gold and bags for the cap and vendor check | **runtime_verified** | — | unknown → purchase not planned |
| `C_AuctionHouse.SupportsCopperValues` | `() → bool` | recorded in diagnostics | documented | meaning on Forever | — |
| `C_Item.GetItemInfo` | 18 values, `sellPrice` in 11th position | vendor price, name, class | **runtime_verified** (`sellPrice` = vendor price, session 8) | cold cache | nil → "vendor price unknown", no opportunity |
| `C_Item.RequestLoadItemDataByID` + `GET_ITEM_INFO_RECEIVED` | — | asynchronous loading | documented | event and arguments | 5 s timeout, queue limited to 200 |
| `C_TradeSkillUI.GetRecipeInfo`, `GetRecipeSchematic` | `GetRecipeSchematic(recipeSpellID, isRecraft, recipeLevel?)` | presence only (phase 4) | documented | required context | professions disabled |
| `C_EventUtils.IsEventValid` | — | registers only valid events | not in the AH table | presence | without it, `RegisterEvent` in `pcall` |

## Candidate events

Registered only if `C_EventUtils.IsEventValid` does not reject them; the outcomes
end up in `ForeverGoldDB.diagnostics.report.events`.

| Event | Documented payload | Use |
| --- | --- | --- |
| `AUCTION_HOUSE_SHOW`, `AUCTION_HOUSE_CLOSED` | — | open/close; closing cancels timers and invalidates quotes |
| `REPLICATE_ITEM_LIST_UPDATE` | — | replica reception (wait of 2 s with no new events before reading) |
| `COMMODITY_SEARCH_RESULTS_UPDATED` | `itemID` | passive observation / quote |
| `ITEM_SEARCH_RESULTS_UPDATED` | `itemKey`, `newAuctionID?` | passive observation / quote |
| `AUCTION_HOUSE_THROTTLED_SYSTEM_READY`, `AUCTION_HOUSE_THROTTLED_MESSAGE_DROPPED` | — | resume after throttle; traced |
| `GET_ITEM_INFO_RECEIVED` | `itemID`, `success` | item cache |

## Open questions (they block promotion to "verified")

1. Index of `GetReplicateItemInfo`: 0 or 1? From the 2nd scan on, the value is saved with the snapshot (`indexBase`).
2. Replica `buyoutPrice`: **stack total**, verified (session 7).
3. Replica cooldown: measured between 14 min 27 s and 15 min 38 s (almost certainly 15 minutes); the bounds are updated on every attempt in `ForeverGoldDB.scanner`. Updates during the read are now counted (`lateUpdates`) and incomplete rows re-read up to 4 times.
9. Link format: resolved. Empty suffix, variants in the bonus IDs (field 13 = count, then the IDs); the item key now includes the sorted bonus IDs (`i:15268:0:b12730`). The `28:5256` modifier remains to be understood.
10. Meaning of the replica buyout: every scan now saves `buyoutVotes` (stacks compared with single auctions of the same item) as statistical evidence, to be confirmed with 2–3 comparisons in the AH window.
4. Commodities: **yes**, the AH UI is the modern commodity one. To do: recognize which items are commodities (e.g. `GetItemKeyInfo().isCommodity`) so their replica rows are treated as divisible (partial purchase at the unit price).
5. AH shared across factions/realms? (while unknown, the faction stays in the `MarketKey`)
6. AH commission and actual deposits: **resolved** (sessions 14–15): fee 5.00%, deposit = `CalculateCommodityDeposit` at posting, refunded on sale. Still open: why the quote before posting differs, and a per-item deposit source for resale.
7. Is `sellPrice` from `C_Item.GetItemInfo` equal to the price paid by the vendor?
8. Persistence of `ForeverGoldDB` after `/reload`, logout/login, full restart.
