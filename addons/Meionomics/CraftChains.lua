-- Craft flips: every way the account can turn gold into more gold through crafting, however
-- many steps it takes. Behind the crafting panel's Flips view (/meio flips).
--   Cost of an item: the cheapest of buying it (AH, vendor) and making it with a recipe any of
--     your characters knows, its materials costed the same way (bolts from cloth, bars from
--     ore, lesser essences combined into a greater). Solved as shortest paths: passes until
--     nothing gets cheaper.
--   A flip: one final recipe, its materials at that cost, its output out the best way: the AH
--     (after the cut, as fast as it sells here), a vendor, or disenchanted by whichever of your
--     characters has the Enchanting for it (BoP crafts too). Essences also split 1 into 3.
--   Time: cast times of every craft in the chain, disenchants and posting. Per hour assumes
--     nonstop crafting; Per day is what sells (or what the AH has of the mats) within an hour
--     of crafting a day, so a 1g flip selling 40 a day beats a 5g one selling 1 a week.
--   Cooldowns (transmutes, Mooncloth): crafts a day capped at what every character knowing
--     the step can cast.
--   Scope: recipes known by any character; or also those one could learn now; or every
--     recipe there's a way to learn, for steps and final crafts alike, each flip saying what
--     it needs learnt, by whom, at what skill and cost. By profession: what adding one
--     profession's recipes would add to a day's best flips.
-- Ch.Start(opts) -> job (sliced, see Run), Ch.Build(opts) -> list: flips (see Flip), best per
-- day first; with opts.byProf, Profession entries
local _, M = ...
local R, P, C = M.Recipes, M.Prices, M.Craft
local V = C.Value
local Ch = {}
C.Chains = Ch

local ENCHANTING = 333
local PASSES = 8
local MAX_DEPTH = 6
local CRAFT_SECS = 3      -- a recipe whose cast time the client doesn't give
local DE_SECS = 3
local CONVERT_SECS = 1.5
local POST_SECS = 2       -- per item posted, buying the mats included
local HOUR_A_DAY = 3600
local MIN_GAIN = 10       -- copper a final craft must make to count
local DE_SHARE = 0.25     -- disenchant materials worth less than this share don't limit
local DAY_MS = 86400000
local TOP = 5             -- By profession: a day's crafting is your best this many flips
local PRIMARY = { [164] = true, [165] = true, [171] = true, [182] = true, [186] = true,
  [197] = true, [202] = true, [333] = true, [393] = true }
-- lesser, greater: three lessers combine into one greater, one greater splits into three
local ESSENCES = { { 10938, 10939 }, { 10998, 11082 }, { 11134, 11135 }, { 11174, 11175 },
  { 16202, 16203 } }

------------------------------------------------------------------------------ Characters
-- every character's crafting skills: skillLine -> { { key, name, rank }, ... } highest first
local function Skills()
  local out = {}
  for key, c in pairs(R.Chars()) do
    for _, p in pairs(c.profs or {}) do
      if p.skillLine and p.rank then
        out[p.skillLine] = out[p.skillLine] or {}
        table.insert(out[p.skillLine], { key = key, name = c.name or "?", rank = p.rank })
      end
    end
  end
  for _, list in pairs(out) do table.sort(list, function(a, b) return a.rank > b.rank end) end
  return out
end

local function Line(rec)
  local d = type(rec.id) == "number" and M.CraftData[rec.id]
  return d and d[5] or C.LineOf(rec.prof or "")
end

-- who makes it: this character when he knows it, else the first alt that does (by name)
local function Crafter(rec)
  if rec.convert then return nil end
  if R.KnownMine(rec) then return UnitName("player") end
  local names = R.KnownBy(rec)
  return names[1]
end

