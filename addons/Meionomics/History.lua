-- Price history panel docked beside the auction window: click a result and it shows that item.
-- TSM's window (Browse and Sniper, patch 16 TSMLocalAuctionSelect) gets the flat TSM look;
-- Blizzard's AH (SelectBrowseResult) a Blizzard window. /meio history <item> shows it anywhere,
-- as a free Blizzard window: dragged by its title, position saved (M.db.historyPos).
-- Esc closes it; closed by hand, it stays shut for that item until another is picked.
-- The Sell tab (AuctionUI) opens it for the item in the box, with a Selling column: sell chance
-- and net by price (SellDay), stock, your posts and TSM ledger sales.
-- Trend and level bars: TSM's own averages (DBRecent ~3 days, DBMarket 14, DBHistorical 60),
-- there from day one for every item. Chart: our daily rows (Auction.lua), one per day an AH
-- scan saw the item; showing an item here starts recording it. Through the day: a row per scan
-- (Auction.lua A.Scans, A.Index).
-- A random-suffix item ("of the Bear") shows that variant's own scans (A.Key); TSM's averages
-- and region figures are for every variant together, so they're labelled or set aside.
local _, M = ...
local P, A = M.Prices, M.Auction
local H = {}
M.History = H

local WIDTH = 240
local PAD = 8
local CHART_H = 72
local DAYS = 30
local DAY = 86400
H.STEADY = 0.1 -- 3-day vs 60-day within this: steady

local panel, shownID
local CreateIntraday, FillSell
local closedByUser = false

local function C(key, text) return "|cff" .. M.Tooltip.style[key] .. text .. "|r" end

local function Pct(f)
  return ("%s%d%%"):format(f >= 0 and "+" or "-", math.floor(math.abs(f) * 100 + 0.5))
end

local function Ago(sec)
  if sec < 3600 then return math.max(1, math.floor(sec / 60)) .. " min ago" end
  if sec < DAY then return math.floor(sec / 3600) .. " h ago" end
  return math.floor(sec / DAY) .. " days ago"
end

------------------------------------------------------------------------------ Data
-- { recent, market, historical, regionMarket, change, vs, word, tone }: change compares the
-- shortest average there is with the longest; vs names them ("3-day vs 60-day")
function H.Trend(itemID)
  local t = { recent = P.Get(itemID, "recent"), market = P.Get(itemID, "market"),
    historical = P.Get(itemID, "historical"), regionMarket = P.Get(itemID, "regionMarket") }
  local pairsToTry = { { "recent", "historical", "3-day vs 60-day" },
    { "market", "historical", "14-day vs 60-day" }, { "recent", "market", "3-day vs 14-day" } }
  for _, p in ipairs(pairsToTry) do
    local now, base = t[p[1]], t[p[2]]
    if now and base and base > 0 then
      t.change, t.vs = now / base - 1, p[3]
      break
    end
  end
  if t.change then
    if t.change >= H.STEADY then
      t.word, t.tone = "Rising", "good"
    elseif t.change <= -H.STEADY then
      t.word, t.tone = "Falling", "bad"
    else
      t.word, t.tone = "Steady", "grey"
    end
  end
  return t
end

-- the last DAYS days of rows { day, min, mkt, qty }, today's (still building) included
function H.Days(itemID)
  local rows = {}
  local today = math.floor(M.Now() / DAY)
  for _, r in ipairs(A.History(itemID)) do
    if r.day > today - DAYS then rows[#rows + 1] = r end
  end
  local t = A.Today(itemID)
  if t and t.day > today - DAYS then rows[#rows + 1] = t end
  return rows, today
end

------------------------------------------------------------------------------ Panel
local function Text(parent, font, ...)
  local fs = parent:CreateFontString(nil, "OVERLAY", font)
  fs:SetJustifyH("LEFT")
  if select("#", ...) > 0 then fs:SetPoint(...) end
  return fs
end

local BLUE = { 0.42, 0.6, 0.85 }
local GOLD = { 0.95, 0.79, 0.3 }

-- dark wells under the charts: recessed on Blizzard's parchment, faint on TSM's flat fill
local function Well(tex, blizz)
  if blizz then
    tex:SetColorTexture(0, 0, 0, 0.35)
  else
    tex:SetColorTexture(1, 1, 1, 0.04)
  end
end

-- label left, value right, on one line; frac (0..1) draws a bar behind it in color.
-- blizz: Blizzard's status bar texture, else a flat fill
local function Row(parent, blizz)
  local r = { left = Text(parent, "GameFontHighlightSmall"),
    right = Text(parent, "GameFontHighlightSmall"), bar = parent:CreateTexture(nil, "ARTWORK") }
  r.right:SetJustifyH("RIGHT")
  if blizz then r.bar:SetTexture("Interface\\TargetingFrame\\UI-StatusBar") end
  function r:Set(y, left, right, frac, color)
    self.bar:ClearAllPoints()
    if frac then
      self.bar:SetPoint("TOPLEFT", PAD - 3, y + 2)
      self.bar:SetSize(math.max(2, (WIDTH - 2 * PAD + 6) * frac), 13)
      if blizz then
        self.bar:SetVertexColor(color[1], color[2], color[3], 0.55)
      else
        self.bar:SetColorTexture(color[1], color[2], color[3], 0.3)
      end
      self.bar:Show()
    else
      self.bar:Hide()
    end
    self.left:ClearAllPoints()
    self.left:SetPoint("TOPLEFT", PAD, y)
    self.right:ClearAllPoints()
    self.right:SetPoint("TOPRIGHT", -PAD, y)
    self.left:SetText(left)
    self.right:SetText(right or "")
    self.left:Show()
    self.right:Show()
  end
  function r:Hide()
    self.bar:Hide()
    self.left:Hide()
    self.right:Hide()
  end
  return r
end

local function BarTip(slot)
  local r = slot.row
  if not r then return end
  GameTooltip:SetOwner(slot, "ANCHOR_RIGHT")
  GameTooltip:AddLine(date("%a %d %b", r.day * DAY) .. (r.today and " (so far)" or ""))
  GameTooltip:AddDoubleLine("Market", M.Money(r.mkt), 0.8, 0.8, 0.8, 1, 1, 1)
  GameTooltip:AddDoubleLine("Lowest buyout", M.Money(r.min), 0.8, 0.8, 0.8, 1, 1, 1)
  GameTooltip:AddDoubleLine("Listed", r.qty or "-", 0.8, 0.8, 0.8, 1, 1, 1)
  GameTooltip:Show()
end

-- grey that stays readable on both panel backgrounds
local function Soft(fs)
  fs:SetTextColor(0.75, 0.75, 0.75)
  return fs
end

-- TSM's flat look: dark fill, 1px border, a plain x
local function FlatChrome(p)
  p:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8x8",
    edgeFile = "Interface\\Buttons\\WHITE8x8", edgeSize = 1 })
  p:SetBackdropColor(0.07, 0.07, 0.08, 0.96)
  p:SetBackdropBorderColor(0.25, 0.25, 0.28, 1)
  p.heading = Text(p, "GameFontNormalSmall", "TOPLEFT", PAD, -PAD)
  p.heading:SetText("Price history")
  local close = CreateFrame("Button", nil, p)
  close:SetSize(18, 18)
  close:SetPoint("TOPRIGHT", -3, -3)
  close:SetNormalFontObject("GameFontHighlight")
  close:SetHighlightFontObject("GameFontNormal")
  close:SetText("x")
  close:SetScript("OnClick", function() p:Hide() end)
  p.top, p.side, p.bottom = 0, 0, 0
