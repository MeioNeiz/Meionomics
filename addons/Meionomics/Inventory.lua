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

-- { me = { bags, bank, mail, auctions, total }, alts = { { name, class, total }... },
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
    local me, realm = UnitName("player"), GetNormalizedRealmName()
    for _, c in ipairs(info.characters or {}) do
      if c.character == me and (c.realmNormalized == realm or not c.realmNormalized) then
        out.me = c
      else
        local n = Sum(c)
        if n > 0 then
          table.insert(out.alts, { name = c.character, class = c.className, total = n })
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