------------------------------------------------------------------------------ Recipes
local converts
local function Converts()
  if converts then return converts end
  converts = {}
  for _, pair in ipairs(ESSENCES) do
    local lesser, greater = pair[1], pair[2]
    local function Make(from, n, to, made, verb)
      local name = C_Item.GetItemNameByID(to)
      converts[#converts + 1] = { id = "convert" .. from .. ">" .. to, convert = true,
        name = verb .. " " .. (C_Item.GetItemNameByID(from) or ("item " .. from)),
        out = to, qmin = made, qmax = made, mats = { { from, n } }, known = {},
        icon = C_Item.GetItemIconByID(to), outName = name }
    end
    Make(lesser, 3, greater, 1, "Combine")
    Make(greater, 1, lesser, 3, "Split")
  end
  return converts
end

-- every recipe making an item: recorded ones and CraftData's
local function AllRecipes(Yield)
  local out, seen = {}, {}
  for id, rec in pairs(R.All()) do
    if rec.mats and rec.out then
      seen[id] = true
      out[#out + 1] = rec
    end
  end
  -- pairs() must not run across a yield that lets the table change: ids first
  local ids = {}
  for id, d in pairs(M.CraftData) do
    if not seen[id] and d[7] ~= 0 then ids[#ids + 1] = id end
  end
  for _, id in ipairs(ids) do
    local rec = C.Recipe(id)
    if rec and rec.mats and rec.out then out[#out + 1] = rec end
    if Yield then Yield() end
  end
  return out
end

local function KnownAnywhere(rec)
  return rec.convert or R.KnownMine(rec) or next(rec.known or {}) ~= nil
end

-- what having a recipe nobody knows takes -> { rec, line, prof, skill (to learn it), cost,
-- from, est (cost estimated), who (a character who could learn it now), best (highest rank in
-- its profession) }; nil when the scope leaves it out: "learnable" only what someone can learn
-- now, "all" whatever can be had (a pattern nobody sells can't)
local function Want(rec, skills, scope, real)
  local line = Line(rec)
  local learn, _, _, grey, _, item, estLearn = C.Bands(rec)
  if not (line and learn and (real[line] or skills[line])) then return nil end
  local list = skills[line] or {}
  local who
  for _, c in ipairs(list) do
    if c.rank >= learn and not (estLearn and grey and c.rank >= grey) then
      who = c
      break
    end
  end
  if scope == "learnable" and not who then return nil end
  local cost, from, est = C.LearnCost(rec, item, learn)
  if scope == "all" and not cost then return nil end
  return { rec = rec, line = line, prof = rec.prof, skill = learn, cost = cost, from = from,
    est = est, who = who and who.name, best = list[1] }
end

local function CastSecs(rec)
  if rec.convert then return CONVERT_SECS end
  local info = C_Spell.GetSpellInfo and C_Spell.GetSpellInfo(rec.id)
  local ms = info and info.castTime
  return ms and ms > 0 and ms / 1000 or CRAFT_SECS
end

-- ms between two casts of it, nil when none (transmutes, Mooncloth, Salt Shaker)
local cooldowns = {}
local function Cooldown(rec)
  if rec.convert or type(rec.id) ~= "number" or not GetSpellBaseCooldown then return nil end
  local cd = cooldowns[rec.id]
  if cd == nil then
    cd = GetSpellBaseCooldown(rec.id) or 0
    cooldowns[rec.id] = cd
  end
  return cd > 0 and cd or nil
end

-- final crafts a day the chain's cooldowns allow, each character knowing a step casting it
local function CooldownCap(steps)
  local cap
  for _, s in ipairs(steps) do
    local cd = Cooldown(s.rec)
    if cd then
      local c = DAY_MS / cd * math.max(1, #R.KnownBy(s.rec)) / s.n
      if not cap or c < cap then cap = c end
    end
  end
  return cap
end

------------------------------------------------------------------------------ Costs
-- buy price and where: vendor when it's the vendor's price, else the AH
local function Buy(id)
  local p = R.MatPrice(id)
  if not p then return nil end
  local vendor = P.VendorBuy(id)
  return p, vendor and vendor <= p and "vendor" or "ah"
end

-- cost per unit of every item reached, and how: nil (bought) or the recipe making it
local function Solve(recipes, Yield)
  local cost, how = {}, {}
  local function Cost(id)
    local c = cost[id]
    if c == nil then
      c = Buy(id) or false
      cost[id] = c
    end
    return c or nil
  end
  for _ = 1, PASSES do
    local changed = false
    for _, rec in ipairs(recipes) do
      local sum = 0
      for _, m in ipairs(rec.mats) do
        local c = Cost(m[1])
        if not c then sum = nil break end
        sum = sum + c * m[2]
      end
      local st = sum and R.Station(rec)
      if st then sum = st.complete and sum + st.cost or nil end
      if sum then
        local each = sum / R.Made(rec)
        local now = Cost(rec.out)
        if not now or each < now - 0.5 then
          cost[rec.out], how[rec.out], changed = each, rec, true
        end
      end
      Yield()
    end
    if not changed then break end
  end
  return Cost, how
end

------------------------------------------------------------------------------ Exits
-- items disenchanted a day before what comes out swamps the AH: each material worth a good
-- share of the value sells as fast as it does here
local function DEPerDay(id, total)
  local day
  for _, y in ipairs(P.DisenchantYield(id) or {}) do
    if y.value and y.value * y.n >= total * DE_SHARE then
      local d = V.Sales(y.mat).day / y.n
      if not day or d < day then day = d end
    end
  end
  return day
end

-- every way out for one unit: { how = "ah" | "vendor" | "de", value, perDay (nil: unlimited),
-- who (disenchanter), level (AH evidence) }; Flip picks the one making most a day
local function Exits(id, enchanter)
  local opts = {}
  local each, where, level, noAH = R.SellValue(id)
  if each and where == "ah" then
    local day = V.Sales(id).day
    if day > 0 then
      opts[#opts + 1] = { how = "ah", value = each, perDay = day, level = level }
    end
  end
  local vendor = P.Get(id, "vendor")
  if vendor and vendor > 0 then opts[#opts + 1] = { how = "vendor", value = vendor } end
  local de = enchanter and P.Disenchant(id)
  local need = de and P.DisenchantSkill(id)
  if need and enchanter.rank >= need then
    opts[#opts + 1] = { how = "de", value = de, who = enchanter.name,
      perDay = DEPerDay(id, de) }
  end
  return opts, noAH
end

local POST = { ah = POST_SECS, de = DE_SECS, vendor = 0.2 }

-- one way out of a priced chain: profit, time, crafts a day and what limits them
local function Out(exit, made, cost, acc, rec, cdCap)
  local each = exit.value * made - cost
  local secs = acc.secs + CastSecs(rec) + made * POST[exit.how]
  -- crafts a day: what sells, what the AH has of the bought mats, an hour of crafting, the
  -- cooldowns
  local crafts, limit = HOUR_A_DAY / secs, "time"
  if exit.perDay and exit.perDay / made < crafts then
    crafts, limit = exit.perDay / made, "sells"
  end
  for _, b in ipairs(acc.order) do
    if b.src == "ah" and b.n > 0 then
      local s = P.SellRate(b.id)
      local up = s and s.listed
      if up and up / b.n < crafts then crafts, limit = up / b.n, "mats" end
    end
  end
  if cdCap and cdCap < crafts then crafts, limit = cdCap, "cooldown" end
  local hourly = math.min(3600 / secs, cdCap or math.huge)
  return { exit = exit, each = each, secs = secs, crafts = crafts, limit = limit,
    perDay = each * crafts, perHour = each * hourly }
end

------------------------------------------------------------------------------ Flips
-- the chain behind one item: steps in crafting order, bought materials, total casts and
-- seconds, per unit of the item. Bought: id -> units; crafts: list of { rec, n, who }
local function Expand(id, n, how, Cost, acc, depth)
  local rec = how[id]
  if not rec or depth > MAX_DEPTH then
    local p, src = Buy(id)
    local b = acc.buy[id]
    if not b then
      b = { id = id, n = 0, each = p, src = src }
      acc.buy[id] = b
      acc.order[#acc.order + 1] = b
    end
    b.n = b.n + n
    return
  end
  local crafts = n / R.Made(rec)
  for _, m in ipairs(rec.mats) do Expand(m[1], m[2] * crafts, how, Cost, acc, depth + 1) end
  local step = acc.byRec[rec.id]
  if not step then
    step = { rec = rec, n = 0, who = Crafter(rec), intermediate = true }
    acc.byRec[rec.id] = step
    acc.steps[#acc.steps + 1] = step
  end
  step.n = step.n + crafts
  acc.secs = acc.secs + crafts * CastSecs(rec)
end

-- one final recipe -> flip, or nil when it loses money or can't be priced:
--   { rec, out, made, exit, exits, value, cost, each (profit a craft), naive (profit buying
--     every material), margin, secs (a craft, the whole chain), perHour, crafts (a day),
--     perDay, limit ("sells" | "mats" | "time" | "cooldown"), steps ({ rec, n, who, learn }),
--     buys, chars, profs, lines (skill lines used), depth,
--     learns (Want of each step nobody knows yet), ready (nothing to learn), learnCost (nil:
--     a cost unknown), pay (crafts to pay it back) }
-- ctx: enchanter, wants (recipe ID -> Want)
local function Flip(rec, Cost, how, ctx)
  local acc = { buy = {}, order = {}, byRec = {}, steps = {}, secs = 0 }
  for _, m in ipairs(rec.mats) do
    -- a recipe never feeds itself: its own output among the mats is bought
    if how[m[1]] and how[m[1]].id == rec.id then return nil end
    Expand(m[1], m[2], how, Cost, acc, 1)
  end
  -- combine three lessers only to split them again
  for _, s in ipairs(acc.steps) do
    if s.rec.out == rec.out then return nil end
  end
  local cost, naive = 0, 0
  for _, b in ipairs(acc.order) do
    if not b.each then return nil end
    cost = cost + b.each * b.n
  end
  for _, m in ipairs(rec.mats) do
    local p = Buy(m[1])
    naive = naive and p and naive + p * m[2] or nil
  end
  local st = R.Station(rec)
  if st then
    if not st.complete then return nil end
    cost, naive = cost + st.cost, naive and naive + st.cost
  end
  local steps = acc.steps
  steps[#steps + 1] = { rec = rec, n = 1, who = Crafter(rec) }
  local learns, learnCost = {}, 0
  for _, s in ipairs(steps) do
    local w = ctx.wants[s.rec.id]
    if w then
      s.learn, s.who = w, s.who or w.who
      learns[#learns + 1] = w
      learnCost = learnCost and w.cost and learnCost + w.cost or nil
    end
  end
  local cdCap = CooldownCap(steps)
  local made = R.Made(rec)
  local exits, noAH = Exits(rec.out, ctx.enchanter)
  local best
  for _, exit in ipairs(exits) do
    local o = Out(exit, made, cost, acc, rec, cdCap)
    if o.each >= MIN_GAIN and (not best or o.perDay > best.perDay) then best = o end
  end
  if not best then return nil end
  local exit, each = best.exit, best.each
  local value = exit.value * made
  local f = { rec = rec, out = rec.out, made = made, exit = exit, exits = exits, value = value,
    cost = cost, each = each, naive = naive and value - naive, margin = cost > 0 and each / cost,
    secs = best.secs, perHour = best.perHour, crafts = best.crafts, cooldown = cdCap,
    perDay = best.perDay, limit = best.limit, steps = steps, buys = acc.order, noAH = noAH,
    who = steps[#steps].who, learns = learns, ready = #learns == 0, learnCost = learnCost }
  f.pay = learnCost and learnCost > 0 and math.ceil(learnCost / each) or 0
  local chars, profs, lines = {}, {}, {}
  for _, s in ipairs(steps) do
    if s.who then chars[s.who] = true end
    if s.rec.prof then profs[s.rec.prof] = true end
    local line = not s.rec.convert and Line(s.rec)
    if line then lines[line] = true end
  end
  if exit.how == "de" then
    chars[exit.who] = true
    profs.Enchanting, lines[ENCHANTING] = true, true
  end
  f.chars, f.profs, f.lines = chars, profs, lines
  f.depth = #steps
  f.uplift = f.naive and each - f.naive or nil
  f.multi = f.depth > 1 or exit.how ~= "ah" or (next(chars) and next(chars, next(chars)) ~= nil)
  return f
end

local function Better(a, b)
  if a.perDay ~= b.perDay then return a.perDay > b.perDay end
  return tostring(a.rec.id) < tostring(b.rec.id)
end

-- the recipes there are: known by someone (essence converts too), and what the scope adds
local function Avail(all, skills, scope, Yield)
  local known, wants = {}, {}
  -- professions this character could take up (no test ones, Poisons only a rogue), or one has
  local real = {}
  for _, line in pairs(C.Lines()) do real[line] = true end
  for _, rec in ipairs(all) do
    if KnownAnywhere(rec) then
      known[#known + 1] = rec
    elseif scope ~= "known" then
      wants[#wants + 1] = Want(rec, skills, scope, real)
      Yield()
    end
  end
  for _, rec in ipairs(Converts()) do known[#known + 1] = rec end
  return known, wants
end

-- every flip of these recipes, materials made with any of them: best per day first, and the
-- cost of every item. Keep(rec, Cost): leave a final recipe out
local function Flips(job, known, wants, ctx, Yield, Keep)
  local recipes, byID = {}, {}
  for _, rec in ipairs(known) do recipes[#recipes + 1] = rec end
  for _, w in ipairs(wants) do
    recipes[#recipes + 1] = w.rec
    byID[w.rec.id] = w
  end
  ctx.wants = byID
  local Cost, how = Solve(recipes, Yield)
  local out = {}
  for _, rec in ipairs(recipes) do
    if not Keep or Keep(rec, Cost) then
      local f = Flip(rec, Cost, how, ctx)
      if f then out[#out + 1] = f end
    end
    job.done = job.done + 1
    Yield()
  end
  table.sort(out, Better)
  return out, Cost
end

-- a day's crafting: the best TOP flips (one per recipe) summed -> profit, every flip ranked
local function Day(lists)
  local best = {}
  for _, list in ipairs(lists) do
    for _, f in ipairs(list) do
      local b = best[f.rec.id]
      if not b or f.perDay > b.perDay then best[f.rec.id] = f end
    end
  end
  local all = {}
  for _, f in pairs(best) do all[#all + 1] = f end
  table.sort(all, Better)
  local sum = 0
  for i = 1, math.min(TOP, #all) do sum = sum + all[i].perDay end
  return sum, all
end

-- characters with a primary profession slot free: names, or true for a secondary one (anyone)
local function FreeSlots(line)
  if not PRIMARY[line] then return true end
  local names = {}
  for _, c in pairs(R.Chars()) do
    local n, has = 0, false
    for _, p in pairs(c.profs or {}) do
      if PRIMARY[p.skillLine] then n = n + 1 end
      if p.skillLine == line then has = true end
    end
    if n < 2 and not has then names[#names + 1] = c.name or "?" end
  end
  table.sort(names)
  return names
end

-- one profession's recipes added to what's known -> { line, prof, gain (a day over now),
-- with, new (flips needing one of its recipes, best first), cheaper (those of new whose final
-- craft is known: its recipes make a material cheaper; f.cheaper, f.was the flip without,
-- nil when it lost money), skill, cost (learning what the day's best flips need), best (highest rank in
-- it), free (FreeSlots) }
local function Profession(job, line, known, wants, base, Cost0, ctx, Yield)
  -- a known recipe's flip only changes when one of its materials got cheaper
  local function Keep(rec, Cost)
    if ctx.wants[rec.id] then return true end
    for _, m in ipairs(rec.mats) do
      local was, now = Cost0(m[1]), Cost(m[1])
      if now and (not was or now < was - 0.5) then return true end
    end
  end
  local list = Flips(job, known, wants, ctx, Yield, Keep)
  local was = {}
  for _, f in ipairs(base) do was[f.rec.id] = f end
  local new, cheaper = {}, {}
  for _, f in ipairs(list) do
    if not f.ready then
      new[#new + 1] = f
      if not ctx.wants[f.rec.id] then
        f.cheaper, f.was = true, was[f.rec.id]
        cheaper[#cheaper + 1] = f
      end
    end
  end
  local with, day = Day({ base, new })
  -- what learning takes: for the new flips in the day's best, else the best new flip
  local pick = {}
  for i = 1, math.min(TOP, #day) do
    if not day[i].ready then pick[#pick + 1] = day[i] end
  end
  if #pick == 0 then pick[1] = new[1] end
  local cost, skill, seen = 0, nil, {}
  for _, f in ipairs(pick) do
    for _, w in ipairs(f.learns) do
      if not seen[w] then
        seen[w] = true
        cost = cost and w.cost and cost + w.cost or nil
        if not skill or w.skill > skill then skill = w.skill end
      end
    end
  end
  return { line = line, prof = wants[1].prof, gain = with - job.now, with = with, new = new,
    cheaper = cheaper, skill = skill, cost = cost, best = wants[1].best, free = FreeSlots(line) }
end

-- The first run builds ~2200 recipes from the client data (a few hundred ms): a job, run a
-- slice a frame. opts.scope: "known" (default), "learnable" (adds what a character could
-- learn now), "all" (every recipe there's a way to learn). opts.byProf: per profession, what
-- learning its recipes would add -> job.list of Profession entries, best gain first; job.now
-- (a day's profit from known recipes), job.base (their flips).
-- -> job: job.Step(ms) runs up to ms milliseconds, true when done; then job.list (flips,
-- best per day first), job.stats; job.err on an error. job.done, job.total: progress
local function Run(job, opts, Yield)
  R.ResetCache()
  local skills = Skills()
  local ctx = { enchanter = skills[ENCHANTING] and skills[ENCHANTING][1] }
  local scope = opts.byProf and "all" or opts.scope or (opts.learnable and "learnable")
    or "known"
  local all = AllRecipes(Yield)
  local known, wants = Avail(all, skills, scope, Yield)
  local stats = { recipes = #all, known = #known, learnable = #wants,
    enchanter = ctx.enchanter, scope = scope }
  if not opts.byProf then
    job.total = #known + #wants
    job.list, job.stats = Flips(job, known, wants, ctx, Yield), stats
    return
  end
  local byLine, lines = {}, {}
  for _, w in ipairs(wants) do
    if not byLine[w.line] then
      byLine[w.line] = {}
      lines[#lines + 1] = w.line
    end
    table.insert(byLine[w.line], w)
  end
  table.sort(lines)
  job.total = #known * (#lines + 1) + #wants
  local base, Cost0 = Flips(job, known, {}, ctx, Yield)
  job.now, job.base = Day({ base }), base
  local out = {}
  for _, line in ipairs(lines) do
    local p = Profession(job, line, known, byLine[line], base, Cost0, ctx, Yield)
    if #p.new > 0 then out[#out + 1] = p end
  end
  table.sort(out, function(a, b)
    if a.gain ~= b.gain then return a.gain > b.gain end
    return a.line < b.line
  end)
  job.list, job.stats = out, stats
end

function Ch.Start(opts)
  local job, deadline = { done = 0, total = 0 }, math.huge
  local function Yield()
    if debugprofilestop() > deadline then coroutine.yield() end
  end
  local co = coroutine.create(function() Run(job, opts or {}, Yield) end)
  function job.Step(ms)
    if job.list or job.err then return true end
    deadline = ms and debugprofilestop() + ms or math.huge
    local ok, err = coroutine.resume(co)
    if not ok then
      job.err = err
      geterrorhandler()(err)
    end
    return coroutine.status(co) == "dead"
  end
  return job
end

-- all at once -> list, stats
function Ch.Build(opts)
  local job = Ch.Start(opts)
  job.Step()
  return job.list or {}, job.stats
end

