-- "Meionomics" tab in Blizzard's AuctionHouseFrame (the Auctionator model): our own Browse.
-- Views (B.VIEWS) share the list, headers and search:
--   items     Blizzard's browse query, then one item search per item found, so every auction
--             shows with its seller: price each, % of market and of the Evidence safe price,
--             confidence, quantity, seller, region sales, the gain from buying it to vendor.
--             "Below X% of market" and "Below vendor" hide the rest (either one keeps a row).
--             Buyout buys the selected row through Blizzard's own confirmation.
--   patterns  AuctionPatterns.lua
-- Prices are this realm's; sales are the region's (the only measured ones).
local _, M = ...
local P = M.Prices
local B = {}
M.AuctionBrowse = B

local ROW_H, MAX_ITEMS = 20, 60

local function C(key, text) return "|cff" .. M.Tooltip.style[key] .. text .. "|r" end
local function Hex(hex, text) return "|cff" .. hex .. text .. "|r" end
B.C, B.Hex = C, Hex

-- TSM's colours for a % of market (LibTSMService Theme AUCTION_PCT_COLORS): blue under 50,
-- green under 80, yellow under 110, orange under 135, red above
local PCT_BANDS = { { 50, "2076f7" }, { 80, "4ff720" }, { 110, "e1f720" }, { 135, "f77a20" },
  { math.huge, "f72d20" } }
function B.Pct(p)
  if not p then return C("dim", "-") end
  local text = p > 999 and ">999%" or ("%d%%"):format(math.floor(p + 0.5))
  for _, band in ipairs(PCT_BANDS) do
    if p < band[1] then return Hex(band[2], text) end
  end
end

local LEVEL = { high = { 1, "good", "High" }, medium = { 2, "warn", "Medium" },
  low = { 3, "bad", "Low" } }

------------------------------------------------------------------------------ Hover help
-- { title, line, more } (more on Shift), or fn(widget) returning one; as CraftUI's controls
local LABEL, MUTED = NORMAL_FONT_COLOR or { r = 1, g = 0.82, b = 0 }, "999999"
local function ShowHelp(self)
  local h = self.meioHelp
  if type(h) == "function" then h = h(self) end
  if not h then return end
  GameTooltip:SetOwner(self, self.meioAnchor or "ANCHOR_TOP")
  GameTooltip:SetText(h[1], 1, 1, 1)
  if h[2] then GameTooltip:AddLine(h[2], LABEL.r, LABEL.g, LABEL.b, true) end
  if h[3] and IsShiftKeyDown() then
    GameTooltip:AddLine(h[3], 0.8, 0.8, 0.8, true)
  elseif h[3] then
    M.Tooltip.ShiftHint(GameTooltip)
  end
  GameTooltip:Show()
end

function B.Help(widget, help, anchor)
  widget.meioHelp, widget.meioAnchor = help, anchor
  if widget.meioHelpHooked then return end
  widget.meioHelpHooked = true
  if widget.SetMotionScriptsWhileDisabled then widget:SetMotionScriptsWhileDisabled(true) end
  widget:HookScript("OnEnter", ShowHelp)
  widget:HookScript("OnLeave", GameTooltip_Hide)
end

M.On("MODIFIER_STATE_CHANGED", function(_, key)
  if not (key == "LSHIFT" or key == "RSHIFT") then return end
  local owner = GameTooltip:IsShown() and GameTooltip:GetOwner()
  if owner and owner.meioHelp and owner:IsMouseOver() then ShowHelp(owner) end
end)

------------------------------------------------------------------------------ Data
-- state.rows: what the search found, state.shown: after the view's filter, sorted
local state = { rows = {}, shown = {}, queue = {}, offset = 0, view = "items" }
B.state = state
B.VIEWS = {}
B.onBuild = {}   -- fn(panel): later files' extra controls

-- unit: buyoutAmount read as per item, as the workbench emulates it (unconfirmed in game).
-- buyout: buyoutAmount as given, which is what Blizzard's Buy tab pays, whichever it is.
-- ev: P.Evidence, once per item per search
local evidence = {}
function B.Row(key, r)
  local id = key.itemID
  local market = P.Get(id, "market")
  if evidence[id] == nil then evidence[id] = P.Evidence(id) or false end
  local ev = evidence[id] or nil
  local owner = r.owners and r.owners[1]
  local mine = r.containsOwnerItem or owner == "player"
  local sells = P.SellRate(id) or {}
  local extra = (r.totalNumberOfOwners or 1) - 1
  local name, _, quality = C_Item.GetItemInfo(r.itemLink or id)
  -- Forever names can carry a surname; the column has room for the first
  local seller = mine and (UnitName("player") or ""):match("^%S+") or owner or "?"
  local unit = r.buyoutAmount
  -- Evidence's safe price without the fresh min buyout: the min is the cheapest listing, so
  -- with it that row always read 100%
  local region = ev and (ev.regionSale or ev.regionMarket)
  local safe = ev and math.min(ev.market or math.huge, region or math.huge)
  if safe == math.huge then safe = nil end
  return { key = key, itemID = id, link = r.itemLink, name = name or ("item " .. id),
    quality = quality or 1, unit = unit, qty = r.quantity or 1,
    seller = seller .. (extra > 0 and (" +" .. extra) or ""), mine = mine, market = market,
    pct = (market and unit) and unit / market * 100 or nil,
    safe = safe, pctSafe = (safe and safe > 0 and unit) and unit / safe * 100 or nil,
    level = ev and ev.level, levelRank = ev and LEVEL[ev.level][1],
    sold = sells.perDay, rate = sells.rate, auctionID = r.auctionID, buyout = unit,
    flip = not mine and P.FlipGain(P.Get(id, "vendor"), unit) or nil, commodity = r.commodity }
