-- One plain verdict per recipe, with the realistic numbers behind it: the Profit, Skill-up and
-- Route views and the recipe tooltip share these.
-- Sales here: the region's sold/day x REALM_SHARE, or his own recent sales when higher.
-- Internal only: text shows measured region sales and what is up here. What sells within a week goes at the AH value (after the cut), the rest to a
-- vendor.
-- Held materials (bags, bank, mail; not alts) cost what selling them would bring: the last units of the
-- pile, at that same realistic value, so slow sellers cost about their vendor price.
-- Batches: Profit sells a week's worth (at least 1 craft), Skill-up crafts until the recipe
-- changes colour; held materials cover a batch first.
--   C.Value.Fill(x, rank)    adds x.sales, x.real, x.lvl, x.perPoint(All), x.payN/payDays, x.week
--   C.Value.Judge(x, ctx)    -> verdict { rank, key, label, short, colour, reason, note, week }
--     reason: the full why (full hover); note: a few words, only what the panel's columns
--     (each, /day, week, per point, chance) don't already show, or nil
--   C.Value.ForProf(prof, view, rank) -> c; C.Value.JudgeRecipe(c, rec, price, listed) -> x, v
--     judging outside the panel (AH Patterns view), price = a listed pattern's buyout
--   C.Value.JudgeOne(x)      -> verdict for one C.Info on its own (tooltips), nil until warm
--   C.Value.PerDay(x)        -> realistic profit a day once learnt (Find, AH Patterns), or nil
local _, M = ...
local R, P, C = M.Recipes, M.Prices, M.Craft
local V = {}
C.Value = V

-- the region data covers few realms: Azure Silk Belt sells ~1 a day region-wide while this
-- realm alone has 72 up
local REALM_SHARE = 0.2
local WEEK = 7
local MAX_BATCH = 50
local SLOW_PER_DAY = 0.5   -- output selling slower than this: "Slow seller"
local NOT_WORTH_DAYS = 21  -- learning that takes longer to pay back: "Not worth learning"
local TIE = 0.05           -- costs this close count as the same; your own mats win

local VERDICTS = {
  ["do"] = { 1, "Do it", "Do it", "4fe36a" },
  level = { 2, "Worth it if levelling", "If levelling", "ffd100" },
  slow = { 3, "Slow seller", "Slow seller", "e0a050" },
  learn = { 4, "Not worth learning", "Don't learn", "b08cff" },
  loss = { 5, "Loses money", "Loses money", "ff5a5a" },
  costly = { 5, "Costly skill-ups", "Costly", "ff5a5a" },
  nopattern = { 6, "Pattern not available", "No pattern", "b4b4b4" },
  none = { 7, "No price", "No price", "a0a0a0" },
}

local function Hex(c, text) return "|cff" .. c .. text .. "|r" end
local function Dim(text) return Hex("a8a8a8", text) end
local function Gold(c)
  if c < 0 then return "-" .. M.Money(-c) end
  return M.Money(c)
end
local function Signed(c) return (c >= 0 and "+" or "-") .. M.Money(math.abs(c)) end
local function Plural(n, word) return ("%d %s%s"):format(n, word, n == 1 and "" or "s") end

------------------------------------------------------------------------------ Sales
local sales = {}
local resetCache = R.ResetCache
function R.ResetCache()
  resetCache()
  wipe(sales)
end

-- { day (sold here per day), s (P.SellRate), own (his sales a day, P.OwnPerDay), bound,
--   clear (days for what is up here to sell) }
-- A crowded AH doesn't cut his share: he lists at the cheapest rival (R.SellValue) and buyers
-- take the cheapest. Scaling by it put White Bandit Mask at 0.19/day; he sold 5/day.
function V.Sales(itemID)
  local v = sales[itemID]
  if v then return v end
  if not P.Auctionable(itemID) then
    v = { day = 0, bound = true }
  else
    local s = P.SellRate(itemID)
    local day = s and s.perDay and s.perDay * REALM_SHARE or 0
    local clear = s and s.listed and day > 0 and s.listed / day or nil
    local own = P.OwnPerDay(itemID)
    v = { day = math.max(day, own or 0), s = s, own = own, clear = clear }
  end
  sales[itemID] = v
  return v
end

-- n units sold within a week -> value, how many at the AH
function V.Worth(itemID, n)
  if n <= 0 then return 0, 0 end
  local each, where = R.SellValue(itemID)
  local vendor = P.Get(itemID, "vendor") or 0
  if where ~= "ah" then return n * (each or vendor), 0 end
  local atAH = math.min(n, V.Sales(itemID).day * WEEK)
  return atAH * each + (n - atAH) * vendor, atAH
