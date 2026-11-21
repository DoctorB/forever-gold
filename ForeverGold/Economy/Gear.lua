-- Gear: pure scoring of equipment for the upgrades (Services/GearFinder).
-- A score is the sum of stat x weight (Data/GearWeights); an upgrade is a
-- candidate whose score beats what is worn in its slot: for rings, trinkets
-- the weaker of the two; a two-hand weapon against main hand + off hand.
local _, ns = ...

local Gear = {}
ns.Economy.Gear = Gear

-- Equipment slots (GetInventoryItemLink) per INVTYPE_*.
Gear.SLOTS = {
  INVTYPE_HEAD = { 1 }, INVTYPE_NECK = { 2 }, INVTYPE_SHOULDER = { 3 }, INVTYPE_CHEST = { 5 }, INVTYPE_ROBE = { 5 },
  INVTYPE_WAIST = { 6 }, INVTYPE_LEGS = { 7 }, INVTYPE_FEET = { 8 }, INVTYPE_WRIST = { 9 }, INVTYPE_HAND = { 10 },
  INVTYPE_FINGER = { 11, 12 }, INVTYPE_TRINKET = { 13, 14 }, INVTYPE_CLOAK = { 15 },
  INVTYPE_WEAPON = { 16 }, INVTYPE_WEAPONMAINHAND = { 16 }, INVTYPE_2HWEAPON = { 16 },
  INVTYPE_SHIELD = { 17 }, INVTYPE_WEAPONOFFHAND = { 17 }, INVTYPE_HOLDABLE = { 17 },
  INVTYPE_RANGED = { 18 }, INVTYPE_RANGEDRIGHT = { 18 }, INVTYPE_THROWN = { 18 }, INVTYPE_RELIC = { 18 },
}
Gear.MAIN_HAND, Gear.OFF_HAND = 16, 17

-- Short stat names from a GetItemStats table: { STAMINA = 8, ... }.
function Gear.Stats(raw)
  if type(raw) ~= "table" then return nil end
  local out = {}
  for key, value in pairs(raw) do
    if type(value) == "number" then
      out[(tostring(key):gsub("^ITEM_MOD_", ""):gsub("_SHORT$", ""))] = value
    end
  end
  return out
end

function Gear.Score(stats, weights)
  local score = 0
  for key, value in pairs(stats or {}) do score = score + value * (weights[key] or 0) end
  return score
end

-- What a candidate for `loc` replaces: score and the slot(s) compared.
-- worn: [slot] = { score, stats, name } (missing = empty slot, score 0).
function Gear.Baseline(loc, worn)
  local slots = Gear.SLOTS[loc]
  if not slots then return nil end
  if loc == "INVTYPE_2HWEAPON" then
    local main, off = worn[Gear.MAIN_HAND], worn[Gear.OFF_HAND]
    return (main and main.score or 0) + (off and off.score or 0), { Gear.MAIN_HAND, Gear.OFF_HAND }
  end
  local weakest, weakestSlot
  for _, slot in ipairs(slots) do
    local score = worn[slot] and worn[slot].score or 0
    if not weakest or score < weakest then weakest, weakestSlot = score, slot end
  end
  return weakest, { weakestSlot }
end

-- Stat changes against the replaced item(s), biggest weighted change first:
-- { { key, delta } }.
function Gear.Changes(stats, replaced, weights)
  local delta = {}
  for key, value in pairs(stats or {}) do delta[key] = (delta[key] or 0) + value end
  for _, old in ipairs(replaced) do
    for key, value in pairs(old.stats or {}) do delta[key] = (delta[key] or 0) - value end
  end
  local list = {}
  for key, value in pairs(delta) do
    if value ~= 0 and (weights[key] or 0) ~= 0 then list[#list + 1] = { key = key, delta = value } end
  end
  table.sort(list, function(a, b)
    local wa, wb = math.abs(a.delta * weights[a.key]), math.abs(b.delta * weights[b.key])
    if wa ~= wb then return wa > wb end
    return a.key < b.key
  end)
  return list
end
