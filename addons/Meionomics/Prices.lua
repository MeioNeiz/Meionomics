-- Prices. With TSM loaded everything goes through TSM_API, so TSM's sources and custom price
-- strings work. Without it, the AuctionDB data TSM's desktop app writes into
-- TradeSkillMaster_AppHelper\AppData.lua is read directly: AppHelper hands each block to the global
-- TSM_APPHELPER_LOAD_DATA, which TSM defines and we define when TSM is absent.
-- AppHelper declares a dependency on TSM; patch 15 makes it optional so this works without TSM.
-- Our own AH scans and searches (Auction.lua) are merged in either way: the current AH from
-- whichever is newer, market taking over as days of our data build up.
local _, M = ...
local P = {}
M.Prices = P

-- what = TSM source key, AppData field, and whether it is a number (x1000 in the data) not money
local SOURCES = {
  minBuyout = { "DBMinBuyout", "minBuyout" },
  numAuctions = { "DBNumAuctions", "numAuctions", "count" },
  market = { "DBMarket", "marketValue" },
  recent = { "DBRecent", "marketValueRecent" },
  historical = { "DBHistorical", "historical" },
  regionMarket = { "DBRegionMarketAvg", "regionMarketValue" },
  regionHistorical = { "DBRegionHistorical", "regionHistorical" },
  regionSale = { "DBRegionSaleAvg", "regionSale" },
  soldPerDay = { "DBRegionSoldPerDay", "regionSoldPerDay", "rate" },
  saleRate = { "DBRegionSaleRate", "regionSalePercent", "rate" },
}
P.SOURCES = SOURCES

-- Price lookups take an itemID or a random-suffix variant key "itemID:bonusIDs" (Auction.lua
-- A.Key). TSM and its app data only price the itemID, whatever the suffix ("of Shadow Wrath"
-- 17s vs over 1g), so a variant's AH prices are our own sightings of it alone; its region sales
-- rates are the itemID's, the nearest there is.
local function Id(key)
  if type(key) == "string" then return tonumber(key:match("^(%d+)")) end
  return key
end
P.Id = Id
local function Variant(key) return type(key) == "string" end

local function TSMReady()
  return type(TSM_API) == "table" and TSM_API.GetCustomPriceValue ~= nil
end

function P.Source()
  if TSMReady() then return "TSM" end
  if P.appData then return "AppData" end
  if M.Auction and M.Auction.ScanTime() then return "AH scan" end
end

------------------------------------------------------------------------------ TSM
local validCache = {}
function P.Valid(str)
  if not TSMReady() then return false end
  if validCache[str] == nil then
    local ok, valid = pcall(TSM_API.IsCustomPriceValid, str)
    validCache[str] = (ok and valid) and true or false
  end
  return validCache[str]
end

-- any TSM custom price string; nil without TSM
function P.Custom(str, itemID)
  if not (itemID and P.Valid(str)) then return nil end
  local ok, v = pcall(TSM_API.GetCustomPriceValue, str, "i:" .. Id(itemID))
  return (ok and type(v) == "number" and v > 0) and v or nil
end

-- what a vendor charges for one: TSM's VendorBuy, else the cheapest unlimited stock seen at our
-- merchant visits (Recipes.lua records mats and patterns); limited stock is never a price to
-- count on. TSM only knows vendors it has seen too, so ours fills its gaps.
function P.VendorBuy(itemID)
  if not itemID then return nil end
  local tsm = P.Custom("VendorBuy", itemID)
  if tsm then return tsm end
  local best
  for _, v in pairs(M.Recipes and M.Recipes.Vendors(itemID) or {}) do
    if not v.limited and v.price and v.price > 0 and (not best or v.price < best) then
      best = v.price
    end
  end
  return best
end

-- cheapest way to get the item by converting others (essences, milling, prospecting), at
-- DBMarket: TSM's convert tooltip with its default destroy value source
function P.Convert(itemID) return P.Custom("convert(DBMarket)", itemID) end

-- the item's TSM group, formatted ("Parent -> Child"); nil without TSM or outside any group
function P.Group(itemID)
  if not (itemID and TSMReady() and TSM_API.GetGroupPathByItem) then return nil end
  local ok, path = pcall(TSM_API.GetGroupPathByItem, "i:" .. itemID)
  if not (ok and path) then return nil end
  local okFmt, text = pcall(TSM_API.FormatGroupPath, path)
  return okFmt and text or path
end

------------------------------------------------------------------------------ AppData
-- tag -> { fields = { name -> column }, items = { itemID -> "v1,v2" or decoded list } }
-- Decoded lazily per item, as TSM does: most of the 50k rows are never looked at.
local blocks = {}

