-- Levelling route: the cheapest expected sequence of crafts from the current rank to a target,
-- for any crafting profession (recipes, thresholds, reagents from CraftData; recorded data wins).
--   C.Route.Plan(prof, rank, target, opts) -> plan (see the end of Plan)
--   opts.resale      count what crafted items sell for (else materials and learning only)
--   opts.unverified  include trainer recipes no trainer visit has confirmed ("~"); the UI
--                    passes it unless "confirmed only" is set
-- Points: orange gives skill-ups per craft, yellow/green the chance (grey - rank) /
-- (grey - yellow). Learning (fee, pattern) is charged once per step. Patterns the Find view
-- calls "not available" (C.PatternSource none) are left out.
-- Materials held (bags, bank, mail, alts) go first and cost what they would sell for
-- (C.Value.HeldCost); the rest the AH price, or crafting them when cheaper (bolts). Mats the
-- AH has too few of (and no vendor sells) cost SHORT_PENALTY more, and the second half of
-- what is listed THIN_PENALTY more (listings climb from the min price), so a route doesn't
-- plan to buy out the AH.
-- Outputs recoup what sells here within a week (C.Value.Worth) at the AH; the rest the better
-- of vendor and disenchant (only with this character's Enchanting high enough).
-- These depend on how much the route makes and uses, so the plan is solved PASSES times, each
-- with the previous route's quantities, and the cheapest by full costing is kept. Outputs the
-- previous route didn't make are valued as if made over their whole usable range: valued as one
-- sale each, every unused recipe looked profitable and the passes flipped between them.
local _, M = ...
local R, P, C = M.Recipes, M.Prices, M.Craft
local V = C.Value
local Route = {}
C.Route = Route

local CAP_STEP = 75
local SHORT_PENALTY = 1.5
local THIN_PENALTY = 1.25
local PASSES = 3
local STUCK_STEP = 5
-- a craft that pays for itself still costs time (crafting, posting, waiting for sales): the
-- floor per craft, so the route never grinds near-grey crafts for their resale (that is the
-- Profit view's job). At 1s it planned 129 green Black Silk Packs for 39 points.
local CRAFT_EFFORT = 3000

------------------------------------------------------------------------------ Market
-- what the AH has up: { qty, age, from } (P.SellRate: own scan, else TSM's count); nil unknown
function Route.Listed(itemID)
  local s = P.SellRate(itemID)
  if not (s and s.listed) then return nil end
  return { qty = s.listed, age = s.age, from = s.from }
end

local function Rest(id)
  local de = P.CanDisenchant(id) and P.Disenchant(id) or 0
  return math.max(P.Get(id, "vendor") or 0, de), de
end

-- n made: what they bring, how many at the AH
local function OutValue(id, n)
  local each, where = R.SellValue(id)
  local rest = Rest(id)
  if where ~= "ah" then return n * math.max(each or 0, rest), 0 end
  local _, atAH = V.Worth(id, n)
  return atAH * each + (n - atAH) * rest, atAH
end

------------------------------------------------------------------------------ Candidates
-- every recipe of the profession this character can use or get: known, recorded at a trainer,
-- a pattern held or to be had; trainer recipes not confirmed only with opts.unverified
local function Candidates(prof, opts, skipped)
  local line = (R.Professions()[prof] or {}).skillLine
  local out, seen = {}, {}
  local function Consider(id)
    if seen[id] then return end
    seen[id] = true
    local rec = C.Recipe(id)
    if not (rec and rec.mats and rec.prof == prof) then return end
    local learn, yellow, _, grey, ups, item, estLearn = C.Bands(rec)
    if not grey then return end
    local c = { rec = rec, learn = learn or 1, yellow = yellow, grey = grey, ups = ups or 1,
      item = item, estLearn = estLearn, fee = 0 }
    if R.KnownHere(rec) then
      c.how = "known"
    elseif rec.train then
      c.how, c.fee = "trainer", rec.train.cost or 0
    elseif item then
      c.how = "pattern"
      if C.Have(item).total > 0 then
        c.held = true
      else
        local src = C.PatternSource(item)
        -- "unknown": no scan or TSM count says it is ever up; planning on it misleads
        local price = src.how ~= "none" and src.how ~= "unknown"
          and (src.price or C.PatternPrice(item))
        if not price then
          skipped.noSource = skipped.noSource + 1
          return
        end
        c.fee, c.src = price, src
      end
    elseif opts.unverified then
      c.how, c.unverified = "trainer", true
      c.fee, c.estFee = C.EstFee(prof, c.learn), true
    else
      skipped.unverified = skipped.unverified + 1
      return
    end
    out[#out + 1] = c
  end
  if line then
    for id, d in pairs(M.CraftData) do if d[5] == line then Consider(id) end end
  end
  for id, rec in pairs(R.All()) do if rec.prof == prof then Consider(id) end end
  return out
end

------------------------------------------------------------------------------ Pricing
-- sold by a vendor: never short, whatever the AH has up
local function Vendor(id) return P.Custom("VendorBuy", id) end

local function BuyPrice(id)
  local p = R.MatPrice(id)
  local _, each = C.CraftInstead(id)
  if each and (not p or each < p) then return each, true end
  return p
end

-- one pass's unit prices: mats by the previous route's use of stock and listings, outputs by
-- how many of them it made
local function Pricer(use, made, guess, opts)
  local price, value = {}, {}
  function price.Mat(id)
    if price[id] == nil then
      local buy, crafted = BuyPrice(id)
      local h = C.Have(id)
      local need = math.max(use[id] or 0, 1)
      local held = math.min(h.total, need)
      local rest = need - held
      local l = not crafted and rest > 0 and not Vendor(id) and Route.Listed(id)
      local short = l and math.max(0, rest - l.qty) or 0
      local thin = l and math.max(0, math.min(rest, l.qty) - l.qty / 2) or 0
      if rest > 0 and not buy then
        price[id] = false
      else
        local cost = V.HeldCost(id, h.total, held) + (rest - short - thin) * (buy or 0)
          + thin * (buy or 0) * THIN_PENALTY + short * (buy or 0) * SHORT_PENALTY
        price[id] = cost / need
      end
    end
    return price[id] or nil
  end
  function value.Out(id)
    if not opts.resale then return 0 end
    if value[id] == nil then
      local n = math.max(made[id] or guess[id] or 0, 1)
      value[id] = OutValue(id, n) / n
    end
    return value[id]
  end
  return price, value
end

-- net cost of one craft at a pass's prices, or nil when a material has no price
local function CraftCost(c, price, value)
  local cost = 0
  for _, m in ipairs(c.rec.mats) do
    local p = price.Mat(m[1])
    if not p then return nil end
    cost = cost + p * m[2]
  end
  if c.rec.out then cost = cost - value.Out(c.rec.out) * R.Made(c.rec) end
  return cost
end

-- expected points from one craft at a rank
local function Points(c, k)
  if k < c.learn or k >= c.grey then return 0 end
  if k < c.yellow then return c.ups end
  return C.Chance(k, c.yellow, c.grey)
end

------------------------------------------------------------------------------ Solving
-- best[s]: cheapest from s to the target. A step uses one recipe from s to e: its learning
-- cost plus the sum of cost / points over each level. H keeps, per recipe, the best end
-- (best[e] - Q[e]) seen so far going down, Q the running sum, so this is O(levels x recipes).
local function Solve(cands, from, to, price, value)
  local best, choice = { [to] = 0 }, {}
  local st = {}
  for i, c in ipairs(cands) do
    local net = CraftCost(c, price, value)
    if net then
      st[i] = { c = c, net = math.max(net, 0) + CRAFT_EFFORT, q = 0,
        top = math.min(c.grey, to) }
    end
  end
  for s = to - 1, from, -1 do
    local bestCost, bestI, bestE = math.huge, nil, nil
    for i, x in pairs(st) do
      if s < x.top then
        if best[s + 1] and (not x.h or best[s + 1] - x.q < x.h) then
          x.h, x.e = best[s + 1] - x.q, s + 1
        end
        local pts = Points(x.c, s)
        if pts > 0 then
          x.q = x.q + x.net / pts
          if x.h then
            local cost = x.c.fee + x.q + x.h
            if cost < bestCost then bestCost, bestI, bestE = cost, i, x.e end
          end
        else
          x.h = nil   -- not usable here, so no step through here
        end
      end
    end
    if bestI then best[s], choice[s] = bestCost, { i = bestI, e = bestE } end
  end
  if not best[from] then return nil end
  local steps, s = {}, from
  while s < to do
    local ch = choice[s]
    if not ch then return nil end
    local last = steps[#steps]
    if last and last.c == st[ch.i].c then
      last.to = ch.e
    else
      steps[#steps + 1] = { c = st[ch.i].c, from = s, to = ch.e }
    end
    s = ch.e
  end
  return steps
end

-- full costing of a route: expected crafts (and their spread), stock used, shortfalls,
-- recoup, learning, each step's share; fills use/made for the next pass
local function Cost(steps, opts)
  local use, made, plan = {}, {}, { steps = steps, buy = 0, heldValue = 0, learn = 0,
    recoup = 0, crafts = 0, complete = true }
  for _, st in ipairs(steps) do
    local n, var = 0, 0
    for k = st.from, st.to - 1 do
      local p = Points(st.c, k)
      n = n + 1 / p
      if p < 1 then var = var + (1 - p) / (p * p) end
    end
    st.crafts, st.sd = n, math.sqrt(var)
    plan.crafts = plan.crafts + n
    for _, m in ipairs(st.c.rec.mats) do use[m[1]] = (use[m[1]] or 0) + m[2] * n end
    if st.c.rec.out then
      made[st.c.rec.out] = (made[st.c.rec.out] or 0) + R.Made(st.c.rec) * n
    end
    plan.learn = plan.learn + st.c.fee
  end
  plan.mats = {}
  local unit, worth = {}, {}
  for id, need in pairs(use) do
    local h = C.Have(id)
    local held = math.min(h.total, need)
    local buy = math.ceil(need - held)
    local price, crafted = BuyPrice(id)
    local vendor = not crafted and Vendor(id) or nil
    local m = { id = id, need = need, held = held, buy = buy, price = price, crafted = crafted,
      vendor = vendor, heldCost = V.HeldCost(id, h.total, held),
      listed = not (crafted or vendor) and Route.Listed(id) or nil }
    if buy > 0 and not price then plan.complete = false end
    m.cost = buy * (price or 0)
    plan.buy = plan.buy + m.cost
    plan.heldValue = plan.heldValue + m.heldCost
    if m.listed and buy > m.listed.qty then m.short = buy - m.listed.qty end
    unit[id] = (m.cost + m.heldCost) / need
    plan.mats[#plan.mats + 1] = m
  end
  plan.outputs = {}
  for id, n in pairs(made) do
    local value, atAH = OutValue(id, n)
    local rest, de = Rest(id)
    local s = V.Sales(id)
    local o = { id = id, made = n, atAH = atAH, value = value, rest = rest,
      de = de > 0 and de >= (P.Get(id, "vendor") or 0) or nil, day = s.day, bound = s.bound,
      listed = Route.Listed(id) }
    plan.recoup = plan.recoup + value
    worth[id] = value / n
    plan.outputs[id] = o
  end
  for _, st in ipairs(steps) do
    local rec, cost = st.c.rec, 0
    for _, m in ipairs(rec.mats) do cost = cost + m[2] * st.crafts * unit[m[1]] end
    st.mats = cost
    st.value = rec.out and opts.resale and R.Made(rec) * st.crafts * worth[rec.out] or 0
    st.net = cost + st.c.fee - st.value
  end
  plan.gross = plan.buy + plan.heldValue + plan.learn
  plan.net = plan.gross - (opts.resale and plan.recoup or 0)
  return plan, use, made
end

-- outputs if each recipe were crafted over all of its points between rank and to
local function Guess(cands, rank, to)
  local guess = {}
  for _, c in ipairs(cands) do
    local out = c.rec.out
    if out then
      local n = 0
      for k = math.max(rank, c.learn), math.min(c.grey, to) - 1 do
        local p = Points(c, k)
        if p > 0 then n = n + 1 / p end
      end
      n = n * R.Made(c.rec)
      if n > (guess[out] or 0) then guess[out] = n end
    end
  end
  return guess
end

local function Best(cands, rank, to, opts)
  local plan
  local use, made = {}, {}
  local guess = Guess(cands, rank, to)
  for _ = 1, PASSES do
    local price, value = Pricer(use, made, guess, opts)
    local steps = Solve(cands, rank, to, price, value)
    if not steps then break end
    local p
    p, use, made = Cost(steps, opts)
    if not plan or p.net < plan.net then plan = p end
  end
  return plan
end

------------------------------------------------------------------------------ Plan
-- training stops: the current cap, then every CAP_STEP, below the target
local function Stops(max, to)
  local out = {}
  local cap = max
  while cap and cap < to do
    out[#out + 1] = cap
    cap = cap + CAP_STEP
  end
  return out
end

-- default target: the current cap, or the next one when already there
function Route.DefaultTarget(rank, max)
  if not (rank and max) then return nil end
  if rank < max then return max end
  return max + CAP_STEP
end

-- -> { steps = { { c, from, to, crafts, sd, mats, value, net } }, mats, outputs, stops,
--   buy, heldValue, learn, recoup, gross, net, crafts, complete, skipped, prof, from, to,
--   stuck (the target can't be reached: steps go as far as they can, to reach) }
-- c: { rec, how = known|trainer|pattern, fee, held, src (C.PatternSource), unverified,
--   estFee, learn, yellow, grey, item, estLearn }
function Route.Plan(prof, rank, to, opts)
  opts = opts or {}
  R.ResetCache()
  local skipped = { unverified = 0, noSource = 0 }
  local cands = Candidates(prof, opts, skipped)
  local plan, reach = Best(cands, rank, to, opts), to
  if not plan then
    -- as far as the recipes go: the highest end below the target that a route reaches
    local top = rank
    for _, c in ipairs(cands) do top = math.max(top, math.min(c.grey, to - 1)) end
    reach = top
    while reach > rank and not plan do
      plan = Best(cands, rank, reach, opts)
      if not plan then reach = math.max(rank, reach - STUCK_STEP) end
    end
    plan = plan or { steps = {}, mats = {}, outputs = {}, net = 0, crafts = 0, learn = 0,
      buy = 0, recoup = 0, gross = 0, heldValue = 0, complete = true }
    plan.stuck = true
  end
  local _, max = C.Rank(prof)
  plan.prof, plan.from, plan.to, plan.reach, plan.skipped = prof, rank, to, reach, skipped
  plan.resale = opts.resale
  plan.stops = {}
  for _, cap in ipairs(Stops(max, reach)) do
    local unlocks = {}
    for _, st in ipairs(plan.steps) do
      local c = st.c
      if c.how ~= "known" and c.learn > cap and c.learn <= cap + CAP_STEP then
        unlocks[#unlocks + 1] = c
      end
    end
    plan.stops[#plan.stops + 1] = { at = cap, unlocks = unlocks }
  end
  return plan
end

-- the route into the queue: each step's expected crafts, rounded up
function Route.Enqueue(plan)
  for _, st in ipairs(plan.steps or {}) do C.Enqueue(st.c.rec, math.ceil(st.crafts)) end
end
