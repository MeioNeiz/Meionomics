-- Invest: where a pot of gold earns most. Every way the account turns gold into more gold in
-- one pool, a day's gold put where each gold returns most. Behind the Flips tab's Invest view.
--   Options: craft flips with recipes a character knows (CraftChains), AH listings under what
--     they resell for (market and region sales after the cut, where Evidence trusts them) and
--     listings under what a vendor pays. Resale and vendor flips only from sightings under
--     FRESH old: listings move.
--   A day: crafts up to what sells here a day and the cooldowns, resale up to what sells a
--     day, vendor flips what's listed. Gold comes back as it sells, about a day, so X gold
--     keeps X a day at work. An hour of crafting, buying and posting a day (as Flips).
--   Buying deeper: one book per item (the cheapest rival listings at the last sighting,
--     A.Top, then the rest at market price) shared by every option, so two flips on the same
--     cloth bid each other up and the 30th bolt costs what the 30th listing does.
--   Allocation: greedy on profit per gold, a slice at a time from a heap. Returns only fall
--     as books empty, so a stale key is an upper bound (lazy greedy). When the hour runs out
--     before the gold, the plan by profit per second is tried too, and with gold to spare the
--     plan by each slice's profit (shared listings to the bigger use); the best one kept.
-- I.Start() -> job: Step(ms) as Chains; then job.pool (options, books, recipe outputs/mats)
-- I.Plan(pool, gold) -> { gold, used, back, profit, secs, timeBound, rows (best first):
--   { o, n, cost, back, profit, secs, why (what stopped more: see Slice) } }
-- I.Curve(pool, gold) -> { { gold, used, profit } } at fractions of gold, then unlimited
-- I.Ledger(pool, days) -> what TSM's accounting says the account did with its gold
local _, M = ...
local R, P, C = M.Recipes, M.Prices, M.Craft
local V = C.Value
local I = {}
M.Invest = I

local AH_CUT = 0.05
local FRESH = 2 * 3600          -- listings older than this aren't there to buy
local MIN_GAIN = 10             -- copper a unit must make
local MIN_MARGIN = 0.1          -- resale: a listing this far under resale value, for the risk
local MIN_RET = 0.03            -- a slice returning less than this per gold isn't worth it
local HOUR = 3600
local RESALE_SECS, VENDOR_SECS = 4, 2
local SLICES = 8
local LEDGER_DAYS = 14
local DAY = 86400
local CURVE = { 0.25, 0.5, 2, 4 }