-- TSM names a WoW Forever realm by its ruleset ("PvP-Alliance"), not GetRealmName()
local function RulesetRealm()
  local rules, E = C_GameRules, Enum and Enum.GameRule
  if not (rules and rules.IsGameRuleActive and E and E.PvPRuleset) then return nil end
  local function On(rule) return rule ~= nil and rules.IsGameRuleActive(rule) end
  if On(E.HardcoreRuleset) then return "Hardcore" end
  local rp, pvp = On(E.RPRuleset), On(E.PvPRuleset)
  if rp and pvp then return "Roleplay PvP" end
  if rp then return "Roleplay" end
  return pvp and "PvP" or "Normal"
end

local function Plain(s) return s:gsub("%s+", ""):lower() end

local function IsMine(tag, where)
  if tag:find("^AUCTIONDB_REGION_") or tag:find("^AUCTIONDB_COMMODITY_") then
    return where:match("%-(%a+)$") == (GetCurrentRegionName and GetCurrentRegionName())
  end
  local faction = "-" .. (UnitFactionGroup("player") or "")
  for _, realm in ipairs({ M.Realm() or "", RulesetRealm() }) do
    if Plain(where) == Plain(realm .. faction) then return true end
  end
  return false
end

-- when the app data was downloaded: realm (this realm-faction) and region
local dataTime = {}
local function NoteTime(tag, where, data)
  if type(data) ~= "string" or not tag:find("^AUCTIONDB_") or not IsMine(tag, where) then return end
  local t = tonumber(data:match("downloadTime=(%d+)"))
  local kind = (tag:find("^AUCTIONDB_REGION_") or tag:find("^AUCTIONDB_COMMODITY_")) and "region"
    or "realm"
  if t then dataTime[kind] = math.max(dataTime[kind] or 0, t) end
end
function P.DataTime(kind) return dataTime[kind] end

function P.LoadAppData(tag, where, data)
  if type(data) ~= "string" or not tag:find("^AUCTIONDB_") or not IsMine(tag, where) then return end
  NoteTime(tag, where, data)
  local fieldList, rows = data:match("fields={([^}]*)},data={(.*)}")
  if not fieldList then return end
  local b = { fields = {}, items = {}, time = tonumber(data:match("downloadTime=(%d+)")) }
  local i = 0
  for f in fieldList:gmatch('"([^"]+)"') do
    if i > 0 then b.fields[f] = i end
    i = i + 1
  end
  for key, rest in rows:gmatch('{"?([^,"]+)"?,([^}]+)}') do
    local id = tonumber(key) or tonumber(key:match("^i:(%d+)$") or "")
    if id then b.items[id] = rest end
  end
  blocks[tag] = b
  P.appData = true
end

-- base 32; values over 6 digits split as TSM does (tonumber is 32-bit there)
local function Decode(v)
  if #v > 6 then return tonumber(v:sub(-6), 32) + tonumber(v:sub(1, -7), 32) * 2 ^ 30 end
  return tonumber(v, 32)
end

-- when the block holding a field was downloaded
local function AppTime(field)
  for _, b in pairs(blocks) do
    if b.fields[field] then return b.time end
  end
end

