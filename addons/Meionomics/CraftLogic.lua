-- Crafting numbers behind the panel (CraftUI.lua): per recipe profit, sales, skill-up value,
-- what you hold of each material; the queue and its shopping list.
--
-- Skill-ups: orange below yellow (a point every craft), then the chance falls in a straight
-- line to 0 at grey: (grey - rank) / (grey - yellow). Thresholds from CraftData.lua (DB2).
-- Learning a recipe: trainer fee, pattern price, or 0 when known or the pattern is held.
-- Estimates are flagged (x.est*) so the panel can mark them "~".
local _, M = ...
local R, P, I = M.Recipes, M.Prices, M.Inventory
local C = {}
M.Craft = C

local MAX_DEPTH = 3   -- intermediates (bolts) crafted from intermediates...
-- trainers teach a recipe up to this far under its yellow; the requirement itself is only in
-- the trainer's list
local TRAINER_SPAN = 20

------------------------------------------------------------------------------ Recipes
-- profession name of a skill line: this character's, else the client's
local function LineName(line)
  for name, p in pairs(R.Professions()) do
    if p.skillLine == line then return name end
  end
  local T = C_TradeSkillUI
  return T and T.GetTradeSkillDisplayName and T.GetTradeSkillDisplayName(line) or nil
end
C.LineName = LineName

-- every crafting profession in CraftData by name -> skill line, learnt or not. Not class skill
-- lines (Poisons only for rogues) nor the client's test line.
local POISONS = 40
local lines
function C.Lines()
  if lines then return lines end
  lines = {}
  local seen = {}
  local rogue = select(2, UnitClass("player")) == "ROGUE"
  for _, d in pairs(M.CraftData) do
    local line = d[5]
    if not seen[line] and R.PROFESSION_LINES[line] and (line ~= POISONS or rogue) then
      seen[line] = true
      local name = LineName(line)
      if name and name ~= "" and not name:find("[DNT]", 1, true) then
        lines[name] = line
      end
    end
  end
  return lines
end

function C.LineOf(prof)
  local p = R.Professions()[prof]
  return p and p.skillLine or C.Lines()[prof]
end