end

-- using n of a held pile: the units that would have sold last
function V.HeldCost(itemID, pile, n)
  if n <= 0 then return 0 end
  return V.Worth(itemID, pile) - V.Worth(itemID, pile - n)
end

local function BuyPrice(id)
  local p = R.MatPrice(id)
  local _, each = C.CraftInstead(id)
  if each and (not p or each < p) then return each end
  return p
end

-- materials for n crafts, held first -> { cost, complete, held, need, bags } (units)
function V.Mats(rec, n)
  local m = { cost = 0, complete = true, held = 0, need = 0, bags = 0 }
  for _, mat in ipairs(rec.mats) do
    local id, want = mat[1], mat[2] * n
    local h = C.Have(id)
    local pile = h.bags + h.bank + h.mail
    local use = math.min(want, pile)
    local price = use < want and BuyPrice(id)
    if use < want and not price then m.complete = false end
    m.cost = m.cost + V.HeldCost(id, pile, use) + (want - use) * (price or 0)
    m.held, m.need = m.held + use, m.need + want
    m.bags = m.bags + math.min(want, h.bags)
  end
  -- one station placement serves the whole batch (MAX_BATCH crafts fit in its 15 minutes)
  local st = R.Station(rec)
  if st then
    m.station = st
    for _, part in ipairs(st.parts) do
      local h = C.Have(part.item)
      local pile = h.bags + h.bank + h.mail
      if pile > 0 then
        m.cost = m.cost + V.HeldCost(part.item, pile, 1)
      elseif part.price then
        m.cost = m.cost + part.price
      else
        m.complete = false
      end
    end
  end
  return m
end

local function Output(rec, n)
  if not rec.out then return 0, 0 end
  return V.Worth(rec.out, n * R.Made(rec))
end

------------------------------------------------------------------------------ Fill
function V.Fill(x, rank)
  local rec = x.rec
  if not rec.mats then return end
  local made = R.Made(rec)
  local s = rec.out and V.Sales(rec.out)
  x.sales = s
  local n = 1
  if s and not s.bound then
    n = math.max(1, math.min(MAX_BATCH, math.floor(s.day * WEEK / made)))
  end
  local mats = V.Mats(rec, n)
  local value, atAH = Output(rec, n)
  x.real = { n = n, mats = mats, value = value, atAH = atAH }
  if rec.out and mats.complete then x.real.each = (value - mats.cost) / n end
  local learn = x.learnCost
  local each = x.real.each
  if each then x.week = each * n - (learn or 0) end
  x.payN = R.Payback(learn, each)
  if x.payN and s and s.day > 0 then x.payDays = x.payN * made / s.day end
  if not (x.points and x.points > 0) then return end
  local ln = math.max(1, math.min(MAX_BATCH, math.ceil(x.span / x.points)))
  local lm = V.Mats(rec, ln)
  x.lvl = { n = ln, mats = lm, value = Output(rec, ln) }
  if lm.complete then
    x.perPoint = (lm.cost - x.lvl.value) / (ln * x.points)
    x.perPointAll = x.perPoint + (learn or 0) / x.span
    x.estPerPoint = learn == nil or x.learnEst or learn > 0
  end
end

-- profit each x crafts sold here a day (x.sales.day, the Sells/day column); learning is left
-- to payback (x.payN, x.payDays), so a good pattern still costing 5g doesn't show a loss a day.
-- nil when it only sells to a vendor or has no price
function V.PerDay(x)
  local each, s = x.real and x.real.each, x.sales
  if not (each and s) or s.bound then return nil end
  return each * s.day / R.Made(x.rec)
end

-- units to sell before learning has paid for itself
function V.PaySold(x) return x.payN and x.payN * R.Made(x.rec) or nil end

------------------------------------------------------------------------------ Verdict
local function Each(c) return Signed(c) .. " each" end

local function SellsText(s)
  if not s then return nil end
  if s.bound then return "vendor only" end
  local day = s.s and s.s.perDay
  if not day then return "no region sales data" end
  if day >= 1 then return ("sells %s/day in region"):format(M.Count(day)) end
  local week = day * WEEK
  if week >= 1 then return ("sells %s a week in region"):format(M.Count(week)) end
  return "sells under 1 a week in region"
end

