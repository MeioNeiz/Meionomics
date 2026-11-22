-- Shopping view of the Meionomics AH tab: what the craft queue's shopping list still has to buy
-- (C.Shopping), searched item by item. Per item the cheapest auctions that cover the need are
-- picked (glow); none dearer than CAP x its usual price, or than a vendor sells it for.
-- "Buy" buys the top pick outright (PlaceBid, no popup: the button names count, item and
-- price), or the selected row. Purchases count as mail until the mailbox opens (C.AddBought).
-- The craft panel's button and its key binding run it while the AH is open (S.Step), so one
-- key opens the list, buys each pick, then crafts.
local _, M = ...
local B, P, C = M.AuctionBrowse, M.Prices, M.Craft
local Cc = B.C
local S = {}
M.AuctionShop = S

local CAP = 1.5
-- vendor goods: once listings at or under the vendor price run out, ones up to this x it are
-- picked too ("over vendor"): a few thread aren't worth the trip
local VENDOR_OVER = 5
local BUY_WAIT = 10   -- seconds without an answer: the purchase is given up on

local plan = { want = {}, order = {}, short = {}, picked = 0, cost = 0 }
local buying   -- the row being bought
local searched -- itemID -> true: searched for the list since the AH opened
local skipped = {} -- itemID -> true: left off the list until unskipped or the AH closes

local function Name(id) return C_Item.GetItemNameByID(id) or ("item " .. id) end
local EmptyList

