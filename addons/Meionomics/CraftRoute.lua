-- Levelling route: the cheapest expected sequence of crafts from the current rank to a target,
-- for any crafting profession (recipes, thresholds, reagents from CraftData; recorded data wins).
--   C.Route.Plan(prof, rank, target, opts) -> plan (see the end of Plan)
--   opts.resale      count what crafted items sell for (else materials and learning only)
--   opts.unverified  include trainer recipes no trainer visit has confirmed ("~"); the UI
--                    passes it unless "confirmed only" is set
--   opts.pin         { id, from, to }: that recipe over that stretch (as far as it gives points),
--                    the rest planned around it; ignored when it can't be used there
--   opts.max         the training cap, for a rank not his (what-if); else his own
--   opts.heldFree    held materials cost nothing (already paid for), so the route spends them
--   C.Route.Alternatives(plan, step, max) -> other recipes for a step's stretch, cheapest first
--   C.Route.Start(prof, rank, target, opts) -> job: Plan a slice at a time; job.Step() runs one
--                    (true when done), then job.plan, or job.err
-- Points: orange gives skill-ups per craft, yellow/green the chance (grey - rank) /
-- (grey - yellow). A camp station (R.Station: Spinning Wheel...) is charged once per step.
-- Learning (fee, pattern) is charged once per recipe, on its first step; the
-- solver can't see that, so each pass treats what the previous route learnt as free (Cost
-- charges it properly, and Best keeps the least Effort by that). Patterns the Find view
-- calls "not available" (C.PatternSource none) are left out.
-- Materials held (bags, bank, mail, alts) go first and cost what they would sell for
-- (C.Value.HeldCost, after the AH cut; nothing with opts.heldFree), those selling for more
-- than a new one costs kept to sell; the rest the AH price, or crafting them when cheaper
-- (bolts). Mats the AH has too few of (and no vendor sells) cost SHORT_PENALTY more, and the
-- second half of what is listed THIN_PENALTY more (listings climb from the min price), so a
-- route doesn't plan to buy out the AH.
-- Outputs recoup what sells here within a week (C.Value.Worth) at the AH; the rest the better
-- of vendor and disenchant (only with this character's Enchanting high enough). An output a
-- later step uses (Light Leather into kits) goes there first, worth the buy price it saves.
-- These depend on how much the route makes and uses, so the plan is solved PASSES times, each
-- with the previous route's quantities, and the least Effort by full costing is kept.
-- Outputs the previous route didn't make are valued as if made over their usable range (all
-- of it, and again up to green: see Guess): valued as one sale each, every unused recipe
-- looked profitable and the passes flipped between them.
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
-- Profit view's job). At 1s it planned 129 green Black Silk Packs for 39 points. Scaled by
-- rank: a flat 30s swamped low-skill costs (kits at 66c a point over Light Leather at 3c).
local EFFORT_PER_RANK, EFFORT_MIN = 10, 100
-- the solver is a heuristic that lands on different routes at different effort weights, so it
-- searches at each of these (x the effort) and keeps the best under the real one: per rank
-- alone, Tailoring 151-225 cost 9g more than the flat 30s; these two match or beat both
local SEARCH_SCALES = { 2, 0.5 }
local searchScale = 1
-- also searched with each craft's profit counted (floored at half its effort, so a profitable
-- craft still costs time): with net floored at 0 the solver can't see profit and missed
-- routes that earn (Alchemy 1-300 resale 346g vs 166g). Alone it chases outputs whose guessed
-- value Cost doesn't confirm (LW 1-300 resale 6.6g worse), so both run and Effort picks
local searchProfit = false
local function CraftEffort(k)
  return math.max(EFFORT_MIN, EFFORT_PER_RANK * k) * searchScale
end

------------------------------------------------------------------------------ Market
-- per item for one plan (Plan and FromHeld wipe it): a plan solves hundreds of times, and
-- asking TSM afresh each time froze the game ~1.5 s on opening Tailoring
local memo = {}
local function Memo(kind, id, fn)
  local t = memo[kind]
  if not t then t = {} memo[kind] = t end
  local v = t[id]
  if v == nil then
    v = { fn(id) }
    t[id] = v
  end
  return unpack(v)
end

