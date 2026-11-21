-- GearWeights: how much each stat is worth for a class and talent tree, for
-- the equipment upgrades (Services/GearFinder). Stat names are those of
-- C_Item.GetItemStats without "ITEM_MOD_" and "_SHORT" (checked in game
-- 2026-11-21: RESISTANCE0_NAME is armour, DAMAGE_PER_SECOND weapon DPS).
-- Warrior protection: weights chosen by the owner (2026-11-21); the others
-- are plain starting values, to be reviewed with the owner.
local _, ns = ...

local GearWeights = {}
ns.Data.GearWeights = GearWeights

local MELEE_STR = {
  STRENGTH = 1, AGILITY = 0.6, STAMINA = 0.5, CRIT_RATING = 0.8, HIT_RATING = 0.8, ATTACK_POWER = 0.5,
  RESISTANCE0_NAME = 0.02, DAMAGE_PER_SECOND = 3,
}
local MELEE_AGI = {
  AGILITY = 1, STRENGTH = 0.5, STAMINA = 0.4, CRIT_RATING = 0.8, HIT_RATING = 0.8, ATTACK_POWER = 0.5,
  RESISTANCE0_NAME = 0.02, DAMAGE_PER_SECOND = 3,
}
local CASTER = {
  INTELLECT = 1, SPIRIT = 0.5, STAMINA = 0.5, SPELL_POWER = 1, SPELL_DAMAGE_DONE = 1, SPELL_HEALING_DONE = 0.4,
  CRIT_RATING = 0.5, RESISTANCE0_NAME = 0.01,
}
local HYBRID = {
  STRENGTH = 0.6, AGILITY = 0.6, INTELLECT = 0.7, STAMINA = 0.6, SPIRIT = 0.4, SPELL_POWER = 0.7,
  SPELL_DAMAGE_DONE = 0.6, SPELL_HEALING_DONE = 0.4, ATTACK_POWER = 0.4, CRIT_RATING = 0.6,
  RESISTANCE0_NAME = 0.02, DAMAGE_PER_SECOND = 1.5,
}

-- [classFile] = { default = weights, [tree slug] = weights }
GearWeights.BY_CLASS = {
  WARRIOR = {
    default = MELEE_STR,
    protection = {
      STAMINA = 1, STRENGTH = 0.8, DEFENSE_SKILL_RATING = 1, RESISTANCE0_NAME = 0.05, AGILITY = 0.5,
      DAMAGE_PER_SECOND = 2,
    },
  },
  PALADIN = { default = HYBRID },
  ROGUE = { default = MELEE_AGI },
  HUNTER = {
    default = {
      AGILITY = 1, STAMINA = 0.4, INTELLECT = 0.3, ATTACK_POWER = 0.5, RANGED_ATTACK_POWER = 0.5, CRIT_RATING = 0.8,
      HIT_RATING = 0.8, RESISTANCE0_NAME = 0.02, DAMAGE_PER_SECOND = 2,
    },
  },
  SHAMAN = { default = HYBRID },
  DRUID = { default = HYBRID },
  PRIEST = { default = CASTER },
  MAGE = { default = CASTER },
  WARLOCK = { default = CASTER },
}

-- Weights for a class and tree (the class default without a tree list).
function GearWeights.For(classFile, tree)
  local class = GearWeights.BY_CLASS[classFile or ""]
  if not class then return HYBRID end
  return (tree and class[tree]) or class.default
end
