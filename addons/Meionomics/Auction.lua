-- Our own auction house data, per realm-faction, so TSM's app data can retire. From GetAll scans
-- (C_AuctionHouse.ReplicateItems), started on AH open at most every 15 min (the server's
-- throttle). TSM on Forever never starts one itself (its full scan dialog is Mists-only) but
-- records any GetAll it sees, so it gets ours too; someone else's is read the same way.
-- Per item: the last scan, a 14-day market average, and for watched items (recipe outputs and
-- materials, things posted or bought) daily rows for 30 days and a row per scan for 14 (prices
-- through the day). Full history for every item would be megabytes of SavedVariables; the
-- whole AH gets one number per scan instead (A.Index).
local _, M = ...
local A = {}
M.Auction = A

local DAY = 86400
local THROTTLE = 15 * 60
local KEEP_DAYS = 30
local ALPHA = 2 / (14 + 1)   -- EMA weight for a 14-day average
local FRAME_MS = 6           -- reading budget per frame
local REREAD_GAP = 60        -- seconds between re-reads of the same GetAll list
local READ_LIMIT = 120       -- a read paused (tooltips) longer than this is dropped
local SCAN_DAYS = 14         -- per-scan rows kept
local SAME_SCAN = 10 * 60    -- re-reads of one GetAll this close replace its row
local INDEX_MIN_ITEMS = 20

local realmDB
local ahOpen

------------------------------------------------------------------------------ Variants
-- Random-suffix gear ("of the Bear") shares one itemID across very different prices. On Forever
-- the suffix is a bonus ID (item:8178::::::::10:1484:::1:12727; TSM: "i:8178::1:12727"). Each
-- variant gets its own record under "itemID:bonusIDs" beside the itemID's, which still counts
-- every variant (tooltips, crafting, the AH index).

