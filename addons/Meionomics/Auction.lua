-- Our own auction house data, per realm-faction, so TSM's app data can retire. From GetAll scans
-- (C_AuctionHouse.ReplicateItems), started on AH open at most every 15 min (the server's
-- throttle). TSM on Forever never starts one itself (its full scan dialog is Mists-only) but
-- records any GetAll it sees, so it gets ours too; someone else's is read the same way.
-- Per item: the last scan, a 14-day market average, and for watched items (recipe outputs and
-- materials, things posted or bought) daily rows for 30 days. Full daily history for every item
-- would be megabytes of SavedVariables.
local _, M = ...
local A = {}
M.Auction = A

local DAY = 86400
local THROTTLE = 15 * 60
local KEEP_DAYS = 30
local ALPHA = 2 / (14 + 1)   -- EMA weight for a 14-day average
local FRAME_MS = 6           -- reading budget per frame

local realmDB

------------------------------------------------------------------------------ One scan
-- TSM's AuctionDB method: the cheapest 15% of quantity always counts, then up to 30% while each
-- price stays within 20% of the one before; the mean of those, dropping anything over 1.5
-- standard deviations from it. rows: { unit, qty } sorted by unit.
function A.MarketValue(rows)
  local total = 0
  for _, r in ipairs(rows) do total = total + r[2] end
  if total == 0 then return nil end
  local take, n, sum, prev = {}, 0, 0, nil
  for _, r in ipairs(rows) do
    local share = n / total
    if share >= 0.3 or (share >= 0.15 and prev and r[1] > prev * 1.2) then break end
    take[#take + 1] = r
    n, sum, prev = n + r[2], sum + r[1] * r[2], r[1]
  end
  local mean = sum / n
  local var = 0
  for _, r in ipairs(take) do var = var + (r[1] - mean) ^ 2 * r[2] end
  local sd = math.sqrt(var / n)
  local keptN, keptSum = 0, 0
  for _, r in ipairs(take) do
    if math.abs(r[1] - mean) <= 1.5 * sd then
      keptN, keptSum = keptN + r[2], keptSum + r[1] * r[2]
    end
  end
  return math.floor((keptN > 0 and keptSum / keptN or mean) + 0.5)
end

-- listings { itemID, count, buyout, mine, owner } -> itemID -> { min, mine, comp, qty, n, mkt,
-- sellers, flipQty, flipEach }
-- min: lowest unit buyout of all; mine: our lowest; comp: lowest that isn't ours
-- flipQty: others' items listed under what a vendor pays; flipEach: the best gain on one
function A.Aggregate(listings)
  local byItem = {}
  for _, l in ipairs(listings) do
    local id, count, buyout = l[1], l[2], l[3]
    if id and count and count > 0 and buyout and buyout > 0 then
      local a = byItem[id]
      if not a then
        a = { rows = {}, qty = 0, n = 0, owners = {} }
        byItem[id] = a
      end
      local unit = buyout / count
      a.rows[#a.rows + 1] = { unit, count }
      a.qty, a.n = a.qty + count, a.n + 1
      if l[5] and l[5] ~= "" then a.owners[l[5]] = true end
      if l[4] then
        a.mine = math.min(a.mine or unit, unit)
      else
        a.comp = math.min(a.comp or unit, unit)
        local gain = M.Prices.FlipGain(M.Prices.Get(id, "vendor"), unit)
        if gain then
          a.flipQty = (a.flipQty or 0) + count
          a.flipEach = math.max(a.flipEach or 0, gain)
        end
      end
    end
  end
  for _, a in pairs(byItem) do
    table.sort(a.rows, function(x, y) return x[1] < y[1] end)
    a.min = a.rows[1][1]
    local sellers = 0
    for _ in pairs(a.owners) do sellers = sellers + 1 end
    a.sellers = sellers > 0 and sellers or nil
    a.owners = nil
    a.mkt = A.MarketValue(a.rows)
    a.rows = nil
  end
  return byItem
end

------------------------------------------------------------------------------ History
-- daily rows: "day:min:mkt:qty;" in base 36, oldest first
local function B36(n)
  n = math.floor((n or 0) + 0.5)
  local s = ""
  repeat
    local d = n % 36
    s = ("0123456789abcdefghijklmnopqrstuvwxyz"):sub(d + 1, d + 1) .. s
    n = math.floor(n / 36)
  until n == 0
  return s
end

local function Days(rec)
  local out = {}
  for day, mn, mkt, qty in (rec.h or ""):gmatch("(%w+):(%w+):(%w+):(%w+);") do
    out[#out + 1] = { day = tonumber(day, 36), min = tonumber(mn, 36), mkt = tonumber(mkt, 36),
      qty = tonumber(qty, 36) }
  end
  return out
end

local function PushDay(rec, today, watched)
  if not rec.day or rec.day == today then return end
  if rec.dm then
    rec.avg = rec.avg and (rec.avg + (rec.dm - rec.avg) * ALPHA) or rec.dm
    rec.days = math.min((rec.days or 0) + 1, 99)
  end
  if watched and rec.dm then
    local row = ("%s:%s:%s:%s;"):format(B36(rec.day), B36(rec.dmin), B36(rec.dm), B36(rec.dq))
    local h = (rec.h or "") .. row
    -- drop rows older than KEEP_DAYS
    local first = h:match("^(%w+):")
    while first and tonumber(first, 36) <= today - KEEP_DAYS do
      h = h:gsub("^[^;]*;", "", 1)
      first = h:match("^(%w+):")
    end
    rec.h = h
  elseif not watched then
    rec.h = nil
  end
  rec.dmin, rec.dm, rec.dq = nil, nil, nil
end

-- what's worth daily rows: recipe outputs and materials, and anything we posted or bought
function A.Watched(itemID)
  if realmDB and realmDB.watch[itemID] then return true end
  local R = M.Recipes
  return R and (R.Making(itemID) or R.UsedIn(itemID)) and true or false
end

function A.Watch(itemID) realmDB.watch[itemID] = true end

-- watched items' daily rows { day, min, mkt, qty }, oldest first; today's goes in tomorrow
function A.History(itemID)
  local rec = realmDB and realmDB.items[itemID]
  return rec and Days(rec) or {}
end

-- today's row so far { day, min, mkt, qty }, nil before today's first scan saw the item
function A.Today(itemID)
  local rec = realmDB and realmDB.items[itemID]
  if not (rec and rec.dm and rec.day == math.floor(M.Now() / DAY)) then return nil end
  return { day = rec.day, min = rec.dmin, mkt = rec.dm, qty = rec.dq }
end

-- one finished scan into the history; items not in it had nothing up
function A.Record(byItem, now)
  local today = math.floor(now / DAY)
  for id, a in pairs(byItem) do
    local rec = realmDB.items[id]
    if not rec then
      rec = {}
      realmDB.items[id] = rec
    end
    PushDay(rec, today, A.Watched(id))
    rec.day, rec.t = today, now
    rec.min, rec.mine, rec.comp = a.min, a.mine, a.comp
    rec.qty, rec.n, rec.mkt, rec.s = a.qty, a.n, a.mkt, a.sellers
    rec.fq, rec.fe = a.flipQty, a.flipEach
    -- the day's row: lowest min of the day, latest market, latest quantity
    rec.dmin = math.min(rec.dmin or a.min, a.min)
    rec.dm, rec.dq = a.mkt, a.qty
  end
  for id, rec in pairs(realmDB.items) do
    if not byItem[id] then
      PushDay(rec, today, A.Watched(id))
      rec.day = today
      rec.min, rec.mine, rec.comp, rec.qty, rec.n, rec.s = nil, nil, nil, 0, 0, nil
      rec.fq, rec.fe = nil, nil
      local stale = now - (rec.t or 0) > KEEP_DAYS * DAY
      if stale and not A.Watched(id) then realmDB.items[id] = nil end
    end
  end
  realmDB.scanTime = now
end

-- one item's live search (the Sell tab's): what's up now, fresher than the last scan. The
-- day's history row stays the scans' own.
function A.Live(itemID, a, now)
  if not realmDB then return end
  local rec = realmDB.items[itemID]
  if not rec then
    rec = {}
    realmDB.items[itemID] = rec
  end
  rec.min, rec.mine, rec.comp, rec.qty, rec.n, rec.t = a.min, a.mine, a.comp, a.qty, a.n, now
  rec.s, rec.fq, rec.fe = a.sellers, a.flipQty, a.flipEach
end

------------------------------------------------------------------------------ Lookup
-- { min, mine, comp, qty, n, sellers, market, days, t, flipQty, flipEach } as of our last scan,
-- nil if never seen
function A.Get(itemID)
  local rec = realmDB and realmDB.items[itemID]
  if not rec then return nil end
  local market = rec.avg
  if rec.dm then market = market and (market + (rec.dm - market) * ALPHA) or rec.dm end
  return { min = rec.min, mine = rec.mine, comp = rec.comp, qty = rec.qty, n = rec.n,
    sellers = rec.s, market = market, days = (rec.days or 0) + (rec.dm and 1 or 0), t = rec.t,
    flipQty = rec.fq, flipEach = rec.fe }
end

function A.ScanTime() return realmDB and realmDB.scanTime end

------------------------------------------------------------------------------ Scanning
-- Reading is spread over frames by time, not row count: big AHs are 50k rows
local reading
local function ReadReplicate()
  local CA = C_AuctionHouse
  local total = CA.GetNumReplicateItems()
  if total == 0 or reading then return end
  reading = { i = 0, listings = {} }
  -- owners are listed by character name; ours may carry a surname here
  local me = UnitName("player") or ""
  local first = me:match("^%S+")
  local function Step()
    local stop = debugprofilestop() + FRAME_MS
    while reading.i < total and debugprofilestop() < stop do
      local i = reading.i
      local _, _, count, _, _, _, _, _, _, buyout, _, _, _, owner, _, _, itemID =
        CA.GetReplicateItemInfo(i)
      local mine = owner == me or owner == first
      reading.listings[#reading.listings + 1] = { itemID, count, buyout, mine, owner }
      reading.i = i + 1
    end
    if reading.i < total then
      C_Timer.After(0, Step)
      return
    end
    local listings = reading.listings
    reading = nil
    A.Record(A.Aggregate(listings), M.Now())
    M.Print(("AH scan read: %d auctions."):format(#listings))
    if M.History then M.History.Refresh() end
  end
  Step()
end

local function StartScan()
  if M.db.autoScan == false then return end
  local last = realmDB.getAllTime or 0
  if M.Now() - last < THROTTLE then return end
  realmDB.getAllTime = M.Now()
  M.Print("scanning the auction house (/meio autoscan off to stop this).")
  C_AuctionHouse.ReplicateItems()
end

local prevOnLoad = M.OnLoad
function M.OnLoad()
  if prevOnLoad then prevOnLoad() end
  M.db.ah = M.db.ah or {}
end

M.On("PLAYER_LOGIN", function()
  local key = GetRealmName() .. "-" .. (UnitFactionGroup("player") or "?")
  realmDB = M.db.ah[key] or { items = {}, watch = {} }
  M.db.ah[key] = realmDB
  if not C_AuctionHouse then return end
  pcall(M.On, "AUCTION_HOUSE_SHOW", StartScan)
  -- fires in bursts as the list fills: read a moment after the last one
  local ticket = 0
  pcall(M.On, "REPLICATE_ITEM_LIST_UPDATE", function()
    ticket = ticket + 1
    local t = ticket
    C_Timer.After(0.5, function() if t == ticket then ReadReplicate() end end)
  end)
end)

M.commands.autoscan = function(rest)
  if rest == "off" then M.db.autoScan = false elseif rest == "on" then M.db.autoScan = nil end
  M.Print("AH scan on opening: " .. (M.db.autoScan == false and "off" or "on"))
end
