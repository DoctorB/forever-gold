-- Home ("To do"): the one screen most players need. A short list of
-- concrete actions, best gain first, each with one button:
--   sell   items from the bags on the AH (Services/Selling, one auction per click)
--   buy    an AH offer a merchant pays more for (Services/Purchases: the
--          first click asks the server, the second buys)
--   craft  a known recipe that pays off (details in the Crafting tab)
-- and, below, up to three recipes worth learning. Everything else (history,
-- settings, tests) is behind the "Advanced" button (UI/Main.lua).
local _, ns = ...

local W = ns.UI.Widgets
local Money = ns.Economy.Money
ns.UI.Panels = ns.UI.Panels or {}
local Home = {}
ns.UI.Panels.home = Home

Home.MAX_ACTIONS = 8
Home.MAX_LEARN = 3
Home.ROW_HEIGHT = 26

local function L(key) return ns.L[key] or key end
local fmt = Money.Format

local function itemName(app, itemID, fallback)
  local info = itemID and app.items and app.items:Read(itemID)
  return (info and info.name) or fallback or ("#" .. tostring(itemID))
end

-- Second line: how fresh the prices are and what happens next.
function Home.Freshness(app)
  local Main = ns.UI.Main
  if Main.progress or (app.scanner and app.scanner:IsActive()) then
    return Main.ProgressText(Main.progress) or (L("PHASE_waiting") .. "...")
  end
  local scan = Main.LastScan(app)
  local parts = {}
  if scan then
    parts[#parts + 1] = string.format(L("HOME_PRICES_AGE"), Main.Age(app.clock() - scan.t))
  else
    parts[#parts + 1] = L("HOME_PRICES_NONE")
  end
  if not app.ah:IsOpen() then
    parts[#parts + 1] = L("HOME_OPEN_AH")
  else
    local kind, seconds = app.autoScan:Status()
    if kind == "waiting" then
      parts[#parts + 1] = string.format(L("HOME_NEXT_SCAN"), Main.Wait(seconds))
    elseif kind == "off" then
      parts[#parts + 1] = L("HOME_AUTO_OFF")
    end
  end
  return table.concat(parts, "  ·  ")
end

-- Button state of a buy action from the purchase in progress.
local function buyButton(app, opportunity, money)
  local current = app.purchases.current
  local mine = current and current.plan and current.plan.itemID == opportunity.itemID
  if mine and (current.state == "locating" or current.state == "quoting" or current.state == "waiting"
    or current.state == "confirming") then
    return L("HOME_BTN_CHECKING"), false, "wait"
  end
  if mine and (current.state == "located" or current.state == "quoted") then
    local amount = current.quote and current.quote.total or (current.auction and current.auction.amount)
    return string.format(L("HOME_BTN_CONFIRM"), fmt(amount or 0)), true, "confirm"
  end
  if not app.ah:IsOpen() then return L("HOME_BTN_BUY"), false, "closed" end
  if not ns.UI.Main.Affordable(opportunity, money) then return L("HOME_BTN_NO_GOLD"), false, "gold" end
  return L("HOME_BTN_BUY"), true, "start"
end

-- Everything the screen shows. Pure apart from the services' reads.
-- { actions = { { kind, text, gain, button, enabled, tip, run } }, learn = {...}, empty }
function Home.Model(app)
  local model = { actions = {}, learn = {} }
  local money = app.client:Money()
  local settings = app.store:Settings()
  -- Sell
  local selling = app.selling
  local plan = selling.plan or selling:Plan()
  local blocked = selling:Blocked()
  for _, lot in ipairs(plan.lots) do
    local text = string.format(L("HOME_SELL"), lot.quantity, lot.name or "?", fmt(lot.unitPrice))
    local enabled = blocked == nil
    local label = L("HOME_BTN_SELL")
    if blocked == "waiting" then label = L("HOME_BTN_CHECKING") end
    model.actions[#model.actions + 1] = {
      kind = "sell", text = text, gain = lot.expected, button = label, enabled = enabled,
      tip = { lot.name or "?", string.format(L("SELL_TIP_PRICE"), fmt(lot.unitPrice),
        lot.lowest and fmt(lot.lowest) or L("SELL_TIP_NO_LISTING")),
        string.format(L("SELL_TIP_GET"), fmt(lot.net), fmt(lot.deposit or 0), fmt(lot.merchant)),
        blocked and L("SELL_BLOCKED_" .. blocked) or L("HOME_TIP_SELL_CLICK") },
      run = function()
        local ok, reason = selling:PostNext(lot.itemID)
        if not ok then ns.Print(L("SELL_FAIL_" .. tostring(reason))) end
      end,
    }
  end
  -- Buy (merchant pays more): offers that are not speculative
  local results = app.opportunities.results
  if results and not results.demo then
    local queue = ns.Services.Batch.Queue(results.list, app.opportunities.stale)
    for _, opportunity in ipairs(queue) do
      local label, enabled, state = buyButton(app, opportunity, money)
      local text = string.format(L("HOME_BUY"), opportunity.quantity, opportunity.name or opportunity.itemKey)
      if state == "gold" then text = text .. "  " .. W.Color(L("HOME_NEEDS_GOLD"), W.MUTED) end
      local tip = ns.UI.Main.RowTooltip(opportunity)
      tip[#tip] = L(state == "confirm" and "HOME_TIP_CONFIRM" or "HOME_TIP_BUY")
      model.actions[#model.actions + 1] = {
        kind = "buy", text = text, gain = opportunity.profit, button = label, enabled = enabled, tip = tip,
        run = function()
          settings.assistedBuy = true -- clicking "Buy" is the consent
          if state == "confirm" then
            app.purchases:Confirm()
          else
            local started, reason = app.purchases:Begin(opportunity, settings.maxPurchase)
            if started then
              app.purchases:Prepare()
            else
              ns.Print(L("PB_CANNOT") .. " " .. (ns.L["PR_" .. tostring(reason)] or tostring(reason)))
            end
          end
        end,
      }
    end
  end
  -- Craft (known recipes) and learn
  local crafting = results and not results.demo and (results.crafting or app.lastCrafting) or nil
  local Professions = ns.UI.Panels.professions
  for _, row in ipairs(crafting and crafting.learned or {}) do
    local run = row.run
    local made = itemName(app, row.outputItemID, row.name)
    local units = run.crafts * (row.quantity or 1)
    local text = string.format(L("HOME_CRAFT"), units, made, L("HOME_EXIT_" .. run.exit))
    if (run.spend or run.cost) == 0 then
      text = text .. "  " .. W.Color(L("HOME_HAVE_ALL"), W.EMERALD)
    else
      text = text .. "  " .. W.Color(string.format(L("HOME_SPEND"), fmt(run.spend or run.cost)), W.MUTED)
    end
    model.actions[#model.actions + 1] = {
      kind = "craft", text = text, gain = run.profit, button = L("HOME_BTN_HOW"), enabled = true,
      tip = Professions.Rows(app, { row })[1].tip,
      run = function() ns.UI.Main.SetAdvanced(true, "professions") end,
    }
  end
  table.sort(model.actions, function(a, b) return a.gain > b.gain end)
  while #model.actions > Home.MAX_ACTIONS do table.remove(model.actions) end
  for index, row in ipairs(crafting and crafting.learnable or {}) do
    if index > Home.MAX_LEARN then break end
    local requires = row.requires
    local how
    if requires and requires.exact then
      how = string.format(L("HOME_LEARN_TRAINER"), row.profession or "?", requires.skill,
        requires.cost and requires.cost > 0 and fmt(requires.cost) or "-")
    else
      how = string.format(L("HOME_LEARN_UNKNOWN"), row.profession or "?")
    end
    model.learn[#model.learn + 1] = {
      text = string.format(L("HOME_LEARN"), row.name or "?", how), gain = row.run.profit,
      tip = Professions.Rows(app, { row })[1].tip,
    }
  end
  if #model.actions == 0 then
    model.empty = L(ns.UI.Main.LastScan(app) and "HOME_EMPTY_NOTHING" or "HOME_EMPTY_NO_DATA")
  end
  return model
end

-- Layout --------------------------------------------------------------------

local function showTip(owner, lines)
  if not lines or type(GameTooltip) ~= "table" then return end
  GameTooltip:SetOwner(owner, "ANCHOR_CURSOR")
  for index, line in ipairs(lines) do
    if index == 1 then GameTooltip:SetText(line) else GameTooltip:AddLine(line, 0.9, 0.9, 0.9, true) end
  end
  GameTooltip:Show()
end

local function hideTip() if type(GameTooltip) == "table" then GameTooltip:Hide() end end

local function newRow(panel, withButton)
  local row = CreateFrame("Frame", nil, panel)
  row:SetHeight(Home.ROW_HEIGHT)
  row:EnableMouse(true)
  local highlight = row:CreateTexture(nil, "HIGHLIGHT")
  highlight:SetAllPoints()
  highlight:SetColorTexture(1, 0.82, 0.2, 0.08)
  row.text = W.Text(row, "GameFontHighlight")
  row.text:SetPoint("LEFT", row, "LEFT", 4, 0)
  row.gain = W.Text(row, "GameFontNormal", "RIGHT")
  row.gain:SetTextColor(W.EMERALD[1], W.EMERALD[2], W.EMERALD[3])
  if withButton then
    row.button = W.Button(row, "", 130, function() if row.action then row.action.run() Home.RefreshNow() end end)
    row.button:SetPoint("RIGHT", row, "RIGHT", 0, 0)
    row.gain:SetPoint("RIGHT", row.button, "LEFT", -12, 0)
  else
    row.gain:SetPoint("RIGHT", row, "RIGHT", -142, 0)
  end
  -- "+63s 9c a batch" was cut at 90 px.
  row.gain:SetWidth(withButton and 90 or 170)
  row.text:SetPoint("RIGHT", row.gain, "LEFT", -8, 0)
  row:SetScript("OnEnter", function() showTip(row, row.tip) end)
  row:SetScript("OnLeave", hideTip)
  return row
end

function Home.Build(panel)
  panel.title = W.Text(panel, "GameFontNormalLarge")
  panel.title:SetPoint("TOPLEFT", panel, "TOPLEFT", 0, 0)
  panel.title:SetText(L("HOME_TITLE"))
  panel.money = W.Text(panel, "GameFontNormal", "RIGHT")
  -- Left of the "Advanced" button (UI/Main.lua), which covered it in game.
  panel.money:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -124, -2)
  panel.fresh = W.Text(panel, "GameFontHighlightSmall")
  panel.fresh:SetPoint("TOPLEFT", panel, "TOPLEFT", 0, -22)
  panel.fresh:SetPoint("RIGHT", panel, "RIGHT", -150, 0)
  panel.scan = W.Button(panel, L("BTN_SCAN"), 140, function()
    ns.UI.Main.demoResults = nil
    ns.UI.Feedback.StartScan(ns.app)
    Home.RefreshNow()
  end)
  panel.scan:SetPoint("TOPRIGHT", panel, "TOPRIGHT", 0, -18)
  panel.gainHeader = W.Text(panel, "GameFontNormalSmall", "RIGHT")
  panel.gainHeader:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -142, -46)
  panel.gainHeader:SetWidth(90)
  panel.gainHeader:SetText(L("HOME_COL_GAIN"))
  panel.rows = {}
  for index = 1, Home.MAX_ACTIONS do
    local row = newRow(panel, true)
    row:SetPoint("TOPLEFT", panel, "TOPLEFT", 0, -60 - (index - 1) * Home.ROW_HEIGHT)
    row:SetPoint("RIGHT", panel, "RIGHT", 0, 0)
    panel.rows[index] = row
  end
  panel.empty = W.Text(panel, "GameFontHighlight", "CENTER")
  panel.empty:SetPoint("TOPLEFT", panel, "TOPLEFT", 0, -100)
  panel.empty:SetPoint("RIGHT", panel, "RIGHT", 0, 0)
  if panel.empty.SetWordWrap then panel.empty:SetWordWrap(true) end
  panel.learnTitle = W.Text(panel, "GameFontNormal")
  panel.learnTitle:SetText(L("HOME_LEARN_TITLE"))
  panel.learn = {}
  for index = 1, Home.MAX_LEARN do
    panel.learn[index] = newRow(panel, false)
  end
  if ns.app and ns.app.bus then
    local function refresh() ns.UI.Main.RefreshPanel("home") end
    for _, topic in ipairs({ "crafting.updated", "selling.updated", "purchase.state", "batch.state" }) do
      ns.app.bus:Subscribe(topic, refresh)
    end
  end
end

function Home.RefreshNow() ns.UI.Main.RefreshPanel("home") end

function Home.Refresh(panel)
  local app = ns.app
  local model = Home.Model(app)
  local money = app.client:Money()
  panel.money:SetText(money and string.format(L("HOME_MONEY"), fmt(money)) or "")
  panel.fresh:SetText(Home.Freshness(app))
  local Main = ns.UI.Main
  local wait = app.scanner:Wait() or 0
  local active = app.scanner:IsActive()
  panel.scan:SetEnabled(app.ah:IsOpen() and not active and wait <= 0)
  panel.scan:SetText(active and L("BTN_SCANNING") or (wait > 0 and string.format(L("BTN_SCAN_WAIT"), Main.Wait(wait)))
    or L("BTN_SCAN"))
  if #model.actions > 0 then panel.gainHeader:Show() else panel.gainHeader:Hide() end
  for index, row in ipairs(panel.rows) do
    local action = model.actions[index]
    row.action, row.tip = action, action and action.tip
    if action then
      row.text:SetText(action.text)
      row.gain:SetText((action.kind == "sell" and "" or "+") .. fmt(action.gain))
      row.button:SetText(action.button)
      row.button:SetEnabled(action.enabled)
      row:Show()
    else
      row:Hide()
    end
  end
  panel.empty:SetText(model.empty or "")
  local below = -60 - math.max(#model.actions, model.empty and 2 or 0) * Home.ROW_HEIGHT - 16
  panel.learnTitle:ClearAllPoints()
  panel.learnTitle:SetPoint("TOPLEFT", panel, "TOPLEFT", 0, below)
  if #model.learn > 0 then panel.learnTitle:Show() else panel.learnTitle:Hide() end
  for index, row in ipairs(panel.learn) do
    local item = model.learn[index]
    row.tip = item and item.tip
    row:ClearAllPoints()
    row:SetPoint("TOPLEFT", panel, "TOPLEFT", 0, below - 18 - (index - 1) * Home.ROW_HEIGHT)
    row:SetPoint("RIGHT", panel, "RIGHT", 0, 0)
    if item then
      row.text:SetText(item.text)
      row.gain:SetText(string.format(L("HOME_PER_RUN"), fmt(item.gain)))
      row:Show()
    else
      row:Hide()
    end
  end
end
