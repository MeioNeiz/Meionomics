-- What a character's things are worth, by place (bags, bank, gear, mail, auctions), each item
-- valued as the tooltip's Best line does (P.BestAction: safe AH price after the cut, vendor,
-- disenchant or craft). This character's bags and gear come from the client live, the bank too
-- while it's open; the rest, and every alt, from Syndicator's saved copy.
--   W.Characters()          -> { { key, name, full, class, realm, money, me }... }
--   W.Find(name[, realm])   -> Syndicator key for a character name (AltView's), or nil
--   W.Slots(key, place)     -> { { id, count, bound, link }... }, live (true/false), or nil
--   W.Value(id, bound)      -> copper each or nil, act (nil: item data not loaded yet)
--   W.Summary(key)          -> { [place] = { value, slots, count, unpriced }, items, money, total }
local _, M = ...
local P, R = M.Prices, M.Recipes
local W = {}
M.Worth = W

W.PLACES = { "bags", "bank", "equipped", "mail", "auctions" }
W.NAMES = { bags = "Bags", bank = "Bank", equipped = "Gear", mail = "Mail", auctions = "On AH" }
local ME = "me"
local MEMO_SECONDS = 30

local function Secret(v) return issecretvalue ~= nil and issecretvalue(v) end
local function Api() return Syndicator and Syndicator.API end
local function AllChars() return type(SYNDICATOR_DATA) == "table" and SYNDICATOR_DATA.Characters end

------------------------------------------------------------------------------ Characters
-- with regional names Syndicator keys "First Surname-PvP"; its GetCurrentCharacter is nil until
-- its bag cache is up, so match the name too (as Inventory.lua does)
local function MyKey()
  local api, chars = Api(), AllChars()
  if not (api and chars) then return nil end
  local key = api.GetCurrentCharacter and api.GetCurrentCharacter()
  if key and chars[key] then return key end
  local first = UnitName("player")
  for k, c in pairs(chars) do
    local name = c.details and c.details.character
    if name and (name == first or name:match("^(%S+)") == first) then return k end
  end
end

local function Resolve(key)
  local mine = MyKey()
  if key == nil or key == ME then return mine or ME, true end
  return key, key == mine
end
function W.IsMe(key)
  local _, isMe = Resolve(key)
  return isMe
end

function W.Characters()
  local out, mine, chars = {}, MyKey(), AllChars()
  for k, c in pairs(chars or {}) do
    local d = c.details or {}
    local hidden = d.show and d.show.inventory == false
    if not hidden or k == mine then
      out[#out + 1] = { key = k, full = d.character or k, name = (d.character or k):match("^(%S+)"),
        class = d.className, realm = d.realmNormalized, money = c.money, me = k == mine }
    end
  end
  if not mine then
    out[#out + 1] = { key = ME, name = UnitName("player"), full = UnitName("player"),
      class = select(2, UnitClass("player")), money = GetMoney(), me = true }
  end
  table.sort(out, function(a, b)
    if a.me ~= b.me then return a.me end
    return a.full < b.full
  end)
  return out
end

-- AltView knows "Name" and the realm's display name; Syndicator "Name Surname" and the ruleset
function W.Find(name, realm)
  if not name then return nil end
  name = name:lower()
  local want = realm and realm:gsub("%s", ""):lower()
  local hit
  for _, c in ipairs(W.Characters()) do
    if c.name and c.name:lower() == name then
      if not want or (c.realm and c.realm:lower() == want) then return c.key end
      hit = hit or c.key
    end
  end
  return hit
end

------------------------------------------------------------------------------ Slots
local function FromInfo(info, out)
  if not (info and info.itemID) or Secret(info.itemID) then return end
  out[#out + 1] = { id = info.itemID, count = info.stackCount or 1, bound = info.isBound or false,
    link = info.hyperlink }
end

local function Containers(bags, out)
  for _, bag in ipairs(bags) do
    for slot = 1, C_Container.GetContainerNumSlots(bag) or 0 do
      FromInfo(C_Container.GetContainerItemInfo(bag, slot), out)
    end
  end
end

local function Bound(loc)
  local ok, b = pcall(C_Item.IsBound, loc)
  return ok and not Secret(b) and b or false
end

local function InvSlot(slot, out)
  local id = GetInventoryItemID("player", slot)
  if not id or Secret(id) then return end
  local loc = ItemLocation:CreateFromEquipmentSlot(slot)
  out[#out + 1] = { id = id, count = 1, bound = Bound(loc),
    link = GetInventoryItemLink("player", slot) }
end

local function BagIDs()
  local ids = {}
  for bag = 0, NUM_BAG_SLOTS or 4 do ids[#ids + 1] = bag end
  local reagent = Enum.BagIndex and Enum.BagIndex.ReagentBag
  if reagent and reagent > (NUM_BAG_SLOTS or 4) then ids[#ids + 1] = reagent end
  return ids
end

-- Forever's character bank tabs, else Classic's bank and bank bags
local function BankIDs()
  local ids, E = {}, Enum.BagIndex or {}
  for i = 1, 9 do
    local tab = E["CharacterBankTab_" .. i]
    if tab then ids[#ids + 1] = tab end
  end
  if #ids > 0 then return ids end
  ids[1] = BANK_CONTAINER or -1
  for i = 1, NUM_BANKBAGSLOTS or 0 do ids[#ids + 1] = (NUM_BAG_SLOTS or 4) + i end
  return ids
end

local bankOpen = false
M.On("BANKFRAME_OPENED", function() bankOpen = true end)
M.On("BANKFRAME_CLOSED", function() bankOpen = false end)
function W.BankOpen() return bankOpen end

-- the bags themselves count as bags: a 16-slot bag is worth something too
local function LiveBags()
  local out = {}
  Containers(BagIDs(), out)
  for bag = 1, NUM_BAG_SLOTS or 4 do
    local inv = C_Container.ContainerIDToInventoryID and C_Container.ContainerIDToInventoryID(bag)
    if inv then InvSlot(inv, out) end
  end
  return out
end

local function LiveGear()
  local out = {}
  for slot = INVSLOT_FIRST_EQUIPPED or 1, INVSLOT_LAST_EQUIPPED or 19 do InvSlot(slot, out) end
  return out
end

local function Saved(list, out, nested)
  for _, entry in pairs(list or {}) do
    if nested then
      Saved(entry.slots or entry, out)
    elseif type(entry) == "table" and entry.itemID then
      out[#out + 1] = { id = entry.itemID, count = entry.itemCount or 1,
        bound = entry.isBound or false, link = entry.itemLink }
    end
  end
  return out
end

local function SavedBagSlots(c, out)
  local info = c.containerInfo and c.containerInfo.bags
  return Saved(info, out)
end

function W.Slots(key, place)
  local k, isMe = Resolve(key)
  if isMe and place == "bags" then return LiveBags(), true end
  if isMe and place == "equipped" then return LiveGear(), true end
  -- the bank's tabs can still read empty just after it opens: then the saved copy
  if isMe and place == "bank" and bankOpen then
    local out = {}
    Containers(BankIDs(), out)
    if #out > 0 then return out, true end
  end
  local c = AllChars() and AllChars()[k]
  if not c then return nil end
  local out = {}
  if place == "bags" then
    Saved(c.bags, out, true)
    SavedBagSlots(c, out)
  elseif place == "bank" then
    Saved(c.bank, out, true)
    Saved(c.bankTabs, out, true)
  elseif place == "equipped" then
    Saved(c.equipped, out)
  elseif place == "mail" or place == "auctions" then
    Saved(c[place], out)
  end
  return out, false
end

------------------------------------------------------------------------------ Values
-- gen: bumped when prices are re-read or this character's things change; summaries of an
-- older gen are redone (slot lists are cheap, values come from the memo)
local memo, memoAt, gen = {}, 0, 0

local function Fresh()
  local now = GetTime()
  if now - memoAt > MEMO_SECONDS then
    wipe(memo)
    memoAt = now
    gen = gen + 1
    R.ResetCache()
  end
end

-- each, act: Best's value when it sells; a "keep" or "equip" verdict still has a sale price
-- (its runner), which is what it's worth. nil, nil: item data not loaded yet (asked for)
function W.Value(id, bound)
  Fresh()
  local key = id .. (bound and "b" or "")
  local hit = memo[key]
  if hit then return hit[1], hit[2] end
  local act = P.BestAction(id, bound or nil)
  if not act then
    if C_Item.RequestLoadItemDataByID then C_Item.RequestLoadItemDataByID(id) end
    return nil, nil
  end
  local each = act.value or (act.runner and act.runner[2]) or act.sale.value or act.sale.vendor
  memo[key] = { each, act }
  return each, act
end

function W.Forget() memoAt = 0 end
function W.Gen() Fresh() return gen end

local sums = {}
function W.Summary(key)
  Fresh()
  local k = Resolve(key)
  local hit = sums[k]
  if hit and hit.gen == gen then return hit end
  local s = { gen = gen, items = 0, unpriced = 0 }
  for _, place in ipairs(W.PLACES) do
    local list = W.Slots(k, place)
    if list then
      local p = { value = 0, slots = #list, count = 0, unpriced = 0 }
      for _, it in ipairs(list) do
        local each = W.Value(it.id, it.bound)
        p.count = p.count + it.count
        if each then p.value = p.value + each * it.count else p.unpriced = p.unpriced + 1 end
      end
      s[place] = p
      s.items, s.unpriced = s.items + p.value, s.unpriced + p.unpriced
    end
  end
  local c = AllChars() and AllChars()[k]
  s.money = (k == ME or k == MyKey()) and GetMoney() or (c and c.money) or 0
  s.total = s.items + s.money
  sums[k] = s
  return s
end

-- bags, bank or gear changed: this character's figures go stale, item values don't
local function Dirty() gen = gen + 1 end
for _, e in ipairs({ "BAG_UPDATE_DELAYED", "PLAYERBANKSLOTS_CHANGED", "PLAYER_EQUIPMENT_CHANGED",
  "BANKFRAME_OPENED", "PLAYER_MONEY" }) do
  pcall(M.On, e, Dirty)
end
