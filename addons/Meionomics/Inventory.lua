-- How many of an item you have. This character's bags and bank come from the client, live, so
-- they're right whatever Syndicator is set to; Syndicator adds mail, auctions, alts, guild and
-- warband bank. Its API leaves out characters whose inventory is hidden in its character options.
local _, M = ...
local I = {}
M.Inventory = I

local function Sum(c)
  return (c.bags or 0) + (c.bank or 0) + (c.mail or 0) + (c.equipped or 0) + (c.void or 0)
    + (c.auctions or 0)
end

local function Key(c)
  local r = c.realmNormalized
  return c.character .. ((r and r ~= "") and "-" .. r or "")
end

-- -> IsMe(c), c a Syndicator { character, realmNormalized }. With regional names Syndicator
-- keys "First Surname-PvP" (ruleset, not realm); its GetCurrentCharacter is nil until its bag
-- cache is up, so also match the name ourselves
local function MeMatcher(api)
  local key = api.GetCurrentCharacter and api.GetCurrentCharacter()
  local first, surname = UnitName("player")
  local sepC = Constants.CharacterNameSeparatorConsts
  local sep = sepC and sepC.CHARACTERNAME_SURNAME_SEPARATOR or " "
  local me = (surname and surname ~= "") and (first .. sep .. surname) or first
  local regional = RegionalUniqueNamesEnabled and RegionalUniqueNamesEnabled()
  local realm = GetNormalizedRealmName()
  return function(c)
    if key and Key(c) == key then return true end
    local r = c.realmNormalized
    return c.character == me and (regional or r == realm or not r)
  end
end

-- Syndicator's other characters, not hidden in its options: { { key, name, class } }
function I.Others()
  local api = Syndicator and Syndicator.API
  if not (api and api.GetAllCharacters and api.GetByCharacterFullName) then return {} end
  local IsMe, out = MeMatcher(api), {}
  for _, k in ipairs(api.GetAllCharacters() or {}) do
    local c = api.GetByCharacterFullName(k)
    local d = type(c) == "table" and c.details
    if d and d.character and not (d.show and d.show.inventory == false) and not IsMe(d) then
      out[#out + 1] = { key = k, name = d.character, class = d.className }
    end
  end
  table.sort(out, function(a, b)
    if a.name ~= b.name then return a.name < b.name end
    return a.key < b.key
  end)
  return out
end

-- { me = { bags, bank, mail, auctions, total }, alts = { { name, class, total, key }... },
--   altTotal, warband, guild, total } or nil when there are none anywhere
function I.Get(itemID)
  local out = { alts = {}, altTotal = 0, warband = 0, guild = 0 }
  local bags = C_Item.GetItemCount(itemID, false) or 0
  local withBank = C_Item.GetItemCount(itemID, true) or bags
  local api = Syndicator and Syndicator.API
  local ok, info = false, nil
  if api and api.GetInventoryInfoByItemID then
    ok, info = pcall(api.GetInventoryInfoByItemID, itemID, true, false)
  end
  if ok and type(info) == "table" then
    local IsMe = MeMatcher(api)
    for _, c in ipairs(info.characters or {}) do
      if IsMe(c) then
        out.me = c
      else
        local n = Sum(c)
        if n > 0 then
          table.insert(out.alts, { name = c.character, class = c.className, total = n,
            key = Key(c) })
          out.altTotal = out.altTotal + n
        end
      end
    end
    out.warband = info.warband and info.warband[1] or 0
    for _, g in ipairs(info.guilds or {}) do out.guild = out.guild + (g.bank or 0) end
    table.sort(out.alts, function(a, b)
      if a.total ~= b.total then return a.total > b.total end
      return (a.name or "") < (b.name or "")
    end)
  end
  -- the client's bag count may include equipped items; before the bank is opened it may not
  -- know the bank, so Syndicator's recorded bank is the floor
  local me = out.me or {}
  out.me = { bags = bags, bank = math.max(withBank - bags, me.bank or 0), mail = me.mail,
    auctions = me.auctions, void = me.void }
  out.me.total = Sum(out.me)
  out.total = out.me.total + out.altTotal + out.warband + out.guild
  if out.total == 0 then return nil end
  return out
end
