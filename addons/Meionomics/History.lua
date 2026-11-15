-- Price history panel docked beside TSM's auction window (Browse and Sniper): click a result
-- and it shows that item. Needs LocalMods patch 16 (TSMLocalAuctionSelect). /meio history
-- <item> shows it without TSM.
-- Trend and level bars: TSM's own averages (DBRecent ~3 days, DBMarket 14, DBHistorical 60),
-- there from day one for every item. Chart: our daily rows (Auction.lua), one per day an AH
-- scan saw the item; showing an item here starts recording it.
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

-- label left, value right, on one line; frac (0..1) draws a bar behind it in color
local function Row(parent)
  local r = { left = Text(parent, "GameFontHighlightSmall"),
    right = Text(parent, "GameFontHighlightSmall"), bar = parent:CreateTexture(nil, "ARTWORK") }
  r.right:SetJustifyH("RIGHT")
  function r:Set(y, left, right, frac, color)
    self.bar:ClearAllPoints()
    if frac then
      self.bar:SetPoint("TOPLEFT", PAD - 3, y + 2)
      self.bar:SetSize(math.max(2, (WIDTH - 2 * PAD + 6) * frac), 13)
      self.bar:SetColorTexture(color[1], color[2], color[3], 0.3)
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

local function CreatePanel()
  panel = CreateFrame("Frame", "MeionomicsHistoryPanel", UIParent, "BackdropTemplate")
  panel:SetWidth(WIDTH)
  panel:SetFrameStrata("HIGH")
  panel:SetBackdrop({ bgFile = "Interface\\Buttons\\WHITE8x8",
    edgeFile = "Interface\\Buttons\\WHITE8x8", edgeSize = 1 })
  panel:SetBackdropColor(0.07, 0.07, 0.08, 0.96)
  panel:SetBackdropBorderColor(0.25, 0.25, 0.28, 1)
  panel:EnableMouse(true)
  panel:Hide()

  panel.heading = Text(panel, "GameFontNormalSmall", "TOPLEFT", PAD, -PAD)
  panel.heading:SetText("Price history")
  local close = CreateFrame("Button", nil, panel, "UIPanelCloseButton")
  close:SetSize(20, 20)
  close:SetPoint("TOPRIGHT", -1, -1)
  close:SetScript("OnClick", function() H.Hide(true) end)

  panel.icon = panel:CreateTexture(nil, "ARTWORK")
  panel.icon:SetSize(20, 20)
  panel.icon:SetPoint("TOPLEFT", PAD, -24)
  panel.name = Text(panel, "GameFontHighlight", "LEFT", panel.icon, "RIGHT", 5, 0)
  panel.name:SetWidth(WIDTH - 2 * PAD - 25)
  panel.name:SetWordWrap(false)

  panel.rows = {}
  for i = 1, 12 do panel.rows[i] = Row(panel) end
  panel.note = Text(panel, "GameFontDisableSmall")
  panel.note:SetWidth(WIDTH - 2 * PAD)
  panel.note:SetSpacing(2)

  local chart = CreateFrame("Frame", nil, panel)
  chart:SetSize(WIDTH - 2 * PAD, CHART_H)
  panel.chart = chart
  local bg = chart:CreateTexture(nil, "BACKGROUND")
  bg:SetAllPoints()
  bg:SetColorTexture(1, 1, 1, 0.04)
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
  chart.top = Text(chart, "GameFontDisableSmall", "BOTTOMLEFT", chart, "TOPLEFT", 0, 2)
  chart.from = Text(chart, "GameFontDisableSmall", "TOPLEFT", chart, "BOTTOMLEFT", 0, -2)
  chart.to = Text(chart, "GameFontDisableSmall", "TOPRIGHT", chart, "BOTTOMRIGHT", 0, -2)
  chart.to:SetJustifyH("RIGHT")
  chart.legend = Text(chart, "GameFontDisableSmall", "BOTTOMRIGHT", chart, "TOPRIGHT", 0, 2)
  chart.legend:SetJustifyH("RIGHT")
  chart.legend:SetText("|cff6b99d9market|r  |cfff2c94clowest|r")
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