-- what the AH has up: { qty, age, from } (P.SellRate: own scan, else TSM's count); nil unknown
local function Listed(itemID)
  local s = P.SellRate(itemID)
  if not (s and s.listed) then return nil end
  return { qty = s.listed, age = s.age, from = s.from }
end
function Route.Listed(itemID) return Memo("listed", itemID, Listed) end

local function RestNow(id)
  local de = P.CanDisenchant(id) and P.Disenchant(id) or 0
  return math.max(P.Get(id, "vendor") or 0, de), de
end
local function Rest(id) return Memo("rest", id, RestNow) end

-- n made: what they bring, how many at the AH
local function OutValue(id, n)
  local each, where = R.SellValue(id)
  local rest = Rest(id)
  if where ~= "ah" then return n * math.max(each or 0, rest), 0 end
  local _, atAH = V.Worth(id, n)
  return atAH * each + (n - atAH) * rest, atAH
end

------------------------------------------------------------------------------ Slices
-- a big profession's plan is ~0.5 s of Lua (hundreds of solves): in one frame, a freeze when
-- the panel opens on it. Under Route.Start each solve first gives way once the slice is used.
local SLICE_MS = 12
local slice
local function Breathe()
  if not (slice and debugprofilestop() - slice > SLICE_MS) then return end
  -- a plan made meanwhile (scenarios, FromHeld) leaves these at their defaults
  local scale, profit = searchScale, searchProfit
  coroutine.yield()
  searchScale, searchProfit = scale, profit
end

function Route.Start(prof, rank, to, opts)
  local co = coroutine.create(function() return Route.Plan(prof, rank, to, opts) end)
  local job = {}
  function job.Step()
    if job.done then return true end
    slice = debugprofilestop()
    local ok, res = coroutine.resume(co)
    slice = nil
    if not ok then
      job.err, job.done = debug.traceback(co, res), true
    elseif coroutine.status(co) == "dead" then
      job.plan, job.done = res, true
    end
    return job.done
  end
  return job
end

------------------------------------------------------------------------------ Candidates
-- every recipe of the profession this character can use or get: known, recorded at a trainer,
-- a pattern held or to be had; trainer recipes not confirmed only with opts.unverified
local function Candidates(prof, opts, skipped)
  local line = C.LineOf(prof)
  local out, seen = {}, {}
  local function Consider(id)
    Breathe()
    if seen[id] then return end
    seen[id] = true
    local rec = C.Recipe(id)
    if not (rec and rec.mats and rec.prof == prof) then return end
    local learn, yellow, _, grey, ups, item, estLearn = C.Bands(rec)
    if not grey then return end
    local c = { rec = rec, learn = learn or 1, yellow = yellow, grey = grey, ups = ups or 1,
      item = item, estLearn = estLearn, fee = 0, setup = 0 }
    local station = R.Station(rec)
    if station then c.setup, c.station = station.cost, station end
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
local function Vendor(id) return P.VendorBuy(id) end

local function HeldCost(opts, id, pile, n)
  return opts.heldFree and 0 or V.HeldCost(id, pile, n)
end

local function BuyPrice(id)
  local p = R.MatPrice(id)
  local _, each = C.CraftInstead(id)
  if each and (not p or each < p) then return each, true end
  return p
end

-- of need, how much held stock to use: only units selling for no more than buying one costs
-- (a bolt crafted from cloth for less than held bolts sell for). Units a vendor would take
-- (past a week's sales) go first, those selling at the AH after.
local function HeldUse(opts, id, need)
  local pile = C.Have(id).total
  local n = math.min(pile, need)
  local buy = BuyPrice(id)
  if opts.heldFree or not buy or n <= 0 then return n end
  local _, atAH = V.Worth(id, pile)
  local low = math.min(n, pile - atAH)
  local use = 0
  if low > 0 and V.HeldCost(id, pile, low) <= buy * low + 1e-6 then use = low end
  if use == low and n > low
    and V.HeldCost(id, pile, n) - V.HeldCost(id, pile, low) <= buy * (n - low) + 1e-6 then
    use = n
  end
  return use
end

-- of need, what held stock doesn't cover: what the route's own crafts can stand in for
local function Fed(opts, id, need)
  if not need or need <= 0 then return 0 end
  return math.max(0, need - HeldUse(opts, id, need))
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
      local held = HeldUse(opts, id, need)
      local rest = need - held
      local l = not crafted and rest > 0 and not Vendor(id) and Route.Listed(id)
      local short = l and math.max(0, rest - l.qty) or 0
      local thin = l and math.max(0, math.min(rest, l.qty) - l.qty / 2) or 0
      if rest > 0 and not buy then
        price[id] = false
      else
        local cost = HeldCost(opts, id, h.total, held) + (rest - short - thin) * (buy or 0)
          + thin * (buy or 0) * THIN_PENALTY + short * (buy or 0) * SHORT_PENALTY
        price[id] = cost / need
      end
    end
    return price[id] or nil
  end
  function value.Out(id)
    if value[id] == nil then
      local n = math.max(made[id] or guess[id] or 0, 1)
      local used = math.min(n, Fed(opts, id, use[id]))
      local buy = used > 0 and BuyPrice(id) or 0
      value[id] = (used * buy + (opts.resale and OutValue(id, n - used) or 0)) / n
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
local function Solve(cands, from, to, price, value, paid)
  Breathe()
  local best, choice = { [to] = 0 }, {}
  local st = {}
  for i, c in ipairs(cands) do
    local net = CraftCost(c, price, value)
    if net then
      st[i] = { c = c, net = searchProfit and net or math.max(net, 0), q = 0,
        top = math.min(c.grey, to), fee = (paid and paid[c] and 0 or c.fee) + c.setup }
    end
  end
  for s = to - 1, from, -1 do
    local bestCost, bestI, bestE = math.huge, nil, nil
    local effort = CraftEffort(s)
    for i, x in pairs(st) do
      if s < x.top then
        if best[s + 1] and (not x.h or best[s + 1] - x.q < x.h) then
          x.h, x.e = best[s + 1] - x.q, s + 1
        end
        local pts = Points(x.c, s)
        if pts > 0 then
          x.q = x.q + math.max(x.net + effort, effort * 0.5) / pts
          if x.h then
            local cost = x.fee + x.q + x.h
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
    setup = 0, recoup = 0, crafts = 0, complete = true }
  local first = {}
  for _, st in ipairs(steps) do
    local f = first[st.c]
    st.fee, st.learnt = f and 0 or st.c.fee, f and f.from or nil
    first[st.c] = f or st
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
    plan.learn = plan.learn + st.fee
    st.setup = st.c.setup
    plan.setup = plan.setup + st.setup
    if st.c.station and not st.c.station.complete then plan.complete = false end
  end
  plan.mats = {}
  local unit, worth, fed = {}, {}, {}
  for id, need in pairs(use) do
    local h = C.Have(id)
    local held = HeldUse(opts, id, need)
    local price, crafted = BuyPrice(id)
    fed[id] = made[id] and math.min(made[id], Fed(opts, id, need)) or 0
    local buy = math.max(0, math.ceil(need - held - fed[id] - 1e-6))
    local vendor = not crafted and Vendor(id) or nil
    local m = { id = id, need = need, held = held, made = fed[id], buy = buy, price = price,
      crafted = crafted, kept = math.max(0, math.min(h.total, need) - held),
      vendor = vendor, heldCost = HeldCost(opts, id, h.total, held),
      listed = not (crafted or vendor) and Route.Listed(id) or nil }
    if buy > 0 and not price then plan.complete = false end
    m.cost = buy * (price or 0)
    plan.buy = plan.buy + m.cost
    plan.heldValue = plan.heldValue + m.heldCost
    if m.listed and buy > m.listed.qty then m.short = buy - m.listed.qty end
    unit[id] = (m.cost + m.heldCost + fed[id] * (price or 0)) / need
    plan.mats[#plan.mats + 1] = m
  end
  plan.outputs = {}
  for id, n in pairs(made) do
    local used = fed[id] or 0
    local value, atAH = OutValue(id, n - used)
    local rest, de = Rest(id)
    local s = V.Sales(id)
    local o = { id = id, made = n, used = used, atAH = atAH, value = value, rest = rest,
      de = de > 0 and de >= (P.Get(id, "vendor") or 0) or nil, day = s.day, bound = s.bound,
      listed = Route.Listed(id) }
    plan.recoup = plan.recoup + value
    worth[id] = (value + used * (BuyPrice(id) or 0)) / n
    plan.outputs[id] = o
  end
  for _, st in ipairs(steps) do
    local rec, cost = st.c.rec, 0
    for _, m in ipairs(rec.mats) do cost = cost + m[2] * st.crafts * unit[m[1]] end
    st.mats = cost
    local out = rec.out and R.Made(rec) * st.crafts or 0
    st.value = rec.out and (opts.resale and out * worth[rec.out]
      or out * (fed[rec.out] or 0) * (BuyPrice(rec.out) or 0) / made[rec.out]) or 0
    st.net = cost + st.fee + st.setup - st.value
  end
  plan.gross = plan.buy + plan.heldValue + plan.learn + plan.setup
  plan.net = plan.gross - (opts.resale and plan.recoup or 0)
  plan.unit = unit
  return plan, use, made
end

-- outputs if each recipe were crafted over its points between rank and to, or only up to
-- green (toGreen). Which guess finds the cheaper route varies: over the whole range, the green
-- tail (1 / chance, ~20 crafts for 5 points) values a narrow seller as dozens made, most
-- vendored (Orange Martial Shirt: 29 guessed, 6 needed); up to green, other routes come out
-- worse. Best tries both.
local function Guess(cands, rank, to, toGreen)
  local guess = {}
  for _, c in ipairs(cands) do
    local out = c.rec.out
    if out then
      local n = 0
      local top = c.grey
      if toGreen then top = math.max(math.floor((c.yellow + c.grey) / 2), c.yellow + 1) end
      for k = math.max(rank, c.learn), math.min(top, to) - 1 do
        local p = Points(c, k)
        if p > 0 then n = n + 1 / p end
      end
      n = n * R.Made(c.rec)
      if n > (guess[out] or 0) then guess[out] = n end
    end
  end
  return guess
end

-- steps from to to, with pins ({ c, from, to } in order, apart) forced over their stretches
-- and the rest solved around them
local function Steps(cands, from, to, price, value, pins, paid)
  local steps, s = {}, from
  local function Add(st)
    local last = steps[#steps]
    if last and last.c == st.c and last.to == st.from then
      last.to = st.to
    else
      steps[#steps + 1] = st
    end
  end
  local function Fill(b)
    if b <= s then return true end
    local got = Solve(cands, s, b, price, value, paid)
    if not got then return false end
    for _, st in ipairs(got) do Add(st) end
    return true
  end
  for _, pin in ipairs(pins or {}) do
    if pin.from < s or not Fill(pin.from) then return nil end
    Add({ c = pin.c, from = pin.from, to = pin.to })
    s = pin.to
  end
  if not Fill(to) then return nil end
  return steps
end

-- a step more is a recipe more to learn and stock for: what the search must gain to add one.
-- What every pick (Best, Improve, Plan) minimises; picking passes by net alone threw away
-- routes with far fewer crafts for a few copper
local STEP_EFFORT = 10000
local function Effort(p)
  local e = p.net + #p.steps * STEP_EFFORT
  for _, st in ipairs(p.steps) do
    e = e + (st.crafts or 0) * CraftEffort((st.from + st.to) / 2)
  end
  return e
end

local function Best(cands, rank, to, opts, pins)
  local plan
  for _, toGreen in ipairs({ false, true }) do
    local use, made, paid = {}, {}, {}
    for _, pin in ipairs(pins or {}) do paid[pin.c] = true end
    local guess = Guess(cands, rank, to, toGreen)
    for _ = 1, PASSES do
      local price, value = Pricer(use, made, guess, opts)
      local steps = Steps(cands, rank, to, price, value, pins, paid)
      if not steps then break end
      local p
      p, use, made = Cost(steps, opts)
      paid = {}
      for _, st in ipairs(steps) do paid[st.c] = true end
      if not plan or Effort(p) < Effort(plan) then plan = p end
    end
  end
  if plan then plan.pins = pins or {} end
  return plan
end

-- pin { id, from, to } -> { c, from, to }: the recipe over as much of that stretch as it
-- gives points; nil when it can't be used there
local function Pin(cands, rank, to, pin)
  if not pin then return nil end
  for _, c in ipairs(cands) do
    if c.rec.id == pin.id then
      local a, b = math.max(pin.from, rank), math.min(pin.to, c.grey, to)
      if a >= c.learn and b > a then return { c = c, from = a, to = b } end
      return nil
    end
  end
end


-- The solver prices outputs by a guessed count, so a narrow seller can look worse than it is
-- (Tailoring 190: Orange Martial Shirt first, then Star Belt; planned 7.99g, found 3.85g).
-- Alternatives prices each for what it would make: an early step's alternative that beats it
-- there gets a full plan with it pinned beside the pins so far, the cheaper kept; again from
-- that one. Only those that beat it, so most plans cost no extra solve.
-- Later steps get one try a round, the best of them: none, and Leatherworking 4-75 kept
-- Embossed Leather Boots 55-65 where Fine Leather Gloves cost 11s less; as many as the early
-- ones, and Tailoring 151-225 lost 4g (the tries crowded out early ones that paid more).
local IMPROVE_STEPS, IMPROVE_TRIES, IMPROVE_ROUNDS, IMPROVE_LATE = 2, 3, 3, 1
local function Improve(plan, cands, rank, to, opts)
  plan.cands, plan.resale = cands, opts.resale
  local function ByRank(x, y) return x.rank < y.rank end
  for _ = 1, IMPROVE_ROUNDS do
    local early, late, looked = {}, {}, 0
    for _, st in ipairs(plan.steps) do
      local free = true
      for _, pin in ipairs(plan.pins) do
        free = free and (pin.to <= st.from or pin.from >= st.to)
      end
      if free then
        local into = looked < IMPROVE_STEPS and early or late
        for _, a in ipairs(Route.Alternatives(plan, st, IMPROVE_TRIES)) do
          if a.rank < 0 then into[#into + 1] = a end
        end
        looked = looked + 1
      end
    end
    table.sort(early, ByRank)
    table.sort(late, ByRank)
    local tries = {}
    for i = 1, math.min(IMPROVE_TRIES, #early) do tries[#tries + 1] = early[i] end
    for i = 1, math.min(IMPROVE_LATE, #late) do tries[#tries + 1] = late[i] end
    local best = plan
    for _, a in ipairs(tries) do
      local pin = Pin(cands, rank, to, { id = a.c.rec.id, from = a.from, to = a.to })
      if pin then
        local pins = { pin }
        for _, old in ipairs(plan.pins) do pins[#pins + 1] = old end
        table.sort(pins, function(x, y) return x.from < y.from end)
        local p = Best(cands, rank, to, opts, pins)
        if p and Effort(p) < Effort(best) then best = p end
      end
    end
    if best == plan then break end
    best.cands, best.resale = cands, opts.resale
    plan = best
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

-- -> { steps = { { c, from, to, crafts, sd, mats, value, net, fee (0 when an earlier step
--   learnt it), learnt (that step's from), setup (station) } }, mats (made: the part the
--   route's own crafts cover; kept: held units left to sell, worth more), outputs (used: the
--   part later steps take), stops, buy, heldValue, learn, setup, recoup, gross, net, crafts, complete, skipped, prof, from, to,
--   stuck (the target can't be reached: steps go as far as they can, to reach), pin (opts.pin
--   resolved: { c, from, to }, nil when ignored), pins (every stretch forced: the pin and what
--   Improve found), cands, unit (mat id -> cost each) }
-- c: { rec, how = known|trainer|pattern, fee, setup, station (R.Station), held, src (C.PatternSource), unverified,
--   estFee, learn, yellow, grey, item, estLearn }
-- Tools none is held of (Runed Truesilver Rod): a recipe needing one carries the rod's cost
-- as setup, so the solver weighs it (charged per step there; ToolSteps charges it once).
-- Left out when the rod can't be made before the recipe goes grey or a mat has no price.
local function ToolCosts(cands, prof)
  local byRec, perCat, out = {}, {}, {}
  for _, c in ipairs(cands) do byRec[c.rec.id] = c end
  local function Rod(cat)
    if perCat[cat] == nil then
      local rec = C.ToolRecipe(cat, prof)
      local rc = rec and byRec[rec.id]
      if rec and not rc then
        local learn, yellow, _, grey, ups = C.Bands(rec)
        rc = grey and { rec = rec, how = "trainer", fee = C.EstFee(prof, learn or 1),
          estFee = true, learn = learn or 1, yellow = yellow, grey = grey, ups = ups or 1,
          setup = 0 }
      end
      local mats = rc and 0
      for _, m in ipairs(rc and rec.mats or {}) do
        local p = BuyPrice(m[1])
        if not p then mats = nil break end
        mats = mats + p * m[2]
      end
      perCat[cat] = mats and { cat = cat, c = rc, mats = mats, fee = rc.fee,
        cost = mats + rc.fee } or false
      -- bought when that is cheaper (Blacksmith Hammer: 18c at a vendor, the only hammer
      -- Blacksmithing makes is Mithril, at 110; without this it stuck at 89)
      for _, item in ipairs(M.CraftTools[cat] and M.CraftTools[cat][2] or {}) do
        local p = Vendor(item) or R.MatPrice(item)
        local t = perCat[cat]
        if p and (not t or p < t.cost) then
          perCat[cat] = { cat = cat, item = item, mats = 0, fee = 0, cost = p, bought = true }
        end
      end
    end
    return perCat[cat]
  end
  for _, c in ipairs(cands) do
    local cat = C.MissingTool(c.rec)
    local t = cat and Rod(cat)
    if not cat then
      out[#out + 1] = c
    elseif t and (t.bought or t.c.learn < c.grey) then
      c.tool, c.setup = t, c.setup + t.cost
      out[#out + 1] = c
    end
  end
  return out
end

-- the rod's step before the first step needing it; the later ones' setup back to their own
local function ToolSteps(plan)
  local seen, steps = {}, {}
  for _, st in ipairs(plan.steps) do
    local t = st.c.tool
    if t then
      st.setup, st.net = st.setup - t.cost, st.net - t.cost
      plan.setup = plan.setup - t.cost
      if not seen[t.cat] and t.bought then
        seen[t.cat] = true
        plan.mats[#plan.mats + 1] = { id = t.item, need = 1, held = 0, made = 0, buy = 1,
          price = t.cost, cost = t.cost, kept = 0, heldCost = 0, vendor = Vendor(t.item),
          tool = true }
        plan.buy = plan.buy + t.cost
      elseif not seen[t.cat] then
        seen[t.cat] = true
        steps[#steps + 1] = { c = t.c, from = st.from, to = st.from, crafts = 1, sd = 0,
          mats = t.mats, value = 0, setup = 0, fee = t.fee, net = t.cost,
          tool = C.ToolName(t.cat) }
        plan.setup, plan.crafts = plan.setup + t.cost, plan.crafts + 1
      end
    end
    steps[#steps + 1] = st
  end
  plan.steps = steps
  plan.gross = plan.buy + plan.heldValue + plan.learn + plan.setup
  plan.net = plan.gross - (plan.resale and plan.recoup or 0)
end

-- Effort for comparisons outside: cost = { net, at, n } from SkillBonus B.Recost (at[k] gold,
-- n[k] crafts at rank k) prices the plan's steps at other chances, per rank; x, y limit it to
-- ranks x..y-1, a step charged where it starts. Without cost: the plan as planned
function Route.Effort(plan, cost, x, y)
  if not cost then return Effort(plan) end
  x, y = x or plan.from, y or plan.to
  local e = 0
  for k = x, y - 1 do e = e + (cost.at[k] or 0) + (cost.n[k] or 0) * CraftEffort(k) end
  for _, st in ipairs(plan.steps) do
    if st.from >= x and st.from < y then e = e + STEP_EFFORT end
  end
  return e
end

local function Search(cands, rank, to, opts, want)
  local plan, pin
  for _, mode in ipairs({ false, true }) do for _, scale in ipairs(SEARCH_SCALES) do
    searchScale, searchProfit = scale, mode
    local p = want and Best(cands, rank, to, opts, { want })
    local pn = p and want
    if not p then p = Best(cands, rank, to, opts) end
    if p then p = Improve(p, cands, rank, to, opts) end
    searchScale, searchProfit = 1, false
    if p and (not plan or Effort(p) < Effort(plan)) then plan, pin = p, pn end
  end end
  return plan, pin
end

function Route.Plan(prof, rank, to, opts)
  opts = opts or {}
  R.ResetCache()
  wipe(memo)
  local skipped = { unverified = 0, noSource = 0 }
  local cands = ToolCosts(Candidates(prof, opts, skipped), prof)
  local reach = to
  local want = Pin(cands, rank, to, opts.pin)
  local plan, pin = Search(cands, rank, to, opts, want)
  if plan and opts.heldFree then
    -- the paid route, its held mats now free, as a candidate: "use my mats" must never cost
    -- more, and the search alone missed it (Tailoring 151-225 resale: 0.6g more effort)
    local paidOpts = {}
    for k, v in pairs(opts) do paidOpts[k] = v end
    paidOpts.heldFree = nil
    local paid, paidPin = Search(cands, rank, to, paidOpts, want)
    local p = paid and Cost(paid.steps, opts)
    if p and Effort(p) < Effort(plan) then
      p.pins, plan, pin = paid.pins, p, paidPin
    end
  end
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
      buy = 0, recoup = 0, gross = 0, heldValue = 0, setup = 0, complete = true }
    plan.stuck = true
  end
  local max = opts.max or select(2, C.Rank(prof))
  plan.prof, plan.from, plan.to, plan.reach, plan.skipped = prof, rank, to, reach, skipped
  plan.resale, plan.heldFree, plan.cands, plan.pin = opts.resale, opts.heldFree, cands, pin
  ToolSteps(plan)
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

-- money (no craft effort) to take c from a to b in place of step st: crafts, mats at the
-- plan's unit costs (else the buy price), learning unless another step pays it, less what the
-- crafts add to the plan's sales of that item (beside what it already sells, st's own aside).
-- -> cost, crafts; nil when a mat has no price
local function Stretch(plan, st, c, a, b)
  local n = 0
  for k = a, b - 1 do
    local p = Points(c, k)
    if p <= 0 then return nil end
    n = n + 1 / p
  end
  local cost = 0
  for _, m in ipairs(c.rec.mats) do
    local u = plan.unit and plan.unit[m[1]] or BuyPrice(m[1])
    if not u then return nil end
    cost = cost + u * m[2] * n
  end
  local paid = false
  for _, o in ipairs(plan.steps) do paid = paid or (o ~= st and o.c == c) end
  if not paid then cost = cost + c.fee end
  cost = cost + c.setup
  local out = c.rec.out
  if plan.resale and out then
    local o = plan.outputs and plan.outputs[out]
    local had = o and o.made or 0
    if c == st.c then had = had - R.Made(c.rec) * st.crafts end
    had = math.max(had, 0)
    cost = cost - (OutValue(out, had + n * R.Made(c.rec)) - OutValue(out, had))
  end
  return cost, n
end

-- other recipes for step st's stretch, cheapest first (up to max): each priced for what it
-- would make there, not the plan's guess, and only until it turns green (the green tail is
-- many crafts a point); the rest of the stretch at the step's own rate.
-- -> { { c, from, to, n (its crafts there), delta (money vs the step), crafts (extra vs the
--   step) } }
function Route.Alternatives(plan, st, max)
  local base, baseN = Stretch(plan, st, st.c, st.from, st.to)
  if not (base and plan.cands) then return {} end
  local span = st.to - st.from
  local out = {}
  for _, c in ipairs(plan.cands) do
    if c ~= st.c and c.learn <= st.from and c.grey > st.from then
      local green = math.floor((c.yellow + c.grey) / 2)
      local e = math.min(st.to, c.grey, math.max(green, st.from + 1))
      local cost, n = Stretch(plan, st, c, st.from, e)
      if cost then
        local rest = (st.to - e) / span
        local delta = cost + base * rest - base
        local extra = n + baseN * rest - baseN
        out[#out + 1] = { c = c, from = st.from, to = e, delta = delta, crafts = extra, n = n,
          rank = delta + extra * CraftEffort(st.from) }
      end
    end
  end
  table.sort(out, function(x, y) return x.rank < y.rank end)
  for i = #out, (max or 5) + 1, -1 do out[i] = nil end
  return out
end

------------------------------------------------------------------------------ From held
-- What the materials he holds can level, no target: one craft at a time from his rank, the
-- recipe giving the most points per copper (held mats at their price, so the scarce ones are
-- rationed; less what the craft makes is worth), as long as held mats pay at least half of
-- it (vendor mats aside). Held mats are free in the costs; bought ones and learning are not.
-- Known, trainer and held-pattern recipes only (trainer ones not confirmed with
-- opts.unverified); up to opts.to if given.
-- What crafts make joins the held stock (Light Leather made goes into the kits after it) and
-- is worth what it sells for. An intermediate a recipe here uses may be made from bought
-- mats: Light Leather from scraps nets ~8c a point where a kit from held Light Leather costs
-- ~66c (sells for 15c), so the kits wait. Not its buy price: stock nothing uses gets sold.
-- -> a plan as Route.Plan's (held = true; outputs: what is made and left over, sold; no
--   alternatives or pin)
local HELD_MAX_CRAFTS = 400
-- copper a craft costs in time, per skill rank: a cheap craft near grey (Light Leather at 8c,
-- 1 in 4 at 39) loses to an orange one (a kit, 67c) once 1 / chance crafts cost more
local HELD_EFFORT_PER_RANK = 1

function Route.FromHeld(prof, rank, opts)
  opts = opts or {}
  R.ResetCache()
  wipe(memo)
  local skipped = { unverified = 0, noSource = 0 }
  local cands = {}
  for _, c in ipairs(Candidates(prof, opts, skipped)) do
    if not c.src then cands[#cands + 1] = c end
  end
  local left, price, vendor = {}, {}, {}
  local function Left(id)
    if left[id] == nil then left[id] = C.Have(id).total end
    return left[id]
  end
  local function Price(id)
    if price[id] == nil then price[id] = BuyPrice(id) or false end
    return price[id] or nil
  end
  local usedHere = {}
  for _, c in ipairs(cands) do
    for _, m in ipairs(c.rec.mats) do usedHere[m[1]] = true end
  end
  -- one craft now: its weighted cost (at least 1) and bought part, or nil when held mats
  -- don't pay for it and it makes nothing used here
  local function Craft(c)
    local held, buy, any = 0, 0, false
    for _, m in ipairs(c.rec.mats) do
      local id, n = m[1], m[2]
      local p = Price(id)
      if Left(id) >= n then
        held, any = held + n * (p or 0) + 1, true
      elseif not p then
        return nil
      else
        buy = buy + n * p
        if Vendor(id) then held = held + n * p end
      end
    end
    local out = c.rec.out
    if (not any or buy > held) and not (out and usedHere[out]) then return nil end
    local worth = out and OutValue(out, R.Made(c.rec)) or 0
    return math.max(1, held + buy - worth), buy
  end
  local byRec = {}
  for _, c in ipairs(cands) do byRec[c.rec.id] = c end
  -- a tool (Runed Truesilver Rod) none is held of: its recipe, made once before the first
  -- craft needing it; false when it can't be made at this rank
  local tooled = {}
  local function ToolFirst(c, at)
    local cat = C.MissingTool(c.rec)
    if not cat or tooled[cat] then return nil end
    local t = C.ToolRecipe(cat, prof)
    local tc = t and byRec[t.id]
    if not (tc and at >= tc.learn) then return false end
    for _, m in ipairs(tc.rec.mats) do
      if Left(m[1]) < m[2] and not Price(m[1]) then return false end
    end
    return tc, cat
  end
  local k, steps, last = rank, {}, nil
  local learnt, mats, use, made = {}, {}, {}, {}
  local complete = true
  local function Take(c, at, tool)
    local buy = 0
    for _, m in ipairs(c.rec.mats) do
      local id, n = m[1], m[2]
      use[id] = (use[id] or 0) + n
      if Left(id) >= n then
        left[id] = left[id] - n
      else
        buy = buy + n * (Price(id) or 0)
      end
    end
    local out = c.rec.out
    if out then
      local n = R.Made(c.rec)
      left[out] = Left(out) + n
      made[out] = (made[out] or 0) + n
    end
    local pts = Points(c, at)
    if not (last and last.c == c) then
      last = { c = c, from = at, crafts = 0, sd = 0, mats = 0, value = 0, setup = 0,
        fee = learnt[c] and 0 or c.fee, learnt = learnt[c], pts = 0, tool = tool }
      learnt[c] = learnt[c] or at
      steps[#steps + 1] = last
    end
    last.crafts, last.mats, last.pts = last.crafts + 1, last.mats + buy, last.pts + pts
    k = k + pts
    last.to = math.floor(k)
  end
  for _ = 1, HELD_MAX_CRAFTS do
    if opts.to and k >= opts.to then break end
    local best, bestScore, bestTool
    local at = math.floor(k)
    for _, c in ipairs(cands) do
      local pts = Points(c, at)
      local tool = pts > 0 and ToolFirst(c, at)
      if pts > 0 and tool ~= false then
        local w = Craft(c)
        local score = w and pts / (w + HELD_EFFORT_PER_RANK * at)
        if score and (not bestScore or score > bestScore) then
          best, bestScore, bestTool = c, score, tool
        end
      end
    end
    if not best then break end
    if bestTool then
      local tc, cat = ToolFirst(best, at)
      tooled[cat] = true
      Take(tc, at, C.ToolName(cat))
      last = nil
      at = math.floor(k)
      if Points(best, at) <= 0 or not Craft(best) then at = nil end
    end
    if at then Take(best, at) end
  end
  local plan = { steps = steps, held = true, cands = cands, skipped = skipped, outputs = {},
    mats = {}, buy = 0, heldValue = 0, learn = 0, setup = 0, recoup = 0, crafts = 0,
    complete = complete, prof = prof, from = rank, reach = math.floor(k), stops = {} }
  plan.to = plan.reach
  for _, st in ipairs(steps) do
    st.to = math.max(st.to, st.from)
    st.net = st.mats + st.fee
    plan.learn, plan.crafts = plan.learn + st.fee, plan.crafts + st.crafts
  end
  for id, need in pairs(use) do
    local h = C.Have(id).total
    local held = math.min(h, need)
    local buy = math.max(0, need - held - (made[id] or 0))
    local p = Price(id)
    local m = { id = id, need = need, held = held, buy = buy, price = p,
      vendor = Vendor(id), heldCost = 0, cost = buy * (p or 0) }
    plan.buy = plan.buy + m.cost
    mats[#mats + 1] = m
  end
  plan.mats = mats
  -- what crafts made and nothing after used is sold (Light Leather past the kits)
  for id, n in pairs(made) do
    local spare = math.min(n, left[id] or 0)
    if spare > 0 then
      local value, atAH = OutValue(id, spare)
      local rest, de = Rest(id)
      local s = V.Sales(id)
      plan.outputs[id] = { id = id, made = spare, atAH = atAH, value = value, rest = rest,
        de = de > 0 and de >= (P.Get(id, "vendor") or 0) or nil, day = s.day, bound = s.bound,
        listed = Route.Listed(id) }
      plan.recoup = plan.recoup + value
    end
  end
  plan.resale = true
  plan.gross = plan.buy + plan.learn
  plan.net = plan.gross - plan.recoup
  local max = opts.max or select(2, C.Rank(prof))
  for _, cap in ipairs(Stops(max, plan.reach)) do
    local unlocks = {}
    for _, st in ipairs(steps) do
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
  for _, st in ipairs(plan.steps or {}) do C.Enqueue(st.c.rec, math.ceil(st.crafts), st.to) end
end
