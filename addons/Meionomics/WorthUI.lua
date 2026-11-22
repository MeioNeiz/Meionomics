-- The Worth window: every item a character has in one place (bags, bank, gear, mail, on the AH)
-- or all of them, one row per item: how many, worth each, per bag slot it takes, in total.
-- Shift (or the Detail box) adds the tooltip's Best verdict, vendor and AH prices and region
-- sales. Opens beside the bank on its Bank tab; /meio worth anywhere; AltView rows open it for
-- that character.
local _, M = ...
local W, A, P = M.Worth, M.Action, M.Prices
local UI = {}
M.WorthUI = UI

local TABS = { "bags", "bank", "equipped", "mail", "all" }
local TAB_NAME = { bags = "Bags", bank = "Bank", equipped = "Gear", mail = "Mail", all = "All" }
local ROW_H = 18
local LIST_TOP, LIST_BOTTOM = -84, 28
local H = 470
local NAME_W = 200
local CHROME = 8 + 8 + 4 + 22
-- { title, width, sort key, detail only, tip }; name is the flexible first one
local COLUMNS = {
  { "Item", NAME_W, "name", name = true, tip = "Bound and unbound copies get a row each." },
  { "Qty", 44, "count", tip = "How many, across every slot." },
  { "Each", 78, "each", tip = "What one is worth: the tooltip's Best line (AH after the cut, "
    .. "vendor, disenchant or craft)." },
  { "Per slot", 78, "slot", tip = "Worth per bag slot it fills: the lowest are the cheapest "
    .. "to clear out." },
  { "Total", 84, "total", tip = "Qty times Each." },
  { "Best", 112, "verb", detail = true, left = true, tip = "The tooltip's Best verdict: the "
    .. "best way to turn it into gold." },
  { "Vendor", 70, "vendor", detail = true, tip = "What a vendor pays for one." },
  { "AH", 78, "ah", detail = true, tip = "What one sells for on the AH, when it does." },
  { "Sold/day", 56, "perDay", detail = true, tip = "Region sales per day." },
}
local TAB_TIP = {
  bags = "Your bags, and the bags themselves.",
  bank = "Your bank: live while it is open, else as you last left it.",
  equipped = "What you are wearing.",
  mail = "Mail in your mailbox, as last seen at a mailbox.",
  all = "Every place together, items on the AH too: one row per item.",
}
local DIM = "959595"

local frame, rows, offset, list = nil, {}, 0, {}
local state   -- M.db.worth: { tab, sort, flip, detail, bank (auto at bank), at (left, top) }
local charKey -- nil: this character
local docked  -- shown because the bank opened

local function Hex(hex, text) return "|cff" .. hex .. text .. "|r" end
local function Detail() return state.detail or IsShiftKeyDown() end