end

function B.CanBuy(r) return r and r.auctionID and r.buyout and not r.mine and true or false end

------------------------------------------------------------------------------ Commodities
-- Stackable goods are commodities on Forever's AH (TSM treats them so too): SendSearchQuery is
-- answered by COMMODITY_SEARCH_RESULTS_UPDATED, and they're bought by quantity, cheapest
-- first, not by auction. StartCommoditiesPurchase (needs a click) gets the server's quote,
-- then ConfirmCommoditiesPurchase buys; a quote over expect x QUOTE_SLACK (sold meanwhile) is
-- cancelled instead and the item searched again.
local QUOTE_SLACK = 1.1
local QUOTE_WAIT = 10
local commodity   -- { itemID, qty, expect, done = fn(ok, c) }

function B.Commodity() return commodity end

local function EndCommodity(ok)
  local c = commodity
  if not c then return end
  commodity = nil
  if not ok then pcall(C_AuctionHouse.CancelCommoditiesPurchase) end
  if c.done then c.done(ok, c) end
  B.Refresh()
end

function B.BuyCommodity(itemID, qty, expect, done)
  if commodity or qty <= 0 then return end
  local c = { itemID = itemID, qty = qty, expect = expect, done = done }
  commodity = c
  C_AuctionHouse.StartCommoditiesPurchase(itemID, qty)
  C_Timer.After(QUOTE_WAIT, function() if commodity == c then EndCommodity(false) end end)
  B.Refresh()
end

M.On("COMMODITY_PRICE_UPDATED", function(_, _, total)
  local c = commodity
  if not c or c.total then return end
  local name = C_Item.GetItemNameByID(c.itemID) or ("item " .. c.itemID)
  if c.expect and total > c.expect * QUOTE_SLACK then
    M.Print(("%d %s now cost %s, not %s: not bought, searching it again"):format(c.qty, name,
      M.Money(total), M.Money(c.expect)))
    EndCommodity(false)
    return B.Research(c.itemID)
  end
  if GetMoney() < total then
    M.Print(("not enough gold for %d %s (%s)"):format(c.qty, name, M.Money(total)))
    return EndCommodity(false)
  end
  c.total = total
  C_AuctionHouse.ConfirmCommoditiesPurchase(c.itemID, c.qty)
end)
M.On("COMMODITY_PRICE_UNAVAILABLE", function() EndCommodity(false) end)
M.On("COMMODITY_PURCHASE_SUCCEEDED", function() EndCommodity(true) end)
M.On("COMMODITY_PURCHASE_FAILED", function() EndCommodity(false) end)

-- Blizzard's own buyout: its confirmation popup with the amount, then PlaceBid on Accept;
-- a commodity row buys its quantity (the cheapest units, so never dearer than the row)
function B.Buy(r)
  if not B.CanBuy(r) then return end
  if r.commodity then
    return B.BuyCommodity(r.itemID, r.qty, r.unit * r.qty, function(ok)
      if not ok then return end
      for i, x in ipairs(state.rows) do
        if x == r then table.remove(state.rows, i) break end
      end
      if state.selected == r then state.selected = nil end
    end)
  end
  state.buying = r.auctionID
  AuctionHouseFrame:StartItemBuyout(r.auctionID, r.buyout)
end

M.On("AUCTION_HOUSE_PURCHASE_COMPLETED", function(_, auctionID)
  if auctionID ~= state.buying then return end
  state.buying = nil
  for i, r in ipairs(state.rows) do
    if r.auctionID == auctionID then
      table.remove(state.rows, i)
      if state.selected == r then state.selected = nil end
      break
    end
  end
  B.Refresh()
end)

-- nil sorts last either way, so rows without a value never crowd the top
local function Less(a, b, key, desc)
  local x, y = a[key], b[key]
  if x == nil or y == nil then
    if x ~= nil then return true end
    if y ~= nil then return false end
    return (a.unit or 0) < (b.unit or 0)
  end
  if x == y then return (a.unit or 0) < (b.unit or 0) end
  if type(x) == "string" then x, y = x:lower(), y:lower() end
  if desc then return x > y end
  return x < y
end

function B.View() return B.VIEWS[state.view] end

