-- Package and source rules: TOC completeness, forbidden calls, no spending
-- path, no accidental globals (bytecode listing from luac), versions agree.
local entries, fields = T.TocEntries()

local function listLua()
  local files = {}
  local windows = package.config:sub(1, 1) == "\\"
  local command = windows and ('dir /s /b "' .. T.ADDON_DIR:gsub("/", "\\") .. '\\*.lua" 2>nul')
    or ('find "' .. T.ADDON_DIR .. '" -name "*.lua" -type f')
  local pipe = io.popen(command)
  for line in pipe:lines() do
    local relative = line:gsub("\\", "/"):match("ForeverGold/(.+)$")
    if relative then files[#files + 1] = relative end
  end
  pipe:close()
  table.sort(files)
  return files
end

local tocSet = {}
for _, entry in ipairs(entries) do tocSet[(entry:gsub("\\", "/"))] = true end

T.Case("TOC metadata", function()
  T.Eq(fields.Interface, "16001")
  T.Eq(fields.Title, "ForeverGold")
  T.Eq(fields.SavedVariables, "ForeverGoldDB")
  T.Ok(fields["Notes-itIT"] ~= nil)
  T.Eq(entries[1], "Bootstrap.lua")
  T.Eq(entries[#entries], "Core\\Init.lua")
end)

T.Case("every Lua file is listed in the TOC exactly once, and exists with that case", function()
  local files = listLua()
  T.Ok(#files > 10, "found files")
  local onDisk = {}
  for _, file in ipairs(files) do
    onDisk[file] = true
    T.Ok(tocSet[file], "not in TOC: " .. file)
  end
  local seen = {}
  for _, entry in ipairs(entries) do
    local path = entry:gsub("\\", "/")
    T.NotOk(seen[path], "duplicate " .. path)
    seen[path] = true
    T.Ok(onDisk[path], "TOC entry missing or case differs: " .. path)
  end
end)

local sources = {}
for _, entry in ipairs(entries) do
  local path = entry:gsub("\\", "/")
  sources[path] = T.ReadFile(T.ADDON_DIR .. "/" .. path)
end

-- Comments are stripped so documentation may name what code must not do.
local function code(source)
  return (source:gsub("%-%-%[%[.-%]%]", ""):gsub("%-%-[^\n]*", ""))
end

T.Case("no dynamic code, system libraries or file access", function()
  local forbidden = { "loadstring", "RunScript", "require%s*%(", "dofile", "loadfile", "setfenv", "getfenv",
    "[^%w_]io%.", "[^%w_]os%.", "[^%w_]debug%." }
  for path, source in pairs(sources) do
    local body = code(source)
    for _, pattern in ipairs(forbidden) do
      T.NotOk(body:find(pattern), path .. " uses " .. pattern)
    end
  end
end)

-- Assisted buying may use exactly these, and only in Compat/Purchase.lua.
local PURCHASE_NAMES = { StartCommoditiesPurchase = true, ConfirmCommoditiesPurchase = true, CancelCommoditiesPurchase = true,
  PlaceBid = true }

T.Case("spending calls live only in Compat/Purchase.lua; posting and cancelling nowhere", function()
  local names = { "PlaceBid", "StartCommoditiesPurchase", "ConfirmCommoditiesPurchase", "PostItem", "PostCommodity",
    "ConfirmPostItem", "ConfirmPostCommodity", "CancelAuction", "CancelSell", "CancelCommoditiesPurchase",
    "UseContainerItem", "PickupContainerItem" }
  for path, source in pairs(sources) do
    local body = code(source)
    for _, name in ipairs(names) do
      for position in body:gmatch("()" .. name) do
        -- Allowed only as a row of the diagnostics presence table.
        local lineStart = body:sub(1, position):match(".*()\n") or 1
        local line = body:sub(lineStart, (body:find("\n", position, true) or #body + 1) - 1)
        local presenceRow = path == "Compat/ClientAdapter.lua"
          and line:match('^%s*{ "[%w_.]+", "C_AuctionHouse", "[%w_]+" },%s*$') ~= nil
        local purchaseAdapter = path == "Compat/Purchase.lua" and PURCHASE_NAMES[name]
        T.Ok(presenceRow or purchaseAdapter, path .. " mentions " .. name .. " outside the allowed places")
      end
    end
  end
end)

-- Globals read by the addon: Lua base library plus client symbols. Client
-- APIs are otherwise reached through the adapter's env table.
local ALLOWED_GETS = {
  _G = true, pairs = true, ipairs = true, type = true, tostring = true, tonumber = true, select = true,
  setmetatable = true, pcall = true, error = true, next = true, rawget = true, print = true, unpack = true,
  string = true, table = true, math = true,
  CreateFrame = true, UIParent = true, UISpecialFrames = true, DEFAULT_CHAT_FRAME = true, GetLocale = true,
}

T.Case("bytecode lint: no global writes, only allowed global reads", function()
  local luac = os.getenv("LUAC") or "luac5.1"
  for _, entry in ipairs(entries) do
    local path = entry:gsub("\\", "/")
    local pipe = io.popen(luac .. ' -l -p "' .. T.ADDON_DIR .. "/" .. path .. '" 2>&1')
    local listing = pipe:read("*a")
    pipe:close()
    T.Ok(listing:find("GETGLOBAL", 1, true) or listing:find("main <", 1, true), "luac output for " .. path .. ": " .. listing:sub(1, 200))
    for name in listing:gmatch("SETGLOBAL[^;]*;%s*([%w_]+)") do
      T.Ok(false, path .. " writes global " .. name)
    end
    for name in listing:gmatch("GETGLOBAL[^;]*;%s*([%w_]+)") do
      T.Ok(ALLOWED_GETS[name], path .. " reads global " .. name)
    end
  end
end)

T.Case("versions agree: TOC, runtime, changelog", function()
  local ns = T.LoadAddon()
  T.Eq(ns.VERSION, fields.Version)
  local changelog = T.ReadFile(T.ROOT .. "/CHANGELOG.md")
  local top = changelog:match("\n## %[?([%w%.%-]+)%]?")
  T.Eq(top, fields.Version)
end)

T.Case("verified flags match docs/API-AUDIT.md", function()
  local ns = T.LoadAddon()
  local audit = T.ReadFile(T.ROOT .. "/docs/API-AUDIT.md")
  local marker = audit:match("<!%-%- verified: (.-) %-%->")
  T.Ok(marker, "marker present")
  local documented = {}
  for flag, value in marker:gmatch("([%w_]+)=(%a+)") do documented[flag] = value == "true" end
  for flag, value in pairs(ns.Core.Capabilities.VERIFIED) do
    T.Eq(documented[flag], value, "flag " .. flag)
  end
  for flag in pairs(documented) do T.Ok(ns.Core.Capabilities.VERIFIED[flag] ~= nil, "unknown flag " .. flag) end
end)

T.Case("the spending step is reached only from a button click", function()
  for path, source in pairs(sources) do
    local body = code(source)
    if path ~= "Compat/Purchase.lua" and path ~= "Services/Purchases.lua" then
      T.NotOk(body:find("ConfirmCommodity", 1, true), path .. " reaches ConfirmCommodity")
      T.NotOk(body:find(":Buyout(", 1, true), path .. " reaches Buyout")
    end
    for line in (body .. "\n"):gmatch("([^\n]*)\n") do
      if line:find("purchases:Confirm(", 1, true) then
        T.Eq(path, "UI/PurchasePanel.lua", "Confirm called outside the purchase panel")
        T.Ok(line:find("W.Button(", 1, true), "Confirm only inside a button OnClick: " .. line)
      end
    end
  end
  local scanner = code(sources["Services/Scanner.lua"])
  T.NotOk(scanner:find("purchase", 1, true), "scanner never touches purchases")
end)

T.Case("transaction controller has no path to a client call", function()
  local body = code(sources["Services/Transactions.lua"])
  T.NotOk(body:find("client", 1, true), "no adapter access")
  T.NotOk(body:find("C_AuctionHouse", 1, true))
end)