-- "147 up, about 9 days of region sales"
local function CrowdText(s)
  local up = s.s and s.s.listed
  if not up then return nil end
  local days = s.s.clearDays
  days = days and math.max(1, math.floor(days + 0.5))
  return ("%d up%s"):format(up, days and (", about %s of region sales"):format(
    Plural(days, "day")) or "")
end

local function MatsText(m)
  if not m or m.held <= 0 then return nil end
  if m.held >= m.need then return "uses your mats" end
  return ("your mats %d/%d"):format(m.held, m.need)
end

local function Days(x)
  if not x.payDays then return "" end
  return (" (~%s)"):format(Plural(math.max(1, math.ceil(x.payDays)), "day"))
end

local function PayText(x)
  if x.payN then return ("pays back after %d sold%s"):format(V.PaySold(x), Days(x)) end
end

local function PointText(p)
  if p <= 0 then return "earns " .. M.Money(-p) .. " a point" end
  return M.Money(p) .. " a point"
end

local function LearnText(x)
  local from = x.learnFrom == "trainer" and "trainer" or "pattern"
  local up = x.pattern and x.pattern.how == "ah" and (" (%d up)"):format(x.pattern.listed) or ""
  return ("%s %s%s%s"):format(from, x.learnEst and "~" or "", M.Money(x.learnCost), up)
end

-- note texts: a few words each
local function MatsNote(m)
  if not m or m.held <= 0 then return nil end
  if m.held >= m.need then return "your mats" end
  return ("mats %d/%d"):format(m.held, m.need)
end

local function PayNote(x)
  if x.payN then return ("repays after %d sold%s"):format(V.PaySold(x), Days(x)) end
end

local function PointNote(p)
  if p <= 0 then return "earns " .. M.Money(-p) .. "/pt" end
  return M.Money(p) .. "/pt"
end

local function LearnNote(x)
  return "learn " .. (x.learnEst and "~" or "") .. M.Money(x.learnCost)
end

-- "124 up, ~7 days" when this realm already has more up than a week of sales
local function CrowdNote(s)
  local up = s.s and s.s.listed
  if not up then return nil end
  local days = s.s.clearDays
  return days and ("%d up, ~%s"):format(up, Plural(math.max(1, math.floor(days + 0.5)), "day"))
    or (up .. " up")
end

