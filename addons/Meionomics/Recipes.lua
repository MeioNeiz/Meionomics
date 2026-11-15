-- Recipes, from CraftProfit: recorded whenever a profession window or trainer shows them, learned
-- or not, for every character. CraftProfit's recorded recipes are imported at login while it is
-- still installed.
--   cost    materials at TSM's MatPrice, else the cheaper of market value and min buyout
--   sells   market value less the 5% AH cut, or the vendor price if that is more; P.Evidence's
--           safe price instead when confidence in the market value isn't high
--   profit  sells x number made - cost
local _, M = ...
local R = {}
M.Recipes = R

local AH_CUT = 0.95
local DEFAULT_SELL = "first(DBMarket, DBRegionSaleAvg, DBHistorical)"
local DEFAULT_MAT = "MatPrice"
local RECIPE_CLASS = (Enum.ItemClass and Enum.ItemClass.Recipe) or 9
local P = M.Prices

local db, charKey
local byOutput, byName, byMat, dirty = {}, {}, {}, true
local listeners = {}

-- fn() after a profession or trainer scan, or the CraftProfit import, has changed recipes
function R.OnUpdate(fn) listeners[#listeners + 1] = fn end
local function Changed()
  for _, fn in ipairs(listeners) do
    local ok, err = pcall(fn)
    if not ok then geterrorhandler()(err) end
  end
end

-- id -> rec; read-only for callers
function R.All() return db.recipes end

------------------------------------------------------------------------------ Prices
-- per item, for one tooltip or one pass over a list
local cache = {}
function R.ResetCache() wipe(cache) end

function R.MatPrice(itemID)
  local key = "m" .. itemID
  if cache[key] == nil then
    local v = P.Best(itemID, db.matPrice or DEFAULT_MAT)
    if not v then
      local market, buyout = P.Get(itemID, "market"), P.Get(itemID, "minBuyout")
      v = (market and buyout) and math.min(market, buyout) or market or buyout
    end
    cache[key] = v or false
  end
  return cache[key] or nil
end

-- what one sells for: after the AH cut, or to a vendor if that pays more; and where.
-- level: P.Evidence's confidence when the AH price counts
function R.SellValue(itemID)
  local key = "s" .. itemID
  if cache[key] == nil then
    local ah = P.Best(itemID, db.sellPrice or DEFAULT_SELL, "market", "regionSale", "historical")
    local ev = ah and P.Evidence and P.Evidence(itemID)
    if ev and ev.level ~= "high" and ev.price and ev.price < ah then ah = ev.price end
    local net = ah and ah * AH_CUT
    local vendor = P.Get(itemID, "vendor")
    if vendor and (not net or vendor >= net) then
      cache[key] = { vendor, "vendor" }
    elseif net then
      cache[key] = { net, "ah", ev and ev.level }
    else
      cache[key] = false
    end
  end
  local v = cache[key]
  if v then return v[1], v[2], v[3] end
end

------------------------------------------------------------------------------ Recording
local function ProfessionOf(recipeID, fallback)
  if C_TradeSkillUI and C_TradeSkillUI.GetTradeSkillLineForRecipe then
    local ok, _, name, _, parentName = pcall(C_TradeSkillUI.GetTradeSkillLineForRecipe, recipeID)
    name = ok and (parentName or name)
    if type(name) == "string" and name ~= "" then return name end
  end
  return fallback
end

-- enchants are kept too (no item made: rec.out is nil), their cost matters for levelling
local function Record(recipeID, profName, learned)
  if type(recipeID) ~= "number" then return nil end
  local ok, s = pcall(C_TradeSkillUI.GetRecipeSchematic, recipeID, false)
  if not ok or type(s) ~= "table" then return nil end
  local mats = {}
  for _, slot in ipairs(s.reagentSlotSchematics or {}) do
    local basic = slot.reagentType == nil
      or (Enum.CraftingReagentType and slot.reagentType == Enum.CraftingReagentType.Basic)
    local r = slot.reagents and slot.reagents[1]
    if basic and r and r.itemID and (slot.quantityRequired or 0) > 0 then
      mats[#mats + 1] = { r.itemID, slot.quantityRequired }
    end
  end
  if #mats == 0 then return nil end
  local rec = db.recipes[recipeID] or {}
  db.recipes[recipeID] = rec
  rec.id = recipeID
  local okInfo, info = pcall(C_TradeSkillUI.GetRecipeInfo, recipeID)
  info = okInfo and info or nil
  rec.name = (info and info.name) or s.name or rec.name
  rec.icon = (info and info.icon) or rec.icon
  rec.prof = ProfessionOf(recipeID, profName) or rec.prof
  rec.out = s.outputItemID
  rec.qmin, rec.qmax = s.quantityMin or 1, s.quantityMax or s.quantityMin or 1
  rec.mats = mats
  rec.known = rec.known or {}
  if learned == true then
    rec.known[charKey] = true
    if info then
      rec.diff, rec.skillUps = info.relativeDifficulty, info.numSkillUps
      rec.grey = info.maxTrivialLevel
    end
  end
  dirty = true
  return rec
end
R.Record = Record

local scanning
local function ScanProfession()
  local T = C_TradeSkillUI
  if scanning or not (T and T.IsTradeSkillReady and T.IsTradeSkillReady()) then return end
  local linked = T.IsTradeSkillLinked and T.IsTradeSkillLinked()
  local guild = T.IsTradeSkillGuild and T.IsTradeSkillGuild()
  local npc = T.IsNPCCrafting and T.IsNPCCrafting()
  if linked or guild or npc then return end
  local prof
  local okP, base = pcall(T.GetBaseProfessionInfo)
  if okP and type(base) == "table" then prof = base.professionName or base.parentProfessionName end
  local ids
  if T.GetAllRecipeIDs then
    local ok, all = pcall(T.GetAllRecipeIDs)
    if ok and type(all) == "table" and #all > 0 then ids = all end
  end
  if not ids then
    local ok, list = pcall(T.GetFilteredRecipeIDs)
    ids = ok and list or {}
  end
  -- a big profession is hundreds of recipes: a few dozen per frame
  scanning = true
  local i = 1
  local function Step()
    local stop = math.min(#ids, i + 40)
    for n = i, stop do
      local okI, info = pcall(T.GetRecipeInfo, ids[n])
      Record(ids[n], prof, okI and info and info.learned)
    end
    i = stop + 1
    if i <= #ids then
      C_Timer.After(0, Step)
    else
      scanning = false
      Changed()
    end
  end
  Step()
end

local function TrainerRecipeID(index)
  if not (C_TooltipInfo and C_TooltipInfo.GetTrainerService) then return nil end
  local ok, data = pcall(C_TooltipInfo.GetTrainerService, index)
  if not (ok and type(data) == "table" and type(data.id) == "number") then return nil end
  if Enum.TooltipDataType and data.type == Enum.TooltipDataType.Item then return nil end
  return data.id
end

R.TrainerRecipeID = TrainerRecipeID

local function TrainerProf()
  if not GetTrainerServiceSkillLine then return nil end
  local ok, name = pcall(GetTrainerServiceSkillLine, 1)
  if ok and type(name) == "string" and name ~= "" then return name end
end

local function RecordService(i, prof)
  local _, kind = GetTrainerServiceInfo(i)
  if not kind or kind == "header" then return nil end
  local id = TrainerRecipeID(i)
  local rec = id and Record(id, prof, kind == "used")
  if rec then
    local req
    if GetTrainerServiceSkillReq then _, req = GetTrainerServiceSkillReq(i) end
    local cost = GetTrainerServiceCost and GetTrainerServiceCost(i) or 0
    rec.train = { cost = cost, req = req, npc = UnitName("npc"), zone = GetRealZoneText() }
  end
  return rec
end

local function ScanTrainer()
  if not GetNumTrainerServices then return end
  local prof = TrainerProf()
  for i = 1, GetNumTrainerServices() do RecordService(i, prof) end
  Changed()
end

-- one trainer line, for a tooltip shown before the scan after TRAINER_SHOW has run
function R.RecordTrainerService(i)
  if not GetTrainerServiceInfo then return nil end
  local rec = RecordService(i, TrainerProf())
  if rec then Changed() end
  return rec
end

-- recipe items a vendor sells: itemID -> npc name -> { zone, price, limited, t }. Limited stock
-- is only knowable at the vendor (numAvailable), so it is recorded on every visit.
local function ScanMerchant()
  if not (GetMerchantNumItems and GetMerchantItemID) then return end
  local npc = UnitName("npc")
  if not npc then return end
  for i = 1, GetMerchantNumItems() do
    local id = GetMerchantItemID(i)
    local classID = id and select(6, C_Item.GetItemInfoInstant(id))
    if classID == RECIPE_CLASS then
      local ok, price, numAvailable
      if C_MerchantFrame and C_MerchantFrame.GetItemInfo then
        local info
        ok, info = pcall(C_MerchantFrame.GetItemInfo, i)
        ok = ok and type(info) == "table"
        if ok then price, numAvailable = info.price, info.numAvailable end
      elseif GetMerchantItemInfo then
        ok, _, _, price, _, numAvailable = pcall(GetMerchantItemInfo, i)
      end
      if ok then
        db.vendors[id] = db.vendors[id] or {}
        db.vendors[id][npc] = { zone = GetRealZoneText(), price = price,
          limited = (numAvailable or -1) >= 0, t = M.Now() }
      end
    end
  end
end

function R.Vendors(itemID) return db.vendors[itemID] end

------------------------------------------------------------------------------ Lookup
local function Rebuild()
  if not dirty then return end
  wipe(byOutput)
  wipe(byName)
  wipe(byMat)
  for _, rec in pairs(db.recipes) do
    if rec.out then
      byOutput[rec.out] = byOutput[rec.out] or {}
      table.insert(byOutput[rec.out], rec)
    end
    for _, m in ipairs(rec.mats or {}) do
      byMat[m[1]] = byMat[m[1]] or {}
      table.insert(byMat[m[1]], rec)
    end
    if rec.name then
      byName[rec.name] = byName[rec.name] or {}
      table.insert(byName[rec.name], rec)
    end
  end
  dirty = false
end

function R.Making(itemID)
  Rebuild()
  return byOutput[itemID]
end

-- recipes that use it as a material
function R.UsedIn(itemID)
  Rebuild()
  return byMat[itemID]
end

-- recipe item -> recipe spell, from CraftData's recipe item column (client DB2)
local byTeacher
local function TaughtByData(itemID)
  if not byTeacher then
    byTeacher = {}
    for id, d in pairs(M.CraftData or {}) do
      if d[6] ~= 0 then byTeacher[d[6]] = id end
    end
  end
  local id = byTeacher[itemID]
  return id and (db.recipes[id] or Record(id))
end

-- "Pattern: Red Woolen Bag" teaches "Red Woolen Bag": by the client data (recorded on first
-- sight, so formulas for recipes never seen in a window work too), the item's spell, its name
function R.TaughtBy(itemID)
  local classID = select(6, C_Item.GetItemInfoInstant(itemID))
  if classID ~= RECIPE_CLASS then return nil end
  local known = TaughtByData(itemID)
  if known then return { known } end
  local okS, _, spellID = pcall(C_Item.GetItemSpell, itemID)
  local rec = okS and type(spellID) == "number" and db.recipes[spellID]
  if rec then return { rec } end
  local name = C_Item.GetItemNameByID(itemID)
  if type(name) ~= "string" then return nil end
  Rebuild()
  return byName[name:match("^[^:]+:%s*(.+)$") or name] or byName[name]
end

function R.Made(rec) return ((rec.qmin or 1) + (rec.qmax or 1)) / 2 end
-- recipes only in the client data (C.Recipe built them, never seen in a window): the spell
function R.KnownHere(rec)
  if rec.known and rec.known[charKey] then return true end
  return rec.built and IsPlayerSpell and IsPlayerSpell(rec.id) or nil
end
function R.KnownBy(rec)
  local names = {}
  for who in pairs(rec.known or {}) do
    local c = db.chars[who]
    names[#names + 1] = c and c.name or who:match("^([^-]+)")
  end
  table.sort(names)
  return names
end

-- { cost, complete, value, where, profit } for one craft
function R.Evaluate(rec)
  local cost, complete = 0, true
  for _, m in ipairs(rec.mats) do
    local p = R.MatPrice(m[1])
    if p then cost = cost + p * m[2] else complete = false end
  end
  local e = { cost = cost, complete = complete }
  if rec.out then
    local each, where = R.SellValue(rec.out)
    e.value, e.where = each and each * R.Made(rec), where
    e.profit = (e.value and complete) and (e.value - cost) or nil
  end
  return e
end

-- profit first, then recipe ID: lookup lists come from pairs(), so ties need a fixed order
function R.Before(a, aE, b, bE)
  local pa, pb = aE.profit or -math.huge, bE.profit or -math.huge
  if pa ~= pb then return pa > pb end
  return (a.id or 0) < (b.id or 0)
end

-- the best way to make it when several recipes do: highest profit among fully priced ones, else
-- any (shown with what is known)
function R.Best(recs)
  local best, bestE
  for _, rec in ipairs(recs) do
    local e = R.Evaluate(rec)
    local better = not best or (e.complete and not bestE.complete)
      or (e.complete == bestE.complete and R.Before(rec, e, best, bestE))
    if better then best, bestE = rec, e end
  end
  return best, bestE
end

-- material cost to make one: the cheapest fully priced recorded recipe, known ones first.
-- Public, for other addons (KafStats): -> each (copper), rec; nil with no priced recipe
function R.CostEach(itemID)
  local best, bestEach, bestKnown
  for _, rec in ipairs(R.Making(itemID) or {}) do
    local e = R.Evaluate(rec)
    local each = e.complete and e.cost / R.Made(rec)
    local known = next(rec.known or {}) ~= nil
    if each and (not best or (known and not bestKnown)
      or (known == bestKnown and each < bestEach)) then
      best, bestEach, bestKnown = rec, each, known
    end
  end
  return bestEach, best
end

------------------------------------------------------------------------------ Setup
-- CraftProfit keys characters "Name-Realm", and the realm name the client reports has changed
-- over time ("CAMWOW EU4 Realm 8 PvP", "PvP"): this character is matched by first name
local function ImportCraftProfit()
  local src = CraftProfitDB and CraftProfitDB.recipes
  if type(src) ~= "table" then return end
  local first = (UnitName("player") or ""):match("^%S+")
  for id, rec in pairs(src) do
    local mine = db.recipes[id]
    if not mine then
      mine = CopyTable(rec)
      mine.known = {}
      db.recipes[id] = mine
    end
    mine.id = id
    mine.known = mine.known or {}
    for who in pairs(rec.known or {}) do
      mine.known[who:match("^([^-%s]+)") == first and charKey or who] = true
    end
    mine.train = mine.train or (rec.train and CopyTable(rec.train))
  end
  dirty = true
  Changed()
end

-- this character's professions: name -> { rank, max, skillLine }
local function ScanProfessions()
  local me = db.chars[charKey]
  if not (GetProfessions and GetProfessionInfo) then return end
  me.profs = {}
  for _, index in pairs({ GetProfessions() }) do
    local name, _, rank, maxRank, _, _, skillLine = GetProfessionInfo(index)
    if name then
      me.profs[name] = { rank = rank, max = maxRank, skillLine = skillLine }
    end
  end
end

function R.Professions() return db.chars[charKey].profs or {} end

local prevOnLoad = M.OnLoad
function M.OnLoad()
  if prevOnLoad then prevOnLoad() end
  db = M.db
  db.recipes = db.recipes or {}
  db.chars = db.chars or {}
  db.vendors = db.vendors or {}
  for id, rec in pairs(db.recipes) do rec.id = id end
end

M.On("PLAYER_LOGIN", function()
  -- the GUID: names and realm names on Forever have both changed under us
  charKey = UnitGUID("player")
  local me = db.chars[charKey] or {}
  db.chars[charKey] = me
  me.name, me.realm, me.class = UnitName("player"), GetRealmName(), select(2, UnitClass("player"))
  ScanProfessions()
  ImportCraftProfit()
  pcall(M.On, "SKILL_LINES_CHANGED", ScanProfessions)
  -- windows send bursts of events: one scan a moment after the last
  local tickets = {}
  local function Later(kind, fn)
    tickets[kind] = (tickets[kind] or 0) + 1
    local t = tickets[kind]
    C_Timer.After(0.5, function() if tickets[kind] == t then fn() end end)
  end
  local profEvents = { "TRADE_SKILL_SHOW", "TRADE_SKILL_LIST_UPDATE",
    "TRADE_SKILL_DATA_SOURCE_CHANGED" }
  for _, e in ipairs(profEvents) do
    pcall(M.On, e, function() Later("prof", ScanProfession) end)
  end
  for _, e in ipairs({ "TRAINER_SHOW", "TRAINER_UPDATE" }) do
    pcall(M.On, e, function() Later("trainer", ScanTrainer) end)
  end
  for _, e in ipairs({ "MERCHANT_SHOW", "MERCHANT_UPDATE" }) do
    pcall(M.On, e, function() Later("merchant", ScanMerchant) end)
  end
end)

local function SetPrice(key, kind)
  return function(rest)
    local default = kind == "sell" and DEFAULT_SELL or DEFAULT_MAT
    if rest == "" then
      M.Print(("%s price: %s"):format(kind, db[key] or default))
    elseif P.Valid(rest) then
      db[key] = rest
      M.Print(("%s price set to %s"):format(kind, rest))
    else
      M.Print("TSM isn't loaded or doesn't accept that price string.")
    end
  end
end
M.commands.sell = SetPrice("sellPrice", "sell")
M.commands.mat = SetPrice("matPrice", "mat")
