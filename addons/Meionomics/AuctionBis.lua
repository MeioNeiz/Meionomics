-- BiS view of the Meionomics AH tab: gear on the AH that Forever Leveling BiS scores as an
-- upgrade, as a shopping list by slot. "BiS upgrades" browses usable armour and weapons,
-- scores each item with ForeverLevelingBiS_API.GetGain (random suffix included), then reads
-- the auctions of the best N items of each slot (or of the one slot picked) and of every item
-- on its wish list (starred in the BiS window). The search box works here too: what it finds
-- is scored the same way. M.db.bisSlot (nil: all), M.db.bisTop (items per slot).
local _, M = ...
local B = M.AuctionBrowse
local Cc = B.C
local Bis = {}
M.AuctionBis = Bis

local MAX_KEYS = 60 -- item searches per scan: each is a throttled AH round trip
local BROWSE_WAIT = 10
local DEFAULT_TOP, MAX_TOP = 5, 20

local SLOTS = {
  { key = "head", label = "Head", locs = { "INVTYPE_HEAD" } },
  { key = "neck", label = "Neck", locs = { "INVTYPE_NECK" } },
  { key = "shoulder", label = "Shoulder", locs = { "INVTYPE_SHOULDER" } },
  { key = "back", label = "Back", locs = { "INVTYPE_CLOAK" } },
  { key = "chest", label = "Chest", locs = { "INVTYPE_CHEST", "INVTYPE_ROBE" } },
  { key = "wrist", label = "Wrist", locs = { "INVTYPE_WRIST" } },
  { key = "hands", label = "Hands", locs = { "INVTYPE_HAND" } },
  { key = "waist", label = "Waist", locs = { "INVTYPE_WAIST" } },
  { key = "legs", label = "Legs", locs = { "INVTYPE_LEGS" } },
  { key = "feet", label = "Feet", locs = { "INVTYPE_FEET" } },
  { key = "finger", label = "Finger", locs = { "INVTYPE_FINGER" } },
  { key = "trinket", label = "Trinket", locs = { "INVTYPE_TRINKET" } },
  { key = "weapon", label = "Weapon",
    locs = { "INVTYPE_WEAPON", "INVTYPE_2HWEAPON", "INVTYPE_WEAPONMAINHAND" } },
  { key = "offhand", label = "Off hand",
    locs = { "INVTYPE_SHIELD", "INVTYPE_WEAPONOFFHAND", "INVTYPE_HOLDABLE" } },
  { key = "ranged", label = "Ranged",
    locs = { "INVTYPE_RANGED", "INVTYPE_RANGEDRIGHT", "INVTYPE_THROWN", "INVTYPE_RELIC" } },
}
local SLOT_OF, SLOT_BY_KEY = {}, {}
for i, s in ipairs(SLOTS) do
  s.order = i
  SLOT_BY_KEY[s.key] = s
  for _, loc in ipairs(s.locs) do SLOT_OF[loc] = s end
end

local scan        -- { scanned, heard } while the browse is ours
local lastBrowse  -- the last scan's browse results: a new slot or top N re-reads from them
local wish = {}   -- itemID -> true: on the wish list when the scan started
local gains = {}  -- link -> gain (false: none), per scan: auctions of one item share it

local function API()
  local api = ForeverLevelingBiS_API
  return api and (api.version or 1) >= 2 and api or nil
end

local function Top() return M.db.bisTop or DEFAULT_TOP end
local function PickedSlot() return SLOT_BY_KEY[M.db.bisSlot or ""] end

local function SlotOf(id)
  local loc = select(4, C_Item.GetItemInfoInstant(id))
  return loc and SLOT_OF[loc]
end

