-- Sell view of the Meionomics AH tab: bag items worth posting, one row per item key, each at
-- the Sell tab's price (AuctionRules quote, AuctionUI.Decide). Each item's auctions are read
-- once per AH visit for the live cheapest. "Post" (the button, a double-click or the
-- MEIONOMICS_SELL_NEXT key) posts the next row, one hardware press per post. When the AH asks
-- to confirm a price, Blizzard's popup is hidden (its Accept would confirm the Sell tab's post,
-- not ours) and the next press confirms instead.
-- Left out: bound, quest and non-auctionable items, and the craft queue's mats.
-- M.db.sellShowAll: also list rows not worth posting. M.db.sellDuration: 1/2/3 = 12/24/48h.
local _, M = ...
local B, Q, UI, C = M.AuctionBrowse, M.AuctionRules, M.AuctionUI, M.Craft
local SD = M.SellDay
local Cc = B.C
local S = {}
M.AuctionSell = S

BINDING_NAME_MEIONOMICS_SELL_NEXT = "Post next bag item (AH Sell view)"

local SEARCH_WAIT = 5
local POST_WAIT = 10
local HOURS = { 12, 24, 48 }

local live = {}     -- keyStr -> { comp, mine } read this visit (false: no answer)
local skipped = {}  -- keyStr -> true, this visit
local posted = {}   -- keyStr -> row as posted, this visit
local queue = {}    -- rows still to read
local reading       -- the row whose search is out
local post          -- { row, args, commodity, before, confirm }
local held = 0      -- bag items left out for the craft queue

local function Duration() return M.db.sellDuration or 2 end
local function KeyStr(k)
  return ("%d:%d:%d"):format(k.itemID, k.itemLevel or 0, k.itemSuffix or 0)
end
local function Name(r) return r and r.name or "an item" end

local function AHOpen()
  local ah = AuctionHouseFrame
  return ah and ah:IsShown() and B.panel and ah
end
local function Active() return B.state.view == "sell" end

------------------------------------------------------------------------------ Bags
local function Queued()
  local q = {}
  if C.QueueCount() > 0 then
    for _, m in ipairs(C.Shopping(true).mats) do q[m.id] = true end
  end
  return q
end

local function Leave(bag, slot, c, mats)
  if c.isBound then return true end
  local qi = C_Container.GetContainerItemQuestInfo
    and C_Container.GetContainerItemQuestInfo(bag, slot)
  if qi and (qi.isQuestItem or qi.questID) then return true end
  if not M.Prices.Auctionable(c.itemID) then return true end
  if mats[c.itemID] then
    held = held + (c.stackCount or 1)
    return true
  end
end

