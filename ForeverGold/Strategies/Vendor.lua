-- Vendor arbitrage: buy on the AH, sell to an NPC (spec 9.1).
--   profitVendor = quantity * vendorUnitPrice - B - otherRealCosts
-- No AH fee applies to an NPC sale. Selling stays manual in the MVP.
local _, ns = ...

local Money = ns.Economy.Money
local Risk = ns.Economy.Risk
local Vendor = { id = "vendor" }
ns.Strategies.Vendor = Vendor

-- One lot: returns profit or nil, reason.
function Vendor.LotProfit(quantity, buyoutTotal, sellPrice, otherCosts)
  if not Money.IsQuantity(quantity) then return nil, "quantity" end
  if not Money.IsCopper(buyoutTotal) or buyoutTotal == 0 then return nil, "no_buyout" end
  if sellPrice == nil then return nil, "sell_price_unknown" end
  if not Money.IsCopper(sellPrice) then return nil, "sell_price_invalid" end
  if sellPrice == 0 then return nil, "not_vendorable" end
  local revenue = Money.Mul(sellPrice, quantity)
  if not revenue then return nil, "out_of_range" end
  return revenue - buyoutTotal - (otherCosts or 0), revenue
end

local function count(tally, reason)
  tally[reason] = (tally[reason] or 0) + 1
end

-- context: { items = { [itemKey] = { listings, info } }, settings, scan, semantics }
-- Returns opportunities, exclusion tally.
function Vendor.Evaluate(context)
  local settings = context.settings or {}
  -- Per lot only "positive"; totals are filtered after variants are merged
  -- (Services/Opportunities.MergeVendor).
  local minProfit = 1
  local opportunities, excluded = {}, {}
  for itemKey, entry in pairs(context.items or {}) do
    local info = entry.info
    local sellPrice = info and info.sellPrice
    local lots, cost, revenue, units = {}, 0, 0, 0
    for _, listing in ipairs(entry.listings or {}) do
      if not listing.buyable then
        count(excluded, listing.buyoutTotal and "incomplete" or "no_buyout")
      else
        -- A commodity level is linear in units: buying all of it maximises
        -- profit when its per-unit margin is positive.
        local quantity, total = listing.quantity, listing.buyoutTotal
        local profit, reason = Vendor.LotProfit(quantity, total, sellPrice)
        if not profit then
          count(excluded, reason)
        elseif profit >= minProfit then
          lots[#lots + 1] = { listing = listing, quantity = quantity, cost = total, profit = profit }
          cost = cost + total
          revenue = revenue + profit + total
          units = units + quantity
        end
      end
    end
    if #lots > 0 then
      -- "Confirmed" needs both client meanings proven in game: the buyout
      -- (stack total) and the vendor price.
      local semantics = context.semantics or {}
      local verified = semantics.buyoutVerified == true and semantics.sellPriceVerified == true
      local scan = context.scan or {}
      local confidence = Risk.Confidence({
        ageSeconds = scan.ageSeconds, partial = scan.partial, semanticsVerified = verified,
      })
      opportunities[#opportunities + 1] = {
        strategy = Vendor.id,
        itemKey = itemKey,
        name = info and info.name,
        class = verified and "vendor_confirmed" or "prudent",
        quantity = units,
        cost = cost,
        revenuePrudent = revenue,
        revenueBase = revenue,
        profit = revenue - cost,
        roi = cost > 0 and (revenue - cost) / cost or nil,
        capital = cost,
        fee = 0,
        lots = lots,
        confidence = confidence,
        constraints = { "manual_vendor_sale", "bag_space", "listing_may_vanish" },
        pending = (not verified) and (semantics.buyoutVerified and "sellPrice" or "buyout") or nil,
        formula = { kind = "vendor", sellPrice = sellPrice, units = units, B = cost },
        provenance = { source = scan.mode, scanId = scan.id, seen = scan.finished },
      }
    end
  end
  return opportunities, excluded
end