local function Fill(itemID)
  local name, _, quality, _, _, _, _, _, _, icon = C_Item.GetItemInfo(itemID)
  panel.icon:SetTexture(icon or C_Item.GetItemIconByID(itemID))
  local color = quality and ITEM_QUALITY_COLORS[quality]
  panel.name:SetText((color and color.hex or "|cffffffff") .. (name or ("item " .. itemID)) .. "|r")

  local n, y = 0, -50
  local function Add(left, right, frac, color)
    n = n + 1
    panel.rows[n]:Set(y, left, right, frac, color)
    y = y - (frac and 16 or 14)
  end
  local function Gap() y = y - 6 end

  local t = H.Trend(itemID)
  if t.word then
    Add(C(t.tone, t.word), C(t.tone, Pct(t.change)) .. C("dim", " " .. t.vs))
  else
    Add(C("dim", "No TSM price data"))
  end
  -- oldest first, so reading down follows time; bars start at zero so lengths stay honest
  local min = P.Get(itemID, "minBuyout")
  local levels = { { "60-day average", t.historical, BLUE }, { "14-day average", t.market, BLUE },
    { "3-day average", t.recent, BLUE }, { "Lowest now", min, GOLD } }
  local top = 0
  for _, l in ipairs(levels) do top = math.max(top, l[2] or 0) end
  Gap()
  for _, l in ipairs(levels) do
    if l[2] then Add(l[1], M.Money(l[2]), l[2] / top, l[3]) end
  end
  if not min then Add("Lowest now", C("dim", "none up")) end

  local ev = P.Evidence(itemID)
  local s = P.SellRate(itemID)
  Gap()
  if t.regionMarket then Add(C("grey", "Region average"), M.Money(t.regionMarket)) end
  if s and s.listed then Add(C("grey", "Listed"), tostring(s.listed)) end
  if s and s.perDay then Add(C("grey", "Region sold/day"), M.Count(s.perDay)) end

  local days
  y, days = DrawChart(itemID, y)

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
  panel:SetHeight(-y + PAD)
end

-- beside TSM's window, on the side TSMBrowse isn't (outside it when there's only room on one)
local function Dock(window)
  panel:ClearAllPoints()
  if not window then
    panel:SetPoint("CENTER", UIParent, "CENTER", 300, 0)
    return
  end
  -- TSM has its own UI scale: compare in UIParent units
  local scale = window:GetEffectiveScale() / UIParent:GetEffectiveScale()
  local right = (window:GetRight() or 0) * scale
  local onRight = right + WIDTH + 4 <= (UIParent:GetRight() or 1920)
  local anchor = window
  local browse = TSMBrowsePanel and TSMBrowsePanel:IsShown() and TSMBrowsePanel
  if browse and ((browse:GetLeft() or 0) >= right) == onRight then anchor = browse end
  if onRight then
    panel:SetPoint("TOPLEFT", anchor, "TOPRIGHT", 2, 0)
  else
    panel:SetPoint("TOPRIGHT", anchor, "TOPLEFT", -2, 0)
  end
end

local closedByUser, hooked = false, {}

function H.Show(itemID, window)
  if not panel then CreatePanel() end
  shownID = itemID
  A.Watch(itemID)
  Dock(window)
  Fill(itemID)
  panel:Show()
  if window and not hooked[window] then
    hooked[window] = true
    window:HookScript("OnHide", function() H.Hide() end)
  end
end

function H.Hide(byUser)
  if byUser then closedByUser = true end
  shownID = nil
  if panel then panel:Hide() end
end

function H.Refresh()
  if panel and panel:IsShown() and shownID then Fill(shownID) end
end

-- TSM: an item string ("i:2589") and its window; frame nil = results gone (tab switched)
local function OnSelect(itemString, frame)
  if not frame then return H.Hide() end
  local id = itemString and tonumber(itemString:match("^i:(%d+)"))
  if not id or M.db.history == false then return end
  if closedByUser and id == shownID then return end
  closedByUser = false
  H.Show(id, frame)
end

local prevOnLoad = M.OnLoad
function M.OnLoad()
  if prevOnLoad then prevOnLoad() end
  if type(TSMLocalAuctionSelect) == "table" then
    table.insert(TSMLocalAuctionSelect.callbacks, OnSelect)
  end
end

M.commands.history = function(rest)
  if rest == "off" or rest == "on" then
    M.db.history = rest == "off" and false or nil
    if rest == "off" then H.Hide() end
    return M.Print("price history beside TSM's auction window: " .. rest)
  end
  local id = tonumber(rest) or tonumber((rest or ""):match("item:(%d+)"))
  if not id then
    return M.Print("/meio history <item link or ID>, /meio history on|off"
      .. (type(TSMLocalAuctionSelect) == "table" and "" or " (TSM hook missing: patch 16)"))
  end
  H.Show(id)
end