local function AppValue(field, itemID)
  for _, b in pairs(blocks) do
    local col = b.fields[field]
    local row = col and b.items[itemID]
    if row then
      if type(row) == "string" then
        local list = {}
        for v in row:gmatch("[^,]+") do list[#list + 1] = Decode(v) or 0 end
        b.items[itemID] = list
        row = list
      end
      local v = row[col]
      if v and v > 0 then return v end
    end
  end
end

-- TSM keeps its data to itself: watch it go past for the download times. TSM replaces the
-- global at login, once AppHelper is done.
if TSM_APPHELPER_LOAD_DATA == nil then
  TSM_APPHELPER_LOAD_DATA = P.LoadAppData
else
  local tsm = TSM_APPHELPER_LOAD_DATA
  TSM_APPHELPER_LOAD_DATA = function(tag, where, data)
    pcall(NoteTime, tag, where, data)
    return tsm(tag, where, data)
  end
end

------------------------------------------------------------------------------ Lookup
-- the client's sell price, known only once the item is cached: until then TSM's (kept across
-- sessions), and the item is asked for; caches are redone when it arrives, since prices and
-- verdicts worked out without a vendor price were kept
local waiting = {}
local function Vendor(itemID)
  local sell = select(11, C_Item.GetItemInfo(itemID))
  if sell == nil then
    if not waiting[itemID] and C_Item.RequestLoadItemDataByID then
      waiting[itemID] = true
      C_Item.RequestLoadItemDataByID(itemID)
    end
    sell = P.Custom("VendorSell", itemID)
  end
  return (sell and sell > 0) and sell or nil
end

local redo
M.On("GET_ITEM_INFO_RECEIVED", function(_, itemID, ok)
  if not waiting[itemID] then return end
  waiting[itemID] = nil
  if redo or not ok then return end
  redo = true
  C_Timer.After(0.2, function()
    redo = nil
    if M.Recipes then M.Recipes.ResetCache() end
    if M.CraftUI then M.CraftUI.RefreshSoon() end
  end)
end)

-- Our scans and AH searches: the current AH from whichever is newer; market blended in by days
-- of our own data, taking over fully after OWN_DAYS. With TSM loaded its app data is read by
-- TSM, so only the download time (NoteTime) is known.
local OWN_DAYS = 7
local function Merge(what, v, field, itemID)
  local own = M.Auction and M.Auction.Get(itemID)
  if not own then return v end
  if what == "minBuyout" or what == "numAuctions" then
    if own.t and own.t >= (AppTime(field) or dataTime.realm or 0) then
      if what == "minBuyout" then return own.min end
      return (own.n or 0) > 0 and own.n or nil
    end
  elseif what == "market" and own.market then
    local w = math.min(own.days / OWN_DAYS, 1)
    return v and math.floor(own.market * w + v * (1 - w) + 0.5) or own.market
  end
  return v
end

-- our record when it is the newest realm data there is (a variant's always is) or nil
local function Newest(itemID)
  local own = M.Auction and M.Auction.Get(itemID)
  if own and own.t and (Variant(itemID) or own.t >= (dataTime.realm or 0)) then return own end
end

-- what's up now as we saw it (a scan or any AH search), if within LIVE_FOR and newer than
-- TSM's data -> Auction.Get's record plus age; nil otherwise
P.LIVE_FOR = 6 * 3600
function P.Live(itemID)
  local own = Newest(itemID)
  if not own then return nil end
  own.age = M.Now() - own.t
  if own.age <= P.LIVE_FOR then return own end
end

-- the cheapest listing in the newest data, however old (P.Age says how old): our sighting's
-- cheapest rival when at least as new as TSM's realm data, else TSM's min buyout
function P.Current(itemID)
  local own = Newest(itemID)
  if own then return own.comp end
  return P.Get(itemID, "minBuyout")
end

-- how old the item's realm AH price is -> seconds, and true when it's our own sighting rather
-- than TSM's app data; nil when neither has a time
function P.Age(itemID)
  local own = Newest(itemID)
  if own then return M.Now() - own.t, true end
  if Variant(itemID) then return nil end
  local t = dataTime.realm
  if t then return M.Now() - t, false end
end

-- the AH takes unbound, bind-on-equip and bind-on-use items; true, or false and why not
local AUCTIONABLE = { [0] = true, [2] = true, [3] = true }
local NOT_WHY = { [1] = "soulbound", [4] = "quest item" }
function P.Auctionable(itemID)
  local bind = select(14, C_Item.GetItemInfo(Id(itemID)))
  if bind == nil or AUCTIONABLE[bind] then return true end
  return false, NOT_WHY[bind] or "account-bound"
end

-- P.Get(itemID, "market") etc (keys of SOURCES), or "vendor"
function P.Get(itemID, what)
  if not itemID then return nil end
  if what == "vendor" then return Vendor(Id(itemID)) end
  local s = SOURCES[what]
  if Variant(itemID) and s[3] ~= "rate" then
    local own = M.Auction and M.Auction.Get(itemID)
    if not own then return nil end
    if what == "minBuyout" then return own.min end
    if what == "numAuctions" then return (own.n or 0) > 0 and own.n or nil end
    if what == "market" then return own.market end
    return nil
  end
  if TSMReady() then
    -- TSM rounds every value to a whole number: rates are asked for x1000 (as TSM's tooltip does)
    if s[3] == "rate" then
      local v = P.Custom(s[1] .. " * 1000", itemID)
      return v and v / 1000
    end
    return Merge(what, P.Custom(s[1], itemID), s[2], itemID)
  end
  local v = AppValue(s[2], Id(itemID))
  if v and s[3] == "rate" then return v / 1000 end
  return Merge(what, v, s[2], itemID)
end

-- TSM string if TSM is loaded and it parses, else the first source here that has a value
function P.Best(itemID, tsmString, ...)
  if tsmString and P.Valid(tsmString) then return P.Custom(tsmString, itemID) end
  for i = 1, select("#", ...) do
    local v = P.Get(itemID, (select(i, ...)))
    if v then return v end
  end
end

-- How well an item sells: { perDay, rate, listed, auctions, age, from, clearDays }, nil with
-- no data at all. Sales (perDay, rate = share of listings that sell) are region figures from
-- TSM or its app data: our GetAll scans can't tell a sale from an expiry or cancel (replicate
-- rows carry no auction IDs), so realm sales would need our own mail/sale tracking.
-- Listings are this realm's: our last scan while fresh, or (without TSM) while newer than the
-- app data (listed = quantity, from "scan", age), else TSM's auction count (listed = auctions,
-- from = P.Source()).
-- clearDays: how long what's up now takes to sell at perDay, ignoring new posts.
local LISTED_FRESH = 6 * 3600
function P.SellRate(itemID)
  if not itemID then return nil end
  local s = { perDay = P.Get(itemID, "soldPerDay"), rate = P.Get(itemID, "saleRate") }
  local A, now = M.Auction, M.Now()
  local scan = A and A.ScanTime()
  local own = A and A.Get(itemID)
  -- an item missing from a newer scan had none up then
  local t = own and own.t and own.t >= (scan or 0) and own.t or scan
  local newest = t and (Variant(itemID) or not TSMReady()
    and t >= (AppTime(SOURCES.numAuctions[2]) or 0))
  if t and (now - t <= LISTED_FRESH or newest) then
    local up = own and own.t == t
    s.listed, s.auctions = up and own.qty or 0, up and own.n or 0
    s.age, s.from = now - t, "scan"
  else
    local n = P.Get(itemID, "numAuctions")
    if n then s.listed, s.auctions, s.from = n, n, P.Source() end
  end
  if not (s.perDay or s.rate or s.listed) then return nil end
  if s.listed and s.perDay and s.perDay > 0 then s.clearDays = s.listed / s.perDay end
  return s
end

------------------------------------------------------------------------------ Selling
-- What one item realistically fetches each way: vendor, AH (after the cut, only if it sells),
-- disenchant (only with this character's Enchanting). For the tooltip verdict and the quest
-- reward chooser.
P.AH_CUT = 0.05
P.SELLS_PER_DAY = 0.5 -- region sold/day under this: nobody buys it, vendor it
P.SELLS_RATE = 0.1 -- region sale rate under this: most listings expire

-- the cheaper of min buyout and market (one overpriced listing isn't a price), after the cut
function P.AHValue(itemID)
  local min, market = P.Get(itemID, "minBuyout"), P.Get(itemID, "market")
  local v = min and market and math.min(min, market) or min or market
    or P.Get(itemID, "regionMarket")
  return v and math.floor(v * (1 - P.AH_CUT) + 0.5)
end

-- true when it realistically sells; no sales data counts as not selling. s = P.SellRate
function P.Sells(itemID)
  local s = P.SellRate(itemID)
  local ok = s and (s.perDay or 0) >= P.SELLS_PER_DAY and (s.rate or 1) >= P.SELLS_RATE
  return ok and true or false, s
end

-- per material: { classID, quality, min ilvl, max ilvl, average count }
-- from TSM's LibTSMData/Destroy/Disenchant.lua, DATA.Forever
local DISENCHANT = {
  [10940] = { -- Strange Dust
    { 4, 2, 5, 15, 1.2 }, { 4, 2, 16, 20, 1.85 }, { 4, 2, 21, 25, 3.75 },
    { 4, 3, 5, 15, 2 }, { 4, 3, 16, 19, 2.625 }, { 2, 2, 5, 15, 0.3 },
    { 2, 2, 16, 20, 0.5 }, { 2, 2, 21, 25, 0.75 }, { 2, 3, 16, 19, 0.7 },
  },
  [11083] = { -- Soul Dust
    { 4, 2, 26, 30, 1.1 }, { 4, 2, 31, 35, 2.55 }, { 2, 2, 26, 30, 0.3 },
    { 2, 2, 31, 35, 0.7 },
  },
  [11137] = { -- Vision Dust
    { 4, 2, 36, 40, 1.1 }, { 4, 2, 41, 45, 2.55 }, { 2, 2, 36, 40, 0.3 },
    { 2, 2, 41, 45, 0.7 },
  },
  [11176] = { -- Dream Dust
    { 4, 2, 46, 50, 1.1 }, { 4, 2, 51, 55, 2.55 }, { 2, 2, 46, 50, 0.3 },
    { 2, 2, 51, 55, 0.7 },
  },
  [16204] = { -- Illusion Dust
    { 4, 2, 56, 60, 1.1 }, { 4, 2, 61, 99, 2.55 }, { 2, 2, 56, 60, 0.3 },
    { 2, 2, 61, 99, 0.7 },
  },
  [10938] = { -- Lesser Magic Essence
    { 4, 2, 5, 15, 0.3 }, { 4, 3, 5, 15, 0.5 }, { 2, 2, 5, 15, 1.2 },
  },
  [10939] = { -- Greater Magic Essence
    { 4, 2, 16, 20, 0.3 }, { 4, 3, 16, 19, 0.5 }, { 2, 2, 16, 20, 1.1 },
    { 2, 2, 21, 25, 1.1 }, { 2, 2, 26, 30, 1.1 }, { 2, 3, 16, 19, 1.875 },
  },
  [10998] = { -- Lesser Astral Essence
    { 4, 2, 21, 25, 0.22 },
  },
  [11082] = { -- Greater Astral Essence
    { 4, 2, 26, 30, 0.3 },
  },
  [11134] = { -- Lesser Mystic Essence
    { 4, 2, 31, 35, 0.3 }, { 2, 2, 31, 35, 1.1 },
  },
  [11135] = { -- Greater Mystic Essence
    { 4, 2, 36, 40, 0.3 }, { 2, 2, 36, 40, 1.1 },
  },
  [11174] = { -- Lesser Nether Essence
    { 4, 2, 41, 45, 0.3 }, { 2, 2, 41, 45, 1.1 },
  },
  [11175] = { -- Greater Nether Essence
    { 4, 2, 46, 50, 0.3 }, { 2, 2, 46, 50, 1.1 },
  },
  [16202] = { -- Lesser Eternal Essence
    { 4, 2, 51, 55, 0.3 }, { 2, 2, 51, 55, 1.1 },
  },
  [16203] = { -- Greater Eternal Essence
    { 4, 2, 56, 60, 0.3 }, { 4, 2, 61, 99, 0.5 }, { 2, 2, 56, 60, 1.1 },
    { 2, 2, 61, 99, 1.85 },
  },
  [10978] = { -- Small Glimmering Shard
    { 4, 2, 16, 20, 0.05 }, { 4, 2, 21, 25, 0.1 }, { 4, 3, 16, 19, 0.05 },
    { 4, 3, 20, 25, 1 }, { 2, 2, 16, 20, 0.05 }, { 2, 2, 21, 25, 0.1 },
    { 2, 3, 16, 19, 0.05 }, { 2, 3, 20, 25, 1 },
  },
  [11084] = { -- Large Glimmering Shard
    { 4, 2, 26, 30, 0.05 }, { 4, 3, 26, 30, 1 }, { 2, 2, 26, 30, 0.05 },
    { 2, 3, 26, 30, 1 },
  },
  [11138] = { -- Small Glowing Shard
    { 4, 2, 31, 35, 0.05 }, { 4, 3, 31, 35, 1 }, { 2, 2, 31, 35, 0.05 },
    { 2, 3, 31, 35, 1 },
  },
  [11139] = { -- Large Glowing Shard
    { 4, 2, 36, 40, 0.05 }, { 4, 3, 36, 40, 1 }, { 2, 2, 36, 40, 0.05 },
    { 2, 3, 36, 40, 1 },
  },
  [11177] = { -- Small Radiant Shard
    { 4, 2, 41, 45, 0.05 }, { 4, 3, 41, 45, 1 }, { 4, 4, 40, 45, 3 },
    { 2, 2, 41, 45, 0.05 }, { 2, 3, 41, 45, 1 }, { 2, 4, 40, 45, 3 },
  },
  [11178] = { -- Large Radiant Shard
    { 4, 2, 46, 50, 0.05 }, { 4, 3, 46, 50, 1 }, { 4, 4, 46, 50, 3 },
    { 2, 2, 46, 50, 0.05 }, { 2, 3, 46, 50, 1 }, { 2, 4, 46, 50, 3 },
  },
  [14343] = { -- Small Brilliant Shard
    { 4, 2, 51, 55, 0.05 }, { 4, 3, 51, 55, 1 }, { 4, 4, 51, 55, 3 },
    { 2, 2, 51, 55, 0.05 }, { 2, 3, 51, 55, 1 }, { 2, 4, 51, 55, 3 },
  },
  [14344] = { -- Large Brilliant Shard
    { 4, 2, 56, 60, 0.05 }, { 4, 2, 61, 99, 0.05 }, { 4, 3, 56, 60, 0.995 },
    { 4, 3, 61, 99, 0.99 }, { 2, 2, 56, 60, 0.05 }, { 2, 2, 61, 99, 0.05 },
    { 2, 3, 56, 60, 0.995 }, { 2, 3, 61, 99, 0.99 },
  },
  [20725] = { -- Nexus Crystal
    { 4, 3, 56, 60, 0.005 }, { 4, 3, 61, 99, 0.01 }, { 4, 4, 56, 60, 1 },
    { 4, 4, 61, 99, 1.666 }, { 2, 3, 56, 60, 0.005 }, { 2, 3, 61, 99, 0.01 },
    { 2, 4, 56, 60, 1 }, { 2, 4, 61, 99, 1.666 },
  },
}

function P.EnchantingRank()
  for _, p in pairs(M.Recipes.Professions()) do
    if p.skillLine == 333 then return p.rank end
  end
end

-- Enchanting needed: vanilla's 5-level bands, 225 from ilvl 61 (TSM's data has one band 61-99)
function P.DisenchantSkill(itemID)
  local ilvl = select(4, C_Item.GetItemInfo(Id(itemID)))
  if not ilvl then return nil end
  return ilvl <= 20 and 1 or math.min(225, 25 * math.ceil((ilvl - 20) / 5))
end

-- average value of what it disenchants into, mats at P.AHValue (dust and essences sell, so no
-- P.Sells check); nil when it can't be disenchanted or no mat has a price
function P.Disenchant(itemID)
  local _, _, quality, ilvl, _, _, _, _, _, _, _, classID = C_Item.GetItemInfo(Id(itemID))
  if not (quality and ilvl and (classID == 2 or classID == 4)) then return nil end
  local total, any = 0, false
  for mat, rows in pairs(DISENCHANT) do
    for _, r in ipairs(rows) do
      if r[1] == classID and r[2] == quality and ilvl >= r[3] and ilvl <= r[4] then
        local v = P.AHValue(mat)
        if v then total, any = total + v * r[5], true end
      end
    end
  end
  return any and math.floor(total + 0.5) or nil
end

-- this character can disenchant it now; and the skill it needs
function P.CanDisenchant(itemID)
  local need, rank = P.DisenchantSkill(itemID), P.EnchantingRank()
  return (need and rank and rank >= need) and true or false, need
end

-- The best way to turn one into money, nil when none pays:
--   { method = "vendor" | "ah" | "disenchant", value, vendor, ah, disenchant, s, why }
-- s = P.SellRate; why[method] = why an option with a value doesn't count ("soulbound", "slow",
-- "needs Enchanting 75"). bound: soulbound now (bag item); nil goes by the bind type.
-- Ties go to vendor, then AH: less hassle. P.SaleOptions: the same table before the pick (no
-- method or value), for callers adding options of their own.
-- Buying a listing to vendor it: the gain on one, or nil when too small to bother with.
-- Undercutters list hundreds of items at vendor price minus 1c; those aren't money.
function P.FlipGain(vendor, unit)
  if not (vendor and unit) then return nil end
  local gain = math.floor(vendor - unit)
  if gain >= math.max(10, vendor * 0.05) then return gain end
end

function P.SaleOptions(itemID, bound)
  local r = { vendor = P.Get(itemID, "vendor"), why = {} }
  local ok, notWhy = P.Auctionable(itemID)
  if ok and bound then ok, notWhy = false, "soulbound" end
  r.ah = P.AHValue(itemID)
  if ok then
    local sells
    sells, r.s = P.Sells(itemID)
    if not sells then r.why.ah = "slow" end
  else
    r.why.ah = notWhy
  end
  r.disenchant = P.Disenchant(itemID)
  if r.disenchant then
    local can, need = P.CanDisenchant(itemID)
    if not can then r.why.disenchant = "needs Enchanting " .. (need or "?") end
  end
  return r
end

function P.BestSale(itemID, bound)
  local r = P.SaleOptions(itemID, bound)
  for _, k in ipairs({ "vendor", "ah", "disenchant" }) do
    local v = r[k]
    if v and not r.why[k] and v > (r.value or 0) then r.method, r.value = k, v end
  end
  return r.method and r or nil
end

------------------------------------------------------------------------------ Evidence
-- TSM's accounting ledger, from its SavedVariables: as of login (TSM writes new rows on
-- logout). itemID -> { sale = { price, qty, time, n }, buy = ... }, auction rows only: vendor
-- sales say nothing about the AH. price is per item.
-- one of TSM's accounting CSVs for this realm ("csvSales", "csvBuys"), nil without TSM.
-- TSM's realm key on Forever isn't GetRealmName() ("PvP" for "CAMWOW EU4 Realm 8 PvP"):
-- that, else the only realm TSM keeps accounting for
function P.TSMCsv(key)
  local db = type(TradeSkillMasterDB) == "table" and TradeSkillMasterDB
  if not db then return nil end
  local pre = "r@" .. GetRealmName() .. "@internalData@"
  if not db[pre .. "csvSales"] then
    local only
    for k in pairs(db) do
      local realm = type(k) == "string" and k:match("^r@(.+)@internalData@csvSales$")
      if realm then
        if only then only = nil break end
        only = realm
      end
    end
    if only then pre = "r@" .. only .. "@internalData@" end
  end
  local csv = db[pre .. key]
  return type(csv) == "string" and csv or nil