function B.Refresh()
  local view = B.View()
  if view.Prepare then view.Prepare(state.rows) end
  local shown = {}
  for _, r in ipairs(state.rows) do
    if not view.Keep or view.Keep(r) then shown[#shown + 1] = r end
  end
  local cmp = view.compare and view.compare[state.sort]
  table.sort(shown, function(a, b)
    if cmp then return cmp(a, b, state.desc) end
    return Less(a, b, state.sort, state.desc)
  end)
  state.shown = shown
  local vis = B.visible or 1
  -- the row the view acts on next is scrolled to the top row when it changes; between changes
  -- the list stays where the wheel left it
  local focus = view.Focus and view.Focus(shown)
  if focus ~= state.focus then
    state.focus = focus
    for i, r in ipairs(shown) do
      if r == focus then
        state.offset = i - 1
        break
      end
    end
  end
  state.offset = math.max(0, math.min(state.offset or 0, #shown - vis))
  if B.panel then B.Draw() end
end

------------------------------------------------------------------------------ Searching
-- Blizzard throttles item searches: one at a time, the next when the answer is in, or after
-- SEARCH_WAIT without one. A throttled query is dropped with no answer, and the READY event
-- can be missed (e.g. a /reload mid-wait), so waits for either are polled too.
local SEARCH_WAIT = 5
local BROWSE_WAIT = 10
local function Next()
  local key = table.remove(state.queue, 1)
  state.current = key
  if not key then
    state.busy = false
    B.Refresh()
    return
  end
  if not C_AuctionHouse.IsThrottledMessageSystemReady() then
    table.insert(state.queue, 1, key)
    local wait = {}
    state.current, state.waitThrottle = nil, wait
    C_Timer.After(1, function()
      if state.waitThrottle == wait then
        state.waitThrottle = false
        Next()
      end
    end)
    return
  end
  state.read = state.read + 1
  C_AuctionHouse.SendSearchQuery(key, { { sortOrder = Enum.AuctionHouseSortOrder.Price,
    reverseSort = false } }, true)
  C_Timer.After(SEARCH_WAIT, function() if state.current == key then Next() end end)
  if B.panel then B.Draw() end
end

local function SameKey(a, b)
  return a and b and a.itemID == b.itemID and (a.itemLevel or 0) == (b.itemLevel or 0)
    and (a.itemSuffix or 0) == (b.itemSuffix or 0)
end

local function Reset(text)
  state.rows, state.queue, state.read, state.items = {}, {}, 0, 0
  state.text, state.offset, state.selected, state.more = text, 0, nil, false
  wipe(evidence)
  if B.View().OnSearch then B.View().OnSearch() end
end

function B.Search(text)
  if B.View().keysOnly then B.SetView("items") end
  Reset(text)
  state.busy, state.waitBrowse = true, true
  C_AuctionHouse.SendBrowseQuery({ searchString = text or "", filters = {},
    itemClassFilters = B.View().classFilters or {}, sorts = { { sortOrder =
    Enum.AuctionHouseSortOrder.Price, reverseSort = false } } })
  local search = state.queue
  state.heard = GetTime()
  local function Check()
    if not (state.waitBrowse and state.queue == search) then return end
    local quiet = GetTime() - state.heard
    if quiet < BROWSE_WAIT then return C_Timer.After(BROWSE_WAIT - quiet, Check) end
    state.waitBrowse, state.busy = false, false
    M.Print("the AH didn't answer the search (busy or throttled): search again")
    B.Refresh()
  end
  C_Timer.After(BROWSE_WAIT, Check)
  B.Refresh()
end

-- the auctions of given items (a pattern picked in the Patterns view)
function B.SearchKeys(keys, label)
  Reset(label)
  state.busy, state.waitBrowse = true, false
  for _, k in ipairs(keys) do state.queue[#state.queue + 1] = k end
  state.items = #keys
  B.Refresh()
  Next()
end

-- an item's listings went stale (a buy quoted dearer): its rows are read again in place.
-- Only for items read one by one; a browse list has no rows of their auctions
function B.Research(itemID)
  local found
  for i = #state.rows, 1, -1 do
    if state.rows[i].itemID == itemID then
      if state.selected == state.rows[i] then state.selected = nil end
      table.remove(state.rows, i)
      found = true
    end
  end
  if not found then return end
  state.queue[#state.queue + 1] = C_AuctionHouse.MakeItemKey(itemID)
  -- the item was counted when first read
  state.read = state.read - 1
  if state.busy then return B.Refresh() end
  state.busy = true
  B.Refresh()
  Next()
end

-- a view with FromBrowse lists browse results as they are (one row per item, all pages);
-- items reads each item's auctions
local function BrowseResults()
  if not state.waitBrowse then return end
  state.heard = GetTime()
  local view, results = B.View(), C_AuctionHouse.GetBrowseResults()
  if view.FromBrowse then
    if C_AuctionHouse.HasFullBrowseResults and not C_AuctionHouse.HasFullBrowseResults() then
      state.items = #results
      C_AuctionHouse.RequestMoreBrowseResults()
      if B.panel then B.Draw() end
      return
    end
    state.waitBrowse, state.busy = false, false
    state.rows, state.items = view.FromBrowse(results), #results
    B.Refresh()
    return
  end
  state.waitBrowse = false
  for i, r in ipairs(results) do
    if i > MAX_ITEMS then break end
    state.queue[#state.queue + 1] = r.itemKey
  end
  state.items, state.more = #state.queue, #results > MAX_ITEMS
  Next()
end
M.On("AUCTION_HOUSE_BROWSE_RESULTS_UPDATED", BrowseResults)
M.On("AUCTION_HOUSE_BROWSE_RESULTS_ADDED", BrowseResults)

M.On("ITEM_SEARCH_RESULTS_UPDATED", function(_, key)
  if not SameKey(key, state.current) then return end
  for i = 1, C_AuctionHouse.GetNumItemSearchResults(key) do
    local r = C_AuctionHouse.GetItemSearchResultInfo(key, i)
    if r and r.buyoutAmount and r.buyoutAmount > 0 and r.buyoutAmount <= M.MAX_COPPER then
      state.rows[#state.rows + 1] = B.Row(key, r)
    end
  end
  B.Refresh()
  Next()
end)

-- the row's own units are left out: they can't be bought, and a row only of them is ours
M.On("COMMODITY_SEARCH_RESULTS_UPDATED", function(_, itemID)
  local key = state.current
  if not (key and key.itemID == itemID) then return end
  for i = 1, C_AuctionHouse.GetNumCommoditySearchResults(itemID) do
    local r = C_AuctionHouse.GetCommoditySearchResultInfo(itemID, i)
    if r and r.unitPrice and r.unitPrice > 0 and r.unitPrice <= M.MAX_COPPER then
      local own = r.numOwnerItems or 0
      local qty = r.quantity - own
      state.rows[#state.rows + 1] = B.Row(key, { commodity = true, auctionID = r.auctionID,
        buyoutAmount = r.unitPrice, quantity = qty > 0 and qty or r.quantity,
        containsOwnerItem = qty <= 0, owners = r.owners,
        totalNumberOfOwners = r.totalNumberOfOwners })
    end
  end
  B.Refresh()
  Next()
end)

M.On("AUCTION_HOUSE_THROTTLED_SYSTEM_READY", function()
  if state.waitThrottle then
    state.waitThrottle = false
    Next()
  end
end)

M.On("AUCTION_HOUSE_CLOSED", function()
  state.queue, state.current, state.busy, state.waitBrowse = {}, nil, false, false
  state.waitThrottle = false
  commodity = nil
end)

------------------------------------------------------------------------------ Items view
-- shared with the other views' columns
B.ROW_TIP = "Hover a row for the item; click to select, double-click to buy"
B.PCT_TIP = "Price as % of this realm's market value"
B.PCT_MORE = "Blue under 50%, green under 80%, yellow under 110%, orange, then red over 135% "
  .. "(TSM's colours). A dash: no market value yet (no TSM price, and Meionomics' own AH scan "
  .. "hasn't seen it)."
B.SELLER_TIP = "Who listed it; +N: more sellers at this price. Yours in gold."

local function Sold(r)
  if not r.sold then return C("dim", "-") end
  local rate = r.rate and C("grey", (" %d%%"):format(math.floor(r.rate * 100 + 0.5))) or ""
  return M.Count(r.sold) .. C("grey", "/day") .. rate
end

local function Level(r)
  local lv = r.level and LEVEL[r.level]
  return lv and C(lv[2], lv[3]) or C("dim", "-")
end

B.VIEWS.items = {
  sort = "pct",
  columns = {
    { key = "name", title = "Item", width = 0, tip = B.ROW_TIP },
    { key = "unit", title = "Price each", width = 104, right = true, tip = "Buyout for one",
      text = function(r) return M.Money(r.unit) end },
    { key = "pct", title = "% Mkt", width = 62, right = true, tip = B.PCT_TIP, more = B.PCT_MORE,
      text = function(r) return B.Pct(r.pct) end },
    { key = "pctSafe", title = "% Safe", width = 62, right = true,
      tip = "Price each as % of the safe price",
      more = "Safe price: the lower of this realm's market value and the region's sale "
        .. "average. The cheapest listing is left out: that is these auctions.",
      text = function(r) return B.Pct(r.pctSafe) end },
    { key = "levelRank", title = "Conf", width = 62, tip = "How far to trust this realm's price",
      more = "High, Medium or Low. Hover a row and hold Shift for why.",
      text = Level },
    { key = "flip", title = "Vendor +", width = 72, right = true, desc = true,
      tip = "Gain on each from buying it here and selling it to a vendor",
      more = "Only shown when it's worth it. Tick Below vendor to list only these.",
      text = function(r) return r.flip and C("good", "+" .. M.Money(r.flip)) or C("dim", "-") end },
    { key = "qty", title = "Qty", width = 40, right = true, tip = "How many in the auction",
      text = function(r) return r.qty end },
    { key = "seller", title = "Seller", width = 100, tip = B.SELLER_TIP,
      text = function(r) return r.mine and C("accent", r.seller) or r.seller end },
    { key = "sold", title = "Region/day", width = 98, right = true, desc = true,
      tip = "Sold per day across the region, and the share of listings that sell",
      more = "TSM's region data. No figure exists for this realm alone.",
      text = Sold },
  },
  Keep = function(r)
    local below, flip = M.db.browseBelow, M.db.browseFlip
    if not (below or flip) then return true end
    return (below and r.pct and r.pct < below) or (flip and r.flip) and true or false
  end,
  status = function(n)
    return ("%d auctions of %d items"):format(#state.rows, state.items)
      .. (n > 0 and (", %d hidden by the filter"):format(n) or "")
      .. (state.more and (", first %d items only"):format(MAX_ITEMS) or "")
  end,
  reading = function() return ("Reading item %d of %d"):format(state.read, state.items) end,
  empty = "Type an item name and press Enter; an empty search lists everything up",
  welcome = function()
    local text = C("accent", "Search the auction house") .. "\n\nType part of an item name and "
      .. "press Enter, or search with the box empty to list everything up (the first "
      .. MAX_ITEMS .. " items).\nTick Below to see only bargains.\n\nShopping list: buy what "
      .. "your craft queue needs.  BiS upgrades: gear that beats what you wear.\nSell from bags: "
      .. "post what you carry at Meionomics' price, one key press each."
    if not P.Source() then
      text = text .. "\n\n" .. C("warn", "No prices yet:") .. " Meionomics reads them from TSM, "
        .. "or from its own scan when you open the AH (/meio autoscan)."
    end
    return text
  end,
  hidden = function(n)
    local below = M.db.browseBelow
    local what = below and ("Nothing under %d%% of market"):format(below) or "Nothing"
    if M.db.browseFlip then what = what .. (below and " or" or "") .. " below vendor" end
    return ("%s among these %d auctions.\nUntick the filters, or raise the %%."):format(what, n)
  end,
  action = { text = BUYOUT or "Buyout", enabled = function(r) return B.CanBuy(r) end,
    run = function(r) B.Buy(r) end,
    help = function(r)
      local title = BUYOUT or "Buyout"
      local more = "Blizzard asks you to confirm the price first. Double-clicking a row "
        .. "does the same."
      if not r then return { title, "Select an auction in the list first", more } end
      if r.mine then return { title, "That auction is yours" } end
      return { title, "Buy the selected auction", more }
    end },
}

------------------------------------------------------------------------------ Panel
local function Cells(row, view, name)
  local cells = {}
  local cols = view.columns
  for i, col in ipairs(cols) do
    local right = 0
    for j = i + 1, #cols do right = right + cols[j].width end
    local fs = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    fs:SetJustifyH(col.right and "RIGHT" or "LEFT")
    fs:SetWordWrap(false)
    if col.width == 0 then
      fs:SetPoint("LEFT", row, "LEFT", 26, 0)
      fs:SetPoint("RIGHT", row, "RIGHT", -right - 8, 0)
    else
      fs:SetPoint("RIGHT", row, "RIGHT", -right - (col.right and 8 or 0), 0)
      fs:SetWidth(col.width - 8)
    end
    cells[col.key] = fs
  end
  row.cells[name] = cells
end

local function FillRow(row, r, i)
  local view = B.View()
  row.data = r
  row.stripe:SetAtlas(i % 2 == 1 and "auctionhouse-rowstripe-1" or "auctionhouse-rowstripe-2")
  row.icon:SetTexture(C_Item.GetItemIconByID(r.itemID))
  for name, cells in pairs(row.cells) do
    for _, fs in pairs(cells) do fs:SetShown(name == state.view) end
  end
  local cells = row.cells[state.view]
  for _, col in ipairs(view.columns) do
    if col.key == "name" and not col.text then
      local color = ITEM_QUALITY_COLORS[r.quality] or ITEM_QUALITY_COLORS[1]
      cells.name:SetText(color.hex .. r.name .. "|r")
    else
      cells[col.key]:SetText(col.text(r))
    end
  end
  -- r.faded: not buyable here now (last seen, a vendor's); r.glow: worth a look
  local alpha = r.faded and 0.5 or 1
  for _, fs in pairs(cells) do fs:SetAlpha(alpha) end
  row.icon:SetAlpha(alpha)
  row.icon:SetDesaturated(r.faded and true or false)
  row.glow:SetShown(r.glow and true or false)
  row.selected:SetShown(state.selected == r)
  row:Show()
end

-- centred in an empty list: what to do next. nil while there are rows to show.
local function Field(v, ...)
  if type(v) == "function" then return v(...) end
  return v
end

function B.ListNote(view, shown)
  if #shown > 0 then return nil end
  if state.waitBrowse or state.busy then return C("dim", "Searching the auction house...") end
  if state.text == nil then return Field(view.welcome) or Field(view.empty) end
  if #state.rows == 0 then
    if view.none then return Field(view.none, state.text) end
    if state.text == "" then return "Nothing up right now." end
    return ("Nothing up matches \"%s\".\nCheck the spelling, or search with the box empty.")
      :format(state.text)
  end
  return Field(view.hidden, #state.rows) or "Everything found is hidden by the filter."
end

function B.Draw()
  local f = B.panel
  local view, shown = B.View(), state.shown
  for i, row in ipairs(f.rows) do
    local r = shown[state.offset + i]
    if r then FillRow(row, r, state.offset + i) else row:Hide() end
  end
  for name, headers in pairs(f.headers) do
    for _, h in ipairs(headers) do
      h:SetShown(name == state.view)
      h.arrow:SetShown(h.key == state.sort)
      -- the atlas points down; Blizzard flips it for ascending
      h.arrow:SetTexCoord(0, 1, state.desc and 0 or 1, state.desc and 1 or 0)
    end
  end
  for name, filter in pairs(f.filters) do filter:SetShown(name == state.view) end
  local status
  if state.waitBrowse then
    status = "Searching..." .. (state.items > 0 and (" %d"):format(state.items) or "")
  elseif state.busy then
    status = view.reading()
  elseif state.text == nil then
    status = view.empty
  elseif #state.rows == 0 then
    status = Field(view.noneStatus) or "Nothing found"
  else
    status = view.status(#state.rows - #shown)
  end
  f.status:SetText(status)
  local note = B.ListNote(view, shown)
  f.note:SetText(note or "")
  f.note:SetShown(note ~= nil)
  if view.OnDraw then view.OnDraw(f) end
  local text = view.action.text
  if type(text) == "function" then text = text(state.selected) end
  f.action:SetText(text)
  f.action:SetWidth(math.max(100, f.action:GetTextWidth() + 30))
  f.action:SetEnabled(view.action.enabled(state.selected))
  f.patterns:SetChecked(state.view == "patterns")
  local first = #shown > 0 and state.offset + 1 or 0
  f.range:SetText(#shown > f.visible and ("%d-%d of %d"):format(first,
    math.min(state.offset + f.visible, #shown), #shown) or "")
end

function B.SetView(name)
  if state.view == name then return end
  state.view = name
  state.sort, state.desc = B.View().sort, B.View().desc or false
  Reset(nil)
  state.busy, state.waitBrowse = false, false
  B.Refresh()
end

local function Header(f, col)
  local h = CreateFrame("Button", nil, f, "ColumnDisplayButtonShortTemplate")
  h:SetHeight(19)
  h.key = col.key
  h:SetText(col.title)
  h.arrow = h:CreateTexture(nil, "OVERLAY")
  h.arrow:SetAtlas("auctionhouse-ui-sortarrow", true)
  h.arrow:SetPoint("LEFT", h:GetFontString(), "RIGHT", 3, 0)
  h:SetScript("OnClick", function()
    if state.sort == col.key then state.desc = not state.desc else
      state.sort, state.desc = col.key, col.desc or false
    end
    B.Refresh()
  end)
  B.Help(h, function()
    local sort = Hex(MUTED, "Click to sort, again to reverse")
    return { col.title, col.tip and (col.tip .. "\n" .. sort) or sort, col.more }
  end)
  return h
end

local function Row(f, i)
  local row = CreateFrame("Button", nil, f.list)
  row:SetHeight(ROW_H)
  row:SetPoint("TOPLEFT", f.list, "TOPLEFT", 3, -3 - (i - 1) * ROW_H)
  row:SetPoint("RIGHT", f.list, "RIGHT", -3, 0)
  row.stripe = row:CreateTexture(nil, "BACKGROUND")
  row.stripe:SetAllPoints()
  row.glow = row:CreateTexture(nil, "BACKGROUND", nil, 2)
  row.glow:SetAllPoints()
  row.glow:SetColorTexture(1, 0.82, 0, 0.14)
  row.glow:Hide()
  row.selected = row:CreateTexture(nil, "ARTWORK")
  row.selected:SetAtlas("auctionhouse-ui-row-select")
  row.selected:SetBlendMode("ADD")
  row.selected:SetAllPoints()
  row:SetHighlightAtlas("auctionhouse-ui-row-highlight", "ADD")
  row.icon = row:CreateTexture(nil, "ARTWORK")
  row.icon:SetSize(16, 16)
  row.icon:SetPoint("LEFT", 6, 0)
  row.cells = {}
  for name, view in pairs(B.VIEWS) do Cells(row, view, name) end
  row:SetScript("OnClick", function(self)
    state.selected = state.selected ~= self.data and self.data or nil
    B.Draw()
  end)
  row:SetScript("OnDoubleClick", function(self)
    state.selected = self.data
    local action = B.View().action
    if action.enabled(self.data) then action.run(self.data) end
  end)
  row:SetScript("OnEnter", function(self)
    if not self.data then return end
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    if self.data.link then GameTooltip:SetHyperlink(self.data.link) else
      GameTooltip:SetItemByID(self.data.itemID)
    end
    if B.View().Hover then B.View().Hover(self.data, GameTooltip) end
    GameTooltip:Show()
  end)
  row:SetScript("OnLeave", function() GameTooltip:Hide() end)
  row:Hide()
  return row
end

local function Check(f, text, anchor, x)
  local b = CreateFrame("CheckButton", nil, f, "UICheckButtonTemplate")
  b:SetSize(24, 24)
  b:SetPoint("LEFT", anchor, "RIGHT", x, 0)
  b.label = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  b.label:SetPoint("LEFT", b, "RIGHT", 1, 0)
  b.label:SetText(text)
  B.LabelClicks(b, b.label)
  return b
end

-- a check box's label clicks and hovers as the box does
function B.LabelClicks(box, label)
  box:SetHitRectInsets(0, -math.ceil(label:GetStringWidth() + 2), 0, 0)
end

-- items: [x] Below [80] % of market  [x] Below vendor
local function BelowFilter(f, anchor)
  local g = CreateFrame("Frame", nil, f)
  g:SetSize(280, 24)
  g:SetPoint("LEFT", anchor, "RIGHT", 14, 0)
  local below = CreateFrame("CheckButton", nil, g, "UICheckButtonTemplate")
  below:SetSize(24, 24)
  below:SetPoint("LEFT")
  local label = g:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  label:SetPoint("LEFT", below, "RIGHT", 1, 0)
  label:SetText("Below")
  local pct = CreateFrame("EditBox", nil, g, "InputBoxTemplate")
  pct:SetSize(34, 20)
  pct:SetAutoFocus(false)
  pct:SetNumeric(true)
  pct:SetMaxLetters(3)
  pct:SetText(tostring(M.db.browseBelowValue or 80))
  pct:SetPoint("LEFT", label, "RIGHT", 10, 0)
  local label2 = g:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  label2:SetPoint("LEFT", pct, "RIGHT", 4, 0)
  label2:SetText("% of market")
  local function Apply()
    local v = tonumber(pct:GetText()) or 80
    M.db.browseBelowValue = v
    M.db.browseBelow = below:GetChecked() and v or nil
    B.Refresh()
  end
  -- a new % in the box is a filter asked for: it ticks Below
  local function Typed(self)
    local v = tonumber(self:GetText())
    if v and v ~= (M.db.browseBelowValue or 80) then below:SetChecked(true) end
    Apply()
  end
  below:SetChecked(M.db.browseBelow ~= nil)
  below:SetScript("OnClick", Apply)
  B.LabelClicks(below, label)
  pct:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
  pct:SetScript("OnEditFocusLost", Typed)
  pct:SetScript("OnEscapePressed", function(self)
    self:SetText(tostring(M.db.browseBelowValue or 80))
    self:ClearFocus()
  end)
  B.Help(below, { "Below % of market", "Only list auctions priced under this share of their "
    .. "market value", "Set the % in the box. With Below vendor also ticked, a row matching "
    .. "either shows." })
  B.Help(pct, { "Below: % of market", "Type a percentage and press Enter: it ticks Below" })
  local flip = CreateFrame("CheckButton", nil, g, "UICheckButtonTemplate")
  flip:SetSize(24, 24)
  flip:SetPoint("LEFT", label2, "RIGHT", 12, 0)
  local label3 = g:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  label3:SetPoint("LEFT", flip, "RIGHT", 1, 0)
  label3:SetText("Below vendor")
  flip:SetChecked(M.db.browseFlip and true or false)
  flip:SetScript("OnClick", function(self)
    M.db.browseFlip = self:GetChecked() or nil
    B.Refresh()
  end)
  B.LabelClicks(flip, label3)
  B.Help(flip, { "Below vendor", "Only list auctions you can buy and sell to a vendor for more",
    "The Vendor + column shows the gain on each. With Below also ticked, a row matching "
    .. "either shows." })
  f.below, f.pct, f.flip = below, pct, flip
  return g
end

function B.Build(ah)
  local f = CreateFrame("Frame", nil, ah)
  f:SetPoint("TOPLEFT", ah, "TOPLEFT", 8, -29)
  f:SetPoint("BOTTOMRIGHT", ah, "BOTTOMRIGHT", -8, 30)
  f:Hide()
  B.panel = f

  local search = CreateFrame("EditBox", nil, f, "SearchBoxTemplate")
  search:SetSize(160, 22)
  -- clear of the portrait, which hangs over the top left
  search:SetPoint("TOPLEFT", 62, -4)
  search:SetScript("OnEnterPressed", function(self)
    self:ClearFocus()
    B.Search(self:GetText())
  end)
  f.search = search
  local go = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
  go:SetSize(80, 22)
  go:SetPoint("LEFT", search, "RIGHT", 6, 0)
  go:SetText(SEARCH or "Search")
  go:SetScript("OnClick", function() B.Search(search:GetText()) end)
  f.go = go
  local searchHelp = { "Search", "Type part of an item name and press Enter. Empty: "
    .. "everything up.", "Each item found is read one at a time (Blizzard throttles searches), "
    .. "so a broad search takes a while. The first " .. MAX_ITEMS .. " items are read." }
  B.Help(search, searchHelp)
  B.Help(go, function()
    if state.view == "patterns" then
      return { "Search patterns", "Recipe patterns matching the box; empty: every one up" }
    end
    return searchHelp
  end)

  local patterns = Check(f, "Patterns", go, 12)
  patterns:SetScript("OnClick", function(self)
    B.SetView(self:GetChecked() and "patterns" or "items")
    B.Search(search:GetText())
  end)
  B.Help(patterns, { "Patterns", "List recipe patterns on the AH, judged for your professions",
    "Each gets the Craft panel's verdict, paying its buyout to learn it. Watched patterns "
    .. "(worth learning) are starred and show even when not up. Untick for items again." })
  f.patterns = patterns

  f.filters = { items = BelowFilter(f, patterns.label) }
  for name, view in pairs(B.VIEWS) do
    if view.Filter and not f.filters[name] then f.filters[name] = view.Filter(f, patterns.label) end
  end

  local action = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
  action:SetSize(100, 22)
  action:SetPoint("TOPRIGHT", -4, -4)
  action:SetScript("OnClick", function() B.View().action.run(state.selected) end)
  B.Help(action, function()
    local a = B.View().action
    return a.help and a.help(state.selected)
  end)
  f.action, f.buy = action, action

  local list = CreateFrame("Frame", nil, f, "InsetFrameTemplate")
  list:SetPoint("TOPLEFT", 0, -52)
  list:SetPoint("BOTTOMRIGHT", 0, 20)
  local bg = list:CreateTexture(nil, "BACKGROUND", nil, 1)
  bg:SetAtlas("auctionhouse-background-index")
  bg:SetPoint("TOPLEFT", 3, -3)
  bg:SetPoint("BOTTOMRIGHT", -3, 3)
  f.list = list
  f.note = list:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
  f.note:SetPoint("CENTER", 0, 10)
  f.note:SetWidth(460)
  f.note:SetJustifyH("CENTER")
  f.note:SetSpacing(3)
  f.note:SetTextColor(0.85, 0.85, 0.85)

  f.headers = {}
  for name, view in pairs(B.VIEWS) do
    local headers, right = {}, 0
    for i = #view.columns, 1, -1 do
      local col = view.columns[i]
      local h = Header(f, col)
      h:SetPoint("BOTTOMRIGHT", list, "TOPRIGHT", -right - 3, 1)
      if col.width == 0 then
        h:SetPoint("LEFT", list, "LEFT", 3, 0)
      else
        h:SetWidth(col.width)
      end
      right = right + col.width
      table.insert(headers, 1, h)
    end
    f.headers[name] = headers
  end

  f.rows = {}
  f.visible = math.floor((f:GetHeight() - 52 - 20 - 6) / ROW_H)
  B.visible = f.visible
  for i = 1, f.visible do f.rows[i] = Row(f, i) end
  list:EnableMouseWheel(true)
  list:SetScript("OnMouseWheel", function(_, delta)
    state.offset = math.max(0, math.min(state.offset - delta * 3, #state.shown - f.visible))
    B.Draw()
  end)

  f.status = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  f.status:SetPoint("BOTTOMLEFT", 6, 4)
  f.range = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  f.range:SetPoint("BOTTOMRIGHT", -6, 4)
  f:SetScript("OnShow", B.Draw)
  state.sort, state.desc = B.View().sort, B.View().desc or false
  for _, fn in ipairs(B.onBuild) do fn(f) end
  return f
end

------------------------------------------------------------------------------ The tab
-- our display mode lists no Blizzard frames, so SetDisplayMode hides all of theirs; the hook
-- shows ours only in our mode. Hooked once every file has loaded, so views from later files
-- (AuctionPatterns.lua) are in B.VIEWS when the panel is built.
local MODE = {}
B.MODE = MODE

local function Hook()
  local ah = AuctionHouseFrame
  if not ah or ah.meioTab then return end
  local panel = B.Build(ah)
  local last = ah.Tabs[#ah.Tabs]
  -- the template's parentArray puts it in ah.Tabs
  local tab = CreateFrame("Button", "AuctionHouseFrameMeionomicsTab", ah,
    "AuctionHouseFrameDisplayModeTabTemplate")
  tab:SetText("Meionomics")
  tab.displayMode = MODE
  tab:SetPoint("LEFT", last, "RIGHT", -15, 0)
  PanelTemplates_TabResize(tab, 20, nil, 70)
  B.Help(tab, { "Meionomics", "Auctions with prices judged: bargains, your craft shopping list, "
    .. "gear upgrades and recipe patterns" })
  -- TSM's tabs (LibAHTab) hang off whichever tab was last when TSM made them: if that was
  -- before ours, both sat on Blizzard's Auctions tab, overlapping. Theirs follow ours.
  local lib = LibStub and LibStub("LibAHTab-1-0", true)
  local root = lib and lib.internalState and lib.internalState.rootFrame
  if root then
    root:ClearAllPoints()
    root:SetPoint("TOPLEFT", tab, "TOPRIGHT")
  end
  PanelTemplates_SetNumTabs(ah, #ah.Tabs)
  ah.tabsForDisplayMode[MODE] = #ah.Tabs
  ah.meioTab = tab
  hooksecurefunc(ah, "SetDisplayMode", function(self, mode)
    panel:SetShown(mode == MODE)
    if mode == MODE then self:SetTitle("Meionomics") end
  end)
end
B.Hook = Hook

M.On("ADDON_LOADED", function(_, name)
  if name == "Blizzard_AuctionHouseUI" then Hook() end
end)
M.On("PLAYER_LOGIN", function()
  if C_AddOns.IsAddOnLoaded("Blizzard_AuctionHouseUI") then Hook() end
end)
