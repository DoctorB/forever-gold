-- luacheck configuration (CI, informational). The gating lint is the
-- bytecode global check in tests/test_package.lua.
std = "lua51"
max_line_length = 130
unused_args = false

files["ForeverGold"] = {
  read_globals = {
    "CreateFrame", "UIParent", "UISpecialFrames", "DEFAULT_CHAT_FRAME", "GetLocale", "GameTooltip",
  },
}

files["tests"] = {
  globals = { "T", "Fakes", "ForeverGoldDB", "SLASH_FOREVERGOLD1", "SLASH_FOREVERGOLD2" },
}