end

local ledger
local function Ledger()
  if ledger then return ledger end
  ledger = {}
  for kind, key in pairs({ sale = "csvSales", buy = "csvBuys" }) do
    local csv = P.TSMCsv(key)
    if type(csv) == "string" then
      -- itemString,stackSize,quantity,price,otherPlayer,player,time,source
      local row = "\ni:(%d+)[^,\n]*,%d+,(%d+),(%d+),[^,\n]*,[^,\n]*,(%d+),Auction"
      for id, qty, price, t in csv:gmatch(row) do
        id, t = tonumber(id), tonumber(t)
        ledger[id] = ledger[id] or {}
        local last = ledger[id][kind]
        if not last or t >= last.time then
          ledger[id][kind] = { price = tonumber(price), qty = tonumber(qty), time = t,
            n = (last and last.n or 0) + 1 }
        else
          last.n = last.n + 1
        end
      end
    end
  end
  return ledger
end

-- itemID -> auction sales oldest first; TSM's ledger is as of login, so parsed once
local salesIndex
local function SalesIndex()
  if salesIndex then return salesIndex end
  salesIndex = {}
  local csv = P.TSMCsv("csvSales")
  if not csv then return salesIndex end
  local row = "\ni:(%d+)[^,\n]*,%d+,(%d+),(%d+),[^,\n]*,[^,\n]*,(%d+),Auction"
  for id, qty, price, t in csv:gmatch(row) do
    id = tonumber(id)
    local list = salesIndex[id] or {}
    salesIndex[id] = list
    list[#list + 1] = { price = tonumber(price), qty = tonumber(qty), time = tonumber(t) }
  end
  for _, list in pairs(salesIndex) do
    table.sort(list, function(a, b) return a.time < b.time end)
  end
  return salesIndex
end

-- every auction sale of an item in TSM's ledger, oldest first: { price (each), qty, time }
function P.Sales(itemID)
  local out = {}
  for i, x in ipairs(SalesIndex()[Id(itemID)] or {}) do out[i] = x end
  return out
end

-- what he sold of it a day lately: OWN_WINDOW days, over at least OWN_MIN_DAYS so a burst
-- (3 in an hour) doesn't read as a rate. nil when he sold none.
local OWN_WINDOW, OWN_MIN_DAYS = 14 * 86400, 3 * 86400
function P.OwnPerDay(itemID)
  local list = SalesIndex()[Id(itemID)]
  if not list then return nil end
  local now, n, first = M.Now(), 0, nil
  for _, x in ipairs(list) do
    if now - x.time <= OWN_WINDOW then
      n, first = n + x.qty, first or x.time
    end
  end
  if n == 0 then return nil end
  return n / (math.max(now - first, OWN_MIN_DAYS) / 86400)
end

P.EVIDENCE_OLD = 3 * 86400 -- realm data older than this is a guess
P.EVIDENCE_AGING = 86400

-- How far to trust the item's AH price, and a price safe to plan on:
--   min, market, regionMarket, regionSale     prices as P.Get gives them (before the cut)
--   listed, auctions, sellers, from           this realm's listings now (P.SellRate)
--   perDay, rate                              region sales
--   scanAge, realmAge, regionAge              seconds: our scan of it, TSM's app data
--   spread = min / market - 1, realmVsRegion = market / regionMarket - 1
--   vsSale = market / regionSale - 1
--   sale, buy = { price, qty, time, n }       your last auction sale / buy (TSM ledger)
--   avgSell, avgBuy                           TSM accounting averages (TSM loaded)
--   level = "high" | "medium" | "low", reasons = { "1 seller", ... }, the worst first
--   price: conservative, the lowest of the fresh min buyout, market and region sale average
-- Realm sales aren't known (see P.SellRate), so sold/day is the region's. nil with no AH data.
function P.Evidence(itemID)
  if not itemID then return nil end
  local e = { min = P.Get(itemID, "minBuyout"), market = P.Get(itemID, "market"),
    regionMarket = P.Get(itemID, "regionMarket"), regionSale = P.Get(itemID, "regionSale") }
  local s = P.SellRate(itemID) or {}
  e.listed, e.auctions, e.from, e.perDay, e.rate = s.listed, s.auctions, s.from, s.perDay, s.rate
  local now = M.Now()
  local own = M.Auction and M.Auction.Get(itemID)
  if own and own.t then e.scanAge = now - own.t end
  if own and e.from == "scan" then e.sellers = own.sellers end
  local rt, gt = P.DataTime("realm"), P.DataTime("region")
  e.realmAge, e.regionAge = rt and now - rt, gt and now - gt
  -- TSM's realm data says nothing about a variant: how fresh its prices are is our scan's age
  if Variant(itemID) then e.realmAge = nil end
  if not (e.min or e.market or e.regionMarket or e.regionSale) then return nil end
  if e.min and e.market then e.spread = e.min / e.market - 1 end
  if e.market and e.regionMarket then e.realmVsRegion = e.market / e.regionMarket - 1 end
  if e.market and e.regionSale then e.vsSale = e.market / e.regionSale - 1 end
  local mine = Ledger()[Id(itemID)]
  if mine then e.sale, e.buy = mine.sale, mine.buy end
  e.avgSell, e.avgBuy = P.Custom("AvgSell", itemID), P.Custom("SmartAvgBuy", itemID)

  local low, medium = {}, {}
  -- prices that disagree (min vs market, realm vs region, market vs sales): the safe price
  -- already takes the lowest of them, so these alone don't make it a guess
  local spreadLow = 0
  local function Spread(text) low[#low + 1] = text spreadLow = spreadLow + 1 end
  local function Pct(f) return ("%d%%"):format(math.floor(math.abs(f) * 100 + 0.5)) end
  if not (e.min or e.market) then low[#low + 1] = "region price only" end
  if not e.perDay then
    low[#low + 1] = "no sales data"
  elseif e.perDay < P.SELLS_PER_DAY then
    low[#low + 1] = "sells " .. M.Count(e.perDay) .. "/day in region"
  elseif e.perDay < 2 then
    medium[#medium + 1] = "sells " .. M.Count(e.perDay) .. "/day in region"
  end
  if e.rate and e.rate < P.SELLS_RATE then
    low[#low + 1] = Pct(e.rate) .. " of listings sell"
  elseif e.rate and e.rate < 0.25 then
    medium[#medium + 1] = Pct(e.rate) .. " of listings sell"
  end
  if e.spread then
    local text = "min " .. Pct(e.spread) .. (e.spread < 0 and " under" or " over") .. " market"
    local far = math.abs(e.spread)
    if far >= 0.5 then Spread(text) elseif far >= 0.25 then medium[#medium + 1] = text end
  end
  if e.realmVsRegion then
    local x = e.realmVsRegion + 1
    local text = x >= 1 and ("realm %.1fx region"):format(x) or ("realm %s under region")
      :format(Pct(e.realmVsRegion))
    if x >= 2 then Spread(text)
    elseif x >= 1.5 or x <= 0.5 then medium[#medium + 1] = text end
  end
  -- what it actually sells for: a market far above that is asking, not getting
  if e.vsSale and e.vsSale >= 0.5 then
    local text = ("market %.1fx region sales"):format(e.vsSale + 1)
    if e.vsSale >= 1 then Spread(text) else medium[#medium + 1] = text end
  end
  if e.listed == 0 then
    medium[#medium + 1] = "none up"
  elseif e.sellers == 1 or (e.auctions and e.auctions <= 2) then
    medium[#medium + 1] = e.sellers == 1 and "1 seller" or (e.auctions .. " up")
  end
  -- the freshest realm figure we have
  local age = math.min(e.scanAge or math.huge, e.realmAge or math.huge)
  if age == math.huge then
    if e.min or e.market then medium[#medium + 1] = "data age unknown" end
  elseif age > P.EVIDENCE_OLD then
    low[#low + 1] = "data " .. math.floor(age / 86400) .. " days old"
  elseif age > P.EVIDENCE_AGING then
    medium[#medium + 1] = "data " .. math.floor(age / 86400) .. " day old"
  end
  e.level = #low > 0 and "low" or #medium > 0 and "medium" or "high"
  e.spreadOnly = #low > 0 and #low == spreadLow
  e.reasons = low
  for _, r in ipairs(medium) do e.reasons[#e.reasons + 1] = r end

  local fresh = e.min and (e.from == "scan" or (e.realmAge or math.huge) <= P.EVIDENCE_OLD)
  for _, v in ipairs({ fresh and e.min or false, e.market or false,
    e.regionSale or e.regionMarket or false }) do
    if v and v < (e.price or math.huge) then e.price = v end
  end
  return e
end

M.commands.sells = function(rest)
  local id = tonumber(rest) or tonumber((rest or ""):match("item:(%d+)"))
  if not id then return M.Print("/meio sells <item link or ID>") end
  local s = P.SellRate(id)
  if not s then return M.Print("no sales or listing data for item " .. id) end
  local function Pct(r) return r and ("%d%%"):format(math.floor(r * 100 + 0.5)) or "-" end
  local age = s.age and (" %dm ago"):format(math.floor(s.age / 60)) or ""
  M.Print(("%s: %s/day, sells %s | %s up (%s%s) | clears in %s days"):format(rest,
    M.Count(s.perDay), Pct(s.rate), s.listed or "-", s.from or "no listings data", age,
    s.clearDays and M.Count(s.clearDays) or "-"))
end

M.commands.source = function()
  local s = P.Source()
  M.Print(s == "TSM" and "prices from TSM" or s and "prices from TSM app data (TSM not loaded)"
    or "no price data: TSM and its app data are both missing")
end