-- ForeverLevelingBiSDB.chars[key].wish = { { id, suffix? } }, key as its Core.lua makes it
local function WishList()
  local db = ForeverLevelingBiSDB
  if type(db) ~= "table" or type(db.chars) ~= "table" then return {} end
  local name = GetUnitName and GetUnitName("player", true) or UnitName("player")
  if canaccessvalue and not canaccessvalue(name) then return {} end
  local char = db.chars[name .. "-" .. GetRealmName()]
  return char and type(char.wish) == "table" and char.wish or {}
end

-- nil while the item or the worn gear is loading (not cached: asked again)
local function Gain(link)
  if gains[link] == nil then
    local api = API()
    local gain, loading = api and api.GetGain(link)
    if loading then return nil end
    gains[link] = gain or false
  end
  return gains[link] or nil
end

-- browse results carry no link; the key's suffix makes one the scorer reads
local function KeyLink(key)
  if key.itemSuffix and key.itemSuffix ~= 0 then
    return ("item:%d::::::%d"):format(key.itemID, key.itemSuffix)
  end
  return "item:" .. key.itemID
end

-- per slot (the picked one only), its best Top() upgrades; best gains first when MAX_KEYS
-- cuts the list, then items still loading (scored once their auctions are read). The wish
-- list's items always.
local function Keys(results)
  local picked, top = PickedSlot(), Top()
  local bySlot, loading = {}, {}
  for _, r in ipairs(results) do
    local key = r.itemKey
    local slot = key and SlotOf(key.itemID)
    if slot and (not picked or slot == picked) and not wish[key.itemID] then
      local link = KeyLink(key)
      local gain = Gain(link)
      if gain and gain > 0 then
        bySlot[slot] = bySlot[slot] or {}
        table.insert(bySlot[slot], { key = key, gain = gain })
      elseif gain == nil and gains[link] == nil then
        loading[#loading + 1] = { key = key }
      end
    end
  end
  local picks = {}
  for _, list in pairs(bySlot) do
    table.sort(list, function(a, b) return a.gain > b.gain end)
    for i = 1, math.min(#list, top) do picks[#picks + 1] = list[i] end
  end
  table.sort(picks, function(a, b) return a.gain > b.gain end)
  for _, e in ipairs(loading) do picks[#picks + 1] = e end
  local keys = {}
  for _, e in ipairs(WishList()) do
    if type(e) == "table" and e.id then
      keys[#keys + 1] = C_AuctionHouse.MakeItemKey(e.id, nil, e.suffix)
    end
  end
  for i = 1, math.min(#picks, MAX_KEYS) do keys[#keys + 1] = picks[i].key end
  return keys
end

local function ReadAuctions()
  local slot = PickedSlot()
  B.SearchKeys(Keys(lastBrowse), "BiS upgrades" .. (slot and (": " .. slot.label) or ""))
  B.state.scanned = #lastBrowse
end

local function OnBrowse()
  if not scan then return end
  scan.heard = GetTime()
  local results = C_AuctionHouse.GetBrowseResults()
  if C_AuctionHouse.HasFullBrowseResults and not C_AuctionHouse.HasFullBrowseResults() then
    scan.scanned = #results
    C_AuctionHouse.RequestMoreBrowseResults()
    B.Refresh()
    return
  end
  scan, lastBrowse = nil, results
  ReadAuctions()
end
M.On("AUCTION_HOUSE_BROWSE_RESULTS_UPDATED", OnBrowse)
M.On("AUCTION_HOUSE_BROWSE_RESULTS_ADDED", OnBrowse)
M.On("AUCTION_HOUSE_CLOSED", function() scan, lastBrowse = nil, nil end)

local NEEDS = "BiS upgrades needs the Forever Leveling BiS addon (1.3 or later) enabled"

function Bis.Search()
  if not API() then
    -- said in the list, where he's looking; the chat line only without our tab
    if not B.panel then return M.Print(NEEDS) end
    B.SetView("bis")
    B.state.text, B.state.rows = "BiS upgrades", {}
    B.state.noAPI = true
    return B.Refresh()
  end
  B.state.noAPI = nil
  B.SetView("bis")
  wipe(wish)
  wipe(gains)
  for _, e in ipairs(WishList()) do
    if type(e) == "table" and e.id then wish[e.id] = true end
  end
  local st = B.state
  st.rows, st.shown, st.selected, st.offset = {}, {}, nil, 0
  st.text, st.busy, st.items, st.scanned = "BiS upgrades", true, 0, nil
  local mine = { scanned = 0, heard = GetTime() }
  scan = mine
  C_AuctionHouse.SendBrowseQuery({ searchString = "",
    filters = { Enum.AuctionHouseFilter.UsableOnly },
    itemClassFilters = B.VIEWS.bis.classFilters,
    sorts = { { sortOrder = Enum.AuctionHouseSortOrder.Price, reverseSort = false } } })
  local function Check()
    if scan ~= mine then return end
    local quiet = GetTime() - mine.heard
    if quiet < BROWSE_WAIT then return C_Timer.After(BROWSE_WAIT - quiet, Check) end
    scan, st.busy = nil, false
    M.Print("the AH didn't answer the search (busy or throttled): search again")
    B.Refresh()
  end
  C_Timer.After(BROWSE_WAIT, Check)
  B.Refresh()
end

-- a new slot or top N: the last scan's items again, else a scan
local function Changed()
  local f = B.panel
  if f and f.filters.bis then f.filters.bis.Update() end
  if not (AuctionHouseFrame and AuctionHouseFrame:IsShown()) then return end
  if lastBrowse and B.state.view == "bis" and not scan then ReadAuctions() else Bis.Search() end
end

function Bis.SetSlot(key)
  M.db.bisSlot = SLOT_BY_KEY[key or ""] and key or nil
  Changed()
end

function Bis.SetTop(n)
  n = math.floor(tonumber(n) or DEFAULT_TOP)
  n = math.max(1, math.min(n, MAX_TOP))
  M.db.bisTop = n ~= DEFAULT_TOP and n or nil
  Changed()
end

------------------------------------------------------------------------------ The view
-- each row's gain, slot, and its item's rank in the slot (by its best auction's gain)
local function Prepare(rows)
  local best = {}
  for _, r in ipairs(rows) do
    r.wish = wish[r.itemID] or nil
    r.gain = Gain(r.link or ("item:" .. r.itemID))
    r.costPt = (r.gain and r.gain > 0 and r.unit) and r.unit / r.gain or nil
    local slot = SlotOf(r.itemID)
    r.slot, r.slotOrder = slot and slot.key, slot and slot.order
    r.item = r.link and r.link:match("item:[%-%d:]+") or r.itemID
    if slot and r.gain then
      local list = best[slot.key] or {}
      best[slot.key] = list
      if not list[r.item] or r.gain > list[r.item] then list[r.item] = r.gain end
    end
  end
  local rank = {}
  for key, list in pairs(best) do
    local items = {}
    for item, gain in pairs(list) do items[#items + 1] = { item = item, gain = gain } end
    table.sort(items, function(a, b) return a.gain > b.gain end)
    rank[key] = {}
    for i, e in ipairs(items) do rank[key][e.item] = i end
  end
  for _, r in ipairs(rows) do r.slotRank = r.slot and rank[r.slot] and rank[r.slot][r.item] end
end

local function Keep(r)
  local picked = PickedSlot()
  if picked and r.slot ~= picked.key then return false end
  if r.wish then return true end
  return (r.gain and r.gain > 0 and r.slotRank and r.slotRank <= Top()) or false
end

local function GainText(r)
  if r.gain and r.gain > 0 then return Cc("good", ("+%.1f"):format(r.gain)) end
  if r.gain then return Cc("dim", ("%.1f"):format(r.gain)) end
  return Cc("dim", "-")
end

-- by slot, then gain within it
local function BySlot(a, b, desc)
  local x, y = a.slotOrder or 99, b.slotOrder or 99
  if x ~= y then
    if desc then return x > y end
    return x < y
  end
  if (a.gain or -1e9) ~= (b.gain or -1e9) then return (a.gain or -1e9) > (b.gain or -1e9) end
  return (a.unit or 0) < (b.unit or 0)
end

------------------------------------------------------------------------------ Controls
-- Slot: [All v]  Top [5] per slot. The slot button opens a menu (Blizzard_Menu), else cycles.
local function SlotMenu(owner)
  if MenuUtil and MenuUtil.CreateContextMenu then
    MenuUtil.CreateContextMenu(owner, function(_, root)
      root:CreateRadio("All slots", function() return PickedSlot() == nil end,
        function() Bis.SetSlot(nil) end)
      for _, s in ipairs(SLOTS) do
        root:CreateRadio(s.label, function() return M.db.bisSlot == s.key end,
          function() Bis.SetSlot(s.key) end)
      end
    end)
    return
  end
  local cur = PickedSlot()
  local nextSlot = SLOTS[(cur and cur.order or 0) + 1]
  Bis.SetSlot(nextSlot and nextSlot.key)
end

local function Filter(f, anchor)
  local g = CreateFrame("Frame", nil, f)
  g:SetSize(230, 24)
  g:SetPoint("LEFT", anchor, "RIGHT", 14, 0)
  local slot = CreateFrame("Button", nil, g, "UIPanelButtonTemplate")
  slot:SetSize(100, 22)
  slot:SetPoint("LEFT")
  slot:SetScript("OnClick", SlotMenu)
  local label = g:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  label:SetPoint("LEFT", slot, "RIGHT", 10, 0)
  label:SetText("Top")
  local top = CreateFrame("EditBox", nil, g, "InputBoxTemplate")
  top:SetSize(28, 20)
  top:SetPoint("LEFT", label, "RIGHT", 8, 0)
  top:SetAutoFocus(false)
  top:SetNumeric(true)
  top:SetMaxLetters(2)
  top:SetJustifyH("CENTER")
  local function Apply(self)
    self:ClearFocus()
    if tonumber(self:GetText()) ~= Top() then Bis.SetTop(self:GetText()) end
  end
  top:SetScript("OnEnterPressed", Apply)
  top:SetScript("OnEditFocusLost", Apply)
  top:SetScript("OnEscapePressed", function(self)
    self:SetText(Top())
    self:ClearFocus()
  end)
  local per = g:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  per:SetPoint("LEFT", top, "RIGHT", 4, 0)
  per:SetText("per slot")
  B.Help(slot, { "Slot", "Pick one gear slot, or All slots",
    "A new slot re-reads the last scan's items, so it's quick." })
  B.Help(top, { "Top per slot", "How many of the best items of each slot to list (1-"
    .. MAX_TOP .. ")", "Type a number and press Enter. Each item is a throttled AH search, "
    .. "so more takes longer. Wish list items always show." })
  function g.Update()
    local s = PickedSlot()
    slot:SetText(s and s.label or "All slots")
    if not top:HasFocus() then top:SetText(tostring(Top())) end
  end
  g.slot, g.top = slot, top
  g.Update()
  return g
end

B.VIEWS.bis = {
  sort = "slotOrder",
  classFilters = { { classID = Enum.ItemClass.Armor }, { classID = Enum.ItemClass.Weapon } },
  columns = {
    { key = "name", title = "Item", width = 0,
      tip = "Hover a row to compare with what you wear; double-click to buy" },
    { key = "slotOrder", title = "Slot", width = 70, tip = "The gear slot it goes in",
      text = function(r) return r.slot and SLOT_BY_KEY[r.slot].label or Cc("dim", "-") end },
    { key = "wish", title = "Wish", width = 40, desc = true,
      tip = "On your Forever Leveling BiS wish list (starred in its window)",
      text = function(r) return r.wish and Cc("warn", "*") or "" end },
    { key = "gain", title = "Gain", width = 56, right = true, desc = true,
      tip = "How much it beats what you wear, for your main spec",
      more = "Forever Leveling BiS's score, the same as its tooltip.",
      text = GainText },
    { key = "unit", title = "Price", width = 100, right = true, tip = "Buyout",
      text = function(r) return M.Money(r.unit) end },
    { key = "costPt", title = "Per point", width = 92, right = true,
      tip = "Price for each point of gain: low is the cheapest way up",
      text = function(r) return r.costPt and M.Money(math.floor(r.costPt)) or Cc("dim", "-") end },
    { key = "pct", title = "% Mkt", width = 56, right = true,
      tip = B.PCT_TIP, more = B.PCT_MORE,
      text = function(r) return B.Pct(r.pct) end },
    { key = "seller", title = "Seller", width = 96, tip = B.SELLER_TIP,
      text = function(r) return r.mine and Cc("accent", r.seller) or r.seller end },
  },
  compare = { slotOrder = BySlot },
  Prepare = Prepare,
  Keep = Keep,
  Filter = Filter,
  status = function(n)
    local st = B.state
    local from = st.scanned and (" from %d usable items"):format(st.scanned) or ""
    return ("%d auctions shown of %d%s"):format(#st.rows - n, #st.rows, from)
  end,
  reading = function()
    if scan then return ("Scanning usable gear... %d"):format(scan.scanned or 0) end
    return ("Reading item %d of %d"):format(B.state.read, B.state.items)
  end,
  empty = "BiS upgrades: the best gear on the AH for each slot, as Forever Leveling BiS scores it",
  none = function()
    if B.state.noAPI then
      return Cc("warn", NEEDS) .. ".\n\nIt scores the gear; enable it in the AddOns list and "
        .. "reload."
    end
    local slot = PickedSlot()
    return ("No upgrades up for %s right now.\nTry All slots, or check again later.")
      :format(slot and slot.label or "any slot")
  end,
  noneStatus = function()
    return B.state.noAPI and "Needs Forever Leveling BiS" or "No upgrades found"
  end,
  hidden = function(n)
    return ("None of these %d auctions beats what you wear%s."):format(n,
      PickedSlot() and (" in " .. PickedSlot().label) or "")
  end,
  action = B.VIEWS.items.action,
}

-- the game only compares on Shift (alwaysCompareItems off): rows here compare always, after
-- the row's Show
hooksecurefunc(GameTooltip, "Show", function(tip)
  local owner = tip:GetOwner()
  if B.state.view ~= "bis" or not (B.panel and owner and owner:GetParent() == B.panel.list) then
    return
  end
  local shopping = tip.shoppingTooltips and tip.shoppingTooltips[1] or ShoppingTooltip1
  if not shopping or shopping:IsShown() or not GameTooltip_ShowCompareItem then return end
  local ok, err = pcall(GameTooltip_ShowCompareItem, tip)
  if not ok then geterrorhandler()(err) end
end)

table.insert(B.onBuild, function(f)
  local b = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
  b:SetSize(110, 20)
  b:SetPoint("RIGHT", f.shop or f, f.shop and "LEFT" or "BOTTOMRIGHT", -4, 0)
  b:SetText("BiS upgrades")
  b:SetScript("OnClick", Bis.Search)
  B.Help(b, function()
    if not API() then return { "BiS upgrades", NEEDS } end
    return { "BiS upgrades", "Gear on the AH that beats what you wear, best first",
      "Scans usable armour and weapons, scored by Forever Leveling BiS: the best of each "
        .. "slot, and your wish list (starred in its window). Hover a row to compare." }
  end)
  f.range:ClearAllPoints()
  f.range:SetPoint("RIGHT", b, "LEFT", -8, 0)
  f.bis = b
end)