-- a recipe by spell ID: as recorded, else built from CraftData (never seen in a window: no
-- rec.known, not stored in the db)
local built = {}
function C.Recipe(id)
  local rec = R.All()[id]
  if rec and rec.mats then return rec end
  if built[id] then return built[id] end
  local d = M.CraftData[id]
  if not (d and d[9] and #d[9] > 0) then return rec end
  local mats = {}
  for i = 1, #d[9], 2 do mats[#mats + 1] = { d[9][i], d[9][i + 1] } end
  local out = d[7] ~= 0 and d[7] or nil
  rec = { id = id, name = C_Spell.GetSpellName(id), prof = LineName(d[5]), out = out,
    qmin = d[8], qmax = d[8], mats = mats, known = {}, built = true,
    icon = out and C_Item.GetItemIconByID(out) or C_Spell.GetSpellTexture(id) }
  built[id] = rec
  return rec
end

------------------------------------------------------------------------------ Skill
-- learn, yellow, green, grey, skill-ups when orange, recipe item, estimated learn, estimated
-- bands. Trainer recipes say learn 1 in the client data; CraftData has the wiki's requirement
-- for most. The trainer's own (rec.train.req) wins once visited. For the rest, yellow -
-- min(TRAINER_SPAN, the yellow-to-grey width): narrow-band crafts (bolts, shirts) are learnt
-- close to yellow. Fitted on recipes whose items state their requirement: mean error 5 points.
-- Unlisted learn-1 recipes yellow by 40 are all starting recipes (Linen Bandage 1/30/60 was
-- estimated 10, so First Aid planned from 1 stuck)
function C.Bands(rec)
  local d = M.CraftData[rec.id]
  local learn = rec.train and rec.train.req
  if d then
    local estLearn = false
    if not learn then
      if d[1] > 1 or d[6] ~= 0 or d[2] <= 40 then
        learn = d[1]
      else
        learn, estLearn = math.max(1, d[2] - math.min(TRAINER_SPAN, d[3] - d[2])), true
      end
    end
    local item = d[6] ~= 0 and d[6] or nil
    return learn, d[2], math.floor((d[2] + d[3]) / 2), d[3], d[4], item, estLearn, false
  end
  if rec.grey and rec.grey > 0 then   -- recorded grey only: vanilla's usual spread
    local g = rec.grey
    return learn or (g - 50), g - 25, g - 12, g, rec.skillUps or 1, nil, not learn, true
  end
end

function C.Colour(rank, yellow, green, grey)
  if rank >= grey then return "grey" end
  if rank >= green then return "green" end
  if rank >= yellow then return "yellow" end
  return "orange"
end

C.DIFF_HEX = { orange = "ff8040", yellow = "ffff00", green = "40bf40", grey = "a0a0a0" }

-- the recipe's colour at your current rank, as hex; nil when the rank or bands are unknown
function C.DiffHex(rec)
  local rank = rec.prof and C.Rank(rec.prof)
  local _, yellow, green, grey = C.Bands(rec)
  if not (rank and grey) then return nil end
  return C.DIFF_HEX[C.Colour(rank, yellow, green, grey)]
end

function C.Chance(rank, yellow, grey)
  if rank >= grey then return 0 end
  if rank < yellow then return 1 end
  return (grey - rank) / (grey - yellow)
end

-- current rank in a profession by name: the open window first (live), else the login scan
function C.Rank(prof)
  local T = C_TradeSkillUI
  if not R.Viewer() and T and T.IsTradeSkillReady and T.IsTradeSkillReady() then
    local ok, b = pcall(T.GetBaseProfessionInfo)
    if ok and b and b.professionName == prof and b.skillLevel then
      return b.skillLevel, b.maxSkillLevel
    end
  end
  local p = R.Professions()[prof]
  if p then return p.rank, p.max end
end

-- the training cap a rank sits under (75 Apprentice ... 300 Artisan): what-if ranks
function C.CapAt(rank)
  return math.min(300, math.max(75, math.ceil(rank / 75) * 75))
end

-- a pattern bought now: the cheaper of a vendor and the AH
function C.PatternPrice(item)
  local ah = P.Get(item, "minBuyout") or P.Get(item, "market") or P.Get(item, "regionMarket")
  local vendor = P.VendorBuy(item)
  if ah and vendor then return math.min(ah, vendor), "vendor or AH" end
  if vendor then return vendor, "vendor" end
  if ah then return ah, "AH" end
end

function C.Ago(sec)
  if sec < 3600 then return ("%d min ago"):format(math.max(1, math.floor(sec / 60))) end
  if sec < 86400 then return ("%d h ago"):format(math.floor(sec / 3600)) end
  return ("%d days ago"):format(math.floor(sec / 86400))
end
local Ago = C.Ago

-- M.Patterns' record (Patterns.lua) over a scan's count or TSM's while this fresh
local SEEN_TRUST = 3 * 86400

local function FromSeen(seen, now)
  if seen.up then
    return { how = "ah", listed = seen.qty, price = seen.price,
      text = ("%d listed from %s (%s)"):format(seen.qty, M.Money(seen.price), Ago(now - seen.t)) }
  end
  local last = seen.t and ("last %s %s"):format(M.Money(seen.price), Ago(now - seen.t))
    or "never seen"
  return { how = "none",
    text = ("not on AH (checked %s, %s)"):format(Ago(now - seen.checked), last) }
end

-- where a pattern can be had now -> { how = "vendor" | "ah" | "none" | "unknown", listed,
-- price, text }. "none": not up when the Recipe class was last covered (or in a recent scan,
-- or TSM's count) and no vendor sells it
function C.PatternSource(item)
  local vendor = P.VendorBuy(item)
  if vendor then return { how = "vendor", price = vendor, text = "vendor " .. M.Money(vendor) } end
  local now = M.Now()
  local seen = M.Patterns and M.Patterns.Seen(item)
  if seen and not (seen.up or seen.checked) then seen = nil end
  if seen and now - math.max(seen.checked or 0, seen.t or 0) <= SEEN_TRUST then
    return FromSeen(seen, now)
  end
  local s = P.SellRate(item)
  if not (s and s.listed) then
    if seen then return FromSeen(seen, now) end
    return { how = "unknown", text = "AH listings not known" }
  end
  local when = s.from == "scan" and s.age and ("scan " .. Ago(s.age)) or (s.from or "TSM")
  if s.listed == 0 then
    return { how = "none", text = ("not on AH (%s)"):format(when) }
  end
  local own = M.Auction and M.Auction.Get(item)
  local min = own and own.min or P.Get(item, "minBuyout")
  return { how = "ah", listed = s.listed, price = min,
    text = ("%d listed%s"):format(s.listed, min and (" from " .. M.Money(min)) or "") }
end

------------------------------------------------------------------------------ Learning
-- Questie's database (LibQuestieDB, loaded with Questie): who sells or drops an item, which
-- quests give it. nil when Questie isn't loaded or doesn't know.
local function QDB(kind, id, field)
  local lib = LibQuestieDB and LibQuestieDB[kind]
  if not (lib and lib.Get) then return nil end
  local ok, v = pcall(lib.Get, id, field)
  if ok then return v end
end

local function AreaName(zoneID)
  if not (zoneID and zoneID > 0 and C_Map and C_Map.GetAreaInfo) then return nil end
  local ok, name = pcall(C_Map.GetAreaInfo, zoneID)
  return ok and name or nil
end

local FACTION = { Alliance = "A", Horde = "H" }

-- NPC ids -> { name, zone }, own faction's (and neutral) only
local function Npcs(ids)
  local mine = FACTION[UnitFactionGroup("player") or ""]
  local out = {}
  for _, id in ipairs(ids or {}) do
    local f = QDB("Npc", id, "friendlyToFaction")
    if not f or f == "AH" or f == mine or not mine then
      local name = QDB("Npc", id, "name")
      if name then out[#out + 1] = { name = name, zone = AreaName(QDB("Npc", id, "zoneID")) } end
    end
  end
  return out
end

-- where a recipe can be learnt, each { how, who, zone, need, price, limited, n, text }:
--   trainer   recorded visit (npc, zone, required skill, fee), else "not visited" with ~fee
--   vendor    the recipe item: our visits (limited stock), else Questie's vendors
--   drop      Questie's NPCs (n of them) and objects
--   quest     Questie's quests rewarding it
--   ah        C.PatternSource: listed now, or not on the AH
-- Empty when none is known. Needs x from C.Info (x.item, x.learn, x.pattern).
function C.LearnSources(x)
  local rec, out = x.rec, {}
  local function Add(t) out[#out + 1] = t end
  local t = rec.train
  if t then
    Add({ how = "trainer", who = t.npc, zone = t.zone, need = t.req, price = t.cost })
  elseif not x.item then
    Add({ how = "trainer", need = x.learn, price = x.learnCost, est = true })
  end
  local item = x.item
  if not item then return out end
  local seen = {}
  for npc, v in pairs(R.Vendors(item) or {}) do
    seen[npc] = true
    Add({ how = "vendor", who = npc, zone = v.zone, price = v.price, limited = v.limited })
  end
  local price = P.VendorBuy(item)
  for _, n in ipairs(Npcs(QDB("Item", item, "vendors"))) do
    if not seen[n.name] then
      seen[n.name] = true
      Add({ how = "vendor", who = n.name, zone = n.zone, price = price })
    end
  end
  local drops = Npcs(QDB("Item", item, "npcDrops"))
  if #drops > 0 then
    Add({ how = "drop", who = drops[1].name, zone = drops[1].zone, n = #drops })
  end
  local objects = QDB("Item", item, "objectDrops")
  if objects and #objects > 0 then
    local name = QDB("Object", objects[1], "name")
    Add({ how = "drop", who = name, zone = AreaName(QDB("Object", objects[1], "zoneID")),
      n = #objects, object = true })
  end
  for _, q in ipairs(QDB("Item", item, "questRewards") or {}) do
    local name = QDB("Quest", q, "name")
    if name then Add({ how = "quest", who = name, id = q }) end
  end
  local ps = x.pattern or C.PatternSource(item)
  if ps.how == "ah" or ps.how == "none" then
    Add({ how = "ah", n = ps.listed, price = ps.price, text = ps.text, none = ps.how == "none" })
  end
  return out
end

-- a few words for a list row: the easiest way to get it now (the hover has the rest)
function C.LearnWhere(x)
  if x.known then return nil end
  if x.learnFrom == "held" then return "pattern in your bags" end
  local first = {}
  for _, src in ipairs(C.LearnSources(x)) do
    if not (src.how == "ah" and src.none) then first[src.how] = first[src.how] or src end
  end
  local s = first.ah
  if s then return ("AH: %d up, %s"):format(s.n or 0, M.Money(s.price)) end
  s = first.vendor
  if s then return "vendor: " .. s.who end
  if first.trainer then return "trainer" end
  s = first.drop
  if s then return "drop: " .. (s.who or "?") end
  s = first.quest
  if s then return "quest: " .. s.who end
  -- "not available" only when a scan showed none up; without AH data (or Questie for vendors
  -- and drops) we simply don't know
  local ps = x.item and (x.pattern or C.PatternSource(x.item))
  if ps and ps.how == "unknown" then return "source unknown" end
  return "pattern not available"
end

-- Wowhead for this client: the pattern item when there is one (its page lists sources), else the
-- recipe spell
function C.WowheadURL(rec, item)
  if item then return ("https://www.wowhead.com/forever/item=%d"):format(item) end
  return ("https://www.wowhead.com/forever/spell=%d"):format(rec.id)
end

-- recorded trainer fees near a requirement: the median, for trainer recipes not seen yet.
-- Professions only: class trainer spells are recorded too (req 0, gold), and set every
-- low recipe at 54s
function C.EstFee(prof, learn)
  local fees, crafts = {}, C.Lines()
  for _, rec in pairs(R.All()) do
    local t = rec.train
    if t and t.cost and t.cost > 0 and t.req and math.abs(t.req - learn) <= 25
      and crafts[rec.prof] then
      fees[#fees + 1] = { rec.prof == prof and 0 or 1, t.cost }
    end
  end
  if #fees == 0 then return math.max(10, math.floor(learn * learn * 0.4)) end   -- ~vanilla
  table.sort(fees, function(a, b) return a[1] < b[1] or (a[1] == b[1] and a[2] < b[2]) end)
  local same = 0
  for _, f in ipairs(fees) do if f[1] == 0 then same = same + 1 end end
  local n = same > 0 and same or #fees
  return fees[math.ceil(n / 2)][2]
end

-- what learning a recipe costs -> cost, from ("trainer" | "pattern" | "held"), estimated.
-- 0 when known or the pattern is already held; trainer fee once visited, else the pattern's
-- price, else a fee estimated from recorded ones.
function C.LearnCost(rec, item, learn)
  if R.KnownHere(rec) then return 0, "known" end
  local fee = rec.train and rec.train.cost
  if fee and fee > 0 then return fee, "trainer" end
  if item then
    if C.Have(item).total > 0 then return 0, "held" end
    local price = C.PatternPrice(item)
    if price then return price, "pattern" end
    return nil, "pattern"
  end
  if rec.train then return 0, "trainer" end
  return C.EstFee(rec.prof, learn or 1), "trainer", true
end

------------------------------------------------------------------------------ Holdings
-- this character's bags, bank, mail; alts (+ warband, guild) unless left out: where to get it
-- per R.ResetCache pass: a full list asks about the same few materials thousands of times
local haves = {}
local resetCache = R.ResetCache
function R.ResetCache()
  resetCache()
  wipe(haves)
end

function C.Have(itemID)
  local h = haves[itemID]
  if not h then
    h = C.HaveNow(itemID)
    haves[itemID] = h
  end
  return h
end

-- AH purchases go to the mailbox, which Syndicator only counts once it's opened: until then
-- they count as mail here. Gone when the mailbox opens, the bags grow by them, or in 2 days.
local BOUGHT_KEEP = 2 * 86400
local function Bought()
  local key = UnitGUID("player")
  M.db.bought = M.db.bought or {}
  M.db.bought[key] = M.db.bought[key] or {}
  return M.db.bought[key]
end

function C.AddBought(itemID, n)
  local b = Bought()
  local e = b[itemID]
  if not e then
    e = { n = 0, bags = C_Item.GetItemCount(itemID, false) or 0 }
    b[itemID] = e
  end
  e.n, e.t = e.n + n, M.Now()
  R.ResetCache()
end

function C.BoughtPending(itemID)
  local b = Bought()
  local e = b[itemID]
  if not e then return 0 end
  if M.Now() - e.t > BOUGHT_KEEP or (C_Item.GetItemCount(itemID, false) or 0) - e.bags >= e.n then
    b[itemID] = nil
    return 0
  end
  return e.n
end

M.On("MAIL_INBOX_UPDATE", function()
  if M.db and M.db.bought then wipe(Bought()) end
end)

-- Whether items elsewhere count as held (queue, shopping list, routes, verdicts):
-- craftUI.altMats false: this character's only; craftUI.altSkip[key]: that alt left out.
-- key: Syndicator's "Name-Realm"; nil asks about other characters at all.
function C.UsesAlt(key)
  local s = M.db.craftUI
  if not s or s.altMats == false then return false end
  return not (key and s.altSkip and s.altSkip[key])
end

function C.HaveNow(itemID)
  local inv = I.Get(itemID)
  local bought = C.BoughtPending(itemID)
  if not inv then
    return { bags = 0, bank = 0, mail = bought, alts = 0, total = bought, altList = {} }
  end
  local me = inv.me
  local h = { bags = me.bags or 0, bank = me.bank or 0, mail = (me.mail or 0) + bought,
    alts = 0, altList = {} }
  if C.UsesAlt() then
    h.alts = inv.warband + inv.guild
    for _, a in ipairs(inv.alts) do
      if C.UsesAlt(a.key) then
        h.altList[#h.altList + 1] = a
        h.alts = h.alts + a.total
      end
    end
  end
  h.total = h.bags + h.bank + h.mail + h.alts
  return h
end

-- crafts possible from bags alone, and from everything held (alts as C.UsesAlt allows)
function C.Makeable(rec)
  local bags, all = math.huge, math.huge
  for _, m in ipairs(rec.mats) do
    local h = C.Have(m[1])
    bags = math.min(bags, math.floor(h.bags / m[2]))
    all = math.min(all, math.floor(h.total / m[2]))
  end
  if bags == math.huge then return 0, 0 end
  return bags, all
end

------------------------------------------------------------------------------ Rows
-- everything the panel shows about one recipe at a rank; sale values, batches, per point
-- costs and the verdict's numbers come from CraftVerdict.lua (C.Value.Fill)
function C.Info(rec, rank)
  local e = R.Evaluate(rec)
  local x = { rec = rec, e = e, known = R.KnownHere(rec) and true or false, rank = rank }
  x.perDay = rec.out and P.Get(rec.out, "soldPerDay")
  x.bags, x.all = C.Makeable(rec)
  local learn, yellow, green, grey, ups, item, estLearn, estBands = C.Bands(rec)
  x.learn, x.yellow, x.green, x.grey, x.item = learn, yellow, green, grey, item
  x.estLearn, x.estBands = estLearn, estBands
  x.learnCost, x.learnFrom, x.learnEst = C.LearnCost(rec, item, learn)
  if x.learnFrom == "pattern" and item then x.pattern = C.PatternSource(item) end
  if grey and rank then
    x.colour = C.Colour(rank, yellow, green, grey)
    x.tooLow = learn and rank < learn
    x.chance = x.tooLow and 0 or C.Chance(rank, yellow, grey)
    x.points = x.chance * (x.colour == "orange" and ups or 1)
    x.span = math.max(1, (rank < green and green or grey) - rank)
  end
  -- CraftVerdict.lua is new: a /reload without a restart has not loaded it
  if C.Value then C.Value.Fill(x, rank) end
  return x
end

-- sets x.learnable: the requirement (or its estimate) is met and the recipe isn't grey
function C.Learnable(x, rank)
  if not x.known and rank and x.learn then
    x.learnable = rank >= x.learn and not (x.estLearn and x.grey and rank >= x.grey)
  end
  return x.learnable
end

-- recorded recipes of a profession; show = "known" | "learnable" | "all" (C.Learnable).
-- wide: also every CraftData recipe of it never seen in a window (a profession not learnt)
function C.List(prof, show, rank, wide)
  local out = {}
  R.ResetCache()
  local function Add(rec)
    local x = C.Info(rec, rank)
    C.Learnable(x, rank)
    if x.known or show == "all" or (show == "learnable" and x.learnable) then
      out[#out + 1] = x
    end
  end
  local seen = {}
  for id, rec in pairs(R.All()) do
    if rec.prof == prof and rec.mats then
      seen[id] = true
      Add(rec)
    end
  end
  local line = wide and C.LineOf(prof)
  if line then
    for id, d in pairs(M.CraftData) do
      if d[5] == line and not seen[id] then
        local rec = C.Recipe(id)
        if rec and rec.mats then Add(rec) end
      end
    end
  end
  return out
end

------------------------------------------------------------------------------ Queue
local function Queue()
  local key = UnitGUID("player")
  M.db.queue = M.db.queue or {}
  M.db.queue[key] = M.db.queue[key] or {}
  return M.db.queue[key]
end
C.Queue = Queue

-- recipe -> the skill its queued crafts are for (a route step's end): skill-ups come by
-- chance, so the queue holds the expected count and Craft next stops there instead, the rest
-- taken off (C.PruneQueue)
local function Stops()
  local key = UnitGUID("player")
  M.db.queueStop = M.db.queueStop or {}
  M.db.queueStop[key] = M.db.queueStop[key] or {}
  return M.db.queueStop[key]
end

-- stop: the skill these crafts are for; a recipe queued twice keeps the higher
function C.Enqueue(rec, n, stop)
  local q, stops = Queue(), Stops()
  local v = (q[rec.id] or 0) + n
  q[rec.id] = v > 0 and v or nil
  if not q[rec.id] then
    stops[rec.id] = nil
  elseif stop and n > 0 then
    stops[rec.id] = math.max(stops[rec.id] or 0, stop)
  end
end

function C.QueueStop(id) return Stops()[id] end

function C.ClearQueue()
  wipe(Queue())
  wipe(Stops())
end

-- crafts queued for a skill his rank has reached: off the queue, C.OnPruned told.
-- Not while the panel shows an alt (C.Rank would be theirs)
function C.PruneQueue()
  if R.Viewer() then return end
  local q, stops, gone = Queue(), Stops(), {}
  for id, stop in pairs(stops) do
    local rec = q[id] and C.Recipe(id)
    local rank = rec and rec.prof and C.Rank(rec.prof)
    if not q[id] then
      stops[id] = nil
    elseif rank and rank >= stop then
      gone[#gone + 1] = { rec = rec, n = q[id], stop = stop }
      q[id], stops[id] = nil, nil
    end
  end
  if #gone > 0 and C.OnPruned then C.OnPruned(gone) end
end

function C.QueueCount()
  local n = 0
  for _, v in pairs(Queue()) do n = n + v end
  return n
end

------------------------------------------------------------------------------ Tools
-- Runed rods and the like (M.CraftTool, from client DB2): needed in the bags, not used up
function C.ToolCats(rec) return M.CraftTool and M.CraftTool[rec.id] end

function C.ToolName(cat) return M.CraftTools[cat] and M.CraftTools[cat][1] or "a tool" end

-- one that does is held (anywhere; inBags: in the bags, as casting needs)
function C.HasTool(cat, inBags)
  local t = M.CraftTools and M.CraftTools[cat]
  if not t then return true end
  for _, item in ipairs(t[2]) do
    if inBags and (C_Item.GetItemCount(item, false) or 0) > 0
      or not inBags and C.Have(item).total > 0 then
      return true
    end
  end
  return false
end

-- the first tool category rec needs and none is held of, or nil
function C.MissingTool(rec, inBags)
  for _, cat in ipairs(C.ToolCats(rec) or {}) do
    if not C.HasTool(cat, inBags) then return cat end
  end
end

-- the recipe of this profession making the lowest tool that does: known first, then one
-- recorded (trainer), then CraftData's (not learnt or seen yet)
local dataMaking
local function DataMaking(item)
  if not dataMaking then
    dataMaking = {}
    for id, d in pairs(M.CraftData) do
      if d[7] ~= 0 then
        dataMaking[d[7]] = dataMaking[d[7]] or {}
        table.insert(dataMaking[d[7]], id)
      end
    end
  end
  return dataMaking[item] or {}
end
function C.ToolRecipe(cat, prof)
  local t = M.CraftTools and M.CraftTools[cat]
  if not t then return nil end
  local any
  for _, item in ipairs(t[2]) do
    for _, rec in ipairs(R.Making(item) or {}) do
      if rec.prof == prof and rec.mats then
        if R.KnownHere(rec) then return rec end
        any = any or rec
      end
    end
  end
  if any then return any end
  for _, item in ipairs(t[2]) do
    for _, id in ipairs(DataMaking(item)) do
      local rec = C.Recipe(id)
      if rec and rec.prof == prof and rec.mats then return rec end
    end
  end
end

-- the cheapest known recipe making an item, if crafting it beats buying it
local function CraftInstead(itemID)
  local best, bestEach
  for _, rec in ipairs(R.Making(itemID) or {}) do
    if R.KnownHere(rec) then
      local e = R.Evaluate(rec)
      local each = e.complete and e.cost / R.Made(rec)
      if each and (not bestEach or each < bestEach) then best, bestEach = rec, each end
    end
  end
  local price = R.MatPrice(itemID)
  if best and (not price or bestEach < price) then return best, bestEach end
end
C.CraftInstead = CraftInstead

-- Held materials count as free: Medium Leather in the bags becomes Heavy Leather even when the
-- AH sells Heavy Leather for less. spare(id) = held and not needed elsewhere.
-- -> rec, crafts (from what's held, at most up to `short`), each (full cost, MatPrice)
local function CraftFromHeld(itemID, short, spare)
  local best, bestN, bestBuy
  for _, rec in ipairs(R.Making(itemID) or {}) do
    if R.KnownHere(rec) then
      local n, buy = math.ceil(short / R.Made(rec)), 0
      local held = false
      for _, m in ipairs(rec.mats) do
        local s = spare(m[1])
        if s >= m[2] then
          held = true
          n = math.min(n, math.floor(s / m[2]))
        else
          local p = R.MatPrice(m[1])
          buy = p and buy + p * m[2]
          if not buy then break end
        end
      end
      buy = buy and buy / R.Made(rec)
      if held and buy and n > 0 and (not bestBuy or buy < bestBuy) then
        best, bestN, bestBuy = rec, n, buy
      end
    end
  end
  local price = R.MatPrice(itemID)
  if best and (not price or bestBuy < price) then
    local e = R.Evaluate(best)
    return best, bestN, e.complete and e.cost / R.Made(best) or nil
  end
end

-- Shopping list for the queue. Each material: need, then taken from bags, bank, mail, alts in
-- that order; the rest is bought, or crafted (intermediates such as bolts) from held
-- materials, or when cheaper than buying. Shopping for speed (M.db.craftUI.shopFor) buys
-- intermediates the AH has a price for instead: one purchase, no crafting step.
-- -> { mats = { { id, need, crafted, bags, bank, mail, alts, fromAlts = { {name, n} },
--        buy, price } ... },
--      crafts = { recipeID -> { n, saves } } intermediates to craft first,
--      buyCost, complete, profit (queued crafts, priced ones), saves }
function C.Shopping()
  C.PruneQueue()
  R.ResetCache()
  local need, crafts, order = {}, {}, {}
  local function Add(rec, n, intermediate)
    if intermediate then
      crafts[rec.id] = crafts[rec.id] or { n = 0, saves = 0 }
      crafts[rec.id].n = crafts[rec.id].n + n
    end
    for _, m in ipairs(rec.mats) do
      local id = m[1]
      if not need[id] then
        need[id] = 0
        order[#order + 1] = id
      end
      need[id] = need[id] + m[2] * n
    end
  end
  local out = { mats = {}, crafts = crafts, buyCost = 0, complete = true, profit = 0,
    saves = 0 }
  for id, n in pairs(Queue()) do
    local rec = C.Recipe(id)
    if rec and rec.mats then
      Add(rec, n, false)
      local e = R.Evaluate(rec)
      if e.profit then out.profit = out.profit + e.profit * n end
    end
  end
  -- a tool none is held of (Runed Truesilver Rod): one made first, as an intermediate
  local tooled = {}
  for id in pairs(Queue()) do
    local rec = C.Recipe(id)
    local cat = rec and rec.mats and C.MissingTool(rec)
    local t = cat and not tooled[cat] and C.ToolRecipe(cat, rec.prof)
    if t and not Queue()[t.id] then
      tooled[cat] = true
      Add(t, 1, true)
      crafts[t.id].tool = C.ToolName(cat)
    end
  end
  -- intermediates: what still has to be bought, crafted instead when cheaper (repeated for
  -- the intermediates' own materials)
  local held = {}
  local function Held(id)
    held[id] = held[id] or C.Have(id)
    return held[id]
  end
  -- own: this character's bags, bank and mail, without alts
  local function Count(h, own) return own and h.bags + h.bank + h.mail or h.total end
  local function Spare(id, own)
    local h = Held(id)
    return Count(h, own) + (h.crafted or 0) - (need[id] or 0)
  end
  local function OwnSpare(id) return Spare(id, true) end
  -- saves: against buying at MatPrice; below 0 when held materials are worth more on the AH
  local function Craft(id, rec, made, each)
    local h = Held(id)
    h.crafted = (h.crafted or 0) + made * R.Made(rec)
    Add(rec, made, true)
    local price = R.MatPrice(id)
    if price and each then
      local saves = (price - each) * made * R.Made(rec)
      crafts[rec.id].saves = crafts[rec.id].saves + saves
      out.saves = out.saves + saves
    end
  end
  local fast = M.db.craftUI and M.db.craftUI.shopFor == "speed"
  for _ = 1, MAX_DEPTH do
    local more = false
    for _, id in ipairs(order) do
      local function Short(own)
        local h = Held(id)
        return need[id] - Count(h, own) - (h.crafted or 0)
      end
      -- crafting from own materials beats fetching the item from an alt: 40 Silk Cloth in
      -- the bags makes the bolts an alt would otherwise have to mail
      for _, own in ipairs({ true, false }) do
        if Short(own) > 0 then
          local rec, made, each = CraftFromHeld(id, Short(own), own and OwnSpare or Spare)
          if rec then
            Craft(id, rec, made, each)
            more = true
          end
        end
      end
      if Short() > 0 and not (fast and R.MatPrice(id)) then
        local rec, each = CraftInstead(id)
        if rec then
          Craft(id, rec, math.ceil(Short() / R.Made(rec)), each)
          more = true
        end
      end
    end
    if not more then break end
  end
  for _, id in ipairs(order) do
    local h = held[id] or C.Have(id)
    local left = math.max(0, need[id] - (h.crafted or 0))
    local row = { id = id, need = need[id], crafted = h.crafted or 0, fromAlts = {} }
    for _, k in ipairs({ "bags", "bank", "mail", "alts" }) do
      row[k] = math.max(0, math.min(left, h[k]))
      left = left - row[k]
    end
    local fromAlts = row.alts
    for _, a in ipairs(h.altList or {}) do
      if fromAlts <= 0 then break end
      local n = math.min(fromAlts, a.total)
      row.fromAlts[#row.fromAlts + 1] = { name = a.name, n = n }
      fromAlts = fromAlts - n
    end
    row.buy = math.max(0, left)
    row.price = R.MatPrice(id)
    if row.buy > 0 then
      if row.price then
        out.buyCost = out.buyCost + row.price * row.buy
      else
        out.complete = false
      end
    end
    out.mats[#out.mats + 1] = row
  end
  -- to act on first: buy, then fetch from alts, bank or mail; all in bags last
  local function Rank(m)
    if m.buy > 0 then return 1 end
    if m.alts > 0 then return 2 end
    if m.bank + m.mail > 0 then return 3 end
    if m.crafted > 0 then return 4 end
    return 5
  end
  table.sort(out.mats, function(a, b)
    if Rank(a) ~= Rank(b) then return Rank(a) < Rank(b) end
    return a.id < b.id
  end)
  return out
end

------------------------------------------------------------------------------ Crafting
-- Expected skill points of the steps in this order, each profession from its current rank, a
-- craft at a time (fractional rank: the expected one): s.points, s.from, s.to, s.var (each
-- yellow or green craft is a skill-up or not, so the total varies; orange ones always give);
-- -> prof -> { points, var, from, to }
local function SimulatePoints(steps)
  local gain = {}
  for _, s in ipairs(steps) do
    local prof = s.rec.prof
    local g = prof and gain[prof]
    if prof and not g then
      local rank, max = C.Rank(prof)
      g = { points = 0, var = 0, from = rank, to = rank, max = max }
      gain[prof] = g
    end
    s.points, s.from, s.to, s.var = nil, nil, nil, nil
    local _, yellow, _, grey, ups = C.Bands(s.rec)
    if g and g.to and grey and s.known then
      local k, pts, var = g.to, 0, 0
      for _ = 1, s.n do
        local f = math.floor(k)
        if (g.max and f >= g.max) or f >= grey or (s.stop and f >= s.stop) then break end
        if f < yellow then
          pts, k = pts + (ups or 1), k + (ups or 1)
        else
          local p = C.Chance(f, yellow, grey)
          pts, k, var = pts + p, k + p, var + p * (1 - p)
        end
      end
      if g.max then k = math.min(k, g.max) end
      s.points, s.from, s.to, s.var = pts, g.to, k, var
      g.points, g.to, g.var = g.points + pts, k, g.var + var
    end
  end
  return gain
end

local function TotalPoints(steps)
  local t = 0
  for _, g in pairs(SimulatePoints(steps)) do t = t + g.points end
  return t
end

-- the order with the most expected points. Steps at one depth don't use each other's output,
-- so any order works: those going grey soonest first, then neighbours swapped while it gains
local function ForPoints(steps)
  table.sort(steps, function(a, b)
    if a.depth ~= b.depth then return a.depth > b.depth end
    if a.grey ~= b.grey then return a.grey < b.grey end
    return (a.rec.name or "") < (b.rec.name or "")
  end)
  local best = TotalPoints(steps)
  for _ = 1, #steps do
    local better = false
    for i = 1, #steps - 1 do
      local a, b = steps[i], steps[i + 1]
      if a.depth == b.depth then
        steps[i], steps[i + 1] = b, a
        local t = TotalPoints(steps)
        if t > best + 1e-6 then
          best, better = t, true
        else
          steps[i], steps[i + 1] = a, b
        end
      end
    end
    if not better then break end
  end
  steps.gain = SimulatePoints(steps)
end

-- The queue as crafts in order: intermediates first (deepest first: bolts before the item),
-- then for the most skill points (ForPoints). Each { rec, n (wanted), can (from bags now),
-- queued, stop (C.QueueStop), saves, enchant, known, missing = { { id, short } }, points,
-- var, from, to };
-- steps.gain: prof -> { points, var, from, to }. Enchants go on an item (C.EnchantTarget), one
-- cast at a time. Bags only: the client crafts from bags.
function C.CraftSteps(shop)
  C.PruneQueue()
  shop = shop or C.Shopping()
  local steps, byOut = {}, {}
  local function Add(rec, n, queued, saves)
    local s = { rec = rec, n = n, queued = queued, saves = saves, depth = 0,
      grey = select(4, C.Bands(rec)) or math.huge, enchant = not rec.out, known = R.KnownHere(rec) and true or false, missing = {} }
    local can = math.huge
    for _, m in ipairs(rec.mats) do
      local bags = C_Item.GetItemCount(m[1], false) or 0
      can = math.min(can, math.floor(bags / m[2]))
      if bags < m[2] * n then s.missing[#s.missing + 1] = { m[1], m[2] * n - bags } end
    end
    s.can = math.min(n, can == math.huge and 0 or can)
    steps[#steps + 1] = s
    if rec.out then byOut[rec.out] = s end
  end
  for id, c in pairs(shop.crafts) do
    local rec = C.Recipe(id)
    if rec and rec.mats and c.n > 0 then
      Add(rec, c.n, false, c.saves)
      steps[#steps].tool = c.tool
    end
  end
  for id, n in pairs(Queue()) do
    local rec = C.Recipe(id)
    if rec and rec.mats and n > 0 then
      Add(rec, n, true)
      steps[#steps].stop = C.QueueStop(id)
    end
  end
  -- an intermediate goes one deeper than the deepest step using it, a tool's than its users
  local function Deeper(src, s)
    if src and src ~= s and src.depth <= s.depth then src.depth = s.depth + 1 end
  end
  for _ = 1, MAX_DEPTH do
    for _, s in ipairs(steps) do
      for _, m in ipairs(s.rec.mats) do Deeper(byOut[m[1]], s) end
      for _, cat in ipairs(C.ToolCats(s.rec) or {}) do
        for _, item in ipairs(M.CraftTools[cat][2]) do Deeper(byOut[item], s) end
      end
    end
  end
  ForPoints(steps)
  return steps
end

-- the last enchant Craft next put on an item: { id, guid }. Replacing it loses nothing, so its
-- replace prompt is confirmed and the next cast goes there
local ourEnchant
function C.MarkOurEnchant(id, guid) ourEnchant = guid and { id = id, guid = guid } or nil end
function C.IsOurEnchant(id, guid)
  return ourEnchant ~= nil and ourEnchant.id == id and ourEnchant.guid == guid
end

-- An item for an enchant to go on, from what the client offers (profession window open):
-- the one carrying this enchant from Craft next's last cast (so one item takes the queue);
-- else unenchanted, worn before bags (its stats stay of use); then an enchanted one in bags
-- before a worn one (the game asks before replacing an enchant). { loc, link, guid, ours }
local function Bagged(loc)
  local bag = loc:GetBagAndSlot()
  return bag and bag >= 0 and bag <= (NUM_TOTAL_EQUIPPED_BAG_SLOTS or NUM_BAG_SLOTS or 4)
end
function C.EnchantTarget(rec)
  local T = C_TradeSkillUI
  if not (T and T.GetEnchantItems and C_Item.GetItemLocation) then return nil end
  local ok, guids = pcall(T.GetEnchantItems, rec.id)
  if not ok or type(guids) ~= "table" then return nil end
  local best, bestRank
  for _, guid in ipairs(guids) do
    local loc = C_Item.GetItemLocation(guid)
    local worn = loc and loc:IsEquipmentSlot()
    if loc and (worn or loc:IsBagAndSlot() and Bagged(loc)) then
      local link = C_Item.GetItemLink(loc)
      local enchanted = (link and link:match("item:%d+:(%d*)") or "") ~= ""
      local ours = enchanted and C.IsOurEnchant(rec.id, guid)
      local rank = ours and -1 or enchanted and (worn and 3 or 2) or (worn and 0 or 1)
      if not bestRank or rank < bestRank then
        best, bestRank = { loc = loc, link = link, guid = guid, ours = ours }, rank
      end
    end
  end
  return best
end

-- known, mats and tools (s.noTool) in bags, and an enchant something to go on (only checked with its profession
-- open: else the button opens it first; s.noTarget when nothing takes it)
local function Ready(s, openProf)
  if not (s.known and s.can > 0) then return false end
  local tool = C.MissingTool(s.rec, true)
  s.noTool = tool and C.ToolName(tool) or nil
  if tool then return false end
  if not s.enchant or s.rec.prof ~= openProf then return true end
  s.target = s.target or C.EnchantTarget(s.rec)
  s.noTarget = not s.target
  return s.target ~= nil
end

-- The step to craft now.
-- queue: the first with anything craftable, partial batches included.
-- bulk: only a step whose whole count is in bags, so each recipe is one batch; the open
--   profession's first (no "Open" press in between)
function C.NextCraft(steps, mode, openProf)
  local first
  for _, s in ipairs(steps) do
    if Ready(s, openProf) then
      if mode ~= "bulk" then return s end
      if s.can >= s.n then
        if s.rec.prof == openProf then return s end
        first = first or s
      end
    end
  end
  return first
end
