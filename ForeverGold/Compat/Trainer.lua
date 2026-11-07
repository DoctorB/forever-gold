-- Trainer adapter: read-only view of the open trainer window, for the skill
-- each profession recipe requires and what it costs to learn. The recipe
-- window gives only the level where a recipe turns grey (maxTrivialLevel);
-- the trainer lists the exact requirement. Which API Forever exposes is not
-- verified: Read() uses the classic GetTrainerService* functions and keeps
-- the raw shape of the first rows as evidence. Nothing is learned here.
local _, ns = ...

local Trainer = {}
ns.Compat.Trainer = Trainer

Trainer.MAX_SERVICES = 400
Trainer.SAMPLES = 3

Trainer.SYMBOLS = {
  { nil, "GetNumTrainerServices" }, { nil, "GetTrainerServiceInfo" }, { nil, "GetTrainerServiceSkillReq" },
  { nil, "GetTrainerServiceCost" }, { nil, "GetTrainerServiceSkillLine" },
}

function Trainer.New(client)
  return setmetatable({ client = client }, { __index = Trainer })
end

local function plain(client, value)
  if client:IsSecret(value) then return nil end
  local kind = type(value)
  if kind == "number" or kind == "boolean" or kind == "string" then return value end
  return nil
end

-- Returns { services, rows = { { name, kind, skillName, skill, cost } }, samples, symbols }
-- or nil, reason.
function Trainer:Read()
  local c = self.client
  local symbols = {}
  for _, symbol in ipairs(Trainer.SYMBOLS) do
    symbols[(symbol[1] and (symbol[1] .. ".") or "") .. symbol[2]] = c:Lookup(symbol[1], symbol[2]) ~= nil
  end
  local ok, count = c:Call(nil, "GetNumTrainerServices")
  count = ok and plain(c, count) or nil
  if type(count) ~= "number" then return nil, "no_api" end
  local report = { services = count, rows = {}, samples = {}, symbols = symbols }
  for index = 1, math.min(count, Trainer.MAX_SERVICES) do
    local okInfo, name, subText, kind = c:Call(nil, "GetTrainerServiceInfo", index)
    name, kind = okInfo and plain(c, name) or nil, okInfo and plain(c, kind) or nil
    -- On Forever the second value is the icon and the third the type
    -- ("available"...): seen in game 2026-11-07 (kind 134401, subText "available").
    if type(kind) == "number" and type(subText) == "string" then kind, subText = subText, kind end
    if type(name) == "string" and kind ~= "header" then
      local okReq, skillName, skill, hasReq = c:Call(nil, "GetTrainerServiceSkillReq", index)
      local okCost, cost = c:Call(nil, "GetTrainerServiceCost", index)
      local row = { name = name, kind = kind,
        skillName = okReq and plain(c, skillName) or nil, skill = okReq and plain(c, skill) or nil,
        cost = okCost and plain(c, cost) or nil }
      if type(row.skillName) ~= "string" then
        local okLine, line = c:Call(nil, "GetTrainerServiceSkillLine", index)
        row.skillName = okLine and plain(c, line) or nil
      end
      report.rows[#report.rows + 1] = row
      if #report.samples < Trainer.SAMPLES then
        report.samples[#report.samples + 1] = { name = name, subText = okInfo and plain(c, subText) or nil, kind = kind,
          skillName = row.skillName, skill = row.skill, hasReq = okReq and plain(c, hasReq) or nil, cost = row.cost }
      end
    end
  end
  return report
end
