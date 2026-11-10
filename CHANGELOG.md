# Changelog

Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), SemVer versions.

## [Unreleased]

### Added

- Sales watching: each full AH scan is compared with the previous one (at
  most 30 minutes before, with a similar number of auctions read): units
  gone at their price count as sold. Only items with at least 5 auctions
  and no random variant. After an hour of watching, the item tooltip says
  "sells about N an hour, at about P each"; Advanced > History shows how
  many items are watched. Nothing is bought or posted: it only measures.
- "To do" screen, the new default view: one list of concrete actions, best
  gain first, each with one button: sell items from your bags on the AH,
  buy an AH offer a merchant pays more for (first click checks the price,
  second click buys), make a known recipe that pays off ("How?" opens the
  details); below, up to three recipes worth learning with skill and trainer
  cost. One line says how fresh the AH prices are. Every other tab, the
  settings and the test tools are behind "Advanced".
- Sell tab: the items your known recipes make that sell better on the AH
  than to a merchant, from your bags, with price (1 copper under the lowest
  listing), quantity (what the AH takes now), 8 h duration and deposit
  already set. With the AH open, each click on "Sell ..." creates the next
  auction (the game requires a click per auction); the server's answer is
  shown next to the button. Items a merchant pays more for, bound items and
  items with no AH price are left out.
- Required skill of the recipes to learn. Opening a profession trainer reads
  the skill and cost of every recipe it lists (nothing is learned); the
  tooltip of a recipe to learn shows "Requires Leatherworking 125" and the
  trainer cost. Recipes that need more skill than the character has are
  left out of "Recipes you could learn" (the summary counts them). Without
  a trainer reading, the level where the recipe turns grey (given by the
  recipe window) is used: a recipe grey 100 points or more above the
  character's skill is left out.
- Automatic scan alert: when an automatic scan finds offers that are not
  speculative, one chat line with the count and the gain, and a sound
  (with "Aggregated notifications" on).
- History: click an item in the prices table to see its price chart (one
  bar per scan, a lighter bar where a day starts, lowest and highest price
  and the dates covered); click the chart to go back to the scans.
- Item tooltips: besides the reference price, the crafting gain when one of
  your recipes (or one you could learn) makes the item, and the merchant
  price when a merchant you visited sells it. The Crafting tab is re-priced
  10 s after the bags stop changing (reagents bought, crafted or looted).
- Crafting with reagents already in your bags: the "To spend" column shows
  only the gold for what is missing; the tooltip says how many units of each
  reagent you have and what they are worth. The gain still counts them at
  their price (they are not free: you could sell them instead).
- AH deposit: estimated from the merchant price (15% / 30% / 60% for
  2 / 8 / 24 h, at least 1 silver per auction; one auction for a commodity,
  one per unit otherwise) and deducted from AH sales as an expected loss
  (half of it, refunded when the item sells). Resale and the AH exits of
  crafting include it; the Crafting tooltip shows it.
- Deposit check: when the AH opens, the deposit the game quotes for up to
  8 sellable items in your bags is compared with the formula (quotes only,
  nothing is posted). Once 5 items match and none differs, deposits count
  as known and resale can leave the "speculative" class.
- Optional automatic scan (Settings, off by default): with the AH window
  open, the add-on asks for the AH replica by itself as soon as the
  measured cooldown ends, e.g. while you are away. Reads only: it never
  buys, posts or cancels. It waits while a scan is processed or a purchase
  uses the AH, pauses after 3 unanswered requests in a row (reopen the AH
  to retry), and switches itself off if the game blocks the request
  without a click. The status line shows the next automatic scan.
- Profession probe (read-only): opening a profession window records which
  recipe APIs the client has, the recipes it lists (classic list and recipe
  IDs) and, for the first 12, product, quantity made and reagents, in
  `ForeverGoldDB.diagnostics.professions`. `/fg professions` prints a
  summary. Nothing is crafted or learned.
- Crafting evaluation: every recipe of the player's professions (observed
  when each profession window is opened, kept across sessions) is priced
  with the latest scan. Reagents are bought at their real AH depth; the
  result is sold to a merchant or on the AH (price history, or the current
  lowest listing until three days of history exist, both before deposit),
  whichever pays more. `/fg crafting` lists the best recipes the player
  knows and the best ones a trainer could teach.
  The pricing is spread over frames (one recipe per step): run in one go it
  froze the game for 360-380 ms after each scan. The best rows are kept in
  `ForeverGoldDB.diagnostics.crafting`.
  While a profession window stays open the client sends a list update every
  1-2 s: the window is read when it opens and then at most once a minute,
  and recipes are re-priced only when they changed.