-- item key -> { locs, count }: bag items that could go up
local function Scan()
  local groups, order, mats = {}, {}, Queued()
  held = 0
  for bag = 0, NUM_BAG_SLOTS or 4 do
    for slot = 1, C_Container.GetContainerNumSlots(bag) or 0 do
      local c = C_Container.GetContainerItemInfo(bag, slot)
      if c and c.itemID and not Leave(bag, slot, c, mats) then
        local loc = ItemLocation:CreateFromBagAndSlot(bag, slot)
        local valid = C_AuctionHouse.IsSellItemValid
        local ok = not valid or valid(loc, false)
        local key = ok and (C_AuctionHouse.GetItemKeyFromItem(loc)
          or C_AuctionHouse.MakeItemKey(c.itemID))
        if key then
          local ks = KeyStr(key)
          local g = groups[ks]
          if not g then
            g = { key = key, ks = ks, count = 0, locs = {}, link = c.hyperlink, id = c.itemID }
            groups[ks] = g
            order[#order + 1] = g
          end
          g.count = g.count + (c.stackCount or 1)
          if not c.isLocked then g.locs[#g.locs + 1] = loc end
        end
      end
    end
  end
  return groups, order
end

local function Count(ks)
  local groups = Scan()
  return groups[ks] and groups[ks].count or 0
end

------------------------------------------------------------------------------ Rows
local function Deposit(r, qty)
  local loc, dur = r.loc, Duration()
  if not loc then return nil end
  local dep
  if r.commodity and C_AuctionHouse.CalculateCommodityDeposit then
    local ok, v = pcall(C_AuctionHouse.CalculateCommodityDeposit, r.itemID, dur, qty)
    dep = ok and v or nil
  end
  if not dep then
    local ok, v = pcall(C_AuctionHouse.CalculateItemDeposit, loc, dur, qty)
    dep = ok and v or nil
  end
  return dep
end

-- the price and plan once the item's auctions are read (or failed to answer)
local function Quote(r)
  local l = live[r.ks] or {}
  local each = Deposit(r, 1)
  local q = Q.Quote(r.itemID, { lowest = l.comp, mine = l.mine, deposit = each })
  q.itemID = r.itemID
  local price, tone, why = UI.Decide(q)
  r.q, r.unit, r.tone, r.why = q, price, tone, why
  r.comp, r.mine = q.lowest, q.mine
  r.deposit = Deposit(r, r.qty)
  r.chance = nil
  if price and q.sellDay then r.chance = SD.Net(q.sellDay, price).P end
  r.value = (price or 0) * r.qty
  r.quoted = true
end

local function NewRow(g)
  local id = g.id
  local name, _, quality = C_Item.GetItemInfo(g.link or id)
  local loc = g.locs[1]
  local commodity = loc and C_AuctionHouse.GetItemCommodityStatus
    and C_AuctionHouse.GetItemCommodityStatus(loc) == Enum.ItemCommodityStatus.Commodity
  local can = loc and C_AuctionHouse.GetAvailablePostCount
    and C_AuctionHouse.GetAvailablePostCount(loc) or g.count
  return { key = g.key, ks = g.ks, itemID = id, link = g.link, loc = loc,
    name = name or (g.link and g.link:match("%[(.-)%]")) or ("item " .. id),
    quality = quality or 1, qty = math.max(1, math.min(g.count, can > 0 and can or g.count)),
    commodity = commodity or nil }
end

-- the bags read afresh: rows of what's there, then what was posted this visit
local function Build()
  local _, order = Scan()
  local rows = {}
  wipe(queue)
  for _, g in ipairs(order) do
    if not posted[g.ks] and g.locs[1] then
      local r = NewRow(g)
      rows[#rows + 1] = r
      if live[r.ks] ~= nil then Quote(r) else queue[#queue + 1] = r end
    end
  end
  for _, r in pairs(posted) do rows[#rows + 1] = r end
  return rows
end

local function CanPost(r)
  return r and r.quoted and r.unit and r.loc and not r.posted and true or false
end

local function Postable(r)
  return CanPost(r) and r.q.action == "post" and not skipped[r.ks] and not r.failed
end

function S.NextRow()
  if post then return post.row end
  for _, r in ipairs(B.state.shown) do if Postable(r) then return r end end
end

------------------------------------------------------------------------------ Reading
local ReadNext

local function Answer(r, l)
  if reading ~= r then return end
  reading = nil
  live[r.ks] = l
  Quote(r)
  -- the bags were read again meanwhile: that list's row of the item gets the answer too
  for _, x in ipairs(B.state.rows) do if x.ks == r.ks and not x.quoted then Quote(x) end end
  for i = #queue, 1, -1 do if queue[i].ks == r.ks then table.remove(queue, i) end end
  ReadNext()
end

function ReadNext()
  if not (Active() and AHOpen()) then
    reading = nil
    B.state.busy = false
    return
  end
  local r = table.remove(queue, 1)
  if not r then
    reading, B.state.busy = nil, false
    return B.Refresh()
  end
  if not C_AuctionHouse.IsThrottledMessageSystemReady() then
    table.insert(queue, 1, r)
    return C_Timer.After(1, function() if not reading then ReadNext() end end)
  end
  reading = r
  B.state.busy = true
  B.state.read = B.state.read + 1
  C_AuctionHouse.SendSearchQuery(r.key, { { sortOrder = Enum.AuctionHouseSortOrder.Price,
    reverseSort = false } }, true)
  C_Timer.After(SEARCH_WAIT, function() if reading == r then Answer(r, false) end end)
  B.Refresh()
end

M.On("ITEM_SEARCH_RESULTS_UPDATED", function(_, key)
  local r = reading
  if not (r and key and KeyStr(key) == r.ks) then return end
  local a = M.Auction.ItemSearch(key)
  Answer(r, { comp = a.comp, mine = a.mine })
end)

M.On("COMMODITY_SEARCH_RESULTS_UPDATED", function(_, itemID)
  local r = reading
  if not (r and r.itemID == itemID) then return end
  local l = {}
  for i = 1, C_AuctionHouse.GetNumCommoditySearchResults(itemID) do
    local x = C_AuctionHouse.GetCommoditySearchResultInfo(itemID, i)
    if x and x.unitPrice and x.unitPrice > 0 and x.unitPrice <= M.MAX_COPPER then
      if (x.numOwnerItems or 0) > 0 then
        l.mine = math.min(l.mine or x.unitPrice, x.unitPrice)
      end
      if x.quantity > (x.numOwnerItems or 0) then
        l.comp = math.min(l.comp or x.unitPrice, x.unitPrice)
      end
    end
  end
  Answer(r, l)
end)

local function Start()
  B.state.selected = nil
  B.state.rows = Build()
  B.state.text, B.state.read, B.state.items = "Sell from bags", 0, #queue
  B.state.busy = #queue > 0
  B.Refresh()
  if not reading then ReadNext() end
end

-- the AH on our tab, the Sell view read; fresh: forget this visit's prices first
function S.Open(fresh)
  local ah = AHOpen()
  if not ah then return false end
  if fresh then wipe(live) end
  ah:SetDisplayMode(B.MODE)
  B.SetView("sell")
  Start()
  return true
end

------------------------------------------------------------------------------ Posting
local function Label(r)
  return ("Post %d at %s"):format(r.qty, M.Money(r.unit))
end

local function EndPost(ok)
  local p = post
  if not p then return end
  post = nil
  if ok then
    p.row.posted, p.row.glow = true, nil
    posted[p.row.ks] = p.row
  else
    p.row.failed = true
  end
  if Active() then
    B.state.rows = Build()
    B.Refresh()
  end
end

function S.Post(sel)
  if not AHOpen() then return end
  if post and post.confirm then
    local loc, id = post.args[1], post.row.itemID
    -- the slot changed since the post asked for it: confirming would list another item
    if not (C_Item.DoesItemExist(loc) and C_Item.GetItemID(loc) == id) then
      post = nil
      B.state.rows = Build()
      return B.Refresh()
    end
    local fn = post.commodity and C_AuctionHouse.ConfirmPostCommodity
      or C_AuctionHouse.ConfirmPostItem
    post.confirm = false
    fn(unpack(post.args, 1, 5))
    return B.Refresh()
  end
  if post or reading then return end
  local r = (sel and CanPost(sel)) and sel or S.NextRow()
  if not r then return end
  -- the bags may have changed since the list was made
  if not (C_Item.DoesItemExist(r.loc) and C_Item.GetItemID(r.loc) == r.itemID) then
    B.state.rows = Build()
    return B.Refresh()
  end
  local args, fn
  if r.commodity then
    args, fn = { r.loc, Duration(), r.qty, r.unit }, C_AuctionHouse.PostCommodity
  else
    args, fn = { r.loc, Duration(), r.qty, nil, r.unit }, C_AuctionHouse.PostItem
  end
  local p = { row = r, args = args, commodity = r.commodity, before = Count(r.ks) }
  post = p
  r.glow = true
  local needs = fn(unpack(args, 1, 5))
  if needs then p.confirm = true end
  C_Timer.After(POST_WAIT, function()
    if post == p and not p.confirm then EndPost(Count(r.ks) < p.before) end
  end)
  B.Refresh()
end

-- the binding: the view first, then a post per press
function S.Next()
  local ah = AHOpen()
  if not ah then
    if UIErrorsFrame then
      UIErrorsFrame:AddMessage("Open the auction house first", 1, 0.1, 0.1)
    end
    return
  end
  if not (B.panel:IsShown() and Active()) then return S.Open() end
  S.Post()
end

local function SkipTarget()
  local r = B.state.selected or S.NextRow()
  return r and not r.posted and r or nil
end

function S.Skip()
  local r = SkipTarget()
  if not r then return end
  -- a price the AH asked to confirm can be skipped instead; one being posted can't
  if post and post.row == r then
    if not post.confirm then return end
    post = nil
  end
  skipped[r.ks] = not skipped[r.ks] or nil
  B.Refresh()
end

local function HidePopup()
  if StaticPopup_Hide then StaticPopup_Hide("AUCTION_HOUSE_POST_WARNING") end
end

-- Blizzard's popup shows from its own handler, which may run after ours: hidden next frame too
pcall(M.On, "AUCTION_HOUSE_POST_WARNING", function()
  if not post then return end
  post.confirm = true
  HidePopup()
  C_Timer.After(0, HidePopup)
  B.Refresh()
end)
pcall(M.On, "AUCTION_HOUSE_POST_ERROR", function() if post then EndPost(false) end end)
pcall(M.On, "AUCTION_HOUSE_SHOW_ERROR", function() if post then EndPost(false) end end)
pcall(M.On, "AUCTION_HOUSE_AUCTION_CREATED", function()
  if post and not post.confirm then EndPost(true) end
end)
M.On("BAG_UPDATE_DELAYED", function()
  if post and not post.confirm and Count(post.row.ks) < post.before then
    return EndPost(true)
  end
  if Active() and AHOpen() and B.panel:IsShown() and not post and not reading then
    B.state.rows = Build()
    B.Refresh()
    if #queue > 0 then ReadNext() end
  end
end)

M.On("AUCTION_HOUSE_CLOSED", function()
  wipe(live)
  wipe(skipped)
  wipe(posted)
  wipe(queue)
  reading, post = nil, nil
end)

------------------------------------------------------------------------------ The view
local PLAN = {
  post = { 1, "good", "post" }, next = { 0, "good", "next" }, confirm = { 0, "warn", "confirm" },
  posting = { 0, "accent", "posting..." }, reading = { 2, "dim", "reading..." },
  skipped = { 3, "dim", "skipped" }, hold = { 4, "warn", "under min" },
  vendor = { 5, "warn", "vendor it" }, none = { 6, "dim", "no price" },
  failed = { 7, "bad", "failed" }, posted = { 8, "dim", "posted" },
}

local function PlanOf(r)
  if r.posted then return "posted" end
  if post and post.row == r then return post.confirm and "confirm" or "posting" end
  if not r.quoted then return "reading" end
  if r.failed then return "failed" end
  if skipped[r.ks] then return "skipped" end
  if r.q.action == "post" and r.unit then return "post" end
  if r.q.action == "vendor" then return "vendor" end
  if r.q.action == "hold" and r.unit then return "hold" end
  return "none"
end

local function Prepare(rows)
  local nextRow
  for _, r in ipairs(rows) do
    r.plan = PlanOf(r)
    if not nextRow and r.plan == "post" then nextRow = r end
    r.faded = r.plan == "posted" or r.plan == "skipped" or r.plan == "failed"
      or (r.quoted and not r.unit) or nil
    r.glow = (post and post.row == r) or nil
    r.planRank = PLAN[r.plan][1]
  end
end

local function Keep(r)
  if M.db.sellShowAll then return true end
  local p = r.plan
  return p ~= "vendor" and p ~= "none" and p ~= "hold"
end

local function Counts()
  local done, left, skip = 0, 0, 0
  for _ in pairs(posted) do done = done + 1 end
  for _, r in ipairs(B.state.rows) do
    if skipped[r.ks] and not r.posted then skip = skip + 1 end
    if Postable(r) then left = left + 1 end
  end
  return done, left, skip
end

local function ChanceText(r)
  if not r.chance then return Cc("dim", "-") end
  local tone = r.chance >= 0.8 and "good" or r.chance >= 0.5 and "warn" or "bad"
  return Cc(tone, ("%d%%"):format(math.floor(r.chance * 100 + 0.5)))
end

local function CheapText(r)
  if not r.quoted then return Cc("dim", "...") end
  if r.mine and (not r.comp or r.mine <= r.comp) then return Cc("accent", "yours") end
  return r.comp and M.Money(r.comp) or Cc("dim", "none up")
end

local function ByPlan(a, b, desc)
  if a.planRank ~= b.planRank then
    if desc then return a.planRank > b.planRank end
    return a.planRank < b.planRank
  end
  if (a.value or 0) ~= (b.value or 0) then return (a.value or 0) > (b.value or 0) end
  return a.name < b.name
end

local function Status()
  local done, left, skip = Counts()
  local parts = {}
  local r = S.NextRow()
  if post and post.confirm then
    parts[1] = Cc("warn", "The AH asks to confirm this price:") .. " press again to post "
      .. Name(post.row)
  elseif r then
    parts[1] = ("Post %d of %d: %s"):format(done + 1, done + left, r.name)
  elseif done > 0 then
    parts[1] = Cc("good", ("All posted: %d item%s"):format(done, done == 1 and "" or "s"))
  else
    parts[1] = "Nothing to post"
  end
  if skip > 0 then parts[#parts + 1] = Cc("dim", skip .. " skipped") end
  if held > 0 then parts[#parts + 1] = Cc("dim", held .. " kept for crafts") end
  return table.concat(parts, Cc("dim", " · "))
end

local DUR_HELP = { "Auction length", "How long each auction stays up; click to change",
  "Longer costs a bigger deposit, which you lose if it doesn't sell. The Deposit column "
    .. "follows it." }

local function Filter(f, anchor)
  local g = CreateFrame("Frame", nil, f)
  g:SetSize(220, 24)
  g:SetPoint("LEFT", anchor, "RIGHT", 14, 0)
  local all = CreateFrame("CheckButton", nil, g, "UICheckButtonTemplate")
  all:SetSize(24, 24)
  all:SetPoint("LEFT")
  local label = g:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
  label:SetPoint("LEFT", all, "RIGHT", 1, 0)
  label:SetText("Show all")
  all:SetChecked(M.db.sellShowAll and true or false)
  all:SetScript("OnClick", function(self)
    M.db.sellShowAll = self:GetChecked() or nil
    B.Refresh()
  end)
  B.LabelClicks(all, label)
  B.Help(all, { "Show all", "Also list what isn't worth posting",
    "Items a vendor pays more for, ones whose cheapest is under your minimum price, and ones "
      .. "with no price. Post never takes these by itself: select one and press Post." })
  local dur = CreateFrame("Button", nil, g, "UIPanelButtonTemplate")
  dur:SetSize(46, 22)
  dur:SetPoint("LEFT", label, "RIGHT", 10, 0)
  dur:SetScript("OnClick", function()
    M.db.sellDuration = Duration() % 3 + 1
    for _, r in ipairs(B.state.rows) do if r.quoted and not r.posted then Quote(r) end end
    B.Refresh()
  end)
  B.Help(dur, DUR_HELP)
  local skip = CreateFrame("Button", nil, g, "UIPanelButtonTemplate")
  skip:SetSize(70, 22)
  skip:SetPoint("LEFT", dur, "RIGHT", 6, 0)
  skip:SetScript("OnClick", S.Skip)
  B.Help(skip, function()
    local r = SkipTarget()
    if r and skipped[r.ks] then return { "Unskip " .. r.name, "Put it back in the queue" } end
    return { "Skip " .. Name(r), "Leave it in your bags this visit",
      "Acts on the selected row, else the next to post. Skips clear when the AH closes." }
  end)
  g.all, g.dur, g.skip = all, dur, skip
  f.sellAll = all
  return g
end

B.VIEWS.sell = {
  sort = "planRank",
  keysOnly = true,
  columns = {
    { key = "name", title = "Item", width = 0,
      tip = "What's in your bags to post; hover a row for why that price" },
    { key = "qty", title = "Qty", width = 40, right = true, tip = "How many one press posts",
      more = "Every one in your bags. Gear goes up as one auction each; stackable goods as "
        .. "one listing.",
      text = function(r) return r.qty end },
    { key = "unit", title = "Post at", width = 100, right = true, tip = "Price each",
      more = "The Sell tab's price: undercut, your minimum or normal price, or the price that "
        .. "sells within a day. Hover a row for which, and why.",
      text = function(r) return r.unit and M.Money(r.unit) or Cc("dim", "-") end },
    { key = "comp", title = "Cheapest", width = 100, right = true,
      tip = "The cheapest someone else has up",
      more = "Read from the AH this visit. yours: your own auction is the cheapest.",
      text = CheapText },
    { key = "deposit", title = "Deposit", width = 80, right = true,
      tip = "What posting them costs up front",
      more = "Back when they sell, lost when they expire. Set by the auction length button.",
      text = function(r) return r.deposit and M.Money(r.deposit) or Cc("dim", "-") end },
    { key = "chance", title = "Sells", width = 56, right = true, desc = true,
      tip = "Chance it sells within a day at that price",
      more = "Learnt from your own posts (/meio posts). A dash: nobody else has it up, so "
        .. "there's nothing to judge against.",
      text = ChanceText },
    { key = "planRank", title = "Plan", width = 76, tip = "What Post does with it",
      more = "next: the next press posts it. post: queued. under min: the cheapest is under your "
        .. "minimum price. vendor it: a vendor pays more than a sale here nets. skipped: "
        .. "left out with Skip. posted: up this visit.",
      text = function(r)
        local p = PLAN[r.plan]
        if r.plan == "post" and r == S.NextRow() then p = PLAN.next end
        return Cc(p[2], p[3])
      end },
  },
  compare = { planRank = ByPlan },
  Prepare = Prepare,
  Keep = Keep,
  Filter = Filter,
  Focus = function() return S.NextRow() end,
  OnSearch = function() wipe(queue) reading = nil end,
  OnDraw = function(f)
    local g = f.filters.sell
    if not g then return end
    g.dur:SetText(HOURS[Duration()] .. "h")
    local r = SkipTarget()
    g.skip:SetText(r and skipped[r.ks] and "Unskip" or "Skip")
    g.skip:SetEnabled(r ~= nil and not (post and post.row == r and not post.confirm))
  end,
  Hover = function(r, tt)
    if not r.quoted then return end
    tt:AddLine(" ")
    local head = r.unit and ("Meionomics: post at " .. M.Money(r.unit)) or "Meionomics"
    tt:AddLine(head, 1, 0.82, 0)
    if r.why then tt:AddLine(r.why, 0.85, 0.85, 0.85, true) end
    if r.chance and r.q.sellDay then
      tt:AddDoubleLine("Sells within a day", ("%d%%"):format(r.chance * 100 + 0.5),
        1, 0.82, 0, 1, 1, 1)
    end
    if IsShiftKeyDown() then
      for _, k in ipairs({ { "floor", "Minimum price" }, { "normal", "Normal price" },
        { "ceiling", "Maximum price" } }) do
        if r.q[k[1]] then tt:AddDoubleLine(k[2], M.Money(r.q[k[1]]), 1, 0.82, 0, 1, 1, 1) end
      end
      if r.q.reason then tt:AddLine(r.q.reason, 0.7, 0.7, 0.7, true) end
      if r.q.sellDay then tt:AddLine(SD.Basis(r.q.sellDay.fit), 0.7, 0.7, 0.7, true) end
    else
      M.Tooltip.ShiftHint(tt)
    end
  end,
  status = function() return Status() end,
  reading = function()
    return ("Reading prices %d of %d"):format(B.state.read, B.state.items)
  end,
  empty = "Sell from bags: post what's in your bags at Meionomics' price",
  none = function()
    local text = Cc("accent", "Nothing in your bags to post") .. "\n\nBound and quest items "
      .. "can't go up."
    if held > 0 then
      text = text .. ("\n%d item%s kept back: your craft queue needs them."):format(held,
        held == 1 and " is" or "s are")
    end
    return text .. "\nLoot or craft something, then press Sell from bags again."
  end,
  noneStatus = function() return "Nothing in your bags to post" end,
  hidden = function(n)
    return ("None of these %d item%s is worth posting now:\na vendor pays more, the cheapest is "
      .. "under your minimum, or there's no price.\nTick Show all to see them."):format(n,
      n == 1 and "" or "s")
  end,
  action = {
    text = function(sel)
      if post and post.confirm then return "Confirm: post " .. Name(post.row) end
      if post then return "Posting..." end
      if reading then return "Reading prices..." end
      local r = (sel and CanPost(sel)) and sel or S.NextRow()
      return r and Label(r) or "Nothing to post"
    end,
    enabled = function(sel)
      if post then return post.confirm and true or false end
      return not reading and ((sel and CanPost(sel)) or S.NextRow() ~= nil)
    end,
    run = function(sel) S.Post(sel) end,
    help = function(sel)
      local key = GetBindingKey and GetBindingKey("MEIONOMICS_SELL_NEXT")
      local more = "Posts at once at the price shown, for " .. HOURS[Duration()] .. "h. "
        .. "Select a row to post that one instead. "
        .. (key and ("Your key " .. key .. " does the same.")
          or "Bind a key to it: Key Bindings > AddOns > Meionomics.")
      if post and post.confirm then
        return { "Confirm", "The AH asks to confirm this price: press to post " .. Name(post.row),
          "Blizzard warns when a price is far from what it expects. Skip it instead if the "
            .. "price looks wrong." }
      end
      if post then return { "Posting...", "Waiting for the auction house" } end
      if reading then return { "Reading prices...", "Each item's auctions are read first" } end
      if sel and CanPost(sel) then
        return { Label(sel), "Post the selected row: " .. sel.name, more }
      end
      local r = S.NextRow()
      if r then return { Label(r), "Post the next in the list: " .. r.name, more } end
      return { "Nothing to post", "Nothing left in your bags worth posting",
        "Tick Show all to see what was left out, and why." }
    end,
  },
}

table.insert(B.onBuild, function(f)
  local b = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
  b:SetSize(110, 20)
  local left = f.bis or f.shop
  if left then
    b:SetPoint("RIGHT", left, "LEFT", -4, 0)
  else
    b:SetPoint("BOTTOMRIGHT", 0, -1)
  end
  b:SetText("Sell from bags")
  b:SetScript("OnClick", function() S.Open(Active()) end)
  B.Help(b, function()
    local key = GetBindingKey and GetBindingKey("MEIONOMICS_SELL_NEXT")
    return { "Sell from bags", "List what's in your bags to post, at Meionomics' price",
      "Reads each item's auctions, then Post puts them up one press at a time"
        .. (key and (" (or your key " .. key .. ")") or "") .. ". Click again to read the "
        .. "prices afresh. Bound, quest items and your craft queue's mats are left out." }
  end)
  f.range:ClearAllPoints()
  f.range:SetPoint("RIGHT", b, "LEFT", -8, 0)
  f.sell = b
end)
