-- AH resale: buy cheap lots and relist (spec 9.2).
-- Ranked by prudent profit within constraints, never by the biggest discount.
-- Without a verified fee the opportunity is downgraded to speculative; with
-- insufficient history only a scenario is shown, nothing is ranked.
local _, ns = ...

local Money = ns.Economy.Money
local Depth = ns.Economy.Depth
local Costs = ns.Economy.Costs
local MarketValue = ns.Economy.MarketValue
local Risk = ns.Economy.Risk
local Schema = ns.Data.Schema
local Resale = { id = "resale", MAX_LOTS = 20 }
ns.Strategies.Resale = Resale

Resale.DEFAULT_DEPOSIT_LOSS_BP = 5000 -- scenario: half the deposits lost

local function count(tally, reason)
  tally[reason] = (tally[reason] or 0) + 1
end

-- Per-unit price of a book level, rounded up (a purchase price).
local function unitCost(level)
  if level.divisible then return level.unitPrice end
  return Money.DivCeil(level.buyoutTotal, level.quantity)
end

-- Evaluates buying the k cheapest levels of a sorted book whose prefix sums
-- are given (cost, units). The next level is the sustainable competitor.
-- Returns evaluation table or nil, reason.
function Resale.EvaluatePrefix(book, k, cost, units, entry, settings)
  local nextLevel = book[k + 1]
  local prudent, reason = MarketValue.PrudentResale({
    estimate = entry.estimate, competitor = nextLevel and unitCost(nextLevel) or nil, units = units,
    bufferBp = settings.bufferBp,
  })
  if not prudent then return nil, reason end
  local depositKnown = Money.IsCopper(entry.depositPerUnit)
  local lostDeposits = 0
  if depositKnown then
    local deposits = Money.Mul(entry.depositPerUnit, prudent.sellUnits)
    lostDeposits = Money.ShareUp(deposits, settings.depositLossBp or Resale.DEFAULT_DEPOSIT_LOSS_BP)
  end
  local result, costReason = Costs.Evaluate({ B = cost, R = prudent.prudentGross, feeBp = settings.feeBp, L = lostDeposits, X = 0 })
  if not result then return nil, costReason end
  local base = Costs.Evaluate({ B = cost, R = prudent.baseGross, feeBp = settings.feeBp, L = lostDeposits, X = 0 })
  local used = {}
  for index = 1, k do
    local level = book[index]
    used[index] = { level = level.source, units = level.quantity,
      cost = level.divisible and level.unitPrice * level.quantity or level.buyoutTotal }
  end
  return {
    purchase = { cost = cost, quantity = units, used = used, complete = true },
    prudent = prudent, costs = result, base = base, depositKnown = depositKnown, lostDeposits = lostDeposits,
  }
end

-- Best prefix of the book: the book is sorted once; levels priced at or
-- above the reference cannot add prudent profit and stop the walk.
function Resale.Best(entry, settings, itemCap)
  local book = Depth.Book(entry.listings)
  local best
  local cost, units = 0, 0
  for k = 1, math.min(#book, Resale.MAX_LOTS) do
    local level = book[k]
    if unitCost(level) >= entry.estimate.reference then break end
    cost = cost + (level.divisible and level.unitPrice * level.quantity or level.buyoutTotal)
    units = units + level.quantity
    if itemCap and cost > itemCap then break end
    local evaluation = Resale.EvaluatePrefix(book, k, cost, units, entry, settings)
    if evaluation and (not best or evaluation.costs.profit > best.costs.profit) then best = evaluation end
  end
  return best
end

function Resale.Evaluate(context)
  local settings = context.settings or {}
  local minRoi = (settings.minRoiBp or 1500) / Money.BP
  local minProfit = settings.minProfit or 1000
  local itemCap
  if Money.IsCopper(settings.budget) then
    itemCap = Money.ShareDown(settings.budget, settings.maxItemBp or 1000)
  end
  local opportunities, excluded, scenarios = {}, {}, {}
  for itemKey, entry in pairs(context.items or {}) do
    if Schema.IsVariantUnknown(itemKey) then
      count(excluded, "variant_unknown")
    elseif not entry.estimate or entry.estimate.status ~= "ok" then
      count(excluded, "insufficient_history")
      scenarios[itemKey] = { status = "insufficient_history", lowest = Depth.LowestUnit(entry.listings) }
    else
      local best = Resale.Best(entry, settings, itemCap)
      if not best then
        count(excluded, "no_candidate")
      elseif best.costs.profit < minProfit or not best.costs.roi or best.costs.roi < minRoi then
        count(excluded, "below_threshold")
      else
        local scan = context.scan or {}
        local estimate = entry.estimate
        local capitalBp
        if Money.IsCopper(settings.budget) and settings.budget > 0 then
          capitalBp = math.floor(best.purchase.cost * Money.BP / settings.budget)
        end
        local confidence = Risk.Confidence({
          ageSeconds = scan.ageSeconds, partial = scan.partial, samples = estimate.samples[estimate.window],
          dispersionBp = estimate.dispersionBp, feeVerified = settings.feeVerified == true,
          depositKnown = best.depositKnown, depth = estimate.typicalDepth,
          semanticsVerified = context.semantics and context.semantics.buyoutVerified == true,
          capitalBp = capitalBp,
        })
        local class = "prudent"
        if settings.feeVerified ~= true or not best.depositKnown or confidence.label == "low" then
          class = "speculative"
        end
        local lotsUsed = {}
        for _, use in ipairs(best.purchase.used) do
          lotsUsed[#lotsUsed + 1] = { listing = use.level, quantity = use.units, cost = use.cost }
        end
        opportunities[#opportunities + 1] = {
          strategy = Resale.id,
          itemKey = itemKey,
          name = entry.info and entry.info.name,
          class = class,
          quantity = best.purchase.quantity,
          cost = best.purchase.cost,
          revenuePrudent = best.costs.net,
          revenueBase = best.base and best.base.net,
          profit = best.costs.profit,
          profitBase = best.base and best.base.profit,
          roi = best.costs.roi,
          capital = best.purchase.cost,
          fee = best.costs.fee,
          lots = lotsUsed,
          confidence = confidence,
          constraints = { "relist_manual", "sale_not_guaranteed" },
          formula = {
            kind = "resale", B = best.purchase.cost, R = best.prudent.prudentGross, feeBp = settings.feeBp,
            feeVerified = settings.feeVerified == true, L = best.lostDeposits, X = 0,
            depositKnown = best.depositKnown, breakEven = best.costs.breakEven,
            unitPrice = best.prudent.unitPrice, basePrice = best.prudent.basePrice,
            reference = estimate.reference, window = estimate.window, competitor = best.prudent.competitor,
            sellUnits = best.prudent.sellUnits, residualUnits = best.prudent.residualUnits,
          },
          provenance = { source = scan.mode, scanId = scan.id, seen = scan.finished },
        }
      end
    end
  end
  return opportunities, excluded, scenarios
end