end

-- Blizzard's own window, as the Meionomics AH tab and crafting panel use (Inset 8 in, like
-- CraftUI). Content keeps clear of the frame and Inset borders, which otherwise cover the
-- first letters of every line.
local function BlizzChrome(p)
  ButtonFrameTemplate_HidePortrait(p)
  if ButtonFrameTemplate_HideButtonBar then ButtonFrameTemplate_HideButtonBar(p) end
  p:SetTitle("Price history")
  p.CloseButton:SetScript("OnClick", function() p:Hide() end)
  p.Inset:ClearAllPoints()
  p.Inset:SetPoint("TOPLEFT", 8, -26)
  p.Inset:SetPoint("BOTTOMRIGHT", -8, 8)
  p.top, p.side, p.bottom = 10, 8, 10
end

-- blizz: the Blizzard-styled one (Blizzard's AH), else the flat one (TSM's window)
local panels = {}
local function CreatePanel(blizz)
  panel = blizz
    and CreateFrame("Frame", "MeionomicsHistoryPanelBlizz", UIParent, "ButtonFrameTemplate")
    or CreateFrame("Frame", "MeionomicsHistoryPanel", UIParent, "BackdropTemplate")
  panels[blizz and "blizz" or "flat"] = panel
  panel.blizz = blizz
  panel:SetFrameStrata("MEDIUM")
  panel:SetToplevel(true)
  panel:EnableMouse(true)
  panel:SetClampedToScreen(true)
  panel:Hide()
  if blizz then BlizzChrome(panel) else FlatChrome(panel) end
  -- docked, it follows the auction window; free, it's dragged
  panel:SetMovable(true)
  panel:RegisterForDrag("LeftButton")
  panel:SetScript("OnDragStart", function(self) if not self.window then self:StartMoving() end end)
  panel:SetScript("OnDragStop", function(self)
    self:StopMovingOrSizing()
    if self.window then return end
    self:SetUserPlaced(false)
    local point, _, rel, x, y = self:GetPoint()
    M.db.historyPos = { point, rel, math.floor(x + 0.5), math.floor(y + 0.5) }
  end)
  -- Esc (UISpecialFrames) or the close button: shut by hand. Not UIParent hiding (Alt+Z).
  panel:HookScript("OnHide", function(self)
    if not self.meioQuiet and not self:IsShown() then closedByUser = true end
  end)
  tinsert(UISpecialFrames, panel:GetName())
  panel:SetWidth(WIDTH + 2 * panel.side)
  -- everything below is laid out in WIDTH-wide body units, side-inset from the chrome
  local body = CreateFrame("Frame", nil, panel)
  body:SetPoint("TOPLEFT", panel.side, 0)
  body:SetPoint("BOTTOMLEFT", panel.side, 0)
  body:SetWidth(WIDTH)
  if panel.Inset then body:SetFrameLevel(panel.Inset:GetFrameLevel() + 2) end
  panel.body = body
  -- the Sell tab's column, right of the history
  local sell = CreateFrame("Frame", nil, panel)
  sell:SetPoint("TOPLEFT", body, "TOPRIGHT")
  sell:SetPoint("BOTTOMLEFT", body, "BOTTOMRIGHT")
  sell:SetWidth(WIDTH)
  sell:SetFrameLevel(body:GetFrameLevel())
  sell.rows = {}
  sell.heading = Text(sell, "GameFontNormal", "TOPLEFT", PAD, -27 - panel.top)
  sell.heading:SetText("Selling")
  sell.note = Soft(Text(sell, "GameFontHighlightSmall"))
  sell.note:SetWidth(WIDTH - 2 * PAD)
  sell.note:SetSpacing(2)
  local rule = sell:CreateTexture(nil, "ARTWORK")
  rule:SetColorTexture(1, 1, 1, blizz and 0.15 or 0.08)
  rule:SetPoint("TOPLEFT", 0, -22 - panel.top)
  rule:SetPoint("BOTTOMLEFT", 0, PAD + panel.bottom)
  rule:SetWidth(1)
  sell:Hide()
  panel.sellCol = sell

  panel.icon = body:CreateTexture(nil, "ARTWORK")
  panel.icon:SetSize(20, 20)
  panel.icon:SetPoint("TOPLEFT", PAD, -24 - panel.top)
  panel.name = Text(body, "GameFontHighlight", "LEFT", panel.icon, "RIGHT", 5, 0)
  panel.name:SetWidth(WIDTH - 2 * PAD - 25)
  panel.name:SetWordWrap(false)

  panel.rows = {}
  for i = 1, 12 do panel.rows[i] = Row(body, blizz) end
  panel.note = Soft(Text(body, "GameFontHighlightSmall"))
  panel.note:SetWidth(WIDTH - 2 * PAD)
  panel.note:SetSpacing(2)

  local chart = CreateFrame("Frame", nil, body)
  chart:SetSize(WIDTH - 2 * PAD, CHART_H)
  panel.chart = chart
  local bg = chart:CreateTexture(nil, "BACKGROUND")
  bg:SetAllPoints()
  Well(bg, blizz)
  local slotW = (WIDTH - 2 * PAD) / DAYS
  chart.slots = {}
  for i = 1, DAYS do
    local slot = CreateFrame("Frame", nil, chart)
    slot:SetPoint("BOTTOMLEFT", (i - 1) * slotW, 0)
    slot:SetSize(slotW, CHART_H)
    slot:EnableMouse(true)
    slot:SetScript("OnEnter", BarTip)
    slot:SetScript("OnLeave", GameTooltip_Hide)
    slot.bar = slot:CreateTexture(nil, "ARTWORK")
    slot.bar:SetWidth(math.max(2, slotW - 2))
    slot.bar:SetPoint("BOTTOM")
    slot.tick = slot:CreateTexture(nil, "OVERLAY")
    slot.tick:SetSize(slotW, 2)
    slot.tick:SetColorTexture(0.95, 0.79, 0.3, 1)
    chart.slots[i] = slot
  end
  local function Label(...) return Soft(Text(chart, "GameFontHighlightSmall", ...)) end
  chart.top = Label("BOTTOMLEFT", chart, "TOPLEFT", 0, 2)
  chart.from = Label("TOPLEFT", chart, "BOTTOMLEFT", 0, -2)
  chart.to = Label("TOPRIGHT", chart, "BOTTOMRIGHT", 0, -2)
  chart.to:SetJustifyH("RIGHT")
  chart.legend = Label("BOTTOMRIGHT", chart, "TOPRIGHT", 0, 2)
  chart.legend:SetJustifyH("RIGHT")
  chart.legend:SetText("|cff6b99d9market|r  |cfff2c94clowest|r")
  CreateIntraday(panel)