local function Join(...)
  local parts = {}
  for i = 1, select("#", ...) do
    local p = select(i, ...)
    if p and p ~= "" then parts[#parts + 1] = p end
  end
  return table.concat(parts, ", ")
end

-- what a skill point costs here for "Do it" and for "Worth it if levelling"
local function Limits(best)
  local b = math.max(best or 0, 0)
  return b * (1 + TIE) + 100, b * 2 + 1000
end

local function Make(key, reason, week, note)
  local d = VERDICTS[key]
  return { key = key, rank = d[1], label = d[2], short = d[3], colour = d[4],
    reason = reason, week = week, note = note ~= "" and note or nil }
end
V.Make = Make

-- ctx: { view = "profit" | "skill", best = cheapest per point in the list, levelling }
local function JudgeProfit(x, ctx)
  local each = x.real and x.real.each
  if not each then return Make("none", "a material has no price", nil, "a mat has no price") end
  local s, mats = x.sales, x.real.mats
  local week = x.week
  local doMax, levelMax = Limits(ctx.best)
  local per = x.perPointAll
  local levelOK = ctx.levelling and per and per <= levelMax
  if levelOK and x.points then
    local pts = math.min(x.real.n * x.points, x.span)
    week = week + pts * math.max(ctx.best or 0, 0)
  end
  local learn = x.learnCost or 0
  if each > 0 then
    local slowPay = learn > 0 and (not x.payDays or x.payDays > NOT_WORTH_DAYS)
    if slowPay then
      if levelOK then
        return Make("level", Join(LearnText(x), PointText(per)), week,
          Join(LearnNote(x), PointNote(per)))
      end
      return Make("learn", Join(LearnText(x), PayText(x) or "never pays back"), week,
        Join(LearnNote(x), PayNote(x)))
    end
    if s and not s.bound and s.day < SLOW_PER_DAY then
      local up = s.clear and s.clear > WEEK
      return Make("slow", Join(Each(each), SellsText(s), up and CrowdText(s)), week,
        up and CrowdNote(s))
    end
    return Make("do", Join(Each(each), MatsText(mats), SellsText(s), PayText(x)), week,
      Join(MatsNote(mats), PayNote(x)))
  end
  local nominal = x.e.profit
  if nominal and nominal > 0 and s and not s.bound then
    return Make("slow", Join(Signed(nominal) .. " each at AH price", SellsText(s)), week,
      Signed(nominal) .. " only at AH price")
  end
  if levelOK then
    if mats.held >= mats.need and per <= doMax then
      return Make("do", "you have the mats: " .. PointText(per), week, "your mats")
    end
    return Make("level", Join(Each(each), MatsText(x.lvl.mats), PointText(per)), week,
      Join(MatsNote(x.lvl.mats), PointNote(per)))
  end
  return Make("loss", Join(Each(each), MatsText(mats)), week, MatsNote(mats))
end

local function JudgeSkill(x, ctx)
  local per = x.perPointAll
  if not per then return Make("none", "a material has no price", nil, "a mat has no price") end
  local mats = x.lvl.mats
  local own = mats.need > 0 and mats.held >= mats.need
  local doMax, levelMax = Limits(ctx.best)
  local week = -(per * math.min(x.lvl.n * x.points, x.span))
  if per <= 0 or per <= doMax or (own and per <= levelMax) then
    local why = own and (per <= 100 and "you have the mats: free skill-ups"
      or "uses your mats: " .. PointText(per))
    local note = own and (per <= 100 and "your mats, free" or "your mats") or MatsNote(mats)
    return Make("do", why or Join(PointText(per), MatsText(mats)), week, note)
  end
  if per <= levelMax then
    return Make("level", Join(PointText(per), MatsText(mats),
      ("%d%% chance"):format(x.chance * 100 + 0.5)), week, MatsNote(mats))
  end
  local learn = x.learnCost or 0
  if learn > 0 and x.perPoint and x.perPoint <= levelMax then
    return Make("learn", ("%s over ~%s: %s"):format(LearnText(x), Plural(x.span, "point"),
      PointText(per)), week, ("%s over ~%d pts"):format(LearnNote(x), x.span))
  end
  local times = ctx.best and ctx.best > 0 and per / ctx.best
  local cheapest = times and times >= 2 and ("%dx the cheapest"):format(math.floor(times)) or nil
  return Make("costly", Join(PointText(per), cheapest), week, cheapest)
end

-- a pattern nobody sells right now: whatever it would earn, it can't be had
local function Unobtainable(x)
  return not x.known and x.learnFrom == "pattern" and x.pattern and x.pattern.how == "none"
end
V.Unobtainable = Unobtainable

function V.Judge(x, ctx)
  local v
  if Unobtainable(x) then
    v = Make("nopattern", x.pattern.text .. ", no vendor")
  else
    v = ctx.view == "skill" and JudgeSkill(x, ctx) or JudgeProfit(x, ctx)
  end
  x.v = v
  return v
end

-- the cheapest per point among a list's recipes (known or learnable)
function V.Best(list)
  local best
  for _, x in ipairs(list) do
    local p = x.perPointAll
    if p and (not best or p < best) then best = p end
  end
  return best
end

-- known recipes, then ones that can be learnt now, then the rest
function V.Group(x)
  if x.known then return 1 end
  return Unobtainable(x) and 3 or 2
end

-- verdict first, then the week's net; costs within TIE: the one from your own mats
function V.Before(a, b)
  local va, vb = a.v, b.v
  if va.rank ~= vb.rank then return va.rank < vb.rank end
  local wa, wb = va.week or -math.huge, vb.week or -math.huge
  local scale = math.max(math.abs(wa), math.abs(wb), 1)
  if math.abs(wa - wb) > scale * TIE then return wa > wb end
  local oa = a.real and a.real.mats.held >= a.real.mats.need and 1 or 0
  local ob = b.real and b.real.mats.held >= b.real.mats.need and 1 or 0
  if oa ~= ob then return oa > ob end
  if wa ~= wb then return wa > wb end
  return (a.rec.name or "") < (b.rec.name or "")
end

------------------------------------------------------------------------------ From held
-- What his own mats (bags, bank, mail; not alts) earn crafted rather than sold as they are:
-- one craft at a time, the known recipe earning most for the mats it uses, while that beats
-- selling them. Held mats cost what selling them would bring (V.HeldCost: the scarce ones are
-- rationed), the rest is bought, as long as held mats pay at least half. Outputs he already
-- holds sell first.
--   V.HeldProfit(list) -> { steps = { { x, crafts, value, heldCost, buy, gain, uses, buys (id ->
--   units) } } (best
--   first), crafts, value, heldCost, buy, gain, mats = { { id, used, bought } } }
local HELD_MAX_CRAFTS = 300

local function Pile(id)
  local h = C.Have(id)
  return h.bags + h.bank + h.mail
end

function V.HeldProfit(list)
  local left, made, price = {}, {}, {}
  local function Left(id)
    if not left[id] then left[id] = Pile(id) end
    return left[id]
  end
  local function Price(id)
    if price[id] == nil then price[id] = BuyPrice(id) or false end
    return price[id] or nil
  end
  local cands = {}
  for _, x in ipairs(list) do
    local rec = x.rec
    if x.known and rec.out and rec.mats and not C.MissingTool(rec) then
      for _, m in ipairs(rec.mats) do
        if Left(m[1]) > 0 then
          cands[#cands + 1] = { x = x, crafts = 0, value = 0, heldCost = 0, buy = 0, uses = {},
            buys = {} }
          break
        end
      end
    end
  end
  -- the next craft of s: what it adds, its held mats' worth, what it buys; nil if it can't
  local function Next(s)
    local rec = s.x.rec
    local held, buy, weight, any = 0, 0, 0, false
    for _, m in ipairs(rec.mats) do
      local id, n = m[1], m[2]
      local use = math.min(n, Left(id))
      local p = Price(id)
      if use < n and not p then return nil end
      if use > 0 then
        local c = V.HeldCost(id, left[id], use)
        held, any = held + c, true
        weight = weight + math.max(c, use * (p or 0))
      end
      buy = buy + (n - use) * (p or 0)
    end
    if not any or buy > weight then return nil end
    if s.crafts == 0 then
      local st = R.Station(rec)
      for _, part in ipairs(st and st.parts or {}) do
        local pile = Left(part.item)
        if pile > 0 then held = held + V.HeldCost(part.item, pile, 1)
        elseif part.price then buy = buy + part.price
        else return nil end
      end
    end
    local out, each = rec.out, R.Made(rec)
    if not made[out] then made[out] = Pile(out) end
    local value = V.Worth(out, made[out] + each) - V.Worth(out, made[out])
    return value, held, buy
  end
  local plan = { steps = {}, crafts = 0, value = 0, heldCost = 0, buy = 0, gain = 0, mats = {} }
  local used, bought = {}, {}
  for _ = 1, HELD_MAX_CRAFTS do
    local best, bestScore, bv, bh, bb
    for _, s in ipairs(cands) do
      local value, held, buy = Next(s)
      local gain = value and value - held - buy
      if gain and gain > 0 then
        local score = gain / (held + buy + 1)
        if not bestScore or score > bestScore then
          best, bestScore, bv, bh, bb = s, score, value, held, buy
        end
      end
    end
    if not best then break end
    local rec = best.x.rec
    if best.crafts == 0 then
      local st = R.Station(rec)
      for _, part in ipairs(st and st.parts or {}) do
        if Left(part.item) > 0 then
          left[part.item] = left[part.item] - 1
          used[part.item] = (used[part.item] or 0) + 1
        end
      end
    end
    for _, m in ipairs(rec.mats) do
      local id, n = m[1], m[2]
      local use = math.min(n, Left(id))
      left[id] = left[id] - use
      used[id] = (used[id] or 0) + use
      if use > 0 then best.uses[id] = (best.uses[id] or 0) + use end
      if use < n then
        bought[id] = (bought[id] or 0) + n - use
        best.buys[id] = (best.buys[id] or 0) + n - use
      end
    end
    made[rec.out] = made[rec.out] + R.Made(rec)
    best.crafts = best.crafts + 1
    best.value, best.heldCost, best.buy = best.value + bv, best.heldCost + bh, best.buy + bb
    plan.crafts = plan.crafts + 1
  end
  for _, s in ipairs(cands) do
    if s.crafts > 0 then
      s.gain = s.value - s.heldCost - s.buy
      plan.steps[#plan.steps + 1] = s
      plan.value, plan.heldCost = plan.value + s.value, plan.heldCost + s.heldCost
      plan.buy, plan.gain = plan.buy + s.buy, plan.gain + s.gain
    end
  end
  table.sort(plan.steps, function(a, b)
    if a.gain ~= b.gain then return a.gain > b.gain end
    return a.x.rec.id < b.x.rec.id
  end)
  for id, n in pairs(used) do
    plan.mats[#plan.mats + 1] = { id = id, used = n, bought = bought[id] or 0 }
  end
  for id, n in pairs(bought) do
    if not used[id] then plan.mats[#plan.mats + 1] = { id = id, used = 0, bought = n } end
  end
  table.sort(plan.mats, function(a, b)
    if a.used ~= b.used then return a.used > b.used end
    return a.id < b.id
  end)
  return plan
end

------------------------------------------------------------------------------ Outside the panel
-- one profession judged as the panel's view does: ctx is set against the cheapest skill point
-- among known and learnable recipes. C.List is the costly part: keep the result for a pass.
--   -> { rank, all, byRec, ctx }; rank nil when the profession isn't known.
-- whatIf { max }: a rank not his (the panel's what-if), every recipe in the client data
function V.ForProf(prof, view, rank, whatIf)
  local max
  if whatIf then
    max = whatIf.max
  elseif rank then
    max = select(2, C.Rank(prof))
  else
    rank, max = C.Rank(prof)
  end
  local c = { rank = rank, all = C.List(prof, "all", rank, whatIf ~= nil), byRec = {} }
  local pool = {}
  for _, x in ipairs(c.all) do
    c.byRec[x.rec] = x
    if x.known or x.learnable then pool[#pool + 1] = x end
  end
  c.ctx = { view = view or "profit", best = V.Best(pool),
    levelling = rank and max and rank < max }
  return c
end

-- a recipe judged in c (V.ForProf), learning it at price when it's for sale (a listed
-- pattern's buyout, listed of them up). -> x, verdict; nil when its mats aren't recorded
-- or the profession isn't known.
function V.JudgeRecipe(c, rec, price, listed)
  if not c.rank then return nil end
  local x = c.byRec[rec]
  if not x and rec.mats then
    x = C.Info(rec, c.rank)
    C.Learnable(x, c.rank)
    c.byRec[rec] = x
  end
  if not x then return nil end
  -- it is up now whatever an older scan said, so it costs this to learn
  if price and not x.known and x.learnFrom ~= "held" then
    listed = listed or 1
    x.learnCost, x.learnFrom, x.learnEst = price, "pattern", false
    x.pattern = { how = "ah", listed = listed, price = price,
      text = ("%d listed from %s"):format(listed, M.Money(price)) }
    V.Fill(x, c.rank)
  end
  return x, V.Judge(x, c.ctx)
end

-- one recipe (C.Info) judged on its own, as the Profit view would: tooltips. The context needs
-- every recipe of the profession (~80 ms), which hitches a hover, so Warm builds it a slice
-- per frame (on login and TRAINER_SHOW) and a tooltip only reads it: no verdict until ready,
-- an older one while it is rebuilt.
local CTX_KEEP = 30
local SLICE_MS, SLICE_MAX = 3, 40
local ctxCache, warming = {}, {}

function V.Warm(prof)
  if warming[prof] then return end
  local rank, max = C.Rank(prof)
  if not rank then return end
  warming[prof] = true
  local recs = {}
  for _, rec in pairs(R.All()) do
    if rec.prof == prof and rec.mats then recs[#recs + 1] = rec end
  end
  R.ResetCache()
  local i, best = 0, nil
  local function Step()
    -- the count cap too: the workbench clock doesn't move within a frame
    local stop, n = debugprofilestop() + SLICE_MS, 0
    while i < #recs and n < SLICE_MAX and (n == 0 or debugprofilestop() < stop) do
      i, n = i + 1, n + 1
      local x = C.Info(recs[i], rank)
      local p = (x.known or C.Learnable(x, rank)) and x.perPointAll
      if p and (not best or p < best) then best = p end
    end
    if i < #recs then return C_Timer.After(0, Step) end
    warming[prof] = nil
    ctxCache[prof] = { rank = rank, at = GetTime(), who = R.Viewer(),
      ctx = { view = "profit", best = best, levelling = max and rank < max } }
  end
  Step()
end

function V.JudgeOne(x)
  local prof = x.rec.prof
  if not prof then return nil end
  local hit = ctxCache[prof]
  local fresh = hit and hit.rank == C.Rank(prof) and hit.who == R.Viewer()
  if not (fresh and GetTime() - hit.at < CTX_KEEP) then
    V.Warm(prof)
  end
  return hit and hit.who == R.Viewer() and V.Judge(x, hit.ctx) or nil
end

local function WarmAll()
  for prof in pairs(R.Professions()) do V.Warm(prof) end
end
M.On("TRAINER_SHOW", WarmAll)
M.On("PLAYER_LOGIN", function() C_Timer.After(5, WarmAll) end)
