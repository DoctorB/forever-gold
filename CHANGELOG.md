# Changelog

Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), SemVer versions.

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