end

-- returns the y below the chart (y itself when there's too little to draw) and the day count
local function DrawChart(itemID, y)
  local chart = panel.chart
  local rows, today = H.Days(itemID)
  local top = 0
  for _, r in ipairs(rows) do top = math.max(top, r.mkt or 0, r.min or 0) end
  for _, s in ipairs(chart.slots) do
    s.row = nil
    s.bar:Hide()
    s.tick:Hide()
  end
  if #rows < 2 or top == 0 then
    chart:Hide()
    return y, #rows
  end
  top = top * 1.08
  for _, r in ipairs(rows) do
    local s = chart.slots[DAYS - (today - r.day)]
    if s then
      r.today = r.day == today
      s.row = r
      if r.mkt then
        s.bar:SetHeight(math.max(1, CHART_H * r.mkt / top))
        local a = r.today and 0.45 or 0.75
        s.bar:SetColorTexture(0.42, 0.6, 0.85, a)
        s.bar:Show()
      end
      if r.min then
        s.tick:ClearAllPoints()
        s.tick:SetPoint("BOTTOM", 0, math.max(0, CHART_H * r.min / top - 1))
        s.tick:Show()
      end
    end
  end
  chart.top:SetText(M.Money(top / 1.08))
  chart.from:SetText(date("%d %b", (today - DAYS + 1) * DAY))
  chart.to:SetText("today")
  chart:ClearAllPoints()
  chart:SetPoint("TOPLEFT", PAD, y - 18)
  chart:Show()
  return y - 18 - CHART_H - 16, #rows
end

------------------------------------------------------------------------------ Through the day
-- Every AH scan of the last 3 days as a dot, and the 14 days of scans folded onto one day in
-- 3-hour blocks, for this item and the whole AH (A.Index). Local time: the player's day.
local SPAN = 3 * DAY
local LINE_H = 64
local LINE_MARGIN = 6
local GUTTER = 44 -- price labels, left of the dots
local PROFILE_H = 44
local BLOCK_H = 3
local BLOCKS = 24 / BLOCK_H
local MIN_SCALE = 0.05 -- profile bars never magnify noise under this
local GREY = { 0.7, 0.7, 0.7 }

-- points { t, ... } -> blocks[1..8] { dev, n }: each price over the mean of its own day's, so a
-- slow trend doesn't read as an hour effect; a day with one scan says nothing about the hour
function H.ByHour(points, value)
  local days = {}
  for _, p in ipairs(points) do
    local v = value(p)
    if v and v > 0 then
      local k = date("%Y%m%d", p.t)
      local d = days[k] or { sum = 0, pts = {} }
      days[k] = d
      d.sum = d.sum + v
      d.pts[#d.pts + 1] = { hour = tonumber(date("%H", p.t)), v = v }
    end
  end
  local blocks = {}
  for i = 1, BLOCKS do blocks[i] = { sum = 0, n = 0 } end
  for _, d in pairs(days) do
    if #d.pts >= 2 then
      local mean = d.sum / #d.pts
      for _, p in ipairs(d.pts) do
        local b = blocks[math.floor(p.hour / BLOCK_H) + 1]
        b.sum, b.n = b.sum + p.v / mean - 1, b.n + 1
      end
    end
  end
  for _, b in ipairs(blocks) do b.dev = b.n > 0 and b.sum / b.n or nil end
  return blocks
end

-- cheapest and dearest blocks (indexes), nil with fewer than 2 blocks known
function H.Extremes(blocks)
  local lo, hi
  for i, b in ipairs(blocks) do
    if b.dev then
      if not lo or b.dev < blocks[lo].dev then lo = i end
      if not hi or b.dev > blocks[hi].dev then hi = i end
    end
  end
  if lo and lo ~= hi then return lo, hi end
end

local function BlockName(i)
  return ("%02d-%02d h"):format((i - 1) * BLOCK_H, i * BLOCK_H)
end

-- regions made on first use; Reset hides them all for the next draw
local function Pool(make)
  local pool = { used = 0 }
  function pool.Get()
    pool.used = pool.used + 1
    pool[pool.used] = pool[pool.used] or make()
    return pool[pool.used]
  end
  function pool.Reset()
    for i = 1, #pool do pool[i]:Hide() end
    pool.used = 0
  end
  return pool
end

local function PointTip(f)
  local p = f.point
  GameTooltip:SetOwner(f, "ANCHOR_RIGHT")
  GameTooltip:AddLine(date("%a %d %b, %H:%M", p.t))
  if (p.mkt or 0) == 0 then
    GameTooltip:AddLine("None up", 0.8, 0.8, 0.8)
  else
    GameTooltip:AddDoubleLine("Market", M.Money(p.mkt), 0.8, 0.8, 0.8, 1, 1, 1)
    GameTooltip:AddDoubleLine("Lowest buyout", M.Money(p.min), 0.8, 0.8, 0.8, 1, 1, 1)
    GameTooltip:AddDoubleLine("Listed", p.qty or "-", 0.8, 0.8, 0.8, 1, 1, 1)
  end
  GameTooltip:Show()
end

local function BlockTip(f)
  local function Line(label, b)
    if b and b.dev then
      GameTooltip:AddDoubleLine(label, ("%s  (%d scan%s)"):format(Pct(b.dev), b.n,
        b.n == 1 and "" or "s"), 0.8, 0.8, 0.8, 1, 1, 1)
    else
      GameTooltip:AddDoubleLine(label, "no scans yet", 0.8, 0.8, 0.8, 0.6, 0.6, 0.6)
    end
  end
  GameTooltip:SetOwner(f, "ANCHOR_RIGHT")
  GameTooltip:AddLine(BlockName(f.i) .. ", vs that day's average")
  Line("This item", f.item)
  Line("Whole AH", f.ah)
  GameTooltip:Show()
end

function CreateIntraday(p)
  local w = WIDTH - 2 * PAD
  local s = CreateFrame("Frame", nil, p.body)
  p.intraday = s
  s:SetWidth(w)
  local function Label(font, ...) return Soft(Text(s, font or "GameFontHighlightSmall", ...)) end

  s.heading = Text(s, "GameFontNormalSmall", "TOPLEFT", 0, 0)
  s.heading:SetText("Through the day")
  s.legend = Label(nil, "TOPRIGHT", 0, 0)
  s.legend:SetJustifyH("RIGHT")
  s.legend:SetText("|cff6b99d9market|r  |cfff2c94clowest|r")

  local line = CreateFrame("Frame", nil, s)
  line:SetSize(w, LINE_H)
  line:SetPoint("TOPLEFT", 0, -16)
  s.line = line
  local bg = line:CreateTexture(nil, "BACKGROUND")
  bg:SetPoint("TOPLEFT", GUTTER, 0)
  bg:SetPoint("BOTTOMRIGHT")
  Well(bg, p.blizz)
  line.hi = Label(nil, "RIGHT", line, "TOPLEFT", GUTTER - 3, -LINE_MARGIN)
  line.lo = Label(nil, "RIGHT", line, "BOTTOMLEFT", GUTTER - 3, LINE_MARGIN)
  line.dots = Pool(function()
    local t = line:CreateTexture(nil, "ARTWORK")
    t:SetSize(4, 4)
    t:SetColorTexture(BLUE[1], BLUE[2], BLUE[3], 0.95)
    return t
  end)
  line.ticks = Pool(function()
    local t = line:CreateTexture(nil, "OVERLAY")
    t:SetSize(4, 2)
    t:SetColorTexture(GOLD[1], GOLD[2], GOLD[3], 1)
    return t
  end)
  line.hovers = Pool(function()
    local f = CreateFrame("Frame", nil, line)
    f:EnableMouse(true)
    f:SetScript("OnEnter", PointTip)
    f:SetScript("OnLeave", GameTooltip_Hide)
    return f
  end)
  line.midnights = Pool(function()
    local t = line:CreateTexture(nil, "BORDER")
    t:SetSize(1, LINE_H)
    t:SetColorTexture(1, 1, 1, 0.15)
    return t
  end)
  line.days = Pool(function() return Label() end)

  s.sub = Text(s, "GameFontNormalSmall")
  s.sub:SetText("By time of day, 14 days")
  s.subLegend = Label()
  s.subLegend:SetJustifyH("RIGHT")
  s.subLegend:SetText("|cff6b99d9this item|r  |cffb3b3b3whole AH|r")

  local prof = CreateFrame("Frame", nil, s)
  prof:SetSize(w, PROFILE_H)
  s.prof = prof
  local pbg = prof:CreateTexture(nil, "BACKGROUND")
  pbg:SetAllPoints()
  Well(pbg, p.blizz)
  local mid = prof:CreateTexture(nil, "BORDER")
  mid:SetSize(w, 1)
  mid:SetPoint("LEFT")
  mid:SetColorTexture(1, 1, 1, 0.25)
  prof.scale = Label(nil, "TOPLEFT", prof, "TOPLEFT", 2, -1)
  local bw = w / BLOCKS
  prof.blocks = {}
  for i = 1, BLOCKS do
    local f = CreateFrame("Frame", nil, prof)
    f:SetPoint("TOPLEFT", (i - 1) * bw, 0)
    f:SetSize(bw, PROFILE_H)
    f:EnableMouse(true)
    f:SetScript("OnEnter", BlockTip)
    f:SetScript("OnLeave", GameTooltip_Hide)
    f.i = i
    f.itemBar = prof:CreateTexture(nil, "ARTWORK")
    f.itemBar:SetWidth(math.floor(bw / 3))
    f.ahBar = prof:CreateTexture(nil, "ARTWORK")
    f.ahBar:SetWidth(math.floor(bw / 3))
    f.cx = (i - 0.5) * bw
    prof.blocks[i] = f
  end
  prof.hours = {}
  for i, h in ipairs({ 0, 6, 12, 18 }) do
    local fs = Label(nil, "TOPLEFT", prof, "BOTTOMLEFT", (i - 1) * w / 4, -2)
    fs:SetText(("%02d:00"):format(h))
    prof.hours[i] = fs
  end
  s.summary = Label()
  s.summary:SetWidth(w)
  s.summary:SetSpacing(2)
  s.note = Label()
  s.note:SetWidth(w)
  s.note:SetSpacing(2)
end

-- local midnights after from, up to to
local function Midnights(from, to)
  local out = {}
  local d = date("*t", from)
  d.hour, d.min, d.sec = 0, 0, 0
  while true do
    d.day = d.day + 1
    local t = time(d)
    if t > to then break end
    out[#out + 1] = t
  end
  return out
end

-- the dots chart at the section's y; returns the y below it, nil when under 2 points
local function DrawLine(line, points, now)
  for _, pool in ipairs({ line.dots, line.ticks, line.hovers, line.midnights, line.days }) do
    pool.Reset()
  end
  local from = now - SPAN
  local shown, lo, hi = {}, nil, nil
  for _, p in ipairs(points) do
    if p.t >= from then
      shown[#shown + 1] = p
      for _, v in ipairs({ p.mkt, p.min }) do
        if v and v > 0 then lo, hi = math.min(lo or v, v), math.max(hi or v, v) end
      end
    end
  end
  if #shown < 2 or not lo then
    line.hi:SetText("")
    line.lo:SetText("")
    line:Hide()
    return nil
  end
  -- not from zero: a few percent through the day would be a flat line. lo and hi sit level
  -- with their corner labels, in the margins.
  local w = line:GetWidth()
  local function X(t) return GUTTER + (t - from) / SPAN * (w - GUTTER) end
  local function Y(v)
    if hi == lo then return LINE_H / 2 end
    return LINE_MARGIN + (v - lo) / (hi - lo) * (LINE_H - 2 * LINE_MARGIN)
  end
  for i, p in ipairs(shown) do
    local x = X(p.t)
    if (p.mkt or 0) > 0 then
      local d = line.dots.Get()
      d:ClearAllPoints()
      d:SetPoint("CENTER", line, "BOTTOMLEFT", x, Y(p.mkt))
      d:Show()
    end
    if (p.min or 0) > 0 then
      local t = line.ticks.Get()
      t:ClearAllPoints()
      t:SetPoint("CENTER", line, "BOTTOMLEFT", x, Y(p.min))
      t:Show()
    end
    -- hover strip reaching halfway to each neighbour
    local left = i > 1 and (x + X(shown[i - 1].t)) / 2 or math.max(GUTTER, x - 4)
    local right = i < #shown and (x + X(shown[i + 1].t)) / 2 or math.min(w, x + 4)
    local h = line.hovers.Get()
    h.point = p
    h:ClearAllPoints()
    h:SetPoint("BOTTOMLEFT", left, 0)
    h:SetSize(math.max(2, right - left), LINE_H)
    h:Show()
  end
  local edges = { from }
  for _, t in ipairs(Midnights(from, now)) do
    local m = line.midnights.Get()
    m:ClearAllPoints()
    m:SetPoint("BOTTOMLEFT", X(t), 0)
    m:Show()
    edges[#edges + 1] = t
  end
  edges[#edges + 1] = now
  for i = 1, #edges - 1 do
    local a, b = X(edges[i]), X(edges[i + 1])
    if b - a >= 26 then
      local fs = line.days.Get()
      fs:ClearAllPoints()
      fs:SetPoint("TOP", line, "BOTTOMLEFT", (a + b) / 2, -2)
      fs:SetText(i == #edges - 1 and "today" or date("%a", edges[i] + 1))
      fs:Show()
    end
  end
  line.hi:SetText(M.Money(hi))
  line.lo:SetText(M.Money(lo))
  line:Show()
  return true
end

local function DrawProfile(prof, item, ah)
  local scale = MIN_SCALE
  for i = 1, BLOCKS do
    scale = math.max(scale, math.abs(item[i].dev or 0), math.abs(ah[i].dev or 0))
  end
  local half = PROFILE_H / 2
  local function Bar(tex, dev, x, color)
    if not dev then return tex:Hide() end
    local h = math.max(1, math.abs(dev) / scale * (half - 2))
    tex:ClearAllPoints()
    tex:SetPoint(dev >= 0 and "BOTTOM" or "TOP", prof, "BOTTOMLEFT", x, half)
    tex:SetHeight(h)
    tex:SetColorTexture(color[1], color[2], color[3], 0.85)
    tex:Show()
  end
  for i, f in ipairs(prof.blocks) do
    f.item, f.ah = item[i], ah[i]
    local bw = f.itemBar:GetWidth()
    Bar(f.itemBar, item[i].dev, f.cx - bw / 2 - 1, BLUE)
    Bar(f.ahBar, ah[i].dev, f.cx + bw / 2 + 1, GREY)
  end
  prof.scale:SetText(("+/-%d%%"):format(math.floor(scale * 100 + 0.5)))
end

local function Known(blocks)
  local n = 0
  for _, b in ipairs(blocks) do if b.dev then n = n + 1 end end
  return n
end

-- returns the y below the section
local function DrawIntraday(itemID, y)
  local s = panel.intraday
  local points = A.Scans(itemID)
  local now = M.Now()
  local item = H.ByHour(points, function(p) return p.mkt end)
  local ah = H.ByHour(A.Index(), function(p) return p.pm end)
  s:ClearAllPoints()
  s:SetPoint("TOPLEFT", PAD, y - 10)
  local sy = -16
  local hasLine = DrawLine(s.line, points, now)
  s.legend:SetShown(hasLine)
  if hasLine then sy = sy - LINE_H - 16 end

  local hasProfile = Known(item) >= 2 or Known(ah) >= 2
  s.sub:SetShown(hasProfile)
  s.subLegend:SetShown(hasProfile)
  s.prof:SetShown(hasProfile)
  s.summary:Hide()
  if hasProfile then
    s.sub:ClearAllPoints()
    s.sub:SetPoint("TOPLEFT", 0, sy - 2)
    s.subLegend:ClearAllPoints()
    s.subLegend:SetPoint("TOPRIGHT", 0, sy - 2)
    s.prof:ClearAllPoints()
    s.prof:SetPoint("TOPLEFT", 0, sy - 18)
    DrawProfile(s.prof, item, ah)
    sy = sy - 18 - PROFILE_H - 16
    local who, blocks = "This item", item
    local lo, hi = H.Extremes(item)
    if not lo then
      who, blocks = "Whole AH", ah
      lo, hi = H.Extremes(ah)
    end
    if lo then
      s.summary:ClearAllPoints()
      s.summary:SetPoint("TOPLEFT", 0, sy - 2)
      s.summary:SetText(("%s: cheapest %s (%s), dearest %s (%s)"):format(who, BlockName(lo),
        C("good", Pct(blocks[lo].dev)), BlockName(hi), C("bad", Pct(blocks[hi].dev))))
      s.summary:Show()
      sy = sy - 2 - s.summary:GetStringHeight()
    end
  end

  s.note:ClearAllPoints()
  if not hasLine then
    local recent = 0
    for _, p in ipairs(points) do if p.t >= now - SPAN then recent = recent + 1 end end
    s.note:SetPoint("TOPLEFT", 0, sy)
    s.note:SetText(("%d scan%s of this item in the last 3 days. Each AH visit saves one (15 min"
      .. " apart at most); the dots start at 2, the time-of-day bars at 2 scans in one day.")
      :format(recent, recent == 1 and "" or "s"))
    s.note:Show()
    sy = sy - s.note:GetStringHeight()
  else
    s.note:Hide()
  end
  s:SetHeight(-sy)
  s:Show()
  return y - 10 + sy
end

------------------------------------------------------------------------------ Selling
-- the Sell tab's column: sell chance by price, stock, your record and sales
function FillSell(key, ctx)
  local itemID = A.Base(key)
  local col = panel.sellCol
  local n, y = 0, -50 - panel.top
  local function Add(left, right, frac, color)
    n = n + 1
    col.rows[n] = col.rows[n] or Row(col, panel.blizz)
    col.rows[n]:Set(y, left, right, frac, color)
    y = y - (frac and 16 or 14)
  end
  local function Head(text, right)
    y = y - 8
    Add(C("accent", text), right and C("dim", right))
  end
  local function Count(v) return v > 0 and tostring(v) or C("dim", "0") end
  col.note:Hide()

  local SD = M.SellDay
  local live = ctx.live or {}
  local q = SD and SD.Quote(itemID, { comp = live.comp, deposit = ctx.deposit,
    floor = ctx.floor })
  Head("Sells within a day", "chance  net each")
  if q then
    local best = q.price
    for _, r in ipairs(q.rows) do
      local under = r.m < 0.005 and "1c under" or ("%d%% under"):format(r.m * 100 + 0.5)
      -- money colours its own digits: greyed rows pass the grey in
      local grey = not r.ok and M.Tooltip.style.dim or nil
      local left = M.Money(r.price, grey, grey) .. "  " .. C("dim", under)
      local pct = ("%d%%  "):format(r.P * 100 + 0.5)
      local right = (r.ok and pct or C("dim", pct)) .. M.Money(r.v, grey, grey)
      Add(left, right, r.P, r.price == best and GOLD or BLUE)
    end
    if ctx.price and ctx.price > 0 then
      local r = SD.Net(q, ctx.price)
      Add("In the box " .. M.Money(ctx.price),
        ("%d%%  %s"):format(r.P * 100 + 0.5, M.Money(r.v)))
    end
    local why = {}
    if best then why[#why + 1] = "Gold bar: the best net that sells 4 in 5." end
    for _, r in ipairs(q.rows) do
      if not r.ok then
        why[#why + 1] = ctx.floor and ("Grey: under your floor %s or too slow."):format(
          M.Money(ctx.floor)) or "Grey: sells under 4 in 5."
        break
      end
    end
    col.note:SetText(("%s%s. Net: after the 5%% cut and deposits lost on expiries, reposted."
      .. " %s"):format(SD.DipText(q), SD.Basis(q.fit), table.concat(why, " ")))
    col.note:ClearAllPoints()
    col.note:SetPoint("TOPLEFT", PAD, y - 2)
    col.note:Show()
    y = y - 4 - col.note:GetStringHeight()
  else
    Add(C("dim", "No rival listing to price against"))
  end

  local inv = M.Inventory.Get(itemID)
  Head("Stock", inv and ("%d in all"):format(inv.total) or nil)
  if inv then
    local me = inv.me
    Add("Bags", Count(me.bags))
    Add("Bank", Count(me.bank))
    if (me.mail or 0) > 0 then Add("Mail", me.mail) end
    Add("On the AH", Count(me.auctions or 0))
    for _, a in ipairs(inv.alts) do Add(C("grey", a.name), a.total) end
    if inv.warband > 0 then Add(C("grey", "Warband bank"), inv.warband) end
    if inv.guild > 0 then Add(C("grey", "Guild bank"), inv.guild) end
  else
    Add(C("dim", "None anywhere"))
  end

  local rec = SD and SD.Record(itemID)
  Head("Your posts, 30 days", rec and rec.posts > 0 and ("%d posts"):format(rec.posts) or nil)
  if rec and rec.auctions > 0 then
    Add("Auctions", rec.auctions)
    Add(C("good", "Sold"), rec.sold .. C("dim", (" (%d within a day)"):format(rec.inDay)))
    Add(C("bad", "Expired"), Count(rec.expired))
    if rec.cancelled > 0 then Add("Cancelled", rec.cancelled) end
    if rec.up > 0 then Add("Still up", rec.up) end
    if rec.unknown > 0 then Add(C("grey", "No word yet"), rec.unknown) end
    local done = rec.sold + rec.expired
    if done > 0 then
      Add("Sell-through", ("%d%%"):format(rec.sold / done * 100 + 0.5), rec.sold / done, BLUE)
    end
  else
    Add(C("dim", "Not posted yet"))
  end

  local sales = P.Sales(itemID)
  Head("Your sales", #sales > 0 and "TSM ledger" or nil)
  if #sales > 0 then
    local units, gold = 0, 0
    for _, s in ipairs(sales) do
      units, gold = units + s.qty, gold + s.price * s.qty
    end
    local last = sales[#sales]
    Add("Sold", ("%d in %d sale%s"):format(units, #sales, #sales == 1 and "" or "s"))
    Add("Average price", M.Money(gold / units))
    Add("Sold for", M.Money(gold))
    Add("Last sale", M.Money(last.price) .. C("dim", " " .. Ago(M.Now() - last.time)))
  else
    Add(C("dim", P.TSMCsv("csvSales") and "None yet" or "Needs TSM's accounting"))
  end
  for i = n + 1, #col.rows do col.rows[i]:Hide() end
  return y
end

-- a variant: our own figures, beside TSM's for all of them
local function FillVariant(key, Add, Gap)
  local own = A.Get(key) or {}
  local itemID = A.Base(key)
  local all = P.Get(itemID, "market")
  local levels = { { "14-day average", own.market, BLUE }, { "Lowest now", own.min, GOLD },
    { C("grey", "All variants 14-day"), all, BLUE } }
  local top = 0
  for _, l in ipairs(levels) do top = math.max(top, l[2] or 0) end
  Add(C("dim", "This suffix: our own AH scans"))
  Gap()
  for _, l in ipairs(levels) do
    if l[2] then Add(l[1], M.Money(l[2]), l[2] / top, l[3]) end
  end
  if not own.min then Add("Lowest now", C("dim", "none up")) end
  Gap()
  if (own.n or 0) > 0 then Add(C("grey", "Listed"), tostring(own.n)) end
  local s = P.SellRate(itemID)
  if s and s.perDay then Add(C("grey", "Region sold/day, all"), M.Count(s.perDay)) end
end

local function Fill(key)
  local itemID = A.Base(key)
  local name, _, quality, _, _, _, _, _, _, icon = C_Item.GetItemInfo(A.Link(key))
  if not name then name, _, quality, _, _, _, _, _, _, icon = C_Item.GetItemInfo(itemID) end
  panel.icon:SetTexture(icon or C_Item.GetItemIconByID(itemID))
  local color = quality and ITEM_QUALITY_COLORS[quality]
  panel.name:SetText((color and color.hex or "|cffffffff") .. (name or ("item " .. itemID)) .. "|r")

  local n, y = 0, -50 - panel.top
  local function Add(left, right, frac, color)
    n = n + 1
    panel.rows[n]:Set(y, left, right, frac, color)
    y = y - (frac and 16 or 14)
  end
  local function Gap() y = y - 6 end

  if A.IsVariant(key) then
    FillVariant(key, Add, Gap)
  else
    local t = H.Trend(itemID)
    if t.word then
      Add(C(t.tone, t.word), C(t.tone, Pct(t.change)) .. C("dim", " " .. t.vs))
    else
      Add(C("dim", "No TSM price data"))
    end
    -- oldest first, so reading down follows time; bars start at zero so lengths stay honest
    local min = P.Get(itemID, "minBuyout")
    local levels = { { "60-day average", t.historical, BLUE },
      { "14-day average", t.market, BLUE }, { "3-day average", t.recent, BLUE },
      { "Lowest now", min, GOLD } }
    local top = 0
    for _, l in ipairs(levels) do top = math.max(top, l[2] or 0) end
    Gap()
    for _, l in ipairs(levels) do
      if l[2] then Add(l[1], M.Money(l[2]), l[2] / top, l[3]) end
    end
    if not min then Add("Lowest now", C("dim", "none up")) end

    local s = P.SellRate(itemID)
    Gap()
    if t.regionMarket then Add(C("grey", "Region average"), M.Money(t.regionMarket)) end
    if s and s.listed then Add(C("grey", "Listed"), tostring(s.listed)) end
    if s and s.perDay then Add(C("grey", "Region sold/day"), M.Count(s.perDay)) end
  end

  local ev = P.Evidence(itemID)
  local days
  y, days = DrawChart(key, y)

  local now = M.Now()
  if ev and (ev.sale or ev.buy) then
    Gap()
    if ev.sale then
      Add("Your last sale", M.Money(ev.sale.price) .. C("dim", " " .. Ago(now - ev.sale.time)))
    end
    if ev.buy then
      Add("Your last buy", M.Money(ev.buy.price) .. C("dim", " " .. Ago(now - ev.buy.time)))
    end
  end
  for i = n + 1, #panel.rows do panel.rows[i]:Hide() end

  panel.note:ClearAllPoints()
  if days < 2 then
    panel.note:SetPoint("TOPLEFT", PAD, y - 6)
    panel.note:SetText(("Daily chart: %d day%s recorded so far. Meionomics saves one point a day"
      .. " from the auction house scan it runs when you open the AH (every 15 min at most)."
      .. " This item is now tracked."):format(days, days == 1 and "" or "s"))
    panel.note:Show()
    y = y - 6 - panel.note:GetStringHeight()
  else
    panel.note:Hide()
  end
  y = DrawIntraday(key, y)
  if panel.sellCtx then y = math.min(y, FillSell(key, panel.sellCtx)) end
  local h = -y + PAD + panel.bottom
  -- beside Blizzard's AH: bottoms line up
  local w = panel.blizz and panel.window
  if w then
    h = math.max(h, w:GetHeight() * w:GetEffectiveScale() / panel:GetEffectiveScale())
  end
  panel:SetHeight(h)
end

-- beside TSM's window, on the side TSMBrowse isn't (outside it when there's only room on one)
local function Dock(window)
  panel:ClearAllPoints()
  -- clamped, it can overlap the window: same strata so Raise() puts it on top
  panel:SetFrameStrata(window and window:GetFrameStrata() or "MEDIUM")
  if not window then
    local pos = M.db.historyPos
    if pos then
      panel:SetPoint(pos[1], UIParent, pos[2], pos[3], pos[4])
    else
      panel:SetPoint("CENTER", UIParent, "CENTER", 0, 40)
    end
    return
  end
  -- TSM has its own UI scale: compare in UIParent units. Too little room either side: the
  -- roomier one, clamped to the screen (over the window's right edge, the results list,
  -- rather than over the Sell tab's price boxes on the left)
  local scale = window:GetEffectiveScale() / UIParent:GetEffectiveScale()
  local right = (window:GetRight() or 0) * scale
  local left = (window:GetLeft() or 0) * scale
  local roomRight = (UIParent:GetRight() or 1920) - right
  local onRight = roomRight >= panel:GetWidth() + 4 or roomRight >= left
  local anchor = window
  local browse = TSMBrowsePanel and TSMBrowsePanel:IsShown() and TSMBrowsePanel
  if browse and ((browse:GetLeft() or 0) >= right) == onRight then anchor = browse end
  if onRight then
    panel:SetPoint("TOPLEFT", anchor, "TOPRIGHT", 2, 0)
  else
    panel:SetPoint("TOPRIGHT", anchor, "TOPLEFT", -2, 0)
  end
end

local hooked = {}
local browseKey

-- hidden by us, not by hand
local function Quiet(p)
  p.meioQuiet = true
  p:Hide()
  p.meioQuiet = nil
end

-- itemID or a variant's key (A.Key). blizz: beside Blizzard's AH, in its look; else TSM's flat
-- one. sell: the Sell tab's state (H.ShowSell), adds the Selling column
function H.Show(itemID, window, blizz, sell)
  local want = panels[blizz and "blizz" or "flat"]
  if panel and panel ~= want then Quiet(panel) end
  if want then panel = want else CreatePanel(blizz) end
  shownID = itemID
  panel.window = window
  panel.sellCtx = sell
  panel.sellCol:SetShown(sell ~= nil)
  panel:SetWidth(WIDTH * (sell and 2 or 1) + 2 * panel.side)
  A.Watch(itemID)
  Dock(window)
  Fill(itemID)
  panel:Show()
  panel:Raise()
  if window and not hooked[window] then
    hooked[window] = true
    window:HookScript("OnHide", function() H.Hide() end)
  end
end

function H.Hide()
  shownID = nil
  if panel then Quiet(panel) end
end

function H.ResetPosition()
  M.db.historyPos = nil
  if panel and panel:IsShown() and not panel.window then Dock(nil) end
end
M.OnReset(H.ResetPosition)

function H.Refresh()
  if panel and panel:IsShown() and shownID then Fill(shownID) end
end

function H.SellShown(itemID)
  return panel and panel:IsShown() and panel.sellCtx and itemID and shownID == itemID or false
end

-- the Sell tab (AuctionUI): sell = { live (A.ItemSearch), price (in the box), deposit (each),
-- floor }; nil itemID: the box emptied
function H.ShowSell(itemID, window, sell)
  if not itemID then
    if panel and panel.sellCtx then H.Hide() end
    return
  end
  if M.db.history == false then return end
  if closedByUser and itemID == shownID then return end
  closedByUser = false
  H.Show(itemID, window, true, sell)
end

-- TSM: a base item string ("i:2589"), its window (nil = results gone, tab switched) and the
-- selected auction's full item string (patch 16), which keeps a random suffix
local function OnSelect(itemString, frame, full)
  if not frame then return H.Hide() end
  local id = A.Key(full or itemString)
  if not id or M.db.history == false then return end
  if closedByUser and id == shownID then return end
  closedByUser = false
  H.Show(id, frame)
end

-- Blizzard's AH: a browse result clicked (opens its item or commodity buy page)
local function HookBlizzard()
  local ah = AuctionHouseFrame
  if not ah or ah.meioHistory then return end
  ah.meioHistory = true
  if not ah.SelectBrowseResult then
    return M.Print("price history: Blizzard's AH has no SelectBrowseResult to hook here")
  end
  hooksecurefunc(ah, "SelectBrowseResult", function(self, result)
    local key = result and result.itemKey
    if not (key and key.itemID) or M.db.history == false then return end
    closedByUser = false
    H.Show(key.itemID, self, true)
    -- a suffix's row: which one is known from its auctions' links once the search answers
    browseKey = (key.itemSuffix or 0) ~= 0 and key or nil
  end)
end

M.On("ITEM_SEARCH_RESULTS_UPDATED", function(_, key)
  local want = browseKey
  if not (want and key and key.itemID == want.itemID and key.itemSuffix == want.itemSuffix) then
    return
  end
  browseKey = nil
  local r = C_AuctionHouse.GetItemSearchResultInfo(key, 1)
  local v = r and A.Key(r.itemLink)
  if A.IsVariant(v) and shownID == key.itemID and panel and panel:IsShown() then
    H.Show(v, AuctionHouseFrame, true)
  end
end)

-- Blizzard's SelectBrowseResult errors (and ignores the click) on a result whose item key
-- info isn't cached yet; its rows only ask for the ones on screen. Asking for every result
-- as it arrives gets the reply in before the click. Wrapping SelectBrowseResult instead would
-- taint the buy page, and PlaceBid is restricted.
local function WarmItemKeys()
  for _, r in ipairs(C_AuctionHouse.GetBrowseResults() or {}) do
    if r.itemKey then C_AuctionHouse.GetItemKeyInfo(r.itemKey) end
  end
end
M.On("AUCTION_HOUSE_BROWSE_RESULTS_UPDATED", WarmItemKeys)
M.On("AUCTION_HOUSE_BROWSE_RESULTS_ADDED", WarmItemKeys)

local prevOnLoad = M.OnLoad
function M.OnLoad()
  if prevOnLoad then prevOnLoad() end
  if type(TSMLocalAuctionSelect) == "table" then
    table.insert(TSMLocalAuctionSelect.callbacks, OnSelect)
  end
end

M.On("ADDON_LOADED", function(_, name)
  if name == "Blizzard_AuctionHouseUI" then HookBlizzard() end
end)
M.On("PLAYER_LOGIN", function()
  if C_AddOns.IsAddOnLoaded("Blizzard_AuctionHouseUI") then HookBlizzard() end
end)

M.commands.history = function(rest)
  if rest == "off" or rest == "on" then
    M.db.history = rest == "off" and false or nil
    if rest == "off" then H.Hide() end
    return M.Print("price history beside the auction window: " .. M.OnOff(rest == "on"))
  end
  if rest == "reset" then
    H.ResetPosition()
    return M.Print("price history window back in the middle")
  end
  local id = tonumber(rest) or A.Key(rest or "")
  if not id then
    return M.Print("/meio history <item link or ID> - price history of an item; "
      .. "/meio history on||off - beside the auction window (now "
      .. (M.db.history == false and "off" or "on") .. "); /meio history reset - put the window "
      .. "back"
      .. (type(TSMLocalAuctionSelect) == "table" and "" or " (TSM hook missing: patch 16)"))
  end
  closedByUser = false
  local ah = AuctionHouseFrame and AuctionHouseFrame:IsShown() and AuctionHouseFrame
  H.Show(id, ah or nil, true)
end