local function Columns()
  local out = {}
  for _, c in ipairs(COLUMNS) do
    if not c.detail or Detail() then out[#out + 1] = c end
  end
  return out
end

local function ListWidth()
  local w = 0
  for _, c in ipairs(Columns()) do w = w + c[2] end
  return w
end

------------------------------------------------------------------------------ Data
local function Places() return state.tab == "all" and W.PLACES or { state.tab } end

-- one row per item (and bound state: bound copies sell differently): its slots merged
local function Build()
  local byKey, out = {}, {}
  local live, missing = false, true
  for _, place in ipairs(Places()) do
    local slots, isLive = W.Slots(charKey, place)
    if slots then
      missing = false
      live = live or isLive
      for _, it in ipairs(slots) do
        local key = it.id .. (it.bound and "b" or "")
        local r = byKey[key]
        if not r then
          r = { id = it.id, bound = it.bound, link = it.link, count = 0, slots = 0, where = {},
            stacks = {} }
          byKey[key] = r
          out[#out + 1] = r
        end
        r.count, r.slots = r.count + it.count, r.slots + 1
        r.where[place] = (r.where[place] or 0) + it.count
        r.stacks[#r.stacks + 1] = it.count
      end
    end
  end
  local sum = { value = 0, count = 0, slots = 0, unpriced = 0, live = live, missing = missing }
  for _, r in ipairs(out) do
    local each, act = W.Value(r.id, r.bound)
    r.each, r.act = each, act
    r.total = each and each * r.count
    r.slot = r.total and r.total / r.slots
    r.name = C_Item.GetItemNameByID(r.id) or (r.link and r.link:match("%[(.-)%]")) or ""
    r.quality = select(3, C_Item.GetItemInfo(r.id)) or (r.link and C_Item.GetItemQualityByID
      and C_Item.GetItemQualityByID(r.link))
    r.icon = C_Item.GetItemIconByID(r.id)
    local s = act and act.sale
    r.vendor = s and s.vendor
    r.ah = s and not s.why.ah and s.ah or nil
    r.perDay = P.Get(r.id, "soldPerDay")
    r.verb = act and act.verb or ""
    sum.count, sum.slots = sum.count + r.count, sum.slots + r.slots
    if r.total then sum.value = sum.value + r.total else sum.unpriced = sum.unpriced + 1 end
  end
  local key, flip = state.sort or "total", state.flip
  table.sort(out, function(a, b)
    local x, y = a[key], b[key]
    if x == y or (x == nil and y == nil) then
      if (a.total or -1) ~= (b.total or -1) then return (a.total or -1) > (b.total or -1) end
      return a.name < b.name
    end
    -- no value sorts last either way
    if x == nil then return false end
    if y == nil then return true end
    -- text ascending, numbers descending, as a first click wants
    local asc = type(x) == "string"
    if flip then asc = not asc end
    if asc then return x < y end
    return x > y
  end)
  return out, sum
end

------------------------------------------------------------------------------ Drawing
local function Money(v) return v and M.Money(v) or Hex(DIM, "-") end

local function BestText(r)
  local act = r.act
  if not act then return Hex(DIM, "loading") end
  local v = A.VERBS[act.verb]
  if not v then return "" end
  local word = act.verb == "craft" and "Craft" or v[1]
  return (A.ICONS[act.verb] and (A.ICONS[act.verb] .. " ") or "") .. Hex(v[2], word)
end

local function Cells(r)
  local q = r.quality and ITEM_QUALITY_COLORS and ITEM_QUALITY_COLORS[r.quality]
  local name = q and q.hex and (q.hex .. r.name .. "|r") or r.name
  local stacks = r.slots > 1 and Hex(DIM, (" (%d slots)"):format(r.slots)) or ""
  return {
    name = name .. stacks, count = tostring(r.count), each = Money(r.each),
    slot = Money(r.slot), total = Money(r.total), verb = BestText(r), vendor = Money(r.vendor),
    ah = Money(r.ah), perDay = r.perDay and M.Count(r.perDay) or Hex(DIM, "-"),
  }
end

local function RowTooltip(b)
  local r = b.data
  if not r then return end
  GameTooltip:SetOwner(b, "ANCHOR_RIGHT")
  if r.link then GameTooltip:SetHyperlink(r.link) else GameTooltip:SetItemByID(r.id) end
  if r.slots > 1 then
    GameTooltip:AddLine(("In %d slots: %s"):format(r.slots, table.concat(r.stacks, ", ")),
      0.6, 0.6, 0.6)
  end
  if state.tab == "all" then
    local parts = {}
    for _, place in ipairs(W.PLACES) do
      if r.where[place] then parts[#parts + 1] = W.NAMES[place] .. " " .. r.where[place] end
    end
    GameTooltip:AddLine(table.concat(parts, ", "), 0.6, 0.6, 0.6)
  end
  GameTooltip:Show()
end

local function Row(i)
  if rows[i] then return rows[i] end
  local b = CreateFrame("Button", nil, frame.list)
  b:SetHeight(ROW_H)
  b:SetPoint("TOPLEFT", 0, -(i - 1) * ROW_H)
  b:SetPoint("RIGHT")
  b:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
  b.icon = b:CreateTexture(nil, "ARTWORK")
  b.icon:SetSize(ROW_H - 4, ROW_H - 4)
  b.icon:SetPoint("LEFT", 2, 0)
  b.cells = {}
  b:RegisterForClicks("LeftButtonUp")
  b:SetScript("OnEnter", RowTooltip)
  b:SetScript("OnLeave", GameTooltip_Hide)
  b:SetScript("OnClick", function(self)
    local r = self.data
    if r and r.link and IsModifiedClick("CHATLINK") then ChatEdit_InsertLink(r.link) end
  end)
  rows[i] = b
  return b
end

local function Cell(b, i)
  local fs = b.cells[i]
  if not fs then
    fs = b:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    fs:SetWordWrap(false)
    b.cells[i] = fs
  end
  return fs
end

local function HeaderClick(self)
  if state.sort == self.key then
    state.flip = not state.flip
  else
    state.sort, state.flip = self.key, false
  end
  offset = 0
  UI.Refresh()
end

local function HeadTip(self)
  GameTooltip:SetOwner(self, "ANCHOR_TOP")
  GameTooltip:SetText(self.col[1])
  GameTooltip:AddLine(self.col.tip, 1, 1, 1, true)
  GameTooltip:AddLine("Click to sort, again to reverse.", 0.6, 0.6, 0.6)
  GameTooltip:Show()
end

local function Layout(cols)
  local x = 0
  for i, col in ipairs(cols) do
    local h = frame.heads[i]
    if not h then
      h = CreateFrame("Button", nil, frame, "ColumnDisplayButtonTemplate")
      h:SetScript("OnClick", HeaderClick)
      h:HookScript("OnEnter", HeadTip)
      h:HookScript("OnLeave", GameTooltip_Hide)
      frame.heads[i] = h
    end
    h:ClearAllPoints()
    h:SetPoint("BOTTOMLEFT", frame.Inset, "TOPLEFT", 2 + x, -2)
    h:SetSize(col[2] + 2, 24)
    h:SetText(col[1])
    local fs = h:GetFontString()
    local sorted = col[3] == (state.sort or "total")
    if fs then fs:SetTextColor(1, sorted and 1 or 0.82, sorted and 1 or 0) end
    h.key, h.col = col[3], col
    h:Show()
    x = x + col[2]
  end
  for i = #cols + 1, #frame.heads do frame.heads[i]:Hide() end
end

local function Visible() return math.max(1, math.floor(frame.list:GetHeight() / ROW_H)) end

local syncing
local function SyncBar(shown)
  local extra = #list - shown
  syncing = true
  frame.bar:SetVisibleExtentPercentage(extra > 0 and shown / #list or 1)
  frame.bar:SetPanExtentPercentage(extra > 0 and math.min(1, 3 / extra) or 1)
  frame.bar:SetScrollPercentage(extra > 0 and offset / extra or 0, true)
  syncing = false
end

local function Draw()
  local cols = Columns()
  Layout(cols)
  local n = Visible()
  offset = math.max(0, math.min(offset, #list - n))
  for i = 1, math.max(n, #rows) do
    local r = i <= n and list[offset + i]
    local b = (r or rows[i]) and Row(i)
    if b then
      b.data = r or nil
      b:SetShown(r ~= nil)
      if r then
        local cells = Cells(r)
        local x, used = 0, 0
        for _, col in ipairs(cols) do
          used = used + 1
          local fs = Cell(b, used)
          fs:ClearAllPoints()
          if col.name then
            b.icon:SetTexture(r.icon)
            fs:SetPoint("LEFT", x + ROW_H + 2, 0)
            fs:SetWidth(col[2] - ROW_H - 6)
            fs:SetJustifyH("LEFT")
          else
            fs:SetPoint("LEFT", x + 2, 0)
            fs:SetWidth(col[2] - 8)
            fs:SetJustifyH(col.left and "LEFT" or "RIGHT")
          end
          fs:SetText(cells[col[3]])
          fs:Show()
          x = x + col[2]
        end
        for c = used + 1, #b.cells do b.cells[c]:Hide() end
      end
    end
  end
  SyncBar(math.min(n, #list))
end

local function CharName(key)
  for _, c in ipairs(W.Characters()) do
    if c.key == key or (key == nil and c.me) then
      local col = c.class and RAID_CLASS_COLORS[c.class]
      return col and col:WrapTextInColorCode(c.name) or c.name, c
    end
  end
  return UnitName("player")
end

local function EmptyText(sum, isMe)
  local tab = state.tab
  if sum.missing then
    if not (Syndicator and Syndicator.API) then
      return "Only your bags and gear can be read without Syndicator (it comes with "
        .. "Baganator). Install it to see your bank, mail and alts here."
    end
    return "Nothing recorded for this character yet: log in on them once."
  end
  if tab == "bank" then
    return isMe and "Nothing recorded in your bank yet. Open it at a banker once and it is "
      .. "remembered from then on." or "Nothing recorded in their bank."
  elseif tab == "mail" then
    return isMe and "No mail recorded. Open a mailbox to update it." or "No mail recorded."
  elseif tab == "bags" then
    return "The bags are empty."
  elseif tab == "equipped" then
    return "Nothing equipped."
  end
  return "Nothing recorded for this character yet."
end

local function Footer(sum)
  local parts = { ("%d items in %d slots"):format(sum.count, sum.slots) }
  if sum.unpriced > 0 then parts[#parts + 1] = sum.unpriced .. " without a price" end
  local tab = state.tab
  local _, c = CharName(charKey)
  local isMe = not c or c.me
  frame.empty:SetShown(#list == 0)
  frame.empty:SetText(#list == 0 and EmptyText(sum, isMe) or "")
  if sum.missing then
    parts = {}
  elseif (tab == "bank" or tab == "all") and isMe and not W.BankOpen() then
    parts[#parts + 1] = "bank as last seen"
  elseif not isMe then
    parts[#parts + 1] = "as at their last logout"
  end
  if not state.detail then parts[#parts + 1] = "Shift: more" end
  frame.footer:SetText(Hex(DIM, table.concat(parts, "  ·  ")))
end

local function Header()
  local s = W.Summary(charKey)
  for i, tab in ipairs(TABS) do
    local t = frame.tabs[i]
    local v = tab == "all" and s.items or (s[tab] and s[tab].value)
    t:SetText(TAB_NAME[tab] .. (v and v > 0 and (" " .. M.Money(v)) or ""))
    PanelTemplates_TabResize(t, 0)
  end
  PanelTemplates_SetTab(frame, tIndexOf(TABS, state.tab))
  -- colour codes don't nest: each dim piece closes before the next money
  frame.worth:SetText("Worth " .. M.Money(s.total) .. "  " .. Hex(DIM, "(items ")
    .. M.Money(s.items, DIM, DIM) .. Hex(DIM, ", gold ") .. M.Money(s.money, DIM, DIM)
    .. Hex(DIM, ")"))
end

function UI.Refresh()
  if not (frame and frame:IsShown()) then return end
  frame:SetWidth(ListWidth() + CHROME)
  frame.detailBox:SetChecked(state.detail == true)
  frame.charMenu:GenerateMenu()
  local sum
  list, sum = Build()
  Header()
  Footer(sum)
  Draw()
end

-- events come in bursts (a loot window empties into the bags): one redraw per frame
local pending
function UI.Changed()
  if pending or not (frame and frame:IsShown()) then return end
  pending = true
  C_Timer.After(0.2, function()
    pending = false
    UI.Refresh()
  end)
end

------------------------------------------------------------------------------ Frame
local function TabTip(self)
  GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
  GameTooltip:SetText(TAB_NAME[self.key])
  GameTooltip:AddLine(TAB_TIP[self.key], 1, 1, 1, true)
  if charKey then GameTooltip:AddLine("Alts: as at their last logout.", 0.6, 0.6, 0.6) end
  GameTooltip:Show()
end

local function Tab(i, key)
  local t = CreateFrame("Button", "MeionomicsWorthFrameTab" .. i, frame, "PanelTabButtonTemplate")
  t:SetID(i)
  t:SetText(TAB_NAME[key])
  t.key = key
  -- replaces Blizzard's, which only shows a truncated label
  t:SetScript("OnEnter", TabTip)
  t:SetScript("OnLeave", GameTooltip_Hide)
  if i == 1 then
    t:SetPoint("TOPLEFT", frame, "BOTTOMLEFT", 12, 2)
  else
    t:SetPoint("LEFT", frame.tabs[i - 1], "RIGHT", 3, 0)
  end
  t:SetScript("OnClick", function()
    PlaySound(SOUNDKIT.IG_CHARACTER_INFO_TAB)
    state.tab, offset = key, 0
    UI.Refresh()
  end)
  return t
end

-- saved free position, else centred
local function Place()
  frame:ClearAllPoints()
  if state.at then
    frame:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", state.at[1], state.at[2])
  else
    frame:SetPoint("CENTER")
  end
end

local function Create()
  frame = CreateFrame("Frame", "MeionomicsWorthFrame", UIParent, "ButtonFrameTemplate")
  ButtonFrameTemplate_HidePortrait(frame)
  if ButtonFrameTemplate_HideButtonBar then ButtonFrameTemplate_HideButtonBar(frame) end
  frame:SetTitle("Worth")
  frame:SetSize(ListWidth() + CHROME, H)
  Place()
  frame:SetFrameStrata("MEDIUM")
  frame:SetToplevel(true)
  frame:EnableMouse(true)
  frame:SetMovable(true)
  frame:SetClampedToScreen(true)
  frame:RegisterForDrag("LeftButton")
  frame:SetScript("OnDragStart", function(self) self:StartMoving() end)
  frame:SetScript("OnDragStop", function(self)
    self:StopMovingOrSizing()
    self:SetUserPlaced(false)   -- saved in state.at, not the client's layout cache
    local left, top = self:GetLeft(), self:GetTop()
    if left and top then
      state.at = { math.floor(left + 0.5), math.floor(top + 0.5) }
      Place()
    end
  end)
  tinsert(UISpecialFrames, frame:GetName())
  frame.tabs = {}
  for i, key in ipairs(TABS) do frame.tabs[i] = Tab(i, key) end
  PanelTemplates_SetNumTabs(frame, #TABS)

  frame.Inset:ClearAllPoints()
  frame.Inset:SetPoint("TOPLEFT", 8, LIST_TOP)
  frame.Inset:SetPoint("BOTTOMRIGHT", -8, LIST_BOTTOM)
  frame.list = CreateFrame("Frame", nil, frame.Inset)
  frame.list:SetPoint("TOPLEFT", 4, -3)
  frame.list:SetPoint("BOTTOMRIGHT", -18, 3)
  frame.list:EnableMouseWheel(true)
  frame.list:SetScript("OnMouseWheel", function(_, delta)
    offset = offset - delta * 3
    Draw()
  end)
  -- the inset's marble texture is light enough to wash out small grey text
  local shade = frame.Inset:CreateTexture(nil, "BACKGROUND", nil, 7)
  shade:SetColorTexture(0, 0, 0, 0.45)
  shade:SetPoint("TOPLEFT", 3, -3)
  shade:SetPoint("BOTTOMRIGHT", -3, 3)
  frame.empty = frame.list:CreateFontString(nil, "ARTWORK", "GameFontNormal")
  frame.empty:SetPoint("TOPLEFT", 24, -40)
  frame.empty:SetPoint("TOPRIGHT", -24, -40)
  frame.empty:SetSpacing(3)
  frame.empty:Hide()
  frame.bar = CreateFrame("EventFrame", nil, frame.Inset, "MinimalScrollBar")
  frame.bar:SetPoint("TOPRIGHT", -6, -6)
  frame.bar:SetPoint("BOTTOMRIGHT", -6, 6)
  frame.bar:SetHideIfUnscrollable(true)
  frame.bar:RegisterCallback(frame.bar.Event.OnScroll, function(_, pct)
    if syncing then return end
    local extra = #list - Visible()
    if extra <= 0 then return end
    offset = math.floor(pct * extra + 0.5)
    Draw()
  end, frame)
  frame.heads = {}

  frame.charMenu = CreateFrame("DropdownButton", nil, frame, "WowStyle1DropdownTemplate")
  frame.charMenu:SetWidth(170)
  frame.charMenu:SetPoint("TOPLEFT", 12, -30)
  frame.charMenu:SetupMenu(function(_, root)
    for _, c in ipairs(W.Characters()) do
      local col = c.class and RAID_CLASS_COLORS[c.class]
      local name = col and col:WrapTextInColorCode(c.name) or c.name
      local key = c.me and nil or c.key
      root:CreateRadio(name .. "  " .. M.Money(W.Summary(c.key).total),
        function() return charKey == key end,
        function() UI.Show(key) end)
    end
  end)
  frame.charMenu:SetSelectionText(function() return (CharName(charKey)) end)
  frame.charMenu:HookScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:SetText("Character")
    GameTooltip:AddLine("Any character Syndicator has seen, with all they own, gold included.",
      1, 1, 1, true)
    GameTooltip:Show()
  end)
  frame.charMenu:HookScript("OnLeave", GameTooltip_Hide)
  frame.worth = frame:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
  frame.worth:SetPoint("LEFT", frame.charMenu, "RIGHT", 12, 0)
  frame.detailBox = CreateFrame("CheckButton", nil, frame, "UICheckButtonTemplate")
  frame.detailBox:SetSize(22, 22)
  frame.detailBox:SetPoint("BOTTOMRIGHT", -58, 4)
  frame.detailBox.label = frame.detailBox:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
  frame.detailBox.label:SetPoint("LEFT", frame.detailBox, "RIGHT", 0, 1)
  frame.detailBox.label:SetText("Detail")
  frame.detailBox:SetScript("OnClick", function(self)
    state.detail = self:GetChecked() or nil
    UI.Refresh()
  end)
  frame.detailBox:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:SetText("Detail")
    GameTooltip:AddLine("Best way to sell, vendor and AH prices, region sales. Shift shows them "
      .. "while held.", 1, 1, 1, true)
    GameTooltip:Show()
  end)
  frame.detailBox:SetScript("OnLeave", GameTooltip_Hide)
  frame.footer = frame:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
  frame.footer:SetPoint("BOTTOMLEFT", 14, 10)
  frame.footer:SetPoint("BOTTOMRIGHT", -84, 10)
  frame.footer:SetJustifyH("LEFT")
  frame.footer:SetWordWrap(false)
  frame:SetScript("OnShow", UI.Refresh)
  frame:SetScript("OnHide", function(self)
    docked = nil
    self:SetFrameStrata("MEDIUM")
  end)
  frame:Hide()
end

-- key: a Syndicator character key (W.Characters), nil for this character; tab: one of TABS;
-- near: a frame to open under (or over, without room), in its strata: AltView sits at DIALOG
function UI.Show(key, tab, near)
  if not frame then Create() end
  charKey = not W.IsMe(key) and key or nil
  if tab then state.tab = tab end
  offset = 0
  if frame:IsShown() then
    UI.Refresh()
  else
    if not near then Place() end
    frame:Show()
  end
  if near then
    frame:SetFrameStrata(near:GetFrameStrata())
    frame:ClearAllPoints()
    local room = (near:GetBottom() or 0) - (UIParent:GetBottom() or 0)
    if room >= frame:GetHeight() + 30 then
      frame:SetPoint("TOP", near, "BOTTOM", 0, -4)
    else
      frame:SetPoint("BOTTOM", near, "TOP", 0, 4)
    end
  end
  frame:Raise()
end

function UI.Toggle(key, tab)
  if frame and frame:IsShown() and charKey == key and (not tab or tab == state.tab) then
    return frame:Hide()
  end
  UI.Show(key, tab)
end

------------------------------------------------------------------------------ Bank
-- Baganator's bank view (its name carries a skin's frame group), else Blizzard's
local function BankWindow()
  for _, name in ipairs(UISpecialFrames) do
    local f = name:match("^Baganator_.*BankView") and _G[name]
    if f and f:IsShown() then return f end
  end
  if BankFrame and BankFrame:IsShown() then return BankFrame end
end

local function Dock(window)
  frame:ClearAllPoints()
  local scale = window:GetEffectiveScale() / UIParent:GetEffectiveScale()
  local right = (window:GetRight() or 0) * scale
  if right + frame:GetWidth() + 4 <= (UIParent:GetRight() or 1920) then
    frame:SetPoint("TOPLEFT", window, "TOPRIGHT", 4, 0)
  else
    frame:SetPoint("TOPRIGHT", window, "TOPLEFT", -4, 0)
  end
end

M.On("BANKFRAME_OPENED", function()
  if state.bank == false then return end
  -- bank views show a frame after the event
  C_Timer.After(0.1, function()
    if not W.BankOpen() then return end
    local window = BankWindow()
    local was = frame and frame:IsShown()
    UI.Show(nil, "bank")
    if window and not was then
      Dock(window)
      docked = true
    end
  end)
end)
M.On("BANKFRAME_CLOSED", function()
  if docked and frame then frame:Hide() end
  UI.Changed()
end)

for _, e in ipairs({ "BAG_UPDATE_DELAYED", "PLAYERBANKSLOTS_CHANGED", "PLAYER_EQUIPMENT_CHANGED",
  "PLAYER_MONEY", "GET_ITEM_INFO_RECEIVED" }) do
  pcall(M.On, e, UI.Changed)
end
M.On("MODIFIER_STATE_CHANGED", function(_, key)
  if (key == "LSHIFT" or key == "RSHIFT") and not state.detail then UI.Changed() end
end)

local prevOnLoad = M.OnLoad
function M.OnLoad()
  if prevOnLoad then prevOnLoad() end
  M.db.worth = M.db.worth or {}
  state = M.db.worth
  if not tContains(TABS, state.tab) then state.tab = "bags" end
end

M.OnReset(function()
  state.at = nil
  if frame and frame:IsShown() and not docked then Place() end
end)

-- /meio worth [bags|bank|gear|mail|all], /meio worth bank on|off
M.commands.worth = function(rest)
  local word, arg = (rest or ""):lower():match("^(%S*)%s*(%S*)")
  if word == "bank" and (arg == "on" or arg == "off") then
    state.bank = arg == "off" and false or nil
    return M.Print("Worth window beside the bank " .. M.OnOff(arg == "on"))
  end
  local tab = word == "gear" and "equipped" or (word ~= "" and word or nil)
  if tab and not tContains(TABS, tab) then
    return M.Print("/meio worth [bags||bank||gear||mail||all], /meio worth bank on||off")
  end
  UI.Toggle(nil, tab)
end
