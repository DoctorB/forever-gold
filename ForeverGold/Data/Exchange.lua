-- Exchange: manual export/import of daily history through a text box.
-- Plain line format, parsed with patterns only: never loadstring, never Lua.
--   FGX1 <marketKey>
--   <itemKey> <day> <price> <depth>
-- Import validates every line before writing anything and never overwrites
-- local days; any error leaves the database untouched.
local _, ns = ...

local Money = ns.Economy.Money
local Exchange = {}
ns.Data.Exchange = Exchange

Exchange.HEADER = "FGX1"
Exchange.MAX_BYTES = 256 * 1024
Exchange.MAX_LINES = 20000

function Exchange.Export(store, marketKey)
  local market = store:Market(marketKey, false)
  local lines = { Exchange.HEADER .. " " .. marketKey }
  if market then
    local keys = {}
    for itemKey in pairs(market.items) do keys[#keys + 1] = itemKey end
    table.sort(keys)
    for _, itemKey in ipairs(keys) do
      local days = {}
      for day in pairs(market.items[itemKey].days) do days[#days + 1] = day end
      table.sort(days)
      for _, day in ipairs(days) do
        local bucket = market.items[itemKey].days[day]
        if bucket.price then
          lines[#lines + 1] = string.format("%s %d %d %d", itemKey, day, bucket.price, bucket.depthMedian or 0)
        end
      end
    end
  end
  return table.concat(lines, "\n")
end

-- Returns report { ok, error?, line?, added, skipped }.
function Exchange.Import(store, text, expectedMarketKey)
  if type(text) ~= "string" then return { ok = false, error = "not_text" } end
  if #text > Exchange.MAX_BYTES then return { ok = false, error = "too_large" } end
  local rows, lineNo, marketKey = {}, 0, nil
  for line in (text .. "\n"):gmatch("([^\n]*)\n") do
    line = line:gsub("\r$", "")
    lineNo = lineNo + 1
    if lineNo > Exchange.MAX_LINES + 1 then return { ok = false, error = "too_many_lines" } end
    if lineNo == 1 then
      marketKey = line:match("^" .. Exchange.HEADER .. " (m%d+|.+)$")
      if not marketKey then return { ok = false, error = "bad_header", line = 1 } end
      if expectedMarketKey and marketKey ~= expectedMarketKey then
        return { ok = false, error = "other_market", line = 1 }
      end
    elseif line:match("%S") then
      local itemKey, day, price, depth = line:match("^(%S+) (%d+) (%d+) (%d+)$")
      day, price, depth = tonumber(day), tonumber(price), tonumber(depth)
      if not ns.Data.Schema.IsItemKey(itemKey) or not day or day > 1000000 or not Money.IsCopper(price) or price == 0
        or not Money.IsQuantity(depth + 1) then
        return { ok = false, error = "bad_line", line = lineNo }
      end
      rows[#rows + 1] = { itemKey = itemKey, day = day, price = price, depth = depth }
    end
  end
  if not marketKey then return { ok = false, error = "bad_header", line = 1 } end
  local market = store:Market(marketKey, true)
  local added, skipped = 0, 0
  for _, row in ipairs(rows) do
    local item = market.items[row.itemKey]
    if not item then
      item = { days = {}, recent = {}, imported = true }
      market.items[row.itemKey] = item
      market.itemCount = (market.itemCount or 0) + 1
    end
    if item.days[row.day] then
      skipped = skipped + 1
    else
      item.days[row.day] = { p = { row.price }, depth = { row.depth }, partial = 0, price = row.price,
        depthMedian = row.depth, imported = true }
      added = added + 1
    end
  end
  return { ok = true, added = added, skipped = skipped, marketKey = marketKey }
end