- Crafting tab (was "Professions"): the recipes you know that pay off and
  the ones you could learn, with reagent cost, where to sell, what you get,
  the gain and how many are already on the AH; hover a row for reagents and
  exits. It refreshes by itself after each scan, when a profession window is
  opened and when a recipe is learned (no need to reopen the window).
- Merchant prices for reagents: opening any merchant window records the
  gold price per unit of what it sells (unlimited offers paid in gold), kept
  across sessions. Crafting buys each reagent from the cheapest source, AH
  or merchant; the row tooltip marks merchant reagents. Recipes whose
  reagents only merchants sell (thread, flux, spices, water...) are priced
  once that merchant has been visited. Nothing is bought or sold.
- Several crafts: every recipe is priced for 1 to 20 crafts and the count
  with the largest total gain is shown ("Crafts" column; totals in the
  row, one craft in the tooltip). Reagents are bought deeper into the AH
  book; without price history the AH is assumed to take at most 5% of the
  units already listed, and the rest goes to a merchant when it pays one.
  The tooltip says what stops more crafts: reagents, AH demand, dearer
  reagents or the 20 limit. Lists are sorted by the total gain.
- Reagents you can make: a reagent with no price (not on the AH, no merchant
  seen) is costed by the cheapest recipe that produces it, up to three
  levels (e.g. Solid Grinding Stone from Solid Stone). If a step of the
  chain is a recipe you do not know, the result is listed with the
  learnable recipes and the tooltip says what else to learn.
- The "current lowest" AH price of a crafted item is used only with at least
  3 listings: single overpriced weapons and armour made unlearned recipes
  look worth 100-250 gold.

### Changed

- When the auction house refuses a purchase, the buy window now says why
  (for example "there is already a higher bid") instead of only "AH error".
  The reason comes from the game; an unknown one is shown by name or code.
- "Buy all" stops after two searches or quotes in a row get no answer,
  instead of sending the rest of the queue to a server that is not
  answering. On the live server one run sent 13 requests that all went
  unanswered.
- Searches and commodity quotes wait 30 seconds instead of 10, which was
  sized on the beta.
- Every search, browse and quote request is traced with the throttle state
  at sending, and every answer with its delay, late answers included
  (`/fg diagnostics` trace, now 400 entries).

### Fixed

- An item the scan took for a single auction but the server answers as a
  commodity is now bought by the unit on the next click.
- A purchase started from "To do" closes the details window of another
  offer, which showed the new purchase under the old offer's name.
- Buying an item with a random variant ("of the Bear"...): the add-on looks
  it up by name right away instead of waiting 30 seconds for a search the
  server never answers.
- "To do" screen: "Reading the AH prices... 40%" instead of "Waiting for
  the server... 13 s / 300 s"; a recipe the trainer does not teach says it
  comes from a recipe item or a higher trainer.
- "To do" screen: the Advanced button no longer covers the gold line or the
  last tab (in the advanced view the "To do" tab leads back); gains of the
  recipes to learn are no longer cut.
- Chat lines in plain words: no more "new attempt 2 of 1", item keys or
  rows after a scan.
- AH deposit rounded down like the server (merchant price 306, 24 h: 183,
  not 184); quotes already checked are compared again.
- A purchase found gone was cleared by a late duplicate answer of the
  server and tried again: only a full scan clears it now.
- "Buy all" browse fallback: only variants whose lowest price fits the lot
  are searched, the lot's own variant first.
- One character could get two records when the realm name came with
  spaces: the records are merged.
- Trainer: Forever's order of the service fields (icon, then type); class
  spells are no longer kept as recipe requirements.
- An offer a purchase attempt already found gone can no longer be tried
  again until the next scan (in game the same gone lot was tried three
  times in 20 seconds).
- Professions saved before the per-character record: given to the character
  that has the profession at any skill (the first pass required the same
  skill and missed Leatherworking and First Aid).
- "Buy all" on an item that is not a commodity: when the search with the
  key built by the add-on gets no answer, it now browses by name like the
  AH window and searches again with the server's own keys, instead of
  giving up. In game a Lesser Magic Wand search got no answer in 30 s while
  searches from the AH window were answered.
- Professions per character: skill and known recipes are kept for each
  character (`characters["Name-Realm"]`), the recipe lists stay shared by
  the account. In game a Rogue saw the Warrior's Blacksmithing recipes as
  known, and its Cooking and First Aid replaced the Warrior's. Lists saved
  before go to the character that has that profession at the same skill
  (`GetProfessions`); the others come back when their window is opened.
- Merchant trace: unchanged reads are traced once a minute (the client
  repeats MERCHANT_UPDATE every few seconds while the window is open).
- Deposit of stackable items that are not commodities: one auction per
  stack, not per unit. In game 20 Copper Rods were charged twenty minimum
  deposits and every Blacksmithing recipe left the Crafting tab.
