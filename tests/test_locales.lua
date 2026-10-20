local ns = T.LoadAddon()
local en, it = ns.Locales.enUS, ns.Locales.itIT

T.Case("every English key exists in Italian", function()
  local missing = {}
  for key in pairs(en) do
    if rawget(it, key) == nil then missing[#missing + 1] = key end
  end
  table.sort(missing)
  T.Eq(#missing, 0, "missing itIT: " .. table.concat(missing, ", "))
end)

T.Case("no Italian-only keys", function()
  for key in pairs(it) do T.Ok(en[key] ~= nil, "unknown key " .. key) end
end)

T.Case("format placeholders match between locales", function()
  for key, value in pairs(en) do
    local a = select(2, value:gsub("%%[%d%.]*[sdf]", ""))
    local b = select(2, (rawget(it, key) or value):gsub("%%[%d%.]*[sdf]", ""))
    T.Eq(b, a, "placeholders of " .. key)
  end
end)

T.Case("forced itIT locale is selected with English fallback", function()
  local italian = T.LoadAddon({ locale = "itIT" })
  T.Eq(italian.L.TAB_history, "Storico")
  T.Eq(T.LoadAddon().L.TAB_history, "History")
end)

T.Case("every key referenced in code exists", function()
  local missing = {}
  local entries = T.TocEntries()
  for _, entry in ipairs(entries) do
    local source = T.ReadFile(T.ADDON_DIR .. "/" .. entry:gsub("\\", "/"))
    for key in source:gmatch('L%("([A-Z][A-Z0-9_]*)"%)') do
      if en[key] == nil then missing[#missing + 1] = key end
    end
    for key in source:gmatch('L%["([A-Z][A-Z0-9_]*)"%]') do
      if en[key] == nil then missing[#missing + 1] = key end
    end
  end
  T.Eq(#missing, 0, "missing: " .. table.concat(missing, ", "))
end)

T.Case("dynamic keys used by the UI exist", function()
  local groups = {
    STATE_ = { "IDLE", "REQUESTED", "RECEIVING", "NORMALIZING", "COMPLETE", "THROTTLED", "FAILED", "CANCELLED", "PARTIAL" },
    CLASS_ = { "vendor_confirmed", "prudent", "speculative" },
    STRAT_ = { "vendor", "resale", "disenchant", "crafting", "conversion" },
    ALLOC_ = { "allocated", "no_budget", "over_budget", "item_cap", "category_cap" },
    COVERAGE_ = { "full_verified", "full_unverified", "partial", "unknown", "none" },
    QUOTE_ = { "valid", "changed", "expired" },
    TAB_ = ns.UI.Main.TABS,
    LABEL_ = { "high", "medium", "low" },
  }
  for prefix, keys in pairs(groups) do
    for _, key in ipairs(keys) do T.Ok(en[prefix .. key], prefix .. key) end
  end
  for key in pairs(ns.Economy.Risk.PENALTIES) do T.Ok(en["RISK_" .. key], "RISK_" .. key) end
  for _, column in ipairs(ns.UI.Main.COLUMNS) do T.Ok(en["COL_" .. column.key], "COL_" .. column.key) end
  for _, field in ipairs(ns.UI.Settings.FIELDS) do T.Ok(en[field.label], field.label) end
end)
