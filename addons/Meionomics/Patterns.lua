-- Recipe patterns on the AH, remembered per realm-faction: last price and time seen, and when
-- the whole Recipe class was last covered, so "not on AH" can be trusted and dated. Auction.lua
-- can't hold this: it drops unwatched items after 30 days and nils their min when not up.
-- Fed by GetAll scans (A.Record), the Patterns view's browse (all pages; empty text covers the
-- class) and the Sell tab's live search.
-- Watch list: patterns of his professions he doesn't know, worth learning at their last-seen
-- (else market) price: verdict "do" or "level" and C.Value.PerDay >= WATCH_MIN. Alerted once
-- per spell of being listed, all of a scan in one digest, best first.
local _, M = ...
local A = M.Auction
local Pt = {}
M.Patterns = Pt

local RECIPE_CLASS = (Enum.ItemClass and Enum.ItemClass.Recipe) or 9
Pt.WATCH_MIN = 2000
Pt.STAR = "|TInterface\\TargetingFrame\\UI-RaidTargetingIcon_1:0|t"

-- { items = { [itemID] = { p = price, q = qty, t = last seen up, s = up since, told, up } },
--   checked = last full coverage }
local db

local function IsRecipe(id)
  return type(id) == "number" and select(6, C_Item.GetItemInfoInstant(id)) == RECIPE_CLASS
end

local function Up(id, price, qty, now)
  local rec = db.items[id]
  if not rec then
    rec = {}
    db.items[id] = rec
  end
  if not rec.up then rec.s, rec.told = now, nil end
  rec.up, rec.p, rec.q, rec.t = true, price, qty, now
end

local function Down(rec) rec.up, rec.q, rec.s, rec.told = nil, nil, nil, nil end

-- seen: itemID -> { price, qty } up now; full: everything else up would be in it
local function Observe(seen, full, now, check)
  if not db then return end
  for id, s in pairs(seen) do Up(id, s.price, s.qty, now) end
  if full then
    for id, rec in pairs(db.items) do
      if not seen[id] then Down(rec) end
    end
    db.checked = now
  end
  if check then Pt.Check(seen) end
end

-- browse results of the Recipe class (one per item, minPrice); full: the empty-text search
-- (the Patterns view alerts from its own rows)
function Pt.FromBrowse(results, full)
  local seen = {}
  for _, br in ipairs(results) do
    local id = br.itemKey and br.itemKey.itemID
    if id and br.minPrice and br.minPrice > 0 then
      local s = seen[id] or { qty = 0 }
      s.price = math.min(s.price or br.minPrice, br.minPrice)
      s.qty = s.qty + (br.totalQuantity or 1)
      seen[id] = s
    end
  end
  Observe(seen, full, M.Now())
end

local record = A.Record
function A.Record(byItem, now)
  record(byItem, now)
  local seen = {}
  for id, a in pairs(byItem) do
    if IsRecipe(id) then seen[id] = { price = a.min, qty = a.qty } end
  end
  Observe(seen, true, now, true)
end

local live = A.Live
function A.Live(itemID, a, now)
  live(itemID, a, now)
  if not (db and IsRecipe(itemID)) then return end
  if a.min and (a.qty or 0) > 0 then
    Observe({ [itemID] = { price = a.min, qty = a.qty } }, false, now, true)
  elseif db.items[itemID] then
    Down(db.items[itemID])
  end
end

-- -> { price, qty, t, since, checked, up } (price and t: when last seen up, nil if never);
-- nil before any coverage or sighting
function Pt.Seen(itemID)
  if not db then return nil end
  local rec = db.items[itemID]
  if not (rec or db.checked) then return nil end
  rec = rec or {}
  return { price = rec.p, qty = rec.up and rec.q or 0, t = rec.t, since = rec.s,
    checked = db.checked, up = rec.up or false }
end

function Pt.Checked() return db and db.checked end

------------------------------------------------------------------------------ Watching
-- patterns of his professions he could learn from an item he doesn't hold, each judged by
-- C.Value at its last-seen price, else the market's (est). forProf: prof -> C.Value.ForProf
-- result (the Patterns view passes its per-search cache). fn(item, x, v, price, seen, c, est)
function Pt.EachCandidate(forProf, fn)
  local C, P = M.Craft, M.Prices
  for prof in pairs(M.Recipes.Professions()) do
    local c = forProf(prof)
    for _, x in ipairs(c.rank and c.all or {}) do
      local item = x.item
      if item and not x.known and x.learnFrom == "pattern" then
        local seen = Pt.Seen(item)
        local price = seen and seen.price
        local est = not price
        price = price or P.Get(item, "market") or P.Get(item, "regionMarket")
        local x2, v = C.Value.JudgeRecipe(c, x.rec, price, seen and seen.up and seen.qty or nil)
        if x2 then fn(item, x2, v, price, seen, c, est) end
      end
    end
  end
end

