-- Offline test runner. Plain Lua 5.1, no dependencies.
--   lua5.1 tests/runner.lua            run every suite
--   lua5.1 tests/runner.lua scanner    run suites whose name contains "scanner"
-- Addon files are loaded in TOC order with the client's (addonName, ns)
-- vararg contract, each into a fresh namespace per T.LoadAddon call.
-- Mocks prove our logic only, never the behaviour of the real server.

local ROOT = (arg and arg[0] or ""):match("^(.*)[/\\]tests[/\\]runner%.lua$") or "."
local ADDON_DIR = ROOT .. "/ForeverGold"

T = { ROOT = ROOT, ADDON_DIR = ADDON_DIR, passed = 0, failed = 0, failures = {} }

local function readFile(path)
  local handle, err = io.open(path, "rb")
  if not handle then error(err) end
  local data = handle:read("*a")
  handle:close()
  return data
end
T.ReadFile = readFile

function T.TocEntries()
  local toc = readFile(ADDON_DIR .. "/ForeverGold.toc")
  local entries, fields = {}, {}
  for line in (toc .. "\n"):gmatch("([^\r\n]*)\r?\n") do
    local key, value = line:match("^## ([%w%-_]+):%s*(.-)%s*$")
    if key then
      fields[key] = value
    elseif line:match("%S") and not line:match("^#") then
      entries[#entries + 1] = (line:gsub("^%s+", ""):gsub("%s+$", ""))
    end
  end
  return entries, fields
end

-- options.locale: forces itIT etc.; options.globals: temporary globals
-- visible while files load (removed afterwards unless options.keepGlobals).
function T.LoadAddon(options)
  options = options or {}
  local ns = { forceLocale = options.locale }
  local saved = {}
  for key, value in pairs(options.globals or {}) do
    saved[key] = _G[key]
    _G[key] = value
  end
  local entries = T.TocEntries()
  for index = 1, #entries do
    local path = ADDON_DIR .. "/" .. entries[index]:gsub("\\", "/")
    local chunk, err = loadfile(path)
    if not chunk then error(err) end
    chunk("ForeverGold", ns)
  end
  if not options.keepGlobals then
    for key in pairs(options.globals or {}) do _G[key] = saved[key] end
  end
  ns.printed = {}
  ns.outputFrame = { AddMessage = function(_, line) ns.printed[#ns.printed + 1] = line end }
  return ns
end

local currentSuite = "?"

function T.Case(name, fn)
  local ok, err = pcall(fn)
  if ok then
    T.passed = T.passed + 1
  else
    T.failed = T.failed + 1
    T.failures[#T.failures + 1] = currentSuite .. " :: " .. name .. "\n    " .. tostring(err)
  end
end

local function show(value)
  if type(value) == "string" then return string.format("%q", value) end
  return tostring(value)
end

function T.Eq(actual, expected, message)
  if actual ~= expected then
    error((message or "values differ") .. ": expected " .. show(expected) .. ", got " .. show(actual), 2)
  end
end

function T.Ok(value, message)
  if not value then error(message or "expected a true value", 2) end
end

function T.NotOk(value, message)
  if value then error(message or "expected a false value", 2) end
end

local SUITES = {
  "test_money",
  "test_economy",
  "test_strategies",
  "test_history",
  "test_scanner",
  "test_app",
  "test_ui",
  "test_locales",
  "test_package",
}

local filter = arg and arg[1]
dofile(ROOT .. "/tests/fakes.lua")
for _, suite in ipairs(SUITES) do
  if not filter or suite:find(filter, 1, true) then
    currentSuite = suite
    local before = T.passed + T.failed
    dofile(ROOT .. "/tests/" .. suite .. ".lua")
    print(string.format("%-16s %d checks", suite, T.passed + T.failed - before))
  end
end

for _, failure in ipairs(T.failures) do print("FAIL " .. failure) end
print(string.format("%d passed, %d failed (%s)", T.passed, T.failed, _VERSION))
os.exit(T.failed == 0 and 0 or 1)
