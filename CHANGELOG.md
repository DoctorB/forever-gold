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
