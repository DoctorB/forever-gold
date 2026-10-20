<p align="center">
  <img src="docs/ForeverGold-CurseForge.png" alt="ForeverGold logo" width="160">
</p>

# ForeverGold

Auction House **analysis** add-on for **World of Warcraft: Forever**. It finds
money-making opportunities and explains why they may pay off: effective
price, quantity you can buy, capital, costs, prudent profit, data freshness,
reliability and constraints. **It never buys on its own**: the optional
assisted purchase needs your click for every single purchase. It never
posts or cancels auctions.

> Status: `0.1.0-alpha.2`, alpha partly tested in game on build 1.60.1.70450
> (persistence, full scan, auction prices, vendor prices, assisted purchases
> of commodities and individual auctions). What is verified, and how, is in
> [`docs/API-AUDIT.md`](docs/API-AUDIT.md).

## What it does

- **Vendor arbitrage**: auctions a merchant pays more for than their buyout
  (`quantity × vendor price − buyout`, no AH fee). Margins below 25 copper or
  5% are hidden (configurable); variants of the same item are merged.
- **AH resale**: lots below the local price reference, with real depth (sum
  of the price levels, never "lowest price × quantity"), AH fee (5% scenario
  until measured), deposits, a prudent buffer and a quantity limited by the
  observed liquidity. Without enough history it only shows a scenario.
- **Local price history** per market and item variant: one sample per day,
  7/30-day windows; listed prices and depth, never "sold volume".
- **Assisted purchase** (experimental, off by default): in an opportunity's
  details, "1. Get quote" asks the server for the current price without
  spending; "2. Buy: spend X" is enabled only if the quote fits the plan,
  the spending limit and your gold. After you sell to a merchant, ForeverGold
  compares the gold received with what was expected.
- **Buy all**: queues the vendor offers within the spending limit and
  prepares each purchase by itself; you press the same button once per
  purchase (the game requires a click for every spend).
- **Portfolio**: realized gain, gold spent and received, items still to sell
  and a table of every purchase.
- **Diagnostics** (`/fg diagnostics`): build, API symbols, events, saving.
- Disenchant, crafting and conversions: calculations ready, ranking
  **disabled** until verified data for Forever exists.

## Installation

1. Extract the ZIP into `World of Warcraft\_classic_beta_\Interface\AddOns\`
   (you must end up with `AddOns\ForeverGold\ForeverGold.toc`).
2. Enable ForeverGold in the add-on list.

Backup and rollback: copy `WTF\Account\<account>\SavedVariables\ForeverGold.lua`
before updating; to go back, delete the add-on folder and restore the file.

## Usage

| Command | Effect |
| --- | --- |
| `/fg` | opens/closes the window (Opportunities · History · Professions · Portfolio · Settings) |
| `/fg scan` | read-only full scan; the Auction House must be open (about once every 15 minutes) |
| `/fg cancel` | cancels the scan |
| `/fg diagnostics` | client capability report, saved in the SavedVariables |
| `/fg demo` | fictional data labelled DEMO |
| `/fg probe` | read-only AH search test (variants, multi-unit lots), saved for the audit |
| `/fg lang it` · `en` · `auto` | interface language |
| `/fg reset` | opens History for a confirmed reset |

Typical loop: open the AH, press **Scan AH**, click a green row (or **Buy all**),
press **1. Get quote** then **2. Buy**, sell the items to any merchant, check
the result in **Portfolio**.

The reliability label is a heuristic, **not a probability of profit**. A low
price is not a guaranteed future sale.

## Known limits

- The full scan uses `C_AuctionHouse.ReplicateItems`, available about every
  15 minutes (measured between 14 min 27 s and 15 min 38 s); completeness is
  not declared, so the result stays "partial observation".
- AH fee and deposits are declared scenarios: resale stays speculative.
- Assisted purchase is experimental; selling to merchants and relisting stay
  manual.

## Development

- Offline tests: `lua5.1 tests/runner.lua` (Lua 5.1, no dependencies).
- Benchmark: `lua5.1 tests/bench.lua`.
- Package: `powershell -ExecutionPolicy Bypass -File scripts/build.ps1`
  → `release/ForeverGold-<version>.zip` + `.sha256` + `manifest.json`.
- Texture icon: `scripts/make-icon.ps1` (64×64 TGA from the logo).

Documents: [`docs/STATUS.md`](docs/STATUS.md), [`docs/API-AUDIT.md`](docs/API-AUDIT.md),
[`docs/DECISIONS.md`](docs/DECISIONS.md), [`docs/TESTING-IN-GAME.md`](docs/TESTING-IN-GAME.md).

## License

MIT, see [`LICENSE`](LICENSE).