-- what's still to buy: itemID -> shopping row, and the list order
local function ToBuy(shop)
  local want, order = {}, {}
  for _, m in ipairs((shop or C.Shopping()).mats) do
    if m.buy > 0 and not skipped[m.id] then
      want[m.id] = m
      order[#order + 1] = m.id
    end
  end
  return want, order
end

-- the most an auction may cost each: CAP x its usual price, never above a vendor's
local function Cap(id, m)
  local usual = P.Get(id, "market") or P.Get(id, "regionMarket") or m.price
  local vendor = P.VendorBuy(id)
  local cap = usual and usual * CAP
  if vendor then cap = math.min(cap or vendor, vendor) end
  return cap, vendor
end

-- commodities are bought by quantity, cheapest first: rows in price order, the last in part
-- (r.take)
local function PickCommodity(list, left)
  table.sort(list, function(a, b) return a.unit < b.unit end)
  local picks = {}
  for _, r in ipairs(list) do
    if left <= 0 then break end
    r.take = math.min(r.qty, left)
    left = left - r.take
    picks[#picks + 1] = r
  end
  return picks, left
end

-- the cheapest set of auctions covering left: at each step either one stack that covers the
-- rest, or the cheapest each and on (stacks can't be split). Not enough up: all of it.
local function Pick(list, left)
  if list[1] and list[1].commodity then return PickCommodity(list, left) end
  table.sort(list, function(a, b) return a.unit < b.unit end)
  local up = 0
  for _, r in ipairs(list) do up = up + r.qty end
  if up <= left then return list, left - up end
  local function Best(i, need)
    local cost, picks
    for j = i, #list do
      local r = list[j]
      if r.qty >= need and (not cost or r.total < cost) then cost, picks = r.total, { r } end
    end
    local r = list[i]
    if r and r.qty < need then
      local c, p = Best(i + 1, need - r.qty)
      if c and (not cost or c + r.total < cost) then
        table.insert(p, 1, r)
        cost, picks = c + r.total, p
      end
    end
    return cost, picks
  end
  local _, picks = Best(1, left)
  return picks or {}, 0
end

local function Plan(rows)
  plan.want, plan.order = ToBuy()
  plan.short, plan.picked, plan.cost = {}, 0, 0
  local byItem = {}
  for _, r in ipairs(rows) do
    r.pick, r.dear, r.glow, r.faded, r.take, r.over = nil, nil, nil, nil, nil, nil
    r.total = r.unit * r.qty
    r.planRank = 2
    local list = byItem[r.itemID] or {}
    byItem[r.itemID] = list
    if not plan.want[r.itemID] or r.mine or not B.CanBuy(r) then
      r.faded = true
    else
      list[#list + 1] = r
    end
  end
  for _, id in ipairs(plan.order) do
    local m = plan.want[id]
    local cap, vendor = Cap(id, m)
    local ok = {}
    for _, r in ipairs(byItem[id] or {}) do
      if cap and r.unit > cap then
        r.dear, r.faded, r.planRank = true, true, 3
      else
        ok[#ok + 1] = r
      end
    end
    local function Take(picks)
      for _, r in ipairs(picks) do
        r.pick, r.glow, r.planRank = true, true, 1
        plan.picked, plan.cost = plan.picked + 1, plan.cost + r.unit * (r.take or r.qty)
      end
    end
    local picks, left = Pick(ok, m.buy)
    Take(picks)
    if left > 0 and vendor then
      local near = {}
      for _, r in ipairs(byItem[id] or {}) do
        if r.dear and r.unit <= vendor * VENDOR_OVER then near[#near + 1] = r end
      end
      picks, left = Pick(near, left)
      for _, r in ipairs(picks) do r.dear, r.faded, r.over = nil, nil, true end
      Take(picks)
    end
    if left > 0 then plan.short[#plan.short + 1] = { id = id, n = left, vendor = vendor } end
  end
  if M.CraftUI then M.CraftUI.RefreshSoon() end
end

-- the top pick as listed
function S.Next()
  for _, r in ipairs(B.state.shown) do if r.pick then return r end end
end

-- the item Skip acts on: the selected row's, else the top pick's
local function SkipTarget()
  local r = B.state.selected or S.Next()
  return r and r.itemID
end

function S.Skip()
  local id = SkipTarget()
  if not id or buying then return end
  skipped[id] = not skipped[id] or nil
  B.Refresh()
  if M.CraftUI then M.CraftUI.RefreshSoon() end
end

-- what one press buys -> qty, cost. An auction: itself. A commodity is bought by quantity,
-- cheapest first, whichever row is pressed: every unit picked of it, or for a row picked out by
-- hand what the list still needs of it (else the row's quantity)
local function Amount(r)
  if not r.commodity then return r.qty, r.unit * r.qty end
  local rows = {}
  for _, x in ipairs(B.state.rows) do
    if x.itemID == r.itemID and not x.mine then rows[#rows + 1] = x end
  end
  table.sort(rows, function(a, b) return a.unit < b.unit end)
  local qty, cost = 0, 0
  if r.pick then
    for _, x in ipairs(rows) do
      if x.pick then qty, cost = qty + (x.take or x.qty), cost + x.unit * (x.take or x.qty) end
    end
    return qty, cost
  end
  local m = plan.want[r.itemID]
  local want = m and m.buy or r.qty
  for _, x in ipairs(rows) do
    local n = math.min(x.qty, want - qty)
    if n <= 0 then break end
    qty, cost = qty + n, cost + x.unit * n
  end
  return qty, cost
end

local function Label(r)
  local qty, cost = Amount(r)
  return ("Buy %d %s  %s"):format(qty, r.name, M.Money(cost))
end

------------------------------------------------------------------------------ Buying
function S.Buy(r)
  if buying or not (r and B.CanBuy(r)) then return end
  local qty, cost = Amount(r)
  if GetMoney() < cost then return M.Print("not enough gold for " .. Label(r)) end
  if r.commodity then
    buying = r
    B.BuyCommodity(r.itemID, qty, cost, function(ok)
      buying = nil
      if not ok then return end
      C.AddBought(r.itemID, qty)
      for i = #B.state.rows, 1, -1 do
        local x = B.state.rows[i]
        if x.itemID == r.itemID and x.pick then table.remove(B.state.rows, i) end
      end
      if M.CraftUI then M.CraftUI.RefreshSoon() end
    end)
    return
  end
  buying = r
  B.state.buying = r.auctionID
  C_AuctionHouse.PlaceBid(r.auctionID, r.buyout)
  C_Timer.After(BUY_WAIT, function()
    if buying == r then
      buying, B.state.buying = nil, nil
      B.Refresh()
    end
  end)
  B.Refresh()
end

-- AuctionBrowse's own handler (registered first) has already taken the row off
M.On("AUCTION_HOUSE_PURCHASE_COMPLETED", function(_, auctionID)
  local r = buying
  if not (r and r.auctionID == auctionID) then return end
  buying = nil
  C.AddBought(r.itemID, r.qty)
  if M.CraftUI then M.CraftUI.RefreshSoon() end
  B.Refresh()
end)

-- bought by someone else first, or the server said no: drop the row, the plan moves on
pcall(M.On, "AUCTION_HOUSE_SHOW_ERROR", function()
  local r = buying
  if not r or r.commodity then return end
  buying, B.state.buying = nil, nil
  for i, x in ipairs(B.state.rows) do
    if x == r then table.remove(B.state.rows, i) break end
  end
  B.Refresh()
end)

M.On("AUCTION_HOUSE_CLOSED", function()
  buying, searched = nil, nil
  wipe(skipped)
  if M.CraftUI then M.CraftUI.RefreshSoon() end
end)
M.On("AUCTION_HOUSE_SHOW", function()
  if M.CraftUI then M.CraftUI.RefreshSoon() end
end)

------------------------------------------------------------------------------ Opening
local function AHOpen()
  local ah = AuctionHouseFrame
  return ah and ah:IsShown() and B.panel and ah
end

function S.Search()
  local _, order = ToBuy()
  local keys = {}
  searched = {}
  for _, id in ipairs(order) do
    keys[#keys + 1] = C_AuctionHouse.MakeItemKey(id)
    searched[id] = true
  end
  B.SetView("shopping")
  B.SearchKeys(keys, "Shopping list")
end

-- the AH on our tab, the shopping list searched
function S.Open()
  local ah = AHOpen()
  if not ah then return false end
  ah:SetDisplayMode(B.MODE)
  S.Search()
  return true
end

-- for the craft panel's button while the AH is open: label, enabled, action; nil when the
-- list has nothing left to buy here (crafting goes on). shop: C.Shopping() if already built
function S.Step(shop)
  if not AHOpen() then return nil end
  local _, order = ToBuy(shop)
  if #order == 0 then return nil end
  local st = B.state
  local unsearched = not searched
  for _, id in ipairs(order) do unsearched = unsearched or not searched[id] end
  if unsearched or not (B.panel:IsShown() and st.view == "shopping") then
    return ("Shop on the AH: %d item%s"):format(#order, #order == 1 and "" or "s"), true, S.Open
  end
  -- the list changed since the plan was made (prices seen, a craft-or-buy flip): picks follow it
  local want = ToBuy(shop)
  local stale = #order ~= #plan.order
  for id, m in pairs(want) do stale = stale or not (plan.want[id] and plan.want[id].buy == m.buy) end
  if stale and not (st.busy or st.waitBrowse or buying) then B.Refresh() end
  if st.busy or st.waitBrowse then return "Searching the AH...", false end
  if buying then return "Buying " .. buying.name .. "...", false end
  local r = S.Next()
  if r then return Label(r), true, function() S.Buy(r) end end
end

------------------------------------------------------------------------------ The view
-- why the list searched nothing, and what to do
function EmptyList()
  if C.QueueCount() == 0 then
    return Cc("accent", "Your shopping list is empty") .. "\n\nQueue crafts in the Craft panel "
      .. "(/meio craft) and it fills with the mats they need."
  end
  local _, order = ToBuy()
  if #order > 0 then
    local names = {}
    for i = 1, math.min(#order, 4) do names[i] = Name(order[i]) end
    return ("None of it is up right now: %s%s.\nTry again later, or check a vendor.")
      :format(table.concat(names, ", "), #order > 4 and (" and %d more"):format(#order - 4) or "")
  end
  if next(skipped) then
    return "Everything left on the list is skipped.\nSelect a row and Unskip, or close the AH "
      .. "to clear skips."
  end
  return Cc("good", "Nothing to buy") .. "\n\nYour bags, bank and mail already hold what the "
    .. "craft queue needs: craft it in /meio craft."
end

local function PlanText(r)
  if skipped[r.itemID] then return Cc("dim", "skipped") end
  if r.pick and r.over then return Cc("warn", "over vendor") end
  if r.pick then return Cc("good", "buy") end
  if r.dear then return Cc("bad", "too dear") end
  if r.mine then return Cc("accent", "yours") end
  return Cc("dim", "-")
end

local function ByName(a, b, desc)
  if a.name ~= b.name then
    if desc then return a.name > b.name end
    return a.name < b.name
  end
  return (a.unit or 0) < (b.unit or 0)
end

B.VIEWS.shopping = {
  sort = "name",
  keysOnly = true,
  columns = {
    { key = "name", title = "Item", width = 0,
      tip = "What your craft queue still needs; hover a row for how many" },
    { key = "unit", title = "Price each", width = 104, right = true, tip = "Buyout for one",
      text = function(r) return M.Money(r.unit) end },
    { key = "pct", title = "% Mkt", width = 62, right = true, tip = B.PCT_TIP, more = B.PCT_MORE,
      text = function(r) return B.Pct(r.pct) end },
    { key = "qty", title = "Qty", width = 40, right = true, tip = "How many in the auction",
      more = "5/20: a stackable good bought by quantity, 5 of the 20 listed at that price.",
      text = function(r) return r.take and r.take < r.qty and (r.take .. "/" .. r.qty) or r.qty end },
    { key = "total", title = "Total", width = 104, right = true, tip = "What the auction costs",
      text = function(r) return M.Money(r.total) end },
    { key = "seller", title = "Seller", width = 100, tip = B.SELLER_TIP,
      text = function(r) return r.mine and Cc("accent", r.seller) or r.seller end },
    { key = "planRank", title = "Plan", width = 76,
      tip = "Which auctions the Buy button takes, cheapest first",
      more = "buy: picked to cover what the queue still needs. too dear: over " .. CAP
        .. "x its usual price, or dearer than a vendor sells it. over vendor: picked anyway "
        .. "(up to " .. VENDOR_OVER .. "x the vendor price) once cheaper ones run out. "
        .. "skipped: left off with Skip.",
      text = PlanText },
  },
  compare = { name = ByName },
  Prepare = Plan,
  -- what the buy button buys next
  Focus = function(shown)
    if buying then return buying end
    for _, r in ipairs(shown) do if r.pick then return r end end
  end,
  OnDraw = function(f)
    local skip = f.filters.shopping and f.filters.shopping.skip
    if not skip then return end
    local id = SkipTarget()
    skip:SetText(id and skipped[id] and "Unskip" or "Skip")
    skip:SetEnabled(id ~= nil and not buying)
  end,
  Hover = function(r, tt)
    local m = plan.want[r.itemID]
    if not m then return end
    tt:AddLine(" ")
    tt:AddDoubleLine("Shopping list: to buy", m.buy, 1, 0.82, 0, 1, 1, 1)
    local cap = Cap(r.itemID, m)
    if cap then tt:AddDoubleLine("Most it picks at, each", M.Money(cap), 1, 0.82, 0, 1, 1, 1) end
  end,
  Filter = function(f, anchor)
    local g = CreateFrame("Frame", nil, f)
    g:SetSize(100, 24)
    g:SetPoint("LEFT", anchor, "RIGHT", 14, 0)
    local again = CreateFrame("Button", nil, g, "UIPanelButtonTemplate")
    again:SetSize(90, 22)
    again:SetPoint("LEFT")
    again:SetText("Search again")
    again:SetScript("OnClick", S.Search)
    B.Help(again, { "Search again", "Read the shopping list's auctions afresh",
      "For when someone else bought or listed meanwhile. Skipped items stay skipped." })
    local skip = CreateFrame("Button", nil, g, "UIPanelButtonTemplate")
    skip:SetSize(70, 22)
    skip:SetPoint("LEFT", again, "RIGHT", 6, 0)
    skip:SetScript("OnClick", S.Skip)
    B.Help(skip, function()
      local id = SkipTarget()
      local name = id and Name(id) or "an item"
      if id and skipped[id] then
        return { "Unskip " .. name, "Put it back on the shopping list" }
      end
      return { "Skip " .. name, "Leave it off the list here, e.g. to buy it elsewhere",
        "Acts on the selected row's item, else the next one to buy. It stays skipped until "
          .. "you unskip it or close the AH." }
    end)
    g.skip = skip
    g:SetWidth(166)
    return g
  end,
  status = function()
    if C.QueueCount() == 0 then return "Nothing queued in /meio craft" end
    if #plan.order == 0 then return Cc("good", "All bought:") .. " craft them in /meio craft" end
    local parts = { plan.picked > 0 and ("%d to buy, %s"):format(plan.picked, M.Money(plan.cost))
      or "Nothing more worth buying here" }
    local nSkipped = 0
    for _ in pairs(skipped) do nSkipped = nSkipped + 1 end
    if nSkipped > 0 then parts[#parts + 1] = Cc("dim", nSkipped .. " skipped") end
    for _, s in ipairs(plan.short) do
      parts[#parts + 1] = Cc("bad", ("%d %s short"):format(s.n, Name(s.id)))
        .. (s.vendor and Cc("grey", " (vendor " .. M.Money(s.vendor) .. ")") or "")
    end
    return table.concat(parts, Cc("dim", " · "))
  end,
  reading = function()
    return ("Reading item %d of %d"):format(B.state.read, B.state.items)
  end,
  empty = "Shopping list: what your craft queue needs, from /meio craft",
  none = function() return EmptyList() end,
  noneStatus = function()
    return C.QueueCount() == 0 and "Nothing queued in /meio craft" or "Nothing to buy here"
  end,
  action = {
    text = function(sel)
      if buying then return "Buying..." end
      local r = (sel and B.CanBuy(sel)) and sel or S.Next()
      return r and Label(r) or "Nothing to buy"
    end,
    enabled = function(sel)
      return not buying and ((sel and B.CanBuy(sel)) or S.Next() ~= nil)
    end,
    run = function(sel)
      if sel and B.CanBuy(sel) then return S.Buy(sel) end
      S.Buy(S.Next())
    end,
    help = function(sel)
      local more = "Buys at once, no confirmation: the button names what and the price. Select "
        .. "a row to buy that one instead. The Craft panel's button and key do the same while "
        .. "the AH is open."
      if buying then return { "Buying...", "Waiting for the auction house to answer" } end
      if sel and B.CanBuy(sel) then return { Label(sel), "Buy the selected auction", more } end
      local r = S.Next()
      if r then return { Label(r), "Buy the next pick on the shopping list", more } end
      if C.QueueCount() == 0 then
        return { "Nothing to buy", "Nothing queued: queue crafts in /meio craft first" }
      end
      if #plan.order == 0 then
        return { "Nothing to buy", "The list is done: craft in /meio craft" }
      end
      return { "Nothing to buy", "What's left is too dear here, or not up",
        "The status line names what's short; hover Plan for the price limits." }
    end,
  },
}

table.insert(B.onBuild, function(f)
  local b = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
  b:SetSize(110, 20)
  b:SetPoint("BOTTOMRIGHT", 0, -1)
  b:SetText("Shopping list")
  b:SetScript("OnClick", S.Search)
  B.Help(b, function()
    local _, order = ToBuy()
    local line = #order > 0 and ("%d item%s to buy for your craft queue"):format(#order,
      #order == 1 and "" or "s") or "Nothing to buy: queue crafts in /meio craft first"
    return { "Shopping list", line, "Searches each item the queue still needs and picks the "
      .. "cheapest auctions that cover it. Buy takes them one press at a time." }
  end)
  f.range:ClearAllPoints()
  f.range:SetPoint("RIGHT", b, "LEFT", -8, 0)
  f.shop = b
end)
