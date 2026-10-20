-- PurchasePanel: the assisted-buying section of the details window.
-- Step 1 asks the server for a quote (or locates the auction) and spends
-- nothing; step 2 is the only button that spends, enabled only when the
-- quote fits the plan, the spending cap and the player's money.
local _, ns = ...

local W = ns.UI.Widgets
local Money = ns.Economy.Money
local PurchasePanel = {}
ns.UI.PurchasePanel = PurchasePanel

local function L(key) return ns.L[key] or key end
local fmt = Money.Format

local function reasonText(reason)
  if not reason then return "" end
  local key = tostring(reason):match("^([%w_]+)")
  return ns.L["PR_" .. key] or ns.L["REASON_" .. key] or tostring(reason)
end

-- Pure view model: text and button states for the current situation.
-- view: { enabled, demo, ahOpen, current, beginError, money, cap, quoteLeft }
function PurchasePanel.Model(view)
  local model = { quote = false, buy = false, cancel = false, quoteLabel = L("PB_QUOTE") }
  if not view.enabled then
    model.text = L("PB_DISABLED")
    model.quote, model.quoteLabel, model.enable = true, L("PB_ENABLE"), true
    return model
  end
  if view.demo then
    model.text = L("PB_DEMO")
    return model
  end
  if not view.ahOpen then
    model.text = L("PB_AH_CLOSED")
    return model
  end
  local current = view.current
  if not current then
    model.text = L("PB_CANNOT") .. " " .. reasonText(view.beginError)
    return model
  end
  local plan = current.plan
  local name = plan.name or plan.itemKey
  local lines = {}
  if plan.kind == "commodity" then
    lines[#lines + 1] = string.format(L("PB_PLAN_COMMODITY"), plan.quantity, name, fmt(plan.expectedTotal), fmt(plan.unitMax))
  else
    model.quoteLabel = L("PB_LOCATE")
    lines[#lines + 1] = string.format(L("PB_PLAN_AUCTION"), plan.quantity, name, fmt(plan.expectedTotal))
  end
  if plan.expectedProfit then
    local profit = fmt(plan.expectedProfit)
    if plan.expectedProfit > 0 then profit = W.Color("+" .. profit, W.EMERALD) end
    lines[#lines + 1] = string.format(L(plan.strategy == "vendor" and "PB_GAIN_VENDOR" or "PB_GAIN_RESALE"),
      fmt(plan.expectedRevenue), profit)
  end
  lines[#lines + 1] = string.format(L("PB_LIMITS"), fmt(view.cap), fmt(view.money))
  local state = current.state
  if state == "planned" then
    model.quote, model.cancel = true, true
  elseif state == "quoting" or state == "locating" then
    lines[#lines + 1] = L("PB_WAIT")
    model.cancel = true
  elseif state == "quoted" then
    lines[#lines + 1] = W.Color(string.format(L("PB_QUOTED"), fmt(current.quote.total), fmt(current.quote.unit),
      view.quoteLeft or 0), W.EMERALD)
    model.buy, model.cancel = true, true
    model.buyLabel = string.format(L("PB_BUY"), fmt(current.quote.total))
  elseif state == "located" then
    lines[#lines + 1] = W.Color(string.format(L("PB_LOCATED"), fmt(current.auction.amount)), W.EMERALD)
    model.buy, model.cancel = true, true
    model.buyLabel = string.format(L("PB_BUY"), fmt(current.auction.amount))
  elseif state == "confirming" then
    lines[#lines + 1] = L("PB_CONFIRMING")
  elseif state == "done" then
    lines[#lines + 1] = W.Color(string.format(L("PB_DONE"), plan.quantity, name, fmt(view.paid or plan.expectedTotal),
      fmt(plan.expectedRevenue)), W.EMERALD)
  elseif state == "uncertain" then
    lines[#lines + 1] = W.Color(L("PB_UNCERTAIN"), W.WARN)
  else
    lines[#lines + 1] = W.Color(L("PB_STOPPED") .. " " .. reasonText(current.reason), W.WARN)
  end
  model.text = table.concat(lines, "\n")
  model.buyLabel = model.buyLabel or string.format(L("PB_BUY"), fmt(plan.expectedTotal))
  return model
end

function PurchasePanel.Build(frame)
  local section = CreateFrame("Frame", nil, frame)
  section:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 12, 12)
  section:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -12, 12)
  section:SetHeight(140)
  local title = W.Text(section, "GameFontNormal")
  title:SetPoint("TOPLEFT", section, "TOPLEFT", 0, 0)
  title:SetText(L("PB_TITLE"))
  local text = W.Text(section, "GameFontHighlightSmall")
  if text.SetWordWrap then text:SetWordWrap(true) end
  if text.SetJustifyV then text:SetJustifyV("TOP") end
  text:SetPoint("TOPLEFT", title, "BOTTOMLEFT", 0, -4)
  text:SetPoint("RIGHT", section, "RIGHT", 0, 0)
  text:SetHeight(84)
  section.text = text
  section.quote = W.Button(section, L("PB_QUOTE"), 130, function() PurchasePanel.Primary() end)
  section.quote:SetPoint("BOTTOMLEFT", section, "BOTTOMLEFT", 0, 0)
  section.buy = W.Button(section, L("PB_QUOTE"), 170, function() ns.app.purchases:Confirm() end)
  section.buy:SetPoint("LEFT", section.quote, "RIGHT", 6, 0)
  section.cancel = W.Button(section, L("BTN_CANCEL"), 80, function() ns.app.purchases:Cancel("user") end)
  section.cancel:SetPoint("LEFT", section.buy, "RIGHT", 6, 0)
  frame.purchase = section
  return section
end

local function view()
  local app = ns.app
  local settings = app.store:Settings()
  local current = app.purchases.current
  local paid
  if current and current.ledgerIndex then paid = app.store.db.ledger[current.ledgerIndex].cost end
  return {
    enabled = settings.assistedBuy == true, demo = ns.UI.Main.demoResults ~= nil, ahOpen = app.ah:IsOpen(),
    current = current, beginError = PurchasePanel.beginError, money = app.client:Money(), cap = settings.maxPurchase,
    quoteLeft = current and current.state == "quoted" and app.purchases.purchase:QuoteRemaining() or nil, paid = paid,
  }
end

function PurchasePanel.Update()
  local frame = ns.UI.Details.frame
  local section = frame and frame.purchase
  if not section then return end
  local model = PurchasePanel.Model(view())
  section.text:SetText(model.text)
  section.quote:SetText(model.quoteLabel)
  section.quote:SetEnabled(model.quote)
  section.buy:SetText(model.buyLabel or L("PB_QUOTE"))
  section.buy:SetEnabled(model.buy)
  section.cancel:SetEnabled(model.cancel)
end

-- First button: enables assisted purchases when off, otherwise step 1
-- (quote or locate). Never spends.
function PurchasePanel.Primary()
  local app = ns.app
  local settings = app.store:Settings()
  if not settings.assistedBuy then
    settings.assistedBuy = true
    if ns.UI.Details.current then PurchasePanel.Show(ns.UI.Details.current) end
    ns.UI.Main.RefreshTable()
    return
  end
  app.purchases:Prepare()
end

-- A new opportunity in the details window: plan it (spends nothing).
function PurchasePanel.Show(opportunity)
  local app = ns.app
  local settings = app.store:Settings()
  PurchasePanel.beginError = nil
  local current = app.purchases.current
  local sameItem = current and current.plan.itemKey == opportunity.itemKey
  local busy = current and (current.state == "confirming" or current.state == "done" or current.state == "uncertain")
  if settings.assistedBuy and app.ah:IsOpen() and not ns.UI.Main.demoResults and not (sameItem and busy) then
    local started, reason = app.purchases:Begin(opportunity, settings.maxPurchase)
    if not started then PurchasePanel.beginError = reason end
  end
  PurchasePanel.Update()
end

-- Rejections that mean the offer in the list no longer exists as shown.
PurchasePanel.STALE_REASONS = { lot_gone = true, price_up = true, unavailable = true, no_answer = true }

function PurchasePanel.Attach(app)
  app.bus:Subscribe("purchase.state", function(current)
    PurchasePanel.Update()
    if current and current.state == "done" then
      local plan = current.plan
      ns.Print(string.format(L("PB_DONE_CHAT"), plan.quantity, plan.name or plan.itemKey,
        fmt(app.store.db.ledger[current.ledgerIndex].cost)))
      app.opportunities:Consume(plan, current.auction)
      app:EvaluateChunked()
    elseif current and current.state == "uncertain" then
      ns.Print(L("PB_UNCERTAIN"))
    elseif current and current.state == "rejected" and PurchasePanel.STALE_REASONS[current.reason] then
      app.opportunities:MarkStale(current.plan.itemID)
      app:EvaluateChunked()
    end
  end)
  app.bus:Subscribe("vendor.check", function(report)
    local line = string.format(L("VC_REPORT"), fmt(report.gained), report.sold, fmt(report.expected))
    if report.match then
      line = line .. " " .. W.Color(string.format(L("VC_MATCH"), fmt(report.profit)), W.EMERALD)
      if report.verifiedNow then line = line .. " " .. L("VC_VERIFIED") end
    else
      line = line .. " " .. L("VC_MISMATCH")
    end
    ns.Print(line)
    app:EvaluateChunked()
  end)
end
