-- Merchant adapter: read-only view of the open merchant window, to price
-- the reagents only merchants sell (thread, flux, spices, water...).
-- Which API Forever exposes is not verified: Read() tries the modern
-- C_MerchantFrame.GetItemInfo (a table) and the classic GetMerchantItemInfo
-- (positional values), and keeps the raw shape of the first rows as
-- evidence. Nothing is bought, sold, bought back or repaired here.
local _, ns = ...

local Money = ns.Economy.Money
local Merchant = {}
ns.Compat.Merchant = Merchant

Merchant.MAX_ITEMS = 300
Merchant.SAMPLES = 3

Merchant.SYMBOLS = {
  { nil, "GetMerchantNumItems" }, { nil, "GetMerchantItemInfo" }, { nil, "GetMerchantItemID" },
  { nil, "GetMerchantItemLink" }, { "C_MerchantFrame", "GetItemInfo" }, { "C_MerchantFrame", "GetNumJunkItems" },
}

function Merchant.New(client)
  return setmetatable({ client = client }, { __index = Merchant })
end

local function plain(client, value)
  if client:IsSecret(value) then return nil end
  local kind = type(value)
  if kind == "number" or kind == "boolean" or kind == "string" then return value end
  return nil
end

-- One merchant row: { itemID, name, price, stack, available, purchasable, extended }.
function Merchant:Row(index)
  local c = self.client
  local row = {}
  if c:Lookup("C_MerchantFrame", "GetItemInfo") then
    local ok, info = c:Call("C_MerchantFrame", "GetItemInfo", index)
    if ok and type(info) == "table" then
      row.name, row.price, row.stack = plain(c, info.name), plain(c, info.price), plain(c, info.stackCount)
      row.available, row.purchasable = plain(c, info.numAvailable), plain(c, info.isPurchasable)
      row.extended = plain(c, info.hasExtendedCost)
    end
  end
  if row.price == nil then
    local ok, name, _, price, quantity, available, purchasable, _, extended = c:Call(nil, "GetMerchantItemInfo", index)
    if ok then
      row.name, row.price, row.stack = plain(c, name), plain(c, price), plain(c, quantity)
      row.available, row.purchasable, row.extended = plain(c, available), plain(c, purchasable), plain(c, extended)
    end
  end
  local okID, itemID = c:Call(nil, "GetMerchantItemID", index)
  row.itemID = okID and plain(c, itemID) or nil
  if type(row.itemID) ~= "number" then
    local okLink, link = c:Call(nil, "GetMerchantItemLink", index)
    local id = okLink and type(link) == "string" and link:match("item:(%d+)")
    row.itemID = id and tonumber(id) or nil
  end
  return row
end

-- Gold price per unit, rounded up, or nil with a reason. Only offers paid in
-- gold with an unlimited supply are used for crafting.
function Merchant.UnitPrice(row)
  if type(row.itemID) ~= "number" then return nil, "no_item_id" end
  if row.extended == true then return nil, "extended_cost" end
  if not Money.IsCopper(row.price) or row.price <= 0 then return nil, "no_price" end
  local stack = (type(row.stack) == "number" and row.stack > 0) and row.stack or 1
  if type(row.available) == "number" and row.available >= 0 then return nil, "limited" end
  return Money.DivCeil(row.price, stack)
end

-- Reads the open merchant window. Returns { prices = { [itemID] = unit },
-- rows, skipped = { reason = n }, symbols, samples } or nil, "no_merchant".
function Merchant:Read()
  local c = self.client
  local ok, count = c:Call(nil, "GetMerchantNumItems")
  if not ok or type(count) ~= "number" or count <= 0 then return nil, "no_merchant" end
  local report = { prices = {}, rows = 0, skipped = {}, symbols = {}, samples = {} }
  for _, symbol in ipairs(Merchant.SYMBOLS) do
    report.symbols[(symbol[1] and (symbol[1] .. ".") or "") .. symbol[2]] = c:Lookup(symbol[1], symbol[2]) ~= nil
  end
  for index = 1, math.min(count, Merchant.MAX_ITEMS) do
    local row = self:Row(index)
    report.rows = report.rows + 1
    if #report.samples < Merchant.SAMPLES then
      report.samples[#report.samples + 1] = row
      if c:Lookup("C_MerchantFrame", "GetItemInfo") then
        local okInfo, info = c:Call("C_MerchantFrame", "GetItemInfo", index)
        row.raw = okInfo and ns.Compat.Professions.Capture(c, info, 1, 20) or nil
      end
    end
    local unit, reason = Merchant.UnitPrice(row)
    if unit then
      local known = report.prices[row.itemID]
      if not known or unit < known then report.prices[row.itemID] = unit end
    else
      report.skipped[reason] = (report.skipped[reason] or 0) + 1
    end
  end
  return report
end