-- -> profit a day once learnt when it is worth watching, else nil
function Pt.Worth(x, v)
  if x.known or x.learnFrom == "held" then return nil end
  if not (v and (v.key == "do" or v.key == "level")) then return nil end
  local day = M.Craft.Value.PerDay(x)
  return day and day >= Pt.WATCH_MIN and day or nil
end

-- chat frame for digests: a tab named "Meionomics" if he made one, else the main one
function Pt.ChatFrame()
  for i = 1, NUM_CHAT_WINDOWS or 10 do
    local name, _, _, _, _, _, shown, _, docked = GetChatWindowInfo(i)
    local f = _G["ChatFrame" .. i]
    if f and name == "Meionomics" and (shown or docked) then return f end
  end
  return DEFAULT_CHAT_FRAME
end

Pt.DIGEST_MAX = 8
local queued, flushing = {}, false

-- "[Recipe: Transmute Arcanite]" -> "[Transmute Arcanite]": the type is in the header
local function Short(link) return (link:gsub("|h%[[^%]:]+: ", "|h[")) end

local function Payback(price, perDay)
  local days = math.ceil(price / perDay)
  if days < 2 then return "" end
  return (" |cff9d9d9d(pays back in %d days)|r"):format(days)
end

local function Line(e)
  return ("|cff80ff80+|r%s|cff80ff80/day|r  %s for %s%s"):format(M.Money(e.day, "80ff80"),
    Short(e.link), M.Money(e.price), Payback(e.price, e.day))
end

local function Flush(tries)
  local missing
  for _, e in ipairs(queued) do
    e.link = e.link or select(2, C_Item.GetItemInfo(e.item))
    if not e.link then
      missing = true
      C_Item.RequestLoadItemDataByID(e.item)
    end
  end
  -- uncached items have no link yet; wait a little rather than print bare IDs
  if missing and tries < 6 then return C_Timer.After(0.5, function() Flush(tries + 1) end) end
  local list = queued
  queued, flushing = {}, false
  for _, e in ipairs(list) do
    e.link = e.link or ("[" .. (C_Item.GetItemNameByID(e.item) or ("item " .. e.item)) .. "]")
  end
  table.sort(list, function(a, b) return a.day > b.day end)
  local out = Pt.ChatFrame()
  if #list == 1 then
    return out:AddMessage(M.ACCENT .. "Meionomics:|r " .. Pt.STAR .. " pattern worth learning "
      .. "is up: " .. Line(list[1]))
  end
  out:AddMessage(("%sMeionomics:|r %s %d patterns worth learning are up, best first:"):format(
    M.ACCENT, Pt.STAR, #list))
  for k = 1, math.min(#list, Pt.DIGEST_MAX) do out:AddMessage("   " .. Line(list[k])) end
  if #list > Pt.DIGEST_MAX then
    out:AddMessage(("   |cff9d9d9d+%d more at %s/day or less: AH > Meionomics > Patterns|r")
      :format(#list - Pt.DIGEST_MAX, M.Money(list[Pt.DIGEST_MAX + 1].day)))
  end
end

-- once per spell of being listed; everything alerted in one scan comes as one digest
function Pt.Alert(item, perDay)
  local rec = db and db.items[item]
  if not (rec and rec.up) or rec.told then return end
  rec.told = M.Now()
  queued[#queued + 1] = { item = item, day = perDay, price = rec.p }
  if not flushing then
    flushing = true
    C_Timer.After(0, function() Flush(0) end)
  end
end

-- after a scan: alert the watched ones in seen. C.Value.ForProf builds every recipe of a
-- profession, so only when something untold came up.
function Pt.Check(seen)
  local any
  for id in pairs(seen) do
    local rec = db.items[id]
    if rec and rec.up and not rec.told and M.Recipes.TaughtBy(id) then
      any = true
      break
    end
  end
  if not (any and M.Craft and M.Craft.Value) then return end
  local cache = {}
  M.Recipes.ResetCache()
  Pt.EachCandidate(function(prof)
    cache[prof] = cache[prof] or (M.Craft.Rank(prof) and M.Craft.Value.ForProf(prof) or {})
    return cache[prof]
  end, function(item, x, v)
    local day = seen[item] and Pt.Worth(x, v)
    if day then Pt.Alert(item, day) end
  end)
end

local prevOnLoad = M.OnLoad
function M.OnLoad()
  if prevOnLoad then prevOnLoad() end
  M.db.patterns = M.db.patterns or {}
end

-- the realm's table and the one kept under "-Faction" while the realm name was blank
local function Merge(dst, src)
  for id, s in pairs(src.items or {}) do
    local d = dst.items[id]
    if not d or (s.t or 0) > (d.t or 0) then dst.items[id] = s end
  end
  if (src.checked or 0) > (dst.checked or 0) then dst.checked = src.checked end
  return dst
end

M.OnRealm(function(realm, key)
  M.MergeBlankRealm(M.db.patterns, realm, Merge)
  db = M.db.patterns[key] or { items = {} }
  M.db.patterns[key] = db
end)
