-- Sniper: deals on the AH, and alarms when one shows up.
-- A deal: a rival listing at or under a watched item's max price (/meio snipe add), under
-- what a vendor pays, or under X% of market with at least the minimum profit after the AH cut
-- (market deals only where Evidence trusts the market). Every listing Meionomics sees is
-- judged: GetAll scans (the cheapest 10 rival listings per item), any item search or browse,
-- whichever window made it. A new deal: chat line, raid warning sound (Master channel), taskbar
-- flash; a big one (profit >= big) also a raid warning on screen, and with "phone" on a
-- screenshot showing the deal with a magenta square in the top left corner, for the Windows
-- companion (LocalMods companion/MeioSnipe.exe) to push out. Addons can't reach the network or
-- write files while the game runs; a screenshot is the one thing that leaves at once.
-- Sniper view of the Meionomics AH tab: sweeps the whole AH (browse, every page), reads the
-- auctions of items whose cheapest is a candidate, lists the deals to buy, waits, sweeps again;
-- a GetAll every 15 min (the server's throttle) between sweeps. Runs only while the view shows.
local _, M = ...
local A, B, P = M.Auction, M.AuctionBrowse, M.Prices
local Cc = B.C
local Sn = {}
M.AuctionSnipe = Sn

local AH_CUT = 0.05
local DEFAULTS = { alarms = true, pct = 50, profit = 10000, big = 100000, wait = 30 }
local MAX_KEYS = 40           -- item searches per sweep: each is a throttled round trip
local BROWSE_WAIT = 15
local GETALL_GAP = 15 * 60
local REALARM = 2 * 3600      -- the same listing alarms again after this
local SHOT_GAP = 60
local TRUST_TTL = 120

local function Cfg()
  local c = M.db.snipe
  for k, v in pairs(DEFAULTS) do
    if c[k] == nil then c[k] = v end
  end
  return c
end

local prevOnLoad = M.OnLoad
function M.OnLoad()
  if prevOnLoad then prevOnLoad() end
  M.db.snipe = M.db.snipe or {}
  M.db.snipe.watch = M.db.snipe.watch or {}
end

------------------------------------------------------------------------------ Judging
-- Evidence says whether the market is worth betting on; a listing far under market makes its
-- own "min under market" spread, which alone doesn't count against it
local trust = {}
local function Trusted(key)
  local t = trust[key]
  if t and GetTime() - t[2] < TRUST_TTL then return t[1] end
  local ev = P.Evidence(key)
  local ok = ev and ev.market and (ev.level ~= "low" or ev.spreadOnly) and true or false
  trust[key] = { ok, GetTime() }
  return ok
end

-- worth reading its auctions: the cheapest of an item, qty unknown, so no profit test
function Sn.Candidate(key, unit)
  local cfg = Cfg()
  local max = cfg.watch[A.Base(key)]
  if max and unit <= max then return true end
  if P.FlipGain(P.Get(A.Base(key), "vendor"), unit) then return true end
  if A.IsVariant(key) then return false end
  local market = P.Get(key, "market")
  return market and market > 0 and unit <= market * cfg.pct / 100 and Trusted(key) or false
end

-- key: itemID or variant (A.Key); unit: buyout each -> nil, or { why = "watch" | "vendor" |
-- "market", profit (whole listing, after the AH cut), pct of market, market, big }
function Sn.Judge(key, unit, qty)
  if not (key and unit and unit > 0) then return nil end
  qty = qty or 1
  local cfg = Cfg()
  local base = A.Base(key)
  local market = P.Get(key, "market")
  local pct = market and market > 0 and unit / market * 100 or nil
  local profit = market and (market * (1 - AH_CUT) - unit) * qty or 0
  local flip = P.FlipGain(P.Get(base, "vendor"), unit)
  if flip then profit = math.max(profit, flip * qty) end
  local why
  local max = cfg.watch[base]
  if max and unit <= max then
    why = "watch"
  elseif flip and flip * qty >= cfg.profit then
    why = "vendor"
  elseif pct and pct <= cfg.pct and profit >= cfg.profit and Trusted(key) then
    why = "market"
  end
  if not why then return nil end
  return { why = why, profit = math.floor(profit), pct = pct, market = market,
    big = profit >= cfg.big }
end

------------------------------------------------------------------------------ Alarms
local seen = {}       -- listing key -> time alarmed
local lastSound, lastShot = 0, 0

local WHY = { watch = "under your max", vendor = "under vendor", market = "under market" }

local function Cached(key, link)
  local name, l = C_Item.GetItemInfo(link or A.Link(key))
  return l or name
end

local function ItemText(key, link)
  return Cached(key, link) or link or ("item " .. tostring(key))
end

-- a GetAll scan turns up items the client has never seen, so has no name for: asked for, and
-- the deal told once it arrives (or after a while, for one the server never answers)
local naming = {} -- itemID -> callbacks waiting for its name
local function Named(id)
  if not id then return end
  local waiting = naming[id]
  naming[id] = nil
  for _, fn in ipairs(waiting or {}) do fn() end
end
M.On("GET_ITEM_INFO_RECEIVED", function(_, id) Named(id) end)
M.On("ITEM_DATA_LOAD_RESULT", function(_, id) Named(id) end)

local function WithItemText(key, link, fn)
  if Cached(key, link) then return fn(ItemText(key, link)) end
  local function Give() fn(ItemText(key, link)) end
  local id = A.Base(key)
  if not (id and C_Item.RequestLoadItemDataByID) then return Give() end
  if naming[id] then return table.insert(naming[id], Give) end
  naming[id] = { Give }
  C_Timer.After(3, function() Named(id) end)
  -- may answer at once
  C_Item.RequestLoadItemDataByID(id)
end

-- the deal on screen with the corner marker, then a screenshot of it
local banner
local function Banner()
  if banner then return banner end
  local f = CreateFrame("Frame", nil, nil, "BackdropTemplate")
  f:SetFrameStrata("FULLSCREEN_DIALOG")
  f:SetSize(560, 84)
  f:SetPoint("TOP", 0, -120)
  local white = "Interface\\Buttons\\WHITE8X8"
  f:SetBackdrop({ bgFile = white, edgeFile = white, edgeSize = 2 })
  f:SetBackdropColor(0, 0, 0, 0.92)
  f:SetBackdropBorderColor(1, 0, 1, 1)
  f.title = f:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
  f.title:SetPoint("TOP", 0, -10)
  f.text = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightLarge")
  f.text:SetPoint("TOP", f.title, "BOTTOM", 0, -6)
  f.text:SetWidth(540)
  f.line = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  f.line:SetPoint("TOP", f.text, "BOTTOM", 0, -6)
  -- the companion knows ours from the player's own screenshots by this square
  local mark = CreateFrame("Frame", nil, nil)
  mark:SetFrameStrata("TOOLTIP")
  mark:SetSize(24, 24)
  mark:SetPoint("TOPLEFT", 0, 0)
  local tex = mark:CreateTexture(nil, "OVERLAY")
  tex:SetAllPoints()
  tex:SetColorTexture(1, 0, 1, 1)
  f.mark = mark
  f:Hide()
  mark:Hide()
  banner = f
  return f
end

local function HideBanner()
  if banner then
    banner:Hide()
    banner.mark:Hide()
  end
end
M.On("SCREENSHOT_SUCCEEDED", function() C_Timer.After(0.5, HideBanner) end)
M.On("SCREENSHOT_FAILED", HideBanner)

local function Shoot(text, line)
  local f = Banner()
  f.title:SetText("Meionomics sniper")
  f.text:SetText(text)
  f.line:SetText(line)
  f:Show()
  f.mark:Show()
  -- drawn first: the screenshot is of the next frame
  C_Timer.After(0.2, function() Screenshot() end)
  C_Timer.After(5, HideBanner)
end

-- the alarms of a moment are told together, one line per item, the most profitable first;
-- an item told already is told again only when it shows up cheaper
local BATCH_WAIT = 1
local SHOW = 5
local batch = {}
local told = {}       -- key -> { unit = cheapest told, at = time }

local function Tell(groups, cfg)
  local more, moreProfit = #groups - SHOW, 0
  for i = SHOW + 1, #groups do moreProfit = moreProfit + groups[i].profit end
  for i = 1, math.min(#groups, SHOW) do
    local g = groups[i]
    local pct = g.pct and (" (%d%% of market)"):format(g.pct + 0.5) or ""
    local where = g.n > 1 and (" in %d listings from"):format(g.n) or " at"
    local text = ("%s x%d%s %s each%s"):format(g.item, g.qty, where, M.Money(g.unit), pct)
    local gain = g.profit > 0 and ("+%s profit"):format(M.Money(g.profit)) or WHY[g.why]
    M.Print(Cc(g.big and "good" or "warn", g.big and "BIG DEAL" or "Deal") .. ": " .. text
      .. ", " .. gain .. Cc("grey", ", " .. WHY[g.why] .. (g.from and ("; " .. g.from) or "")))
    g.text, g.gain, g.pctText = text, gain, pct
  end
  if more > 0 then
    M.Print(Cc("grey", ("and %d more item%s with deals%s"):format(more, more > 1 and "s" or "",
      moreProfit > 0 and (", +%s profit in all"):format(M.Money(moreProfit)) or "")))
  end
  local best = groups[1]
  if not best.big then return end
  if RaidNotice_AddMessage and RaidWarningFrame then
    RaidNotice_AddMessage(RaidWarningFrame, "Meionomics: " .. best.text .. ", " .. best.gain,
      ChatTypeInfo.RAID_WARNING)
  end
  if cfg.remote and GetTime() - lastShot >= SHOT_GAP then
    lastShot = GetTime()
    local name = C_Item.GetItemNameByID(A.Base(best.key)) or best.item
    local where = best.n > 1 and (" in %d listings from"):format(best.n) or " at"
    local plain = ("%s x%d%s %s each%s"):format(name, best.qty, where, M.Money(best.unit),
      best.pctText)
    Shoot(plain, best.gain .. "  |cff999999(" .. WHY[best.why] .. ")|r")
  end
end

local function Flush()
  local list = batch
  batch = {}
  local cfg = Cfg()
  local now = GetTime()
  local byKey, groups = {}, {}
  for _, a in ipairs(list) do
    local g = byKey[a.key]
    if not g then
      g = { key = a.key, link = a.link, from = a.from, why = a.deal.why, unit = math.huge,
        qty = 0, profit = 0, n = 0 }
      byKey[a.key] = g
      groups[#groups + 1] = g
    end
    g.n, g.qty, g.profit = g.n + 1, g.qty + (a.qty or 1), g.profit + a.deal.profit
    g.big = g.big or a.deal.big
    if a.unit < g.unit then g.unit, g.pct, g.why = a.unit, a.deal.pct, a.deal.why end
  end
  local fresh = {}
  for _, g in ipairs(groups) do
    local t = told[g.key]
    if not t or now - t.at >= REALARM or g.unit < t.unit then
      told[g.key] = { unit = g.unit, at = now }
      fresh[#fresh + 1] = g
    end
  end
  if #fresh == 0 then return end
  table.sort(fresh, function(x, y)
    if x.big ~= y.big then return x.big end
    return x.profit > y.profit
  end)
  if now - lastSound > 3 then
    lastSound = now
    PlaySound(SOUNDKIT.RAID_WARNING, "Master")
    if FlashClientIcon then FlashClientIcon() end
  end
  local shown = math.min(#fresh, SHOW)
  local left = shown
  for i = 1, shown do
    local g = fresh[i]
    WithItemText(g.key, g.link, function(item)
      g.item = item
      left = left - 1
      if left == 0 then Tell(fresh, cfg) end
    end)
  end
end

function Sn.Alarm(key, unit, qty, deal, link, from)
  local id = ("%s:%d:%d"):format(tostring(key), math.floor(unit + 0.5), qty or 1)
  local now = GetTime()
  if seen[id] and now - seen[id] < REALARM then return end
  seen[id] = now
  if not Cfg().alarms then return end
  if #batch == 0 then C_Timer.After(BATCH_WAIT, Flush) end
  batch[#batch + 1] = { key = key, unit = unit, qty = qty, deal = deal, link = link, from = from }
end

local function Check(key, unit, qty, link, from)
  local deal = Sn.Judge(key, unit, qty)
  if deal then Sn.Alarm(key, unit, qty, deal, link, from) end
  return deal
end

------------------------------------------------------------------------------ Every sighting
-- items a GetAll found deals in: the next sweep reads their auctions first
local found = {}

-- before Auction.lua records the scan: the market it's judged against is the one before it
local record = A.Record
function A.Record(byItem, now)
  local ok, err = pcall(function()
    for key, a in pairs(byItem) do
      if a.comp and a.top and Sn.Candidate(key, a.comp) then
        for u, q in a.top:gmatch("(%d+):(%d+):%d+;") do
          if Check(key, tonumber(u), tonumber(q), nil, "seen in the AH scan") then
            found[A.Base(key)] = true
          end
        end
      end
    end
  end)
  if not ok then geterrorhandler()(err) end
  return record(byItem, now)
end

M.On("ITEM_SEARCH_RESULTS_UPDATED", function(_, key)
  if not (key and key.itemID) then return end
  local CA = C_AuctionHouse
  for i = 1, CA.GetNumItemSearchResults(key) do
    local r = CA.GetItemSearchResultInfo(key, i)
    if r and not r.containsOwnerItem and r.buyoutAmount and r.buyoutAmount > 0 then
      Check(A.Key(r.itemLink) or key.itemID, r.buyoutAmount, r.quantity or 1, r.itemLink)
    end
  end
end)

-- a browse row is the cheapest of an item, quantity unknown: one counts. The sniper's own
-- sweep reads its candidates' auctions instead, quantities and all.
local run
local function OnAnyBrowse()
  if run and run.phase == "browse" then return end
  for _, r in ipairs(C_AuctionHouse.GetBrowseResults() or {}) do
    local key = r.itemKey
    if key and (key.itemSuffix or 0) == 0 and r.minPrice and r.minPrice > 0
      and not r.containsOwnerItem then
      Check(key.itemID, r.minPrice, 1)
    end
  end
end
M.On("AUCTION_HOUSE_BROWSE_RESULTS_UPDATED", OnAnyBrowse)
M.On("AUCTION_HOUSE_BROWSE_RESULTS_ADDED", OnAnyBrowse)

------------------------------------------------------------------------------ Sweeping
-- run: { phase = "browse" | "read" | "wait", scanned, heard, sweeps } while running

local function Showing()
  return B.panel and B.panel:IsVisible() and B.state.view == "snipe"
end

function Sn.Running() return run ~= nil end

function Sn.Stop()
  run = nil
  B.state.busy = false
  if B.panel then B.Refresh() end
end

local Sweep

local function Later(r)
  r.phase = "wait"
  local realm = A.Realm()
  if M.db.autoScan ~= false and realm and M.Now() - (realm.getAllTime or 0) >= GETALL_GAP then
    realm.getAllTime = M.Now()
    C_AuctionHouse.ReplicateItems()
  end
  C_Timer.After(Cfg().wait, function() if run == r then Sweep() end end)
end

local function Keys(results)
  local picks, have = {}, {}
  for _, r in ipairs(results) do
    local key = r.itemKey
    local plain = key and (key.itemSuffix or 0) == 0
    local id = key and key.itemID
    local watched = id and Cfg().watch[id]
    if id and r.minPrice and r.minPrice > 0 and not r.containsOwnerItem and (plain or watched)
      and Sn.Candidate(id, r.minPrice) then
      local market = P.Get(id, "market")
      local rank = watched and 0 or (market and r.minPrice / market or 1)
      picks[#picks + 1] = { key = key, rank = rank }
      have[id] = true
    end
  end
  table.sort(picks, function(a, b) return a.rank < b.rank end)
  local keys = {}
  for id in pairs(found) do
    if not have[id] then keys[#keys + 1] = C_AuctionHouse.MakeItemKey(id) end
  end
  wipe(found)
  for i = 1, math.min(#picks, MAX_KEYS) do keys[#keys + 1] = picks[i].key end
  return keys
end

local function OnBrowse()
  if not (run and run.phase == "browse") then return end
  run.heard = GetTime()
  local results = C_AuctionHouse.GetBrowseResults()
  if C_AuctionHouse.HasFullBrowseResults and not C_AuctionHouse.HasFullBrowseResults() then
    run.scanned = #results
    C_AuctionHouse.RequestMoreBrowseResults()
    if B.panel then B.Draw() end
    return
  end
  run.scanned = #results
  local keys = Keys(results)
  run.phase = "read"
  B.SearchKeys(keys, "Sniper")
  B.state.scanned = #results
end
M.On("AUCTION_HOUSE_BROWSE_RESULTS_UPDATED", OnBrowse)
M.On("AUCTION_HOUSE_BROWSE_RESULTS_ADDED", OnBrowse)
M.On("AUCTION_HOUSE_CLOSED", function() run = nil end)

function Sweep()
  local r = run
  if not r then return end
  if not Showing() then return Sn.Stop() end
  if not C_AuctionHouse.IsThrottledMessageSystemReady() then
    return C_Timer.After(1, function() if run == r then Sweep() end end)
  end
  r.phase, r.scanned, r.heard = "browse", 0, GetTime()
  r.sweeps = r.sweeps + 1
  local st = B.state
  st.busy, st.text = true, "Sniper"
  C_AuctionHouse.SendBrowseQuery({ searchString = "", filters = {}, itemClassFilters = {},
    sorts = { { sortOrder = Enum.AuctionHouseSortOrder.Price, reverseSort = false } } })
  local function Quiet()
    if not (run == r and r.phase == "browse") then return end
    local quiet = GetTime() - r.heard
    if quiet < BROWSE_WAIT then return C_Timer.After(BROWSE_WAIT - quiet, Quiet) end
    -- no answer (busy or throttled): try again after the usual wait
    st.busy = false
    Later(r)
    B.Refresh()
  end
  C_Timer.After(BROWSE_WAIT, Quiet)
  B.Refresh()
end

function Sn.Start()
  if not (AuctionHouseFrame and AuctionHouseFrame:IsShown()) then
    return M.Print("the sniper runs at the auction house: open it, then Meionomics > Sniper")
  end
  if not B.panel then return end
  if AuctionHouseFrame.meioTab and not B.panel:IsVisible() then
    AuctionHouseFrame:SetDisplayMode(B.MODE)
  end
  B.SetView("snipe")
  run = { sweeps = 0 }
  Sweep()
end

------------------------------------------------------------------------------ The view
local function RowKey(r) return r.link and A.Key(r.link) or r.itemID end

-- the B rows of this sweep, judged; a buyable deal alarms (once per listing)
local function Prepare(rows)
  for _, r in ipairs(rows) do
    if r.mine then
      r.deal = nil
    elseif r.deal == nil then
      r.deal = Check(RowKey(r), r.unit, r.qty, r.link) or false
    end
    local d = r.deal or nil
    r.profit, r.why, r.glow = d and d.profit, d and d.why, d and d.big
  end
  if run and run.phase == "read" and not B.state.busy then Later(run) end
end

local WHY_COL = { watch = "Watch", vendor = "Vendor", market = "Market" }

local function Profit(r)
  if not r.profit then return Cc("dim", "-") end
  local text = r.profit > 0 and ("+" .. M.Money(r.profit)) or M.Money(r.profit)
  return Cc(r.glow and "good" or "warn", text)
end

local function Filter(f, anchor)
  local g = CreateFrame("Frame", nil, f)
  g:SetSize(250, 24)
  g:SetPoint("LEFT", anchor, "RIGHT", 10, 0)
  local function Box(width, letters, after, x, value, apply)
    local e = CreateFrame("EditBox", nil, g, "InputBoxTemplate")
    e:SetSize(width, 20)
    e:SetAutoFocus(false)
    e:SetMaxLetters(letters)
    e:SetJustifyH("CENTER")
    e:SetPoint("LEFT", after, "RIGHT", x, 0)
    local function Apply(self)
      self:ClearFocus()
      apply(tonumber(self:GetText()))
      self:SetText(value())
      if B.state.view == "snipe" then
        for _, r in ipairs(B.state.rows) do r.deal = nil end
        B.Refresh()
      end
    end
    e:SetScript("OnEnterPressed", Apply)
    e:SetScript("OnEditFocusLost", Apply)
    e:SetScript("OnEscapePressed", function(self)
      self:SetText(value())
      self:ClearFocus()
    end)
    e:SetText(value())
    return e
  end
  local toggle = CreateFrame("Button", nil, g, "UIPanelButtonTemplate")
  toggle:SetSize(50, 22)
  toggle:SetPoint("LEFT")
  toggle:SetScript("OnClick", function()
    if run then Sn.Stop() else Sn.Start() end
  end)
  local under = g:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  under:SetPoint("LEFT", toggle, "RIGHT", 6, 0)
  under:SetText("Under")
  local pct = Box(30, 3, under, 6, function() return Cfg().pct end, function(v)
    if v and v > 0 and v < 100 then Cfg().pct = v end
  end)
  local pctLabel = g:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  pctLabel:SetPoint("LEFT", pct, "RIGHT", 3, 0)
  pctLabel:SetText("%")
  local profitLabel = g:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  profitLabel:SetPoint("LEFT", pctLabel, "RIGHT", 8, 0)
  profitLabel:SetText("Profit")
  local profit = Box(30, 4, profitLabel, 6,
    function() return ("%g"):format(Cfg().profit / 10000) end,
    function(v) if v and v >= 0 then Cfg().profit = math.floor(v * 10000) end end)
  local g2 = g:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  g2:SetPoint("LEFT", profit, "RIGHT", 3, 0)
  g2:SetText("g")
  local alarm = CreateFrame("CheckButton", nil, g, "UICheckButtonTemplate")
  alarm:SetSize(24, 24)
  alarm:SetPoint("LEFT", g2, "RIGHT", 4, 0)
  alarm.label = g:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  alarm.label:SetPoint("LEFT", alarm, "RIGHT", 1, 0)
  alarm.label:SetText("Alarm")
  alarm:SetScript("OnClick", function(self) Cfg().alarms = self:GetChecked() and true or false end)
  B.LabelClicks(alarm, alarm.label)
  B.Help(toggle, function()
    return run and { "Stop", "Stop sweeping the auction house" }
      or { "Start", "Sweep the whole auction house for deals, again every "
        .. Cfg().wait .. " seconds", "Runs while this view is open; any other tab or view "
        .. "stops it. A full GetAll scan as well every 15 minutes." }
  end)
  B.Help(pct, { "Under % of market", "A listing this far under market or lower is a deal, "
    .. "when the profit is enough too", "Only where the market price is trusted (Conf not "
    .. "Low). Watched items and listings under vendor price count whatever the %." })
  B.Help(profit, { "Minimum profit", "Gold a deal must make on the whole listing, after the "
    .. "5% AH cut, reselling at market (or vendoring)", "Big deals (" .. M.Money(Cfg().big)
    .. "+, /meio snipe big) also show a raid warning, and with /meio snipe phone on are "
    .. "sent to your phone." })
  B.Help(alarm, { "Alarm", "Sound, taskbar flash and a chat line for each new deal",
    "Any search counts, in any AH window, and every GetAll scan. Hear it with the game in the "
    .. "background: Sound > Sound in background." })
  function g.Update()
    toggle:SetText(run and "Stop" or "Start")
    alarm:SetChecked(Cfg().alarms)
  end
  g.Update()
  f.snipe = g
  return g
end

B.VIEWS.snipe = {
  sort = "profit",
  desc = true,
  keysOnly = true,
  columns = {
    { key = "name", title = "Item", width = 0, tip = B.ROW_TIP },
    { key = "unit", title = "Price each", width = 100, right = true, tip = "Buyout for one",
      text = function(r) return M.Money(r.unit) end },
    { key = "pct", title = "% Mkt", width = 56, right = true, tip = B.PCT_TIP, more = B.PCT_MORE,
      text = function(r) return B.Pct(r.pct) end },
    { key = "profit", title = "Profit", width = 96, right = true, desc = true,
      tip = "What the whole auction makes, resold at market after the 5% cut, or vendored",
      more = "Green: a big deal (/meio snipe big).", text = Profit },
    { key = "why", title = "Why", width = 60, tip = "Watch: under your max price (/meio snipe "
      .. "add). Vendor: a vendor pays more. Market: far under market.",
      text = function(r) return WHY_COL[r.why] or Cc("dim", "-") end },
    { key = "qty", title = "Qty", width = 40, right = true, tip = "How many in the auction",
      text = function(r) return r.qty end },
    { key = "seller", title = "Seller", width = 96, tip = B.SELLER_TIP,
      text = function(r) return r.mine and Cc("accent", r.seller) or r.seller end },
  },
  Prepare = Prepare,
  Keep = function(r) return r.deal and true or false end,
  Filter = Filter,
  OnDraw = function(f) if f.snipe then f.snipe.Update() end end,
  status = function(n)
    local st = B.state
    local wait = run and run.phase == "wait" and (", next sweep in %ds"):format(Cfg().wait) or ""
    return ("%d deals in %d auctions of %d items%s"):format(#st.rows - n, #st.rows,
      st.scanned or 0, wait)
  end,
  reading = function()
    if run and run.phase == "browse" then
      return ("Sweeping the AH... %d items"):format(run.scanned or 0)
    end
    return ("Reading item %d of %d"):format(B.state.read, B.state.items)
  end,
  empty = "Sniper: press Start to sweep the AH for deals",
  welcome = function()
    local cfg = Cfg()
    local n = 0
    for _ in pairs(cfg.watch) do n = n + 1 end
    return Cc("accent", "Sniper") .. "\n\nStart sweeps the whole auction house again and again"
      .. " and lists what's cheap enough to buy:\nunder " .. cfg.pct .. "% of market making "
      .. M.Money(cfg.profit) .. " or more, under vendor price, or under your max for a "
      .. "watched item (" .. n .. " watched).\nEach new deal sounds an alarm; double-click to "
      .. "buy.\n\n/meio snipe add <item> <max price> watches an item.  /meio snipe phone on: "
      .. "big deals to your phone."
  end,
  none = "No deals right now. It keeps sweeping.",
  noneStatus = function() return run and "No deals yet" or "Stopped" end,
  hidden = function(n)
    return ("No deals among these %d auctions. It keeps sweeping."):format(n)
  end,
  action = B.VIEWS.items.action,
}

table.insert(B.onBuild, function(f)
  local b = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
  b:SetSize(80, 20)
  local left = f.sell or f.bis or f.shop
  b:SetPoint("RIGHT", left or f, left and "LEFT" or "BOTTOMRIGHT", -4, 0)
  b:SetText("Sniper")
  b:SetScript("OnClick", Sn.Start)
  B.Help(b, { "Sniper", "Sweep the AH for deals over and over, with an alarm for each",
    "Deals: under your % of market with enough profit, under vendor price, or under a watched "
      .. "item's max (/meio snipe add). Double-click a deal to buy it." })
  f.range:ClearAllPoints()
  f.range:SetPoint("RIGHT", b, "LEFT", -8, 0)
  f:HookScript("OnHide", function() if run then Sn.Stop() end end)
end)

------------------------------------------------------------------------------ /meio snipe
-- "5g20s", "50s", "75c", "1.5g", or a bare number of gold -> copper
function Sn.ParseMoney(s)
  s = (s or ""):lower():gsub("%s+", "")
  if s == "" then return nil end
  if s:match("^[%d%.]+$") then
    local g = tonumber(s)
    return g and math.floor(g * 10000 + 0.5)
  end
  local total = 0
  local rest = s:gsub("([%d%.]+)([gsc])", function(n, u)
    total = total + (tonumber(n) or 0) * ({ g = 10000, s = 100, c = 1 })[u]
    return ""
  end)
  if rest ~= "" then return nil end
  return math.floor(total + 0.5)
end

-- "<link> 5g", "2589 5g", "Linen Cloth 5g" -> itemID, the rest
local function ItemAndRest(text)
  local id = tonumber(text:match("item:(%d+)"))
  if id then return id, (text:gsub("|c%x+|H.-|h.-|h|r", ""):gsub("|H.-|h.-|h", "")) end
  local first, rest = text:match("^(%d+)%s*(.*)$")
  if first then return tonumber(first), rest end
  local name, last = text:match("^(.-)%s+(%S+)$")
  local found = name and C_Item.GetItemInfoInstant(name)
  if found then return found, last end
  return C_Item.GetItemInfoInstant(text), ""
end

local function WatchLine(id, max)
  return ("  %s up to %s"):format(ItemText(id), M.Money(max))
end

local function Status()
  local cfg = Cfg()
  M.Print(("sniper alarms %s: deals under %d%% of market making %s+, under vendor, or under "
    .. "a watched item's max; big from %s; phone %s"):format(M.OnOff(cfg.alarms), cfg.pct,
    M.Money(cfg.profit), M.Money(cfg.big), M.OnOff(cfg.remote)))
  if GetCVar("Sound_EnableSoundWhenGameIsInBG") == "0" then
    M.Print(Cc("warn", "game sound is off in the background:") .. " alarms are silent while "
      .. "tabbed out (" .. M.Cmd("/meio snipe bgsound") .. " turns it on)")
  end
  M.Print("  " .. M.Cmd("/meio snipe add <item> <max>") .. ", " .. M.Cmd("remove <item>") .. ", "
    .. M.Cmd("list") .. ", " .. M.Cmd("on||off") .. ", " .. M.Cmd("pct <n>") .. ", "
    .. M.Cmd("profit <gold>") .. ", " .. M.Cmd("big <gold>") .. ", " .. M.Cmd("phone on||off")
    .. ", " .. M.Cmd("test") .. ", " .. M.Cmd("start"))
end

M.commands.snipe = function(rest)
  rest = rest or ""
  local cmd, arg = rest:match("^(%S*)%s*(.-)%s*$")
  cmd = (cmd or ""):lower()
  local cfg = Cfg()
  if cmd == "on" or cmd == "off" then
    cfg.alarms = cmd == "on"
    return Status()
  elseif cmd == "add" or cmd == "watch" then
    local id, price = ItemAndRest(arg)
    local max = Sn.ParseMoney(price)
    if not (id and max) then
      return M.Print("/meio snipe add <item link, ID or name> <max price, e.g. 5g or 50s>")
    end
    cfg.watch[id] = max
    wipe(seen)
    return M.Print("watching " .. WatchLine(id, max):gsub("^%s+", ""))
  elseif cmd == "remove" or cmd == "unwatch" then
    local id = ItemAndRest(arg)
    if not (id and cfg.watch[id]) then return M.Print("not watched: " .. arg) end
    cfg.watch[id] = nil
    return M.Print("stopped watching " .. ItemText(id))
  elseif cmd == "list" then
    local any
    for id, max in pairs(cfg.watch) do
      if not any then M.Print("watched items:") end
      any = true
      DEFAULT_CHAT_FRAME:AddMessage(WatchLine(id, max))
    end
    if not any then M.Print("no watched items: " .. M.Cmd("/meio snipe add <item> <max>")) end
    return
  elseif cmd == "pct" then
    local v = tonumber(arg)
    if v and v > 0 and v < 100 then cfg.pct = v end
  elseif cmd == "profit" or cmd == "big" then
    local v = Sn.ParseMoney(arg)
    if v then cfg[cmd] = v end
  elseif cmd == "phone" or cmd == "remote" then
    if arg == "on" then cfg.remote = true elseif arg == "off" then cfg.remote = nil end
    M.Print("big deals to the phone " .. M.OnOff(cfg.remote) .. Cc("grey", ": a screenshot "
      .. "each, which the MeioSnipe companion on Windows sends on"))
    return
  elseif cmd == "bgsound" then
    SetCVar("Sound_EnableSoundWhenGameIsInBG", "1")
    return M.Print("game sound in the background " .. M.OnOff(true))
  elseif cmd == "start" then
    return Sn.Start()
  elseif cmd == "stop" then
    return Sn.Stop()
  elseif cmd == "test" then
    lastShot = 0
    local deal = { why = "market", profit = cfg.big, pct = 20, big = true }
    seen, told[2589] = {}, nil
    return Sn.Alarm(2589, 5, 20, deal, nil, "a test")
  end
  Status()
end
