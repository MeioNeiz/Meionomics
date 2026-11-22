-- Sells within a day: the best net price per unit that still sells within 24h at least 4 times
-- in 5 (research/questions/sell-within-day-price.md, dip-vs-trend.md, scan-data-to-keep.md).
-- Other sellers' price history can't give a sell chance (it overstates fills: we are never first
-- in the queue, and rivals react to our price), so the chance comes from our own posts:
--   Post log    each post's auctions (AUCTION_HOUSE_AUCTION_CREATED) and how each ended: sold /
--               expired notifications, AUCTION_CANCELED, TSM's ledger for sales while offline
--   Fill curve  P(sold within 24h | m under ref): a default shape set so 1c under sells at the
--               item's region sale rate (TSM's share of listings that sell; 50% unknown), shifted
--               by one learnt logit offset (being cheapest beats the region's average listing),
--               pooled across items; per item shrunk toward the pool
--   Trend       Siegel repeated median over log rival-cheapest per AH visit: level, drift, and
--               dip (few cheap units a day's demand will clear) vs real fall
--   Price       ref = cheapest rival, or the listing above a dip; m maximising net per unit
--               V = (0.95 p P - (1-P) d) / (1 - (1-P)(1-g)) with P >= 0.8
--   /meio posts
local _, M = ...
local A, P = M.Auction, M.Prices
local SD = {}
M.SellDay = SD

local DAY = 86400
local CUT = 0.95
local TARGET = 0.8
local LEARNT = 20           -- resolved auctions before the curve counts as learnt
local KEEP = 30 * DAY
local MAX_POSTS = 1500
local VISIT = 30 * 60       -- sightings this close are one AH visit
local TREND_DAYS = 7
local FLAG_VISITS, FLAG_SPAN = 8, 2 * DAY
local DIP_Z = -3.5
local FALL_VISITS, FALL_SPAN = 3, 12 * 3600
local S_FLOOR = math.log(1.03)
local HOURS = { 12, 24, 48 }

-- default fill curve before any posts (research toy market, flat): m under ref -> P
local KNOT_M = { -0.05, 0, 0.01, 0.02, 0.03, 0.05, 0.08, 0.12 }
local KNOT_P = { 0.25, 0.45, 0.65, 0.80, 0.85, 0.92, 0.95, 0.97 }
local GRID = { 0, 0.01, 0.02, 0.03, 0.05, 0.08, 0.12 }

local function Logit(p) return math.log(p / (1 - p)) end
local function Sigmoid(x) return 1 / (1 + math.exp(-x)) end

-- the default curve's logit at m, linear between knots, flat outside
function SD.BaseLogit(m)
  if m <= KNOT_M[1] then return Logit(KNOT_P[1]) end
  for i = 2, #KNOT_M do
    if m <= KNOT_M[i] then
      local f = (m - KNOT_M[i - 1]) / (KNOT_M[i] - KNOT_M[i - 1])
      return Logit(KNOT_P[i - 1]) + f * (Logit(KNOT_P[i]) - Logit(KNOT_P[i - 1]))
    end
  end
  return Logit(KNOT_P[#KNOT_P])
end

------------------------------------------------------------------------------ Post log
-- realm.posts: { t, id, name, u (unit), n (qty), d (deposit per unit), h (hours), r (ref), m,
--   dip, a = { [auctionID or "x1"..] = { s = sold at } | { x = expired at } | { c = at } | {} } }
local index = {}            -- auctionID -> post
local pending               -- the post being created: auctions arrive one event each
local orphans = {}          -- { auctionID, t } created before the post hook ran

local function Realm() return A.Realm() end
local function Posts()
  local r = Realm()
  if not r then return {} end
  r.posts = r.posts or {}
  return r.posts
end

local function Reindex()
  wipe(index)
  for _, p in ipairs(Posts()) do
    for aid in pairs(p.a) do
      if type(aid) == "number" then index[aid] = p end
    end
  end
end

local function Prune()
  local posts, now = Posts(), M.Now()
  local keep = {}
  for _, p in ipairs(posts) do
    if now - p.t <= KEEP then keep[#keep + 1] = p end
  end
  while #keep > MAX_POSTS do table.remove(keep, 1) end
  wipe(posts)
  for i, p in ipairs(keep) do posts[i] = p end
end

local function Log(p)
  if p.logged then return end
  p.logged = true
  local posts = Posts()
  posts[#posts + 1] = p
  if #posts > MAX_POSTS then Prune() end
  SD.Changed()
end

local function ItemOf(loc)
  local ok, id = pcall(C_Item.GetItemID, loc)
  if ok and id then return id end
  local sf = AuctionHouseFrame and AuctionHouseFrame.ItemSellFrame
  return sf and sf.meioItem
end

local function OnPost(loc, duration, qty, unit, commodity)
  if not (unit and unit > 0 and qty and qty > 0) then return end
  local id = ItemOf(loc)
  if not id then return end
  local now = M.Now()
  -- Post then Confirm (Blizzard's price warning) is one post
  if pending and pending.id == id and pending.u == unit and now - pending.t < 60 then return end
  local deposit
  local ok, dep = pcall(C_AuctionHouse.CalculateItemDeposit, loc, duration, qty)
  if ok and dep then deposit = dep / qty end
  local q = SD.Quote(id, { deposit = deposit })
  local p = { t = now, id = id, name = C_Item.GetItemInfo(id), u = unit, n = qty,
    d = deposit, h = HOURS[duration], a = {}, r = q and q.ref, dip = q and q.dip or nil }
  p.m = p.r and (1 - unit / p.r) or nil
  p.k = commodity and 1 or qty
  pending = p
  A.Watch(id)
  for _, o in ipairs(orphans) do
    if now - o[2] <= 2 then
      p.a[o[1]] = {}
      index[o[1]] = p
    end
  end
  wipe(orphans)
  if next(p.a) then Log(p) end
  -- without the created event (never seen on this realm yet), log it with stand-in auctions
  C_Timer.After(10, function()
    local r = Realm()
    if pending ~= p or p.logged or (r and r.createdSeen) then return end
    for i = 1, p.k do p.a["x" .. i] = {} end
    Log(p)
  end)
end

local function OnCreated(_, auctionID)
  local r = Realm()
  if r then r.createdSeen = true end
  local p = pending
  if not auctionID then return end
  -- another item's auction (its post hook hasn't run yet) waits for its own post
  local ok, info = pcall(C_AuctionHouse.GetAuctionInfoByID, auctionID)
  local other = ok and info and info.itemKey and p and info.itemKey.itemID ~= p.id
  if not (p and M.Now() - p.t < 120) or other then
    orphans[#orphans + 1] = { auctionID, M.Now() }
    return
  end
  p.a[auctionID] = {}
  index[auctionID] = p
  Log(p)
end

-- an auction ended: by ID, else the oldest open auction of that item name
local function Ended(auctionID, name, how)
  local now = M.Now()
  local p = auctionID and index[auctionID]
  local key = auctionID
  if not (p and p.a[key] and not next(p.a[key])) then
    p, key = nil, nil
    if not name then return end
    for _, q in ipairs(Posts()) do
      if q.name == name then
        for k, st in pairs(q.a) do
          if not next(st) then p, key = q, k break end
        end
        if p then break end
      end
    end
  end
  if not p then return end
  p.a[key] = { [how] = now }
  SD.Changed()
end

local NOTE = Enum and Enum.AuctionHouseNotification
local function OnNotification(_, kind, text, auctionID)
  if not NOTE then return end
  local name = type(text) == "string" and text or nil
  if kind == NOTE.AuctionSold then
    Ended(auctionID, name, "s")
  elseif kind == NOTE.AuctionExpired then
    Ended(auctionID, name, "x")
  end
end

local function OnCanceled(_, auctionID)
  if auctionID then Ended(auctionID, nil, "c") end
end

------------------------------------------------------------------------------ Offline sales
-- TSM records auction sales from the mail (sale time from the mail's age). A sale we were
-- online for came as a notification; the rest fill open auctions here, at login.
local function Online(t)
  for _, s in ipairs(Realm().online or {}) do
    if t >= s[1] and t <= s[2] + 120 then return true end
  end
  return false
end

local function Backfill()
  local csv = P.TSMCsv and P.TSMCsv("csvSales")
  if not csv then return end
  local open = {}
  for _, p in ipairs(Posts()) do
    for k, st in pairs(p.a) do
      if not next(st) then
        open[p.id] = open[p.id] or {}
        table.insert(open[p.id], { p = p, k = k })
      end
    end
  end
  if not next(open) then return end
  local claimed = {}
  for _, p in ipairs(Posts()) do
    for _, st in pairs(p.a) do if st.s then claimed[p.id .. ":" .. st.s] = true end end
  end
  local row = "\ni:(%d+)[^,\n]*,%d+,(%d+),%d+,[^,\n]*,[^,\n]*,(%d+),Auction"
  for id, qty, t in csv:gmatch(row) do
    id, t = tonumber(id), tonumber(t)
    local list = open[id]
    if list and not Online(t) and not claimed[id .. ":" .. t] then
      for _ = 1, tonumber(qty) do
        local best
        for i, o in ipairs(list) do
          if o.p.t < t and not next(o.p.a[o.k]) then best = i break end
        end
        if not best then break end
        local o = table.remove(list, best)
        o.p.a[o.k] = { s = t }
        if o.p.k == 1 then break end
      end
    end
  end
end

------------------------------------------------------------------------------ Fill curve
-- resolved auctions { m, y, id }: sold within a day 1; expired, or no sale recorded within a
-- day once 2 days have passed (time for TSM's ledger to catch offline sales), 0; cancelled
-- inside the day: left out (we don't know how it would have gone)
function SD.Outcomes()
  local out, now = {}, M.Now()
  for _, p in ipairs(Posts()) do
    if p.m then
      for _, st in pairs(p.a) do
        local y
        if st.s then
          y = st.s - p.t <= DAY and 1 or 0
        elseif st.x then
          y = 0
        elseif st.c then
          y = st.c - p.t > DAY and 0 or nil
        elseif now - p.t > 2 * DAY then
          y = 0
        end
        if y then out[#out + 1] = { m = p.m, y = y, id = p.id } end
      end
    end
  end
  return out
end

-- The region sale rate anchors each item's curve. Without it, every item inherited the pool's
-- offset: 21 of 21 posts sold (mostly bags at 83%) made a 31% green "sells 5 in 6". Fit on 73
-- own auctions, one item held out at a time (research/questions/sell-within-day-price.md):
-- log-loss 0.46 pooled, 0.40 anchored; the learnt offset came out near +1.
local RATE_MIN, RATE_MAX, RATE_UNKNOWN = 0.05, 0.95, 0.5
local anchors = {}

-- -> logit shift that puts the default curve's 1c under at the region sale rate, and the rate
function SD.Anchor(itemID)
  local id = itemID and A.Base(itemID)
  if not id then return Logit(RATE_UNKNOWN) - SD.BaseLogit(0) end
  local c = anchors[id]
  if not c then
    local rate = P.Get(id, "saleRate")
    if not (rate and rate > 0) then rate = nil end
    local r = rate and math.max(RATE_MIN, math.min(RATE_MAX, rate)) or RATE_UNKNOWN
    c = { Logit(r) - SD.BaseLogit(0), rate }
    anchors[id] = c
  end
  return c[1], c[2]
end

-- MAP logit offset b on the anchored default curve, prior N(mu, tau^2): b, sd, n
local function FitOffset(obs, mu, tau)
  local b = mu
  local info
  for _ = 1, 25 do
    local grad, hess = -(b - mu) / tau ^ 2, -1 / tau ^ 2
    for _, o in ipairs(obs) do
      local p = Sigmoid(SD.BaseLogit(o.m) + o.a + b)
      grad = grad + (o.y - p)
      hess = hess - p * (1 - p)
    end
    info = -hess
    local step = grad / info
    b = b + math.max(-2, math.min(2, step))
    if math.abs(step) < 1e-4 then break end
  end
  return b, 1 / math.sqrt(info), #obs
end

local fits = {}
local version = 0
function SD.Changed()
  version = version + 1
  wipe(fits)
  wipe(anchors)
end

-- { b, sd, n (resolved auctions behind it), item (of them this item's), learnt, a (anchor),
--   rate (region sale rate, nil unknown) }; no itemID: the pool, for an item of unknown rate
function SD.Fit(itemID)
  local key = itemID or 0
  if fits[key] then return fits[key] end
  if not fits[0] then
    local all = SD.Outcomes()
    for _, o in ipairs(all) do o.a = SD.Anchor(o.id) end
    local b, sd, n = FitOffset(all, 0, 1)
    fits[0] = { b = b, sd = sd, n = n, learnt = n >= LEARNT, obs = all, a = SD.Anchor() }
  end
  local pool = fits[0]
  if itemID then
    local mine = {}
    for _, o in ipairs(pool.obs) do if o.id == itemID then mine[#mine + 1] = o end end
    local fit = { b = pool.b, sd = pool.sd, n = pool.n, learnt = pool.learnt }
    if #mine >= 3 then
      local b, sd = FitOffset(mine, pool.b, 0.5)
      fit.b, fit.sd, fit.item = b, math.min(sd, pool.sd), #mine
    end
    fit.a, fit.rate = SD.Anchor(itemID)
    fits[key] = fit
  end
  return fits[key]
end

-- P(sold within a day) at m under ref: point, and the one to test against 0.8 (the lower
-- bound once learnt; the default guess as it stands before)
function SD.Chance(fit, m)
  local base = SD.BaseLogit(m) + (fit.a or 0)
  local test = fit.learnt and (fit.b - 1.28 * fit.sd) or fit.b
  return Sigmoid(base + fit.b), Sigmoid(base + test)
end

------------------------------------------------------------------------------ Trend and dip
local function Median(list)
  table.sort(list)
  local n = #list
  if n == 0 then return nil end
  if n % 2 == 1 then return list[(n + 1) / 2] end
  return (list[n / 2] + list[n / 2 + 1]) / 2
end

-- visits { t, y = log rival cheapest }, oldest first, last TREND_DAYS
function SD.Visits(itemID)
  local out, now = {}, M.Now()
  local group
  for _, r in ipairs(A.Scans(itemID)) do
    local v = r.comp or r.min
    if v and v > 0 and now - r.t <= TREND_DAYS * DAY then
      if group and r.t - group.t0 <= VISIT then
        group.v[#group.v + 1] = v
        group.t = r.t
      else
        group = { t0 = r.t, t = r.t, v = { v } }
        out[#out + 1] = group
      end
    end
  end
  for i, g in ipairs(out) do out[i] = { t = g.t, y = math.log(Median(g.v)) } end
  return out
end

-- Siegel's repeated median: slope = median over i of the median slope from i to each other
-- point; level = median of y - slope t. Tolerates half the points being outliers.
local function Siegel(pts)
  local slopes = {}
  for i, a in ipairs(pts) do
    local s = {}
    for j, b in ipairs(pts) do
      if i ~= j and b.t ~= a.t then s[#s + 1] = (b.y - a.y) / ((b.t - a.t) / DAY) end
    end
    if #s > 0 then slopes[#slopes + 1] = Median(s) end
  end
  local slope = Median(slopes) or 0
  local now = M.Now()
  local icept = {}
  for _, a in ipairs(pts) do icept[#icept + 1] = a.y - slope * (a.t - now) / DAY end
  return Median(icept), slope
end

local trends = {}
-- { level (price now), slope (log per day), s, n, span, g (daily fall), ready } or nil
function SD.Trend(itemID)
  local pts = SD.Visits(itemID)
  local key = #pts .. ":" .. (pts[#pts] and pts[#pts].t or 0) .. ":" .. math.floor(M.Now() / 60)
  local c = trends[itemID]
  if c and c.key == key then return c.v end
  local v
  if #pts >= 3 then
    while #pts > 120 do table.remove(pts, 1) end
    local level, slope = Siegel(pts)
    local now = M.Now()
    local res = {}
    for _, a in ipairs(pts) do
      a.r = a.y - (level + slope * (a.t - now) / DAY)
      res[#res + 1] = math.abs(a.r)
    end
    local s = math.max(1.4826 * Median(res), S_FLOOR)
    local span = pts[#pts].t - pts[1].t
    v = { level = math.exp(level), logLevel = level, slope = slope, s = s, n = #pts,
      span = span, g = math.max(0, 1 - math.exp(slope)),
      ready = #pts >= FLAG_VISITS and span >= FLAG_SPAN, pts = pts }
  end
  trends[itemID] = { key = key, v = v }
  return v
end

-- a day's demand here, conservatively (about the 10% low end of a Poisson day)
local function DemandLow(itemID)
  local V = M.Craft and M.Craft.Value
  local day = V and V.Sales(itemID).day or 0
  return math.max(0, day - 1.28 * math.sqrt(day))
end

-- is comp a dip? -> "dip", above (the next price up past the dip units), units, sellers; or
-- "fall" when the low has held; nil when neither or too little data
function SD.Dip(itemID, comp, tr)
  tr = tr or SD.Trend(itemID)
  if not (tr and tr.ready and comp and comp > 0) then return nil end
  local z = (math.log(comp) - tr.logLevel) / tr.s
  if z >= DIP_Z then return nil end
  -- held 3+ visits over 12h+: the market moved, not a dip
  local low, first = 0, nil
  for i = #tr.pts, 1, -1 do
    local a = tr.pts[i]
    if a.r / tr.s >= DIP_Z then break end
    low, first = low + 1, a.t
  end
  if low >= FALL_VISITS and M.Now() - first >= FALL_SPAN then return "fall" end
  local top, tt = A.Top(itemID)
  if not (top and top[1] and tt and M.Now() - tt <= VISIT) then return nil end
  local cut = math.exp(tr.logLevel - 3 * tr.s)
  local units, sellers, seen, above = 0, 0, {}, nil
  for _, l in ipairs(top) do
    if l[1] < cut then
      units = units + l[2]
      local o = l[3] ~= 0 and l[3] or ("?" .. #seen)
      if not seen[o] then seen[o], sellers = true, sellers + 1 end
    else
      above = l[1]
      break
    end
  end
  if not above or sellers > 2 or units >= DemandLow(itemID) then return "fall" end
  return "dip", above, units, sellers
end

-- A reset: someone buys out the cheap stock and relists far higher (Icy Cloak: 1.66g ->
-- 7.49g, 27 up from 2 sellers, none sold). Holding proves nothing, as nobody need buy; the
-- new level counts once units go from the AH at it.
local JUMP = math.log(1.5)
local JUMP_BASE_VISITS, JUMP_BASE_SPAN = 4, 12 * 3600
local JUMP_SOLD = 2
local jumps = {}

-- is comp a jump? -> base (median before the run of visits at least 1.5x over it), since (the
-- run's first visit), sold (units gone between scans at the new level); nil once JUMP_SOLD go
function SD.Jump(itemID, comp)
  if not (comp and comp > 0) then return nil end
  local rec = Realm() and Realm().items[itemID]
  local key = (rec and rec.sc or "") .. comp .. ":" .. math.floor(M.Now() / 60)
  local c = jumps[itemID]
  if c and c.key == key then return unpack(c.v) end
  local pts = SD.Visits(itemID)
  local function Base(k)
    local ys = {}
    for i = 1, k - 1 do ys[#ys + 1] = pts[i].y end
    return Median(ys)
  end
  local k = #pts + 1
  while k - 1 > JUMP_BASE_VISITS and pts[k - 1].y >= Base(k - 1) + JUMP do k = k - 1 end
  local v = {}
  local base = k > JUMP_BASE_VISITS and Base(k)
  if base and pts[k - 1].t - pts[1].t >= JUMP_BASE_SPAN and math.log(comp) >= base + JUMP then
    local since = pts[k] and pts[k].t or M.Now()
    local high = math.exp(base + JUMP)
    local sold, prev = 0, nil
    for _, r in ipairs(A.Scans(itemID)) do
      local p = r.comp or r.min
      if r.t >= since - VISIT and p and p >= high and r.qty then
        if prev then sold = sold + math.max(0, prev - r.qty) end
        prev = r.qty
      else
        prev = nil
      end
    end
    if sold < JUMP_SOLD then v = { math.floor(math.exp(base)), since, sold } end
  end
  jumps[itemID] = { key = key, v = v }
  return unpack(v)
end

------------------------------------------------------------------------------ Price
local function LastDeposit(itemID)
  local posts = Posts()
  for i = #posts, 1, -1 do
    local p = posts[i]
    if p.id == itemID and p.d then return p.d end
  end
end

-- opts: comp (cheapest rival; else our last sighting while fresh), deposit (per unit), floor
-- -> { price, P, m, ref, comp, dip, fall, dipUnits, dipSellers, g, v, fit, slow,
--   rows = { { m, price, P, v, ok (passes the 4-in-5 test and the floor) } } } or nil
-- without a cheapest rival
function SD.Quote(itemID, opts)
  opts = opts or {}
  local comp = opts.comp
  if not comp then
    local live = P.Live(itemID)
    comp = live and live.comp
  end
  if not (comp and comp > 0) then return nil end
  local tr = SD.Trend(itemID)
  local kind, above, units, sellers = SD.Dip(itemID, comp, tr)
  local q = { comp = comp, ref = comp, dip = kind == "dip", fall = kind == "fall",
    g = tr and tr.g or 0, fit = SD.Fit(itemID) }
  if q.dip then q.ref, q.dipUnits, q.dipSellers = above, units, sellers end
  if not q.dip then
    local base, since, sold = SD.Jump(itemID, comp)
    if base then q.jump, q.ref, q.jumpSince, q.jumpSold = true, base, since, sold end
  end
  local d = opts.deposit or LastDeposit(itemID) or 0
  q.deposit = d
  local best
  q.rows = {}
  for _, m in ipairs(GRID) do
    local price = m == 0 and q.ref - 1 or math.floor(q.ref * (1 - m))
    if price > 0 then
      local row = SD.Net(q, price, m)
      row.ok = price >= (opts.floor or 0) and row.test >= TARGET
      q.rows[#q.rows + 1] = row
      if row.ok and (not best or row.v > best.v) then best = row end
    end
  end
  if best then
    q.m, q.price, q.P, q.v = best.m, best.price, best.P, best.v
  else
    q.slow = true
  end
  return q
end

-- any price against a quote: { m, price, P, test, v } (v: expected net per unit, reposting
-- what expires). m: the grid's, which rounding to whole coppers would move off its knot
function SD.Net(q, price, m)
  m = m or 1 - price / q.ref
  local chance, test = SD.Chance(q.fit, m)
  local v = (CUT * price * chance - (1 - chance) * (q.deposit or 0))
    / (1 - (1 - chance) * (1 - q.g))
  return { m = m, price = price, P = chance, test = test, v = v }
end

-- this item's posts in the post log (30 days): { posts, auctions, sold, inDay, expired,
-- cancelled, up, unknown (past its duration with no word) }
function SD.Record(itemID)
  local r = { posts = 0, auctions = 0, sold = 0, inDay = 0, expired = 0, cancelled = 0, up = 0,
    unknown = 0 }
  local now = M.Now()
  for _, p in ipairs(Posts()) do
    if p.id == itemID then
      r.posts = r.posts + 1
      for _, st in pairs(p.a) do
        r.auctions = r.auctions + 1
        if st.s then
          r.sold = r.sold + 1
          if st.s - p.t <= DAY then r.inDay = r.inDay + 1 end
        elseif st.x then
          r.expired = r.expired + 1
        elseif st.c then
          r.cancelled = r.cancelled + 1
        elseif now - p.t <= (p.h or 48) * 3600 then
          r.up = r.up + 1
        else
          r.unknown = r.unknown + 1
        end
      end
    end
  end
  return r
end

-- "4 in 5" etc: never more precise than the counts behind it
function SD.Odds(p)
  if p >= 0.95 then return "19 in 20" end
  if p >= 0.9 then return "9 in 10" end
  if p >= 0.85 then return "5 in 6" end
  return "4 in 5"
end

function SD.Basis(fit)
  local rate = fit.rate and (", region %d%% sell"):format(fit.rate * 100 + 0.5) or ""
  if fit.item and fit.item >= 3 then
    return ("from %d of your posts of it, %d in all"):format(fit.item, fit.n) .. rate
  end
  if fit.learnt then return ("from %d of your posts"):format(fit.n) .. rate end
  return (fit.n > 0 and ("default guess, %d of %d posts learnt"):format(fit.n, LEARNT)
    or "default guess") .. rate
end

-- "cheapest 55s is a dip (3 from 1 seller), " / "cheapest 7g 49s jumped from 1g 66s, none
-- sold there since, " / ""
function SD.DipText(q)
  if q.jump then
    return ("cheapest %s jumped from %s, %s sold there since, "):format(M.Money(q.comp),
      M.Money(q.ref), q.jumpSold == 0 and "none" or q.jumpSold)
  end
  if not q.dip then return "" end
  return ("cheapest %s is a dip (%d from %d %s), "):format(M.Money(q.comp), q.dipUnits,
    q.dipSellers, q.dipSellers == 1 and "seller" or "sellers")
end

------------------------------------------------------------------------------ Events
local function Hook(name, fn)
  if C_AuctionHouse and C_AuctionHouse[name] then hooksecurefunc(C_AuctionHouse, name, fn) end
end

local function SafeHook(name, fn)
  Hook(name, function(...)
    local ok, err = pcall(fn, ...)
    if not ok then geterrorhandler()(err) end
  end)
end

M.OnRealm(function()
  local r = Realm()
  if not r then return end
  local now = M.Now()
  r.online = r.online or {}
  local keep = {}
  for _, s in ipairs(r.online) do if now - s[2] <= KEEP then keep[#keep + 1] = s end end
  local session = { now, now }
  keep[#keep + 1] = session
  r.online = keep
  C_Timer.NewTicker(60, function() session[2] = M.Now() end)
  Prune()
  Reindex()
  pcall(Backfill)
  SD.Changed()
end)
M.On("PLAYER_LOGOUT", function()
  local r = Realm()
  local s = r and r.online and r.online[#r.online]
  if s then s[2] = M.Now() end
end)

SafeHook("PostItem", function(loc, duration, qty, _, buyout)
  OnPost(loc, duration, qty, buyout, false)
end)
SafeHook("ConfirmPostItem", function(loc, duration, qty, _, buyout)
  OnPost(loc, duration, qty, buyout, false)
end)
SafeHook("PostCommodity", function(loc, duration, qty, unit) OnPost(loc, duration, qty, unit, true) end)
SafeHook("ConfirmPostCommodity", function(loc, duration, qty, unit)
  OnPost(loc, duration, qty, unit, true)
end)
SafeHook("CancelAuction", function(auctionID) OnCanceled(nil, auctionID) end)
pcall(M.On, "AUCTION_HOUSE_AUCTION_CREATED", OnCreated)
pcall(M.On, "AUCTION_HOUSE_SHOW_FORMATTED_NOTIFICATION", OnNotification)
pcall(M.On, "AUCTION_CANCELED", OnCanceled)

------------------------------------------------------------------------------ /meio posts
M.commands.posts = function()
  local posts = Posts()
  local fit = SD.Fit()
  local buckets = {}
  for _, o in ipairs(SD.Outcomes()) do
    local k = o.m <= 0.005 and "1c" or o.m < 0.035 and "1-3%" or o.m < 0.1 and "3-10%"
      or o.m >= 0.1 and "10%+"
    local b = buckets[k] or { 0, 0 }
    b[1], b[2] = b[1] + o.y, b[2] + 1
    buckets[k] = b
  end
  M.Print(("%d posts logged, %d auctions resolved, %s"):format(#posts, fit.n, SD.Basis(fit)))
  for _, k in ipairs({ "1c", "1-3%", "3-10%", "10%+" }) do
    local b = buckets[k]
    if b then M.Print(("  %s under: %d of %d sold within a day"):format(k, b[1], b[2])) end
  end
  M.Print(("  an item 50%% of whose listings sell region-wide: at 1c under ~%d%%, 2%% under"
    .. " ~%d%%"):format(SD.Chance(fit, 0) * 100 + 0.5, SD.Chance(fit, 0.02) * 100 + 0.5))
end