------------------------------------------------------------------------------ Books
-- item -> ascending { { unit, qty } }: rival listings to buy from
local function Book(pool, id)
  local b = pool.books[id]
  if b then return b end
  b = {}
  local A, now = M.Auction, M.Now()
  local s = P.SellRate(id)
  local listed = s and s.listed
  local market = P.Get(id, "market")
  local top, tt = A.Top(id)
  local n = 0
  if top and tt and now - tt <= FRESH then
    for _, r in ipairs(top) do
      b[#b + 1] = { r[1], r[2] }
      n = n + r[2]
    end
  else
    local a = A.Get(id)
    local vendor = P.Get(id, "vendor")
    if a and a.t and now - a.t <= FRESH then
      if a.flipQty and a.flipEach and vendor then
        b[1] = { vendor - a.flipEach, 1 }
        if a.flipQty > 1 then
          b[2] = { vendor - math.max(MIN_GAIN, vendor * 0.05), a.flipQty - 1 }
        end
        n = a.flipQty
      elseif a.comp then
        b[1], n = { a.comp, 1 }, 1
      end
    end
    market = R.MatPrice(id) or market
  end
  local rest = listed and listed - n or (n == 0 and math.huge or 0)
  if rest > 0 and market then
    local last = b[#b] and b[#b][1] or 0
    b[#b + 1] = { math.max(last, market), rest }
  end
  pool.books[id] = b
  return b
end

-- cost of n units past the first `from`, none dearer than maxEach; nil when there aren't n
local function Take(book, from, n, maxEach)
  local cost = 0
  for _, r in ipairs(book) do
    if maxEach and r[1] > maxEach then return nil end
    if from >= r[2] then
      from = from - r[2]
    else
      local t = math.min(r[2] - from, n)
      from, cost, n = 0, cost + t * r[1], n - t
      if n <= 1e-9 then return cost end
    end
  end
end

local function Avail(book, from, maxEach)
  local total = 0
  for _, r in ipairs(book) do
    if maxEach and r[1] > maxEach then break end
    total = total + r[2]
  end
  return math.max(0, total - from)
end

------------------------------------------------------------------------------ Options
-- option: { kind = "craft" | "resale" | "vendor", id (item made or bought), f (flip), value
--   (gold back a unit), fixed (vendor mats and station a unit), draws ({ id, n } from books a
--   unit), maxEach (resale, vendor: dearest listing worth buying), cap (units a day), secs,
--   level (AH confidence) }
local function CraftOption(f)
  local fixed, draws = f.cost, {}
  for _, b in ipairs(f.buys) do
    if b.src == "ah" and b.n > 0 then
      draws[#draws + 1] = { id = b.id, n = b.n }
      fixed = fixed - b.each * b.n
    end
  end
  local cap = math.huge
  if f.exit.perDay then cap = f.exit.perDay / f.made end
  if f.cooldown then cap = math.min(cap, f.cooldown) end
  return { kind = "craft", id = f.out, f = f, value = f.value, fixed = math.max(0, fixed),
    draws = draws, cap = cap, secs = f.secs, level = f.exit.level }
end

-- after the cut; nil when the market isn't one to bet on
local function ResaleValue(id)
  local v, _, ev = P.Resale(id)
  if not v then return nil end
  return v * (1 - AH_CUT), ev.level
end

local function ListingOptions(pool, Yield)
  local realm = M.Auction.Realm()
  if not realm then return end
  local now, ids = M.Now(), {}
  for id, rec in pairs(realm.items) do
    if type(id) == "number" and rec.comp and rec.t and now - rec.t <= FRESH then
      ids[#ids + 1] = id
    end
  end
  for _, id in ipairs(ids) do
    local a = M.Auction.Get(id)
    local vendor = P.Get(id, "vendor")
    if a.flipQty and vendor then
      local maxEach = vendor - math.max(MIN_GAIN, vendor * 0.05)
      pool.options[#pool.options + 1] = { kind = "vendor", id = id, value = vendor, fixed = 0,
        draws = { { id = id, n = 1 } }, maxEach = maxEach, cap = math.huge, secs = VENDOR_SECS,
        level = "high" }
    end
    local market = a.market or P.Get(id, "market")
    if market and a.comp < market * (1 - AH_CUT) * (1 - MIN_MARGIN) and P.Auctionable(id) then
      local value, level = ResaleValue(id)
      local maxEach = value and value - math.max(MIN_GAIN, value * MIN_MARGIN)
      local day = value and V.Sales(id).day or 0
      if maxEach and a.comp <= maxEach and day > 0 then
        pool.options[#pool.options + 1] = { kind = "resale", id = id, value = value, fixed = 0,
          draws = { { id = id, n = 1 } }, maxEach = maxEach, cap = day, secs = RESALE_SECS,
          level = level }
      end
    end
    Yield()
  end
end

-- the Chains run's recipes: item -> true for what one makes, what one uses
local function RecipeSets(all)
  local outs, mats = {}, {}
  for _, rec in ipairs(all or {}) do
    outs[rec.out] = true
    for _, m in ipairs(rec.mats) do mats[m[1]] = true end
  end
  return outs, mats
end

function I.Start()
  local job, deadline = { done = 0, total = 0 }, math.huge
  local function Yield()
    if debugprofilestop() > deadline then coroutine.yield() end
  end
  local co = coroutine.create(function()
    C.Chains.Run(job, { scope = "known" }, Yield)
    local pool = { options = {}, books = {}, flips = job.list or {} }
    pool.outs, pool.mats = RecipeSets(job.all)
    for _, f in ipairs(pool.flips) do
      if f.ready then pool.options[#pool.options + 1] = CraftOption(f) end
    end
    pool.crafts = #pool.options
    ListingOptions(pool, Yield)
    job.pool = pool
  end)
  function job.Step(ms)
    if job.pool or job.err then return true end
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

------------------------------------------------------------------------------ Allocation
-- binary max-heap of { key, ... }
local function Push(h, x)
  h[#h + 1] = x
  local i = #h
  while i > 1 do
    local p = math.floor(i / 2)
    if h[p].key >= h[i].key then break end
    h[p], h[i] = h[i], h[p]
    i = p
  end
end

local function Pop(h)
  local top = h[1]
  local last = table.remove(h)
  if #h > 0 then
    h[1] = last
    local i = 1
    while true do
      local l, r, big = 2 * i, 2 * i + 1, i
      if h[l] and h[l].key > h[big].key then big = l end
      if h[r] and h[r].key > h[big].key then big = r end
      if big == i then break end
      h[big], h[i] = h[i], h[big]
      i = big
    end
  end
  return top
end

-- n units of an option at the books' state -> cost, nil when the books can't supply them
local function Cost(pool, o, n, taken)
  local cost = o.fixed * n
  for _, d in ipairs(o.draws) do
    local c = Take(Book(pool, d.id), taken[d.id] or 0, d.n * n, o.maxEach)
    if not c then return nil end
    cost = cost + c
  end
  return cost
end

local function MaxUnits(pool, o, taken)
  local n = math.huge
  for _, d in ipairs(o.draws) do
    n = math.min(n, Avail(Book(pool, d.id), taken[d.id] or 0, o.maxEach) / d.n)
  end
  return n
end

-- by: what a slice is ranked on, "gold" (profit per gold), "time" (per second) or
-- "profit" (the slice's own: for gold to spare, where shared listings go to the bigger use)
local function Run(pool, gold, secsMax, by)
  local taken, heap, rows = {}, {}, {}
  local left, tleft = gold, secsMax
  for _, o in ipairs(pool.options) do Push(heap, { key = math.huge, o = o, n = 0 }) end
  -- the next slice of x: units, cost, score; or nil and why it stops ("cap", "books",
  -- "time", "gold", "dear": the next unit wouldn't pay)
  local function Slice(x)
    local o = x.o
    local whole = o.kind ~= "craft"
    local least = whole and 1 or 0.1
    local cap, books, time = o.cap - x.n, MaxUnits(pool, o, taken), tleft / o.secs
    local most = math.min(cap, books, time)
    if not x.size then x.size = math.max(least, most / SLICES) end
    local n = math.min(most, x.size)
    if whole then n = math.floor(n + 1e-9) end
    if n <= 1e-6 then
      return nil, most == cap and "cap" or most == books and "books" or "time"
    end
    while true do
      local cost = Cost(pool, o, n, taken)
      if not cost then return nil, "books" end
      if cost > left then
        -- the most of it the gold left buys: costs only rise with n
        local lo, hi = 0, n
        for _ = 1, 24 do
          local mid = (lo + hi) / 2
          if whole then mid = math.floor(mid) end
          local c = Cost(pool, o, mid, taken)
          if c and c <= left then lo = mid else hi = mid end
          if whole and hi - lo <= 1 then break end
        end
        if lo <= 1e-6 then return nil, "gold" end
        n, cost = lo, Cost(pool, o, lo, taken)
      end
      local profit = o.value * n - cost
      if profit >= MIN_GAIN * n and profit >= cost * MIN_RET then
        local key = by == "time" and profit / (o.secs * n) or by == "profit" and profit
          or profit / math.max(cost, 1)
        return n, cost, key
      end
      -- a slice reaching into dear listings: the cheap end of it may still pay
      if n <= least + 1e-9 then return nil, "dear" end
      n = math.max(least, n / 2)
      if whole then n = math.floor(n) end
    end
  end
  local guard = 0
  while #heap > 0 and left > 0.5 and tleft > 0.01 and guard < 50000 do
    guard = guard + 1
    local x = Pop(heap)
    local n, cost, key = Slice(x)
    if not n then
      if rows[x.o] then rows[x.o].why = cost end
    else
      if heap[1] and key < heap[1].key then
        x.key = key
        Push(heap, x)
      else
        local o = x.o
        for _, d in ipairs(o.draws) do taken[d.id] = (taken[d.id] or 0) + d.n * n end
        left, tleft = left - cost, tleft - o.secs * n
        local row = rows[o]
        if not row then
          row = { o = o, n = 0, cost = 0, back = 0, secs = 0 }
          rows[o] = row
        end
        row.n, row.cost = row.n + n, row.cost + cost
        row.back, row.secs = row.back + o.value * n, row.secs + o.secs * n
        x.n, x.key = x.n + n, key
        Push(heap, x)
      end
    end
  end
  local plan = { gold = gold, used = 0, back = 0, secs = 0, rows = {} }
  for _, row in pairs(rows) do
    row.why = row.why or (tleft <= 0.01 and "time" or "gold")
    row.profit = row.back - row.cost
    plan.used, plan.back, plan.secs = plan.used + row.cost, plan.back + row.back,
      plan.secs + row.secs
    plan.rows[#plan.rows + 1] = row
  end
  plan.profit = plan.back - plan.used
  plan.timeBound = tleft < secsMax * 0.02 and (gold == math.huge or left > gold * 0.01)
  table.sort(plan.rows, function(a, b)
    if a.profit ~= b.profit then return a.profit > b.profit end
    return tostring(a.o.id) < tostring(b.o.id)
  end)
  return plan
end

function I.Plan(pool, gold, secs)
  secs = secs or HOUR
  local plan = Run(pool, gold, secs, "gold")
  local tries = {}
  if plan.timeBound then tries[#tries + 1] = "time" end
  if plan.used < gold * 0.98 then tries[#tries + 1] = "profit" end
  for _, by in ipairs(tries) do
    local other = Run(pool, gold, secs, by)
    if other.profit > plan.profit then plan = other end
  end
  return plan
end

-- profit at other pots: where more gold stops paying
function I.Curve(pool, gold, secs)
  local out = {}
  for _, k in ipairs(CURVE) do
    local p = I.Plan(pool, gold * k, secs)
    out[#out + 1] = { gold = gold * k, used = p.used, profit = p.profit }
  end
  local all = I.Plan(pool, math.huge, secs)
  out[#out + 1] = { used = all.used, profit = all.profit, unlimited = true,
    timeBound = all.timeBound }
  return out
end

------------------------------------------------------------------------------ Ledger
-- TSM's accounting, every character on the realm, the last `days` (or since its first row):
-- { days, spent (AH buys of materials or things sold again, vendor buys of materials), back
--   (sales of what was bought or crafted: AH after the cut, vendor), loot (sales of the rest),
--   own (AH buys of things neither used nor sold: gear and such), resale, crafted, items
--   ({ id, spent, back } by item) }
-- Trades with your own characters don't count.
function I.Ledger(pool, days)
  days = days or LEDGER_DAYS
  local sales, buys = P.TSMCsv("csvSales"), P.TSMCsv("csvBuys")
  if not (sales or buys) then return nil end
  local mine = {}
  for _, c in pairs(R.Chars()) do if c.name then mine[c.name] = true end end
  local now = M.Now()
  local since, first = now - days * DAY, math.huge
  local row = "\ni:(%d+)[^,\n]*,%d+,(%d+),(%d+),([^,\n]*),[^,\n]*,(%d+),(%a+)"
  local items = {}
  local function Read(csv, kind)
    for id, qty, price, other, t, source in (csv or ""):gmatch(row) do
      t = tonumber(t)
      local who = other:match("^(%S+)")
      if t >= since and not mine[who] then
        if t < first then first = t end
        id = tonumber(id)
        local x = items[id] or { id = id, ahBuy = 0, vBuy = 0, ahSale = 0, vSale = 0 }
        items[id] = x
        local total = tonumber(qty) * tonumber(price)
        local ah = source == "Auction"
        if kind == "buy" then
          if ah then x.ahBuy = x.ahBuy + total else x.vBuy = x.vBuy + total end
        elseif ah then
          x.ahSale = x.ahSale + total * (1 - AH_CUT)
        else
          x.vSale = x.vSale + total
        end
      end
    end
  end
  Read(sales, "sale")
  Read(buys, "buy")
  if first == math.huge then return { days = 0, spent = 0, back = 0, loot = 0, own = 0,
    resale = 0, crafted = 0, items = {} } end
  local out = { days = math.max(1, (now - first) / DAY), spent = 0, back = 0, loot = 0,
    own = 0, resale = 0, crafted = 0, items = {} }
  for id, x in pairs(items) do
    local sold = x.ahSale + x.vSale
    local bought = x.ahBuy > 0 or x.vBuy > 0
    local made, used = pool.outs[id], pool.mats[id]
    local spent = 0
    if used or (bought and sold > 0) then
      spent = x.ahBuy + (used and x.vBuy or 0)
    else
      out.own = out.own + x.ahBuy
    end
    local back = 0
    if bought or made then
      back = sold
      if made and not bought then out.crafted = out.crafted + sold
      else out.resale = out.resale + sold end
    else
      out.loot = out.loot + sold
    end
    out.spent, out.back = out.spent + spent, out.back + back
    if spent > 0 or back > 0 then
      out.items[#out.items + 1] = { id = id, spent = spent, back = back }
    end
  end
  out.profit = out.back - out.spent
  return out
end

I.HOUR, I.LEDGER_DAYS, I.FRESH = HOUR, LEDGER_DAYS, FRESH