-- an item link, TSM item string or itemID -> the itemID, or "itemID:bonusIDs" for a variant
function A.Key(item)
  if type(item) ~= "string" then return item end
  -- fields after the itemID up to numBonusIDs: 12 in a link, 2 (rand, n) in TSM's string
  local n = 12
  local id, rest = item:match("item:(%d+)([^|]*)")
  if not id then
    id, rest = item:match("^i:(%d+)(.*)")
    n = 2
  end
  if not id then return tonumber(item) end
  local f = {}
  for v in rest:gmatch(":([^:]*)") do f[#f + 1] = v end
  local bonus = {}
  for i = n + 1, n + (tonumber(f[n]) or 0) do bonus[#bonus + 1] = f[i] end
  if #bonus == 0 then return tonumber(id) end
  return id .. ":" .. table.concat(bonus, ":")
end

function A.Base(key)
  if type(key) == "number" then return key end
  return key and tonumber(key:match("^(%d+)"))
end

function A.IsVariant(key) return type(key) == "string" end

-- a link the client can name and show: the variant's bonus IDs, or the plain item
function A.Link(key)
  if not A.IsVariant(key) then return "item:" .. key end
  local id, bonus = key:match("^(%d+):(.+)$")
  local _, n = bonus:gsub("%d+", "")
  return ("item:%s%s%d:%s"):format(id, (":"):rep(12), n, bonus)
end

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

-- Rival depth, for the dip test and the sell-in-a-day price (SellDay.lua). rows { unit, qty,
-- owner, mine } sorted by unit -> a.u100 / a.u105: rival units at <= comp, <= comp x 1.05;
-- a.s105: their sellers; a.top: the cheapest TOP_N rival listings "unit:qty:seller;" (seller:
-- an index per owner within this sighting, enough to count them; 0 unknown)
local TOP_N = 10
function A.Depth(a, rows)
  local comp
  for _, r in ipairs(rows) do
    if not r[4] then comp = r[1] break end
  end
  if not comp then return end
  local owners, nOwners, top, seen = {}, 0, {}, {}
  local u100, u105 = 0, 0
  for _, r in ipairs(rows) do
    if not r[4] then
      local o = r[3] and r[3] ~= "" and r[3]
      if o and not owners[o] then
        nOwners = nOwners + 1
        owners[o] = nOwners
      end
      if r[1] <= comp + 0.5 then u100 = u100 + r[2] end
      if r[1] <= comp * 1.05 then
        u105 = u105 + r[2]
        if o then seen[o] = true end
      end
      if #top < TOP_N then
        top[#top + 1] = ("%.0f:%d:%d;"):format(r[1], r[2], o and owners[o] or 0)
      end
    end
  end
  local s105 = 0
  for _ in pairs(seen) do s105 = s105 + 1 end
  a.u100, a.u105, a.s105, a.top = u100, u105, s105, table.concat(top)
end

-- listings { itemID, count, buyout, mine, owner } -> itemID -> { min, mine, comp, qty, n, mkt,
-- sellers, flipQty, flipEach, u100, u105, s105, top }
-- min: lowest unit buyout of all; mine: our lowest; comp: lowest that isn't ours
-- flipQty: others' items listed under what a vendor pays; flipEach: the best gain on one
function A.Aggregate(listings)
  local byItem = {}
  for _, l in ipairs(listings) do
    local id, count, buyout = l[1], l[2], l[3]
    if id and count and count > 0 and buyout and buyout > 0 and buyout <= M.MAX_COPPER then
      local a = byItem[id]
      if not a then
        a = { rows = {}, qty = 0, n = 0, owners = {} }
        byItem[id] = a
      end
      local unit = buyout / count
      a.rows[#a.rows + 1] = { unit, count, l[5], l[4] }
      a.qty, a.n = a.qty + count, a.n + 1
      if l[5] and l[5] ~= "" then a.owners[l[5]] = true end
      if l[4] then
        a.mine = math.min(a.mine or unit, unit)
      else
        a.comp = math.min(a.comp or unit, unit)
        local gain = M.Prices.FlipGain(M.Prices.Get(A.Base(id), "vendor"), unit)
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
    A.Depth(a, a.rows)
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
  if A.IsVariant(itemID) then return false end
  local R = M.Recipes
  return R and (R.Making(itemID) or R.UsedIn(itemID)) and true or false
end

function A.Watch(itemID) if realmDB then realmDB.watch[itemID] = true end end

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

------------------------------------------------------------------------------ Through the day
-- per-scan rows: "minute:field:field...;" in base 36, oldest first; minute = epoch minutes; an
-- unknown field is empty. The last field marks a search or browse sighting (1) or a GetAll (empty).
-- One GetAll is read several times (names fill in): a row this close to the last of the same
-- kind replaces it; a sighting never replaces a scan's row.
local function PushScan(s, now, sighting, ...)
  local m = math.floor(now / 60)
  local fields = { B36(m) }
  for i = 1, select("#", ...) do
    local v = select(i, ...)
    fields[#fields + 1] = v and B36(v) or ""
  end
  fields[#fields + 1] = sighting and "1" or ""
  local last, kind = (s or ""):match("(%w+):[^;]-(%w*);$")
  local sameKind = (kind == "1") == (sighting and true or false)
  if last and sameKind and m - tonumber(last, 36) < SAME_SCAN / 60 then
    s = s:gsub("[^;]*;$", "")
  end
  s = (s or "") .. table.concat(fields, ":") .. ";"
  local cut = m - SCAN_DAYS * DAY / 60
  local first = s:match("^(%w+):")
  while first and tonumber(first, 36) <= cut do
    s = s:gsub("^[^;]*;", "", 1)
    first = s:match("^(%w+):")
  end
  return s
end

local function Scans(s, names)
  local out = {}
  for row in (s or ""):gmatch("([^;]+);") do
    local r, i = {}, 0
    for v in (row .. ":"):gmatch("(%w*):") do
      i = i + 1
      if names[i] and v ~= "" then r[names[i]] = tonumber(v, 36) end
    end
    r.t = r.t * 60
    out[#out + 1] = r
  end
  return out
end

local SCAN_ROW = { "t", "min", "mkt", "qty", "comp", "u100", "u105", "s105", "seen" }
local INDEX_ROW = { "t", "pm", "n" }

-- watched items' scan rows { t, min, mkt, qty, comp, u100, u105, s105 } for 14 days; min and
-- mkt 0: none up; comp and the depth (A.Depth) nil when not seen (older rows, browse rows)
function A.Scans(itemID)
  local rec = realmDB and realmDB.items[itemID]
  return Scans(rec and rec.sc, SCAN_ROW)
end

-- the whole AH per scan { t, pm, n }: the median of each item's market now over its own 14-day
-- average, in thousandths (1000 = usual), over n items with 3+ days of averages
function A.Index()
  return Scans(realmDB and realmDB.index, INDEX_ROW)
end

-- one finished scan into the history; items not in it had nothing up
function A.Record(byItem, now)
  local today = math.floor(now / DAY)
  local ratios = {}
  for id, a in pairs(byItem) do
    local rec = realmDB.items[id]
    if not rec then
      rec = {}
      realmDB.items[id] = rec
    end
    local watched = A.Watched(id)
    PushDay(rec, today, watched)
    if rec.avg and rec.avg > 0 and (rec.days or 0) >= 3 and a.mkt and not A.IsVariant(id) then
      ratios[#ratios + 1] = a.mkt / rec.avg
    end
    if watched then
      rec.sc = PushScan(rec.sc, now, false, a.min, a.mkt, a.qty, a.comp or 0, a.u100, a.u105,
        a.s105)
      rec.z = nil
      rec.top, rec.tt = a.top, now
    end
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
      local watched = A.Watched(id)
      PushDay(rec, today, watched)
      -- one "none up" row per run of them
      if watched and rec.sc and not rec.z then
        rec.sc = PushScan(rec.sc, now, false, 0, 0, 0, 0, 0, 0, 0)
        rec.z = true
      end
      rec.top, rec.tt = nil, nil
      rec.day = today
      rec.min, rec.mine, rec.comp, rec.qty, rec.n, rec.s = nil, nil, nil, 0, 0, nil
      rec.fq, rec.fe = nil, nil
      local stale = now - (rec.t or 0) > KEEP_DAYS * DAY
      if stale and not watched then realmDB.items[id] = nil end
    end
  end
  if #ratios >= INDEX_MIN_ITEMS then
    table.sort(ratios)
    local median = ratios[math.floor(#ratios / 2) + 1]
    realmDB.index = PushScan(realmDB.index, now, false, median * 1000, #ratios)
  end
  realmDB.scanTime = now
end

-- a search or browse row between scans: another point through the day (P.InADay). "None up"
-- from a search may be pages still loading, so only prices count.
local function Sighted(rec, itemID, a, now)
  if a.min and a.min > 0 and A.Watched(itemID) then
    rec.sc = PushScan(rec.sc, now, true, a.min, rec.mkt or 0, a.qty or 0, a.comp, a.u100,
      a.u105, a.s105)
    rec.z = nil
    if a.top then rec.top, rec.tt = a.top, now end
  end
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
  Sighted(rec, itemID, a, now)
end

-- a browse row: the lowest price and how many are up, not whose or how many auctions
function A.Glimpse(itemID, min, qty, mine, now)
  if not realmDB then return end
  local rec = realmDB.items[itemID]
  if not rec then
    rec = {}
    realmDB.items[itemID] = rec
  end
  rec.min, rec.qty, rec.t = min, qty, now
  -- a group holding ours: min may be ours or a rival's, so the last known split stands
  if not mine then rec.comp, rec.mine = min, nil end
  if (rec.n or 0) == 0 then rec.n = 1 end
  Sighted(rec, itemID, { min = min, qty = qty, comp = not mine and min or nil }, now)
end

------------------------------------------------------------------------------ Live sightings
-- Every AH search, whichever window made it (Blizzard's, TSM's, ours), goes in as what's up
-- now, so prices follow what you browse. A search's variants (A.Key) each go in as well; a
-- browse row can't tell them apart. Stackable goods (cloth, herbs, ore) are commodities on
-- Forever: their searches answer with COMMODITY_SEARCH_RESULTS_UPDATED.

-- an item search's results as Aggregate's shape, only those of variant (A.Key) if given.
-- buyoutAmount is per item (Blizzard puts it straight into the Sell tab's per-item price box).
-- With pages still to load, qty and n count what's loaded; Blizzard and TSM sort by price, so
-- min is right.
function A.ItemSearch(key, variant)
  local CA = C_AuctionHouse
  local a = { qty = 0, n = 0 }
  local rows = {}
  for i = 1, CA.GetNumItemSearchResults(key) do
    local r = CA.GetItemSearchResultInfo(key, i)
    local unit = r and r.buyoutAmount
    if variant and A.Key(r.itemLink) ~= variant then unit = nil end
    if unit and unit > 0 then
      local owner = type(r.owners) == "table" and r.owners[1] or nil
      rows[#rows + 1] = { unit, r.quantity or 1, owner, r.containsOwnerItem }
      a.n, a.qty = a.n + 1, a.qty + (r.quantity or 1)
      a.min = math.min(a.min or unit, unit)
      if r.containsOwnerItem then
        a.mine = math.min(a.mine or unit, unit)
      else
        a.comp = math.min(a.comp or unit, unit)
      end
    end
  end
  table.sort(rows, function(x, y) return x[1] < y[1] end)
  A.Depth(a, rows)
  return a
end

-- a commodity search's results as Aggregate's shape. A row's own units (numOwnerItems) are
-- ours, the rest a rival's at the same price.
function A.CommoditySearch(itemID)
  local CA = C_AuctionHouse
  local a = { qty = 0, n = 0 }
  local rows = {}
  for i = 1, CA.GetNumCommoditySearchResults(itemID) do
    local r = CA.GetCommoditySearchResultInfo(itemID, i)
    local unit, qty = r and r.unitPrice, r and r.quantity or 0
    if unit and unit > 0 and unit <= M.MAX_COPPER and qty > 0 then
      local own = math.min(r.numOwnerItems or 0, qty)
      local owner = type(r.owners) == "table" and r.owners[1] or nil
      a.n, a.qty = a.n + 1, a.qty + qty
      a.min = math.min(a.min or unit, unit)
      if own > 0 then
        rows[#rows + 1] = { unit, own, nil, true }
        a.mine = math.min(a.mine or unit, unit)
      end
      if qty > own then
        rows[#rows + 1] = { unit, qty - own, owner, false }
        a.comp = math.min(a.comp or unit, unit)
      end
    end
  end
  table.sort(rows, function(x, y) return x[1] < y[1] end)
  A.Depth(a, rows)
  return a
end

local function Plain(key) return key and key.itemID and (key.itemSuffix or 0) == 0 end

-- prices behind tooltips and the crafting panel changed: once per burst of results
local pending
local function Changed()
  if pending then return end
  pending = true
  C_Timer.After(0.5, function()
    pending = nil
    if M.Recipes then M.Recipes.ResetCache() end
    if M.CraftUI then M.CraftUI.PricesChanged() end
  end)
end

-- the variants among an item search's results
local function Variants(key)
  local CA, out = C_AuctionHouse, {}
  for i = 1, CA.GetNumItemSearchResults(key) do
    local r = CA.GetItemSearchResultInfo(key, i)
    local v = r and A.Key(r.itemLink)
    if A.IsVariant(v) then out[v] = true end
  end
  return out
end

local function OnItemSearch(_, key)
  if not (key and key.itemID) then return end
  local CA = C_AuctionHouse
  local full = CA.HasFullItemSearchResults and CA.HasFullItemSearchResults(key)
  local now = M.Now()
  -- a suffix's own search holds only that suffix: the itemID's record keeps the scans' figures
  if Plain(key) then
    local a = A.ItemSearch(key)
    -- nothing loaded yet isn't "none up"
    if a.n == 0 and not full then return end
    A.Live(key.itemID, a, now)
  end
  for v in pairs(Variants(key)) do A.Live(v, A.ItemSearch(key, v), now) end
  Changed()
end

local function OnCommoditySearch(_, itemID)
  if not itemID then return end
  local CA = C_AuctionHouse
  local full = CA.HasFullCommoditySearchResults and CA.HasFullCommoditySearchResults(itemID)
  local a = A.CommoditySearch(itemID)
  if a.n == 0 and not full then return end
  A.Live(itemID, a, M.Now())
  Changed()
end

local function OnBrowse()
  local now = M.Now()
  for _, r in ipairs(C_AuctionHouse.GetBrowseResults() or {}) do
    local key = r.itemKey
    if Plain(key) and r.minPrice and r.minPrice > 0 then
      A.Glimpse(key.itemID, r.minPrice, r.totalQuantity, r.containsOwnerItem, now)
    end
  end
  Changed()
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

-- the cheapest rival listings at the last full sighting (A.Depth): { { unit, qty, seller } },
-- and when; nil for unwatched items or none seen
function A.Top(itemID)
  local rec = realmDB and realmDB.items[itemID]
  if not (rec and rec.top) then return nil end
  local out = {}
  for u, q, o in rec.top:gmatch("(%d+):(%d+):(%d+);") do
    out[#out + 1] = { tonumber(u), tonumber(q), tonumber(o) }
  end
  return out, rec.tt
end

-- this realm-faction's saved table (SellDay keeps its post log in it)
function A.Realm() return realmDB end

------------------------------------------------------------------------------ Scanning
-- Reading is spread over frames by time, not row count: big AHs are 50k rows
local reading
local lastRead = { n = 0, t = 0 }
local function ReadReplicate()
  local CA = C_AuctionHouse
  local total = CA.GetNumReplicateItems()
  if total == 0 or reading or not realmDB then return end
  reading = { i = 0, listings = {}, t = M.Now() }
  -- owners are listed by character name; ours may carry a surname here
  local me = UnitName("player") or ""
  local first = me:match("^%S+")
  local function Step()
    -- a short read would record everything past it as "none up": drop it, the next update
    -- reads again
    if not ahOpen or CA.GetNumReplicateItems() ~= total or M.Now() - reading.t > READ_LIMIT then
      reading = nil
      return
    end
    -- each row read can evict the hovered item's data: its tooltip flashes red "Retrieving
    -- item information". Wait while one is shown.
    if GameTooltip:IsShown() then
      C_Timer.After(0.25, Step)
      return
    end
    local stop = debugprofilestop() + FRAME_MS
    while reading.i < total and debugprofilestop() < stop do
      local i = reading.i
      local _, _, count, quality, _, _, _, _, _, buyout, _, _, _, owner, _, _, itemID =
        CA.GetReplicateItemInfo(i)
      local mine = owner == me or owner == first
      local list = reading.listings
      list[#list + 1] = { itemID, count, buyout, mine, owner }
      -- suffixes are on uncommon and better gear: most rows need no link
      if (quality or 0) >= 2 then
        local key = A.Key(CA.GetReplicateItemLink(i))
        if A.IsVariant(key) then list[#list + 1] = { key, count, buyout, mine, owner } end
      end
      reading.i = i + 1
    end
    if reading.i < total then
      C_Timer.After(0, Step)
      return
    end
    local listings = reading.listings
    reading = nil
    A.Record(A.Aggregate(listings), M.Now())
    -- the list fires updates again as seller names fill in; re-read, but say so once
    if total ~= lastRead.n or M.Now() - lastRead.t > 120 then
      M.Print(("AH scan read: %d auctions."):format(total))
    end
    lastRead.n, lastRead.t = total, M.Now()
    if M.History then M.History.Refresh() end
    Changed()
  end
  Step()
end

local function StartScan()
  if M.db.autoScan == false or not realmDB then return end
  local last = realmDB.getAllTime or 0
  if M.Now() - last < THROTTLE then return end
  realmDB.getAllTime = M.Now()
  M.Print("scanning the auction house (" .. M.Cmd("/meio autoscan off") .. " to stop this).")
  C_AuctionHouse.ReplicateItems()
end

local prevOnLoad = M.OnLoad
function M.OnLoad()
  if prevOnLoad then prevOnLoad() end
  M.db.ah = M.db.ah or {}
end

-- "t:..;" row strings (A.Scans, history) of two copies: every row once, oldest first
local function MergeRows(a, b)
  if not (a and b) then return a or b end
  local rows, seen = {}, {}
  for row in (a .. b):gmatch("[^;]+;") do
    if not seen[row] then
      seen[row] = true
      rows[#rows + 1] = { tonumber(row:match("^(%w+)"), 36) or 0, row }
    end
  end
  table.sort(rows, function(x, y) return x[1] < y[1] end)
  local out = {}
  for i, r in ipairs(rows) do out[i] = r[2] end
  return table.concat(out)
end

local function MergeList(dst, src, field)
  local list = dst[field] or {}
  for _, v in ipairs(src[field] or {}) do list[#list + 1] = v end
  table.sort(list, function(x, y) return (x.t or x[1] or 0) < (y.t or y[1] or 0) end)
  dst[field] = list
end

-- a realm's AH table and the one kept under "-Faction" while the realm name was blank: the
-- newer record of each item, with both copies' rows and the longer-running average
local function MergeRealmDB(dst, src)
  for id, s in pairs(src.items or {}) do
    local d = dst.items[id]
    if not d then
      dst.items[id] = s
    else
      local new, old = s, d
      if (d.t or 0) > (s.t or 0) then new, old = d, s end
      new.sc, new.h = MergeRows(old.sc, new.sc), MergeRows(old.h, new.h)
      if (old.days or 0) > (new.days or 0) then new.avg, new.days = old.avg, old.days end
      dst.items[id] = new
    end
  end
  for id in pairs(src.watch or {}) do dst.watch[id] = true end
  MergeList(dst, src, "posts")
  MergeList(dst, src, "online")
  dst.index = MergeRows(dst.index, src.index)
  for _, k in ipairs({ "scanTime", "getAllTime" }) do
    dst[k] = math.max(dst[k] or 0, src[k] or 0)
  end
  dst.createdSeen = dst.createdSeen or src.createdSeen
  return dst
end
A.MergeRealmDB = MergeRealmDB

M.OnRealm(function(realm, key)
  M.MergeBlankRealm(M.db.ah, realm, MergeRealmDB)
  realmDB = M.db.ah[key] or { items = {}, watch = {} }
  realmDB.items, realmDB.watch = realmDB.items or {}, realmDB.watch or {}
  M.db.ah[key] = realmDB
end)

M.On("PLAYER_LOGIN", function()
  if not C_AuctionHouse then return end
  pcall(M.On, "AUCTION_HOUSE_SHOW", function()
    ahOpen = true
    StartScan()
  end)
  pcall(M.On, "AUCTION_HOUSE_CLOSED", function() ahOpen = false end)
  -- fires in bursts as the list fills: read a moment after the last one. It keeps firing while
  -- seller names and item data load, and every full re-read requests item data for each row
  -- again: AH-wide lag and "Retrieving item information" flicker in AH tooltips. The same
  -- list again: once per REREAD_GAP at most, plus one trailing read so the names still land
  local ticket, trailing = 0, false
  local function MaybeRead()
    local wait = REREAD_GAP - (M.Now() - lastRead.t)
    if C_AuctionHouse.GetNumReplicateItems() == lastRead.n and wait > 0 then
      if not trailing then
        trailing = true
        C_Timer.After(wait, function()
          trailing = false
          MaybeRead()
        end)
      end
      return
    end
    ReadReplicate()
  end
  pcall(M.On, "REPLICATE_ITEM_LIST_UPDATE", function()
    ticket = ticket + 1
    local t = ticket
    C_Timer.After(0.5, function() if t == ticket then MaybeRead() end end)
  end)
  pcall(M.On, "ITEM_SEARCH_RESULTS_UPDATED", OnItemSearch)
  pcall(M.On, "COMMODITY_SEARCH_RESULTS_UPDATED", OnCommoditySearch)
  pcall(M.On, "AUCTION_HOUSE_BROWSE_RESULTS_UPDATED", OnBrowse)
  pcall(M.On, "AUCTION_HOUSE_BROWSE_RESULTS_ADDED", OnBrowse)
end)

M.commands.autoscan = function(rest)
  if rest == "off" then M.db.autoScan = false elseif rest == "on" then M.db.autoScan = nil end
  M.Print("AH scan on opening: " .. M.OnOff(M.db.autoScan ~= false))
end
