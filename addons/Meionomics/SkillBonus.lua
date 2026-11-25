-- Legacy System "Working Overtime" (Professions tree): "Increases your chance to gain a skill
-- increase ... by N%". How the N% applies isn't documented, so every craft is evidence: each
-- model below is scored on what crafts actually gave (Bayes), and C.Chance uses the leader.
-- Orange crafts only tell "extra point" apart; green ones near grey separate the rest best
-- (10% base: 30% added, 12% multiplied at +20).
local _, M = ...
local C = M.Craft
local B = {}
M.SkillBonus = B

local SPELL = 1225451   -- Working Overtime
local TREE = Constants and Constants.LegacyConsts
  and Constants.LegacyConsts.LEGACY_TREE_PROFESSIONS_ID or 1187
local PER_RANK = 10     -- DB2 base points, used only when the trait description won't parse
local MAX_OBS = 3000
-- a misread craft (lag, a Dedicated Study point landing mid-craft) must not zero a model
local NOISE = 0.02
-- a skill-up landing this soon before its craft's cast event still belongs to it
local EARLY = 0.5
-- a craft with no skill-up this long after it gave nothing
local SETTLE = 3

-- Up(p, b): base chance p of a yellow/green craft (1 for orange), bonus b as a fraction ->
-- chance of the skill-up, chance of one extra point on top of it
B.MODELS = {
  { key = "add", name = "added", prior = 0.5,
    Up = function(p, b) return math.min(1, p + b), 0 end },
  { key = "mult", name = "multiplied", prior = 0.2,
    Up = function(p, b) return math.min(1, p * (1 + b)), 0 end },
  { key = "extra", name = "extra point", prior = 0.2,
    Up = function(p, b) return p, b end },
  { key = "none", name = "no effect", prior = 0.1,
    Up = function(p) return p, 0 end },
}

------------------------------------------------------------------------------ Perk
local perk   -- { rank, max, bonus } of this character, read lazily
local perkTried

local NONE = { rank = 0, max = 0, bonus = 0 }

-- nil while the Legacy tree isn't loaded yet (early in login)
local function ReadPerk()
  local T = C_Traits
  if not (T and T.GetConfigIDByTreeID) then return NONE end
  local config = T.GetConfigIDByTreeID(TREE)
  if not config then return nil end
  local nodes = T.GetTreeNodes(TREE)
  if type(nodes) ~= "table" or #nodes == 0 then return nil end
  for _, nodeID in ipairs(nodes) do
    local node = T.GetNodeInfo(config, nodeID)
    local entryID = node and (node.activeEntry and node.activeEntry.entryID
      or node.entryIDs and node.entryIDs[1])
    local entry = entryID and T.GetEntryInfo(config, entryID)
    local def = entry and entry.definitionID and T.GetDefinitionInfo(entry.definitionID)
    if def and def.spellID == SPELL then
      local rank = node.activeRank or 0
      local pct = rank * PER_RANK
      if rank > 0 and T.GetTraitDescription then
        local ok, text = pcall(T.GetTraitDescription, entryID, rank)
        local n = ok and type(text) == "string" and tonumber(text:match("(%d+)%%"))
        if n then pct = n end
      end
      return { rank = rank, max = node.maxRanks or 0, bonus = pct / 100 }
    end
  end
  return NONE
end

function B.Perk()
  if perk then return perk end
  -- a tree not loaded yet isn't cached: B.Bonus runs on every solve of a route plan
  local now = GetTime()
  if perkTried and now - perkTried < 1 then return NONE end
  perkTried = now
  local ok, p = pcall(ReadPerk)
  if not ok then p = NONE end
  perk = p
  local me = p and M.Recipes.Chars()[M.Recipes.Me() or ""]
  if me then me.overtime = p.bonus end
  return p or NONE
end

-- Legacy points are per character: an alt shown in the crafting panel (R.SetViewer) gets
-- its own bonus as its last login saw it, none if never seen
function B.Bonus()
  local who = M.Recipes.Viewer()
  if not who then return B.Perk().bonus end
  local c = M.Recipes.Chars()[who]
  return c and c.overtime or 0
end

------------------------------------------------------------------------------ Models
local function Store()
  M.db.skillBonus = M.db.skillBonus or { obs = {} }
  return M.db.skillBonus
