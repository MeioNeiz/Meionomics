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
local TRAINER_SPAN = 25

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
-- bands. Trainer recipes all say learn 1 in the client data: the real requirement is known
-- once the trainer was visited (rec.train.req), until then it is yellow - TRAINER_SPAN.
function C.Bands(rec)
  local d = M.CraftData[rec.id]
  local learn = rec.train and rec.train.req
  if d then
    local estLearn = false
    if not learn then
      if d[1] > 1 or d[6] ~= 0 or d[2] < 30 then
        learn = d[1]
      else
        learn, estLearn = math.max(1, d[2] - TRAINER_SPAN), true
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

function C.Chance(rank, yellow, grey)
  if rank >= grey then return 0 end
  if rank < yellow then return 1 end
  return (grey - rank) / (grey - yellow)
end

-- current rank in a profession by name: the open window first (live), else the login scan
function C.Rank(prof)
  local T = C_TradeSkillUI
  if T and T.IsTradeSkillReady and T.IsTradeSkillReady() then
    local ok, b = pcall(T.GetBaseProfessionInfo)
    if ok and b and b.professionName == prof and b.skillLevel then
      return b.skillLevel, b.maxSkillLevel
    end
  end
  local p = R.Professions()[prof]
  if p then return p.rank, p.max end
end

-- a pattern bought now: the cheaper of a vendor and the AH
function C.PatternPrice(item)
  local ah = P.Get(item, "minBuyout") or P.Get(item, "market") or P.Get(item, "regionMarket")
  local vendor = P.Custom("VendorBuy", item)
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
  local vendor = P.Custom("VendorBuy", item)
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
  local price = P.Custom("VendorBuy", item)
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

-- recorded trainer fees near a requirement: the median, for trainer recipes not seen yet
function C.EstFee(prof, learn)
  local fees = {}
  for _, rec in pairs(R.All()) do
    local t = rec.train
    if t and t.cost and t.cost > 0 and t.req and math.abs(t.req - learn) <= 25 then
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
-- this character's bags, bank, mail; alts (+ warband, guild): where to get an item from
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

function C.HaveNow(itemID)
  local inv = I.Get(itemID)
  if not inv then
    return { bags = 0, bank = 0, mail = 0, alts = 0, total = 0, altList = {} }
  end
  local me = inv.me
  local h = { bags = me.bags or 0, bank = me.bank or 0, mail = me.mail or 0,
    alts = inv.altTotal + inv.warband + inv.guild, altList = inv.alts }
  h.total = h.bags + h.bank + h.mail + h.alts
  return h
end

-- crafts possible from bags alone, and from everything you and your alts hold
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
  local x = { rec = rec, e = e, known = R.KnownHere(rec) and true or false }
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

-- recorded recipes of a profession; show = "known" | "learnable" | "all" (C.Learnable)
function C.List(prof, show, rank)
  local out = {}
  R.ResetCache()
  for _, rec in pairs(R.All()) do
    if rec.prof == prof and rec.mats then
      local x = C.Info(rec, rank)
      C.Learnable(x, rank)
      if x.known or show == "all" or (show == "learnable" and x.learnable) then
        out[#out + 1] = x
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

function C.Enqueue(rec, n)
  local q = Queue()
  local v = (q[rec.id] or 0) + n
  q[rec.id] = v > 0 and v or nil
end

function C.QueueCount()
  local n = 0
  for _, v in pairs(Queue()) do n = n + v end
  return n
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

-- Shopping list for the queue. Each material: need, then taken from bags, bank, mail, alts in
-- that order; the rest is bought, or crafted (intermediates such as bolts) when cheaper.
-- -> { mats = { { id, need, crafted, bags, bank, mail, alts, fromAlts = { {name, n} },
--        buy, price } ... },
--      crafts = { recipeID -> { n, saves } } intermediates to craft first,
--      buyCost, complete, profit (queued crafts, priced ones), saves }
function C.Shopping()
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
  -- intermediates: what still has to be bought, crafted instead when cheaper (repeated for
  -- the intermediates' own materials)
  local held = {}
  for _ = 1, MAX_DEPTH do
    local more = false
    for _, id in ipairs(order) do
      held[id] = held[id] or C.Have(id)
      local h = held[id]
      local short = need[id] - h.total - (h.crafted or 0)
      if short > 0 then
        local rec, each = CraftInstead(id)
        if rec then
          local made = math.ceil(short / R.Made(rec))
          h.crafted = (h.crafted or 0) + made * R.Made(rec)
          Add(rec, made, true)
          local price = R.MatPrice(id)
          if price then
            local saves = (price - each) * made * R.Made(rec)
            crafts[rec.id].saves = crafts[rec.id].saves + saves
            out.saves = out.saves + saves
          end
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
-- The queue as crafts in order: intermediates first (deepest first: bolts before the item),
-- each { rec, n (wanted), can (from bags now), queued, saves, enchant, known,
--   missing = { { id, short } } }. Enchants need a target item, so they are crafted by hand.
-- Bags only: the client crafts from bags.
function C.CraftSteps(shop)
  shop = shop or C.Shopping()
  local steps, byOut = {}, {}
  local function Add(rec, n, queued, saves)
    local s = { rec = rec, n = n, queued = queued, saves = saves, depth = 0,
      enchant = not rec.out, known = R.KnownHere(rec) and true or false, missing = {} }
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
    if rec and rec.mats and c.n > 0 then Add(rec, c.n, false, c.saves) end
  end
  for id, n in pairs(Queue()) do
    local rec = C.Recipe(id)
    if rec and rec.mats and n > 0 then Add(rec, n, true) end
  end
  -- an intermediate goes one deeper than the deepest step using it
  for _ = 1, MAX_DEPTH do
    for _, s in ipairs(steps) do
      for _, m in ipairs(s.rec.mats) do
        local src = byOut[m[1]]
        if src and src ~= s and src.depth <= s.depth then src.depth = s.depth + 1 end
      end
    end
  end
  table.sort(steps, function(a, b)
    if a.depth ~= b.depth then return a.depth > b.depth end
    return (a.rec.name or "") < (b.rec.name or "")
  end)
  return steps
end

-- the first step that can be crafted now (known, not an enchant, mats in bags)
function C.NextCraft(steps)
  for _, s in ipairs(steps) do
    if s.known and not s.enchant and s.can > 0 then return s end
  end
end