- Deposit check: matches at the 1-silver minimum no longer verify the
  formula on their own; two items quoted above the minimum are also needed
  (in game all eight first items were quoted the minimum).
- History chart: bars share the chart width instead of a fixed 48 slots.
- After a scan, item data arriving in bursts started a full evaluation each
  time (three passes of about 1.4 s CPU in game) and data arriving during a
  pass was not re-evaluated: one pass now starts after 3 s without new data.
- The scan cooldown waits the time proven to be enough (a past answer)
  instead of the time proven to be too short (a past silence): in game the
  first automatic request went out at +871 s, stayed unanswered for 5
  minutes, and the retry was answered at once.
- Opportunities: after /reload an empty list said "No data yet: open the
  Auction House and press Scan" even right after a scan; it now says the
  last scan found nothing worth buying.
- Crafting tab: the summary shows its second line (recipes priced, merchant
  prices known); it was cut off after the professions.
- The banner no longer announces a gain as available when you cannot pay
  for any of its offers ("but none you can pay for with your gold"), and
  says how many are within your gold when only some are.
- The status line always describes the last full AH scan: after /reload or
  a search in the AH window it read "19 auctions read · 1 items" instead of
  the 108,000 rows of the scan.
- Opportunity details: the second button read "1. Get quote" too when no
  purchase could be planned; it now always reads "2. Buy". When the gold is
  not enough, the panel says how much the cheapest lot costs and how much
  gold you have (or that the lot is above your limit per purchase).
- An offer whose search got no answer is no longer hidden as "gone": no
  answer says nothing about the offer.

## [0.1.0-alpha.3] - 2026-11-06

Verified in game on the live build 1.60.1.70790: three full scans (about
158,000 rows, answers after 171–203 s), history and opportunities kept
across `/reload`.

### Changed

- Scan reads an AH replica the client already holds (a late answer or a
  request made outside the add-on) without a new server request; the scan
  button is enabled for it even during the cooldown. A replica already read
  is not read again.
- The replica request waits up to 5 minutes instead of 60 seconds: on the
  live client the server answered after 148 s. An answer that arrives after
  the add-on gave up is recorded and read automatically while the AH is open.
- After a scan, grouping the ~160,000 listings is spread over frames: in
  game it blocked one frame for 214 ms, and saving history another 83 ms.
- The opportunities kept across `/reload` save only the auctions they use
  plus the 50 cheapest per item, instead of every auction of the item: on
  the live server this was 2.3 MB of a 5.2 MB saved file.

### Fixed

- An AH answer arriving after the timeout no longer counts as a silent
  request too: in game a 327 s answer raised the measured cooldown to
  31 minutes. Saved data with that error is repaired on load, and the wait
  never exceeds the longest cooldown already measured (found after the
  alpha.3 check, before any package was built).

### Added

- Performance measurement of every scan phase (replica read, history,
  evaluation): rows, frames, longest frame and total time, saved in
  `ForeverGoldDB.diagnostics.timings`, with the slowest single step and its
  item key.

## [0.1.0-alpha.2] - 2026-10-20

In-game verification on build 1.60.1.70450 and first assisted purchases.

### Added

- Experimental assisted purchase (off by default, Settings): server quote
  for commodities or auction search, then a "Buy: spend X" click enabled only
  if the price does not exceed the plan, the per-purchase limit (default 50
  silver) and the gold available. No timer, no retry; an uncertain outcome is
  recorded for checking.
- Purchase ledger and merchant check: the gold received is compared with the
  units sold; when it matches, the vendor price is recorded as verified on
  this client.
- Commodities recognised (`GetItemKeyInfo`): partial purchase at the unit
  price, exact cost from the order book.
- Gain banner (verified / probable / speculative), rows coloured by class,
  unaffordable rows greyed out, "Verified only" filter, "How to" steps in the
  details.
- Scan feedback in chat and a progress bar.
- Evidence saved with every scan (counts, index base, stack samples, raw
  links, buyout votes).

### Changed

- The add-on is called "Forever Gold" in the AddOns list, window, chat and
  tooltips, and shows its icon in the AddOns list (`## IconTexture`). Folder,
  saved data and `/fg` are unchanged.
- AH fee (5.00%) and deposit verified in game with 20 Copper Bars: the fee
  is no longer a scenario (default `feeBp` 500, verified), the deposit paid
  matched the server quote at posting and was refunded with the sale.
- AH durations shown as 2 / 8 / 24 h, as in the Forever AH window (they
  were reported as 12 / 24 / 48 h).
- Item key includes bonus IDs: on Forever item variants arrive that way.
- Full scan: no automatic re-request; the measured cooldown is used to avoid
  pointless requests.