end

-- o: { r = rank before, y = yellow, gr = grey, u = points when orange, b = bonus, g = gained }
local function Likelihood(model, o)
  local p = o.r < o.y and 1 or C.BaseChance(o.r, o.y, o.gr)
  local u = o.r < o.y and o.u or 1
  local up, extra = model.Up(p, o.b)
  local l = 0
  if o.g == 0 then l = 1 - up
  elseif o.g == u then l = up * (1 - extra)
  elseif o.g == u + 1 then l = up * extra end
  return (1 - NOISE) * l + NOISE / 4
end

local scored   -- { [key] = posterior, leader = model, n = crafts, telling = count }

-- a craft where the models predict differently enough to matter
local function Telling(o)
  if o.r < o.y then return false end
  local p = C.BaseChance(o.r, o.y, o.gr)
  return math.abs(math.min(1, p + o.b) - math.min(1, p * (1 + o.b))) > 0.02
end

function B.Scores()
  if scored then return scored end
  local logs, obs = {}, Store().obs
  for i, m in ipairs(B.MODELS) do
    local s = math.log(m.prior)
    for _, o in ipairs(obs) do s = s + math.log(Likelihood(m, o)) end
    logs[i] = s
  end
  local top = math.max(unpack(logs))
  local sum = 0
  for i in ipairs(logs) do logs[i] = math.exp(logs[i] - top); sum = sum + logs[i] end
  scored = { n = #obs, telling = 0 }
  local best
  for i, m in ipairs(B.MODELS) do
    scored[m.key] = logs[i] / sum
    if not best or scored[m.key] > scored[best.key] then best = m end
  end
  scored.leader = best
  for _, o in ipairs(obs) do if Telling(o) then scored.telling = scored.telling + 1 end end
  return scored
end

-- yellow and green crafts under the leading model; orange (1) and grey (0) as they were
local Base = C.Chance
C.BaseChance = Base
function C.Chance(rank, yellow, grey)
  local p = Base(rank, yellow, grey)
  if p <= 0 or p >= 1 then return p end
  local b = B.Bonus()
  if b <= 0 then return p end
  local up, extra = B.Scores().leader.Up(p, b)
  return math.min(1, up * (1 + extra))
end

------------------------------------------------------------------------------ What it saves
-- chances as if the bonus were b under model key (nil: the leader); restore() undoes it
local function Pretend(b, key)
  local bonus, scores = B.Bonus, B.Scores
  B.Bonus = function() return b end
  if key then
    local fixed
    for _, m in ipairs(B.MODELS) do if m.key == key then fixed = { leader = m } end end
    B.Scores = function() return fixed end
  end
  return function() B.Bonus, B.Scores = bonus, scores end
end

local function Points(c, k)
  if k < c.learn or k >= c.grey then return 0 end
  if k < c.yellow then return c.ups end
  return C.Chance(k, c.yellow, c.grey)
end

-- a plan's steps at the current chances, each craft costing what the plan priced it at
-- (fewer crafts would buy fewer of the dearest mats, so this overstates the cost a little)
-- -> net, crafts, cost[level], crafts[level]; learning and tools on their step's first level.
-- keep: a step whose crafts pay for themselves (resale) keeps its craft count, spread over
-- its levels; fewer would only give up profit the old route had
function B.Recost(plan, keep)
  local net, crafts, at, n = 0, 0, {}, {}
  for _, st in ipairs(plan.steps) do
    local fixed = (st.fee or 0) + (st.setup or 0)
    at[st.from] = (at[st.from] or 0) + fixed
    net = net + fixed
    local each = st.crafts > 0 and (st.net - fixed) / st.crafts or 0
    if st.to > st.from then
      local scale = 1
      if keep and each < 0 then
        local total = 0
        for k = st.from, st.to - 1 do total = total + 1 / Points(st.c, k) end
        scale = st.crafts / total
      end
      for k = st.from, st.to - 1 do
        local x = scale / Points(st.c, k)
        at[k], n[k] = (at[k] or 0) + x * each, (n[k] or 0) + x
        net, crafts = net + x * each, crafts + x
      end
    else
      at[st.from], n[st.from] = at[st.from] + st.net - fixed, (n[st.from] or 0) + st.crafts
      net, crafts = net + st.net - fixed, crafts + st.crafts
    end
  end
  return net, crafts, at, n
end

-- the bonus b (default: his, else +20%) on a stretch, under model key (default: the leader)
-- -> { none = plan without it, best = plan with it, b, and B.Recost of each as
--   { net, crafts, at, n }: noneAt (without it), same (none with it, keep), bare (none with
--   it, no keep), bestAt (with it) }. same.net <= none.net always: what the bonus saves.
-- best against bare tells a missed route (the planner never crafts past the skill-ups, so
-- same's kept crafts aren't a route it could pick), by C.Route.Effort: what it minimises.
function B.Saving(prof, from, to, opts, b, key)
  b = b or (B.Bonus() > 0 and B.Bonus()) or 0.2
  local restore = Pretend(0)
  local function Costed(plan, keep)
    local r = {}
    r.net, r.crafts, r.at, r.n = B.Recost(plan, keep)
    return r
  end
  local ok, none, noneAt = pcall(function()
    local p = C.Route.Plan(prof, from, to, opts)
    return p, Costed(p)
  end)
  restore()
  if not ok then error(none, 0) end
  restore = Pretend(b, key)
  local same, bare, best, bestAt
  ok, same, bare, best, bestAt = pcall(function()
    local p = C.Route.Plan(prof, from, to, opts)
    return Costed(none, true), Costed(none), p, Costed(p)
  end)
  restore()
  if not ok then error(same, 0) end
  return { none = none, best = best, b = b, noneAt = noneAt, same = same, bare = bare,
    bestAt = bestAt }
end

------------------------------------------------------------------------------ Watching crafts
-- skill line -> { rank, max }
local ranks = {}
local pending, early = nil, {}

local function ReadRanks()
  local out = {}
  if not (GetProfessions and GetProfessionInfo) then return out end
  for _, i in pairs({ GetProfessions() }) do
    local _, _, rank, max, _, _, line = GetProfessionInfo(i)
    if line then out[line] = { rank = rank, max = max } end
  end
  return out
end

local function Settle(craft)
  if pending ~= craft then return end
  pending = nil
  local o = craft.o
  o.g = (ranks[craft.line] and ranks[craft.line].rank or o.r) - o.r
  if o.g < 0 then return end
  local obs = Store().obs
  obs[#obs + 1] = o
  if #obs > MAX_OBS then table.remove(obs, 1) end
  local was = B.Scores().leader
  scored = nil
  if B.Scores().leader ~= was then M.Recipes.Changed() end
end

local function SkillChanged()
  local now, new = GetTime(), ReadRanks()
  for line, s in pairs(new) do
    local old = ranks[line]
    if old and s.rank ~= old.rank and not (pending and pending.line == line) then
      local e = early[line]
      if not (e and now - e.t < EARLY) then early[line] = { from = old.rank, t = now } end
    end
  end
  ranks = new
end

local function Crafted(id)
  local d = M.CraftData[id]
  if not d then return end
  if pending then Settle(pending) end
  local b = B.Bonus()
  local line = d[5]
  local s = ranks[line]
  if b <= 0 or not s then return end
  local before = s.rank
  local e = early[line]
  if e and GetTime() - e.t < EARLY then before = e.from end
  early[line] = nil
  if before >= d[3] or (s.max and before >= s.max) then return end
  local craft = { line = line,
    o = { id = id, r = before, y = d[2], gr = d[3], u = d[4], b = b, t = time() } }
  pending = craft
  C_Timer.After(SETTLE, function() Settle(craft) end)
end

M.On("PLAYER_LOGIN", function()
  -- a read before Recipes knew who this is wasn't recorded for the alt view
  perk, perkTried = nil, nil
  ranks = ReadRanks()
  for _, e in ipairs({ "SKILL_LINES_CHANGED", "CHAT_MSG_SKILL" }) do
    pcall(M.On, e, SkillChanged)
  end
  local traitEvents = { "TRAIT_CONFIG_UPDATED", "TRAIT_NODE_CHANGED",
    "TRAIT_CONFIG_LIST_UPDATED" }
  for _, e in ipairs(traitEvents) do
    pcall(M.On, e, function()
      local was = B.Bonus()
      perk, perkTried = nil, nil
      if B.Bonus() ~= was then M.Recipes.Changed() end
    end)
  end
  M.On("UNIT_SPELLCAST_SUCCEEDED", function(_, unit, _, id)
    if unit == "player" then Crafted(id) end
  end)
end)

------------------------------------------------------------------------------ /meio legacy
local function Pct(x) return ("%d%%"):format(x * 100 + 0.5) end

function B.Report()
  perk, perkTried = nil, nil
  local p = B.Perk()
  if p.rank == 0 then
    M.Print(("Working Overtime not taken (0/%d): skill-up chances are the base ones.")
      :format(p.max))
    return
  end
  local s = B.Scores()
  M.Print(("Working Overtime %d/%d: +%s skill-up chance.")
    :format(p.rank, p.max, Pct(p.bonus)))
  local parts = {}
  for _, m in ipairs(B.MODELS) do
    parts[#parts + 1] = ("%s %s"):format(m.name, Pct(s[m.key]))
  end
  M.Print(("How it applies, from %d crafts (%d telling): %s."):format(s.n, s.telling,
    table.concat(parts, ", ")))
  local up, extra = s.leader.Up(0.5, p.bonus)
  M.Print(("Using: %s (a 50%% craft counts as %s)."):format(s.leader.name,
    Pct(math.min(1, up * (1 + extra)))))
  if s[s.leader.key] < 0.95 then
    local lo = 0.1
    M.Print(("Green crafts close to grey settle it fastest: a %s craft is %s if added, %s if "
      .. "multiplied."):format(Pct(lo), Pct(math.min(1, lo + p.bonus)),
      Pct(math.min(1, lo * (1 + p.bonus)))))
  end
end

function B.Forget()
  Store().obs = {}
  scored = nil
  M.Recipes.Changed()
  M.Print("Working Overtime evidence cleared.")
end

-- /meio legacy <profession> [from] [to]: what the bonus saves on that stretch, both ways
function B.ReportSaving(rest)
  local words, nums = {}, {}
  for w in rest:gmatch("%S+") do
    if tonumber(w) then nums[#nums + 1] = tonumber(w) else words[#words + 1] = w:lower() end
  end
  local want = table.concat(words, " ")
  local prof
  for name in pairs(C.Lines()) do
    if name:lower():sub(1, #want) == want and (not prof or name:lower() == want) then
      prof = name
    end
  end
  local rank, max
  if prof then rank, max = C.Rank(prof) end
  local from = nums[1] or rank or 1
  local to = nums[2] or (rank and C.Route.DefaultTarget(rank, max)) or 300
  if not prof or to <= from then
    M.Print("Usage: /meio legacy <profession> [from] [to], e.g. /meio legacy tailoring 150 225")
    return
  end
  local G = M.Money
  local head
  for _, resale in ipairs({ false, true }) do
    local s = B.Saving(prof, from, to, { resale = resale, unverified = true })
    if not head then
      head = true
      M.Print(("Working Overtime (+%s, %s) on %s %d-%d%s:"):format(Pct(s.b),
        B.Scores().leader.name, prof, from, to, B.Perk().rank == 0 and ", if you took it" or ""))
    end
    local none, same, best = s.none, s.same, s.best
    local line = ("  %s: %s without it | same route %s, saves %s (%d fewer crafts)"):format(
      resale and "with resale" or "materials only", G(none.net), G(same.net),
      G(none.net - same.net), math.floor(none.crafts - same.crafts + 0.5))
    if best.stuck and not none.stuck then
      line = line .. " | best route: none found"
    elseif C.Route.Effort(best, s.bestAt) <= C.Route.Effort(none, s.bare) + 1000 then
      local d = none.net - best.net
      line = line .. (d >= 0 and " | best route %s, saves %s" or
        " | best route %s, costs %s more but less work"):format(G(best.net), G(math.abs(d)))
    else
      line = line .. (" | the planner's route with it costs %s (%d crafts), the old one %s"
        .. " (%d) and less work: follow the old one"):format(G(best.net),
        math.floor(best.crafts + 0.5), G(s.bare.net), math.floor(s.bare.crafts + 0.5))
    end
    M.Print(line)
  end
end

M.commands.legacy = function(rest)
  if rest == "forget" then return B.Forget() end
  if rest and rest:match("%a") then return B.ReportSaving(rest) end
  B.Report()
end