- "Verified" requires both auction buyout and vendor price proven in game.
- Plain-language interface: "What to do / You pay / You get / Gain /
  Reliability" columns, a hint line saying what to do next, status line and
  footer without jargon, row tooltips, an "Enable" button for assisted
  purchases right in the details.
- Variants of the same item merged into one vendor row; vendor margins below
  25 copper or 5% hidden (configurable; schema migration 2).
- Selectable language: `/fg lang it|en|auto` or Settings.
- The last opportunity list survives `/reload` and relog; cooldown countdown
  on the scan button and in the hint line.
- Vendor price verified in game (first assisted purchase: +1s 60c): complete
  vendor opportunities show as "VERIFIED".
- Shorter details; "Prepare" and "Refresh quote" buttons removed; a single
  chat summary per scan, with the final count.
- "Buy all" replaces "Demo" (still available as `/fg demo`): queues vendor
  offers best first, prepares quotes and searches by itself, skips offers
  that vanished or got dearer and stops at the spending limit or on an
  uncertain outcome. Each purchase is still one click on the same button, as
  the game requires.
- "Buy all" fixes after the first run in game: a purchase waits (up to 15 s,
  resuming on the AH ready event) while the AH throttle is busy instead of
  being skipped; each offer is skipped at most once and a pending quote is no
  longer cancelled by the queue; offers already found gone stay out of the
  queue; variant items (bonus IDs) are searched with their item level.
- Variant items the direct search cannot reach are located like the native
  AH window does: a browse by name returns the server's exact item keys, then
  each key of the same item is searched (at most 5); keys are traced.
- Merchant purchases accept a lot with more units at no higher price, once
  the meaning of multi-unit item-search prices is verified; until then such
  lots stay excluded (a lower `PlaceBid` could become a bid).
- Variant items are searched directly with Forever's key (effective item
  level, item suffix = bonus ID + 1580, measured with the AH search test).
- Guided fee and deposit test (Settings, `/fg feetest [itemID]`, default
  Copper Bar): the player posts the item from the native AH window; the
  add-on records the server's deposit quotes, measures the deposit paid,
  reads the seller invoices in the mailbox and computes the real AH fee,
  which then replaces the 5% scenario. Nothing is posted by the add-on.
  When the deposit paid matches several quotes (small lots hit the minimum
  deposit, e.g. 100 copper for both 2 and 8 h), all matching durations are
  reported and none is recorded as the posting duration.
- Multi-unit item-search rows priced per unit (verified in game: the search
  groups single auctions at one price); they are observed, not bought.
- Smaller saved data: one detailed observation per item and at most 8
  interval prices per item and day (the saved file had reached 7.9 MB; the
  new pruning cuts the estimate from 11.3 to 4.3 MB); old saves are trimmed
  on load.
- AH search test also probes items with several single auctions at the
  same price (the search may group them) and votes per lot / per unit.
- AH search test also probes stackable non-commodity items and records
  same-price rows with another lot size; purchase-related client events are
  traced while a purchase is in progress.
- "AH search test" (Settings, `/fg probe`): read-only probe of variant items
  (built key, browse by name, server keys) and of multi-unit lots (replicate
  vs item search, per-lot / per-unit votes), saved in the diagnostics.
- Portfolio tab as a table: cards with realized gain, spent, received and
  value still to sell; purchases table (date, item, quantity, paid, sold,
  received, gain, in bags, status).
- History tab as a table: summary, scans table and recorded-prices table
  (reference, days of data, lowest, on sale); export/import in a box that
  opens only when needed.

## [0.1.0-alpha.1] - 2026-10-20

First analysis-only alpha, **not verified in game**.

### Added

- Pure economic core: money as integer copper without turning `nil` into
  zero, depth by price levels, profit/ROI/break-even with prudent rounding,
  refunded and lost deposits, labelled confidence score.
- Vendor and AH resale strategies with configurable thresholds (15% ROI,
  10 silver) declared as product choices; disenchant, crafting and
  conversions as pure functions with ranking disabled.
- Read-only scanner with a state machine, generations, timeouts, bounded
  retries with backoff, chunked reading within a per-frame budget, passive
  observation of the player's own searches, targeted search to refresh a
  quote.
- Local history per market and variant with retention, validated text
  import/export, versioned migrations on a copy.
- Native UI (Opportunities, History, Professions, Portfolio, Settings),
  details with the expanded formula, labelled demo mode, tooltips, enUS and
  itIT localisation.
- `/fg diagnostics` with a saved report and a bounded event trace.
- MIT license.
- Offline tests (economy, scanner replay, app, UI on mocks, package, bytecode
  globals lint), benchmark, PowerShell build with checksum.
