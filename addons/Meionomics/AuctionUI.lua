-- Blizzard's Sell tab. When an item goes in and the AH's search for it answers, the price is set
-- from AuctionRules' quote and a line under it says why in a player's words (TSM Auctioning's
-- minimum / normal / maximum price); hovering the line shows the rule's sums. A price the player
-- typed is never replaced and Post is never blocked. Posting an item makes it watched (daily
-- history).
-- Forever lists everything as non-commodity items, so only ItemSellFrame is hooked; TSM's own AH
-- window doesn't show the Sell tab, so nothing here runs while it's in use.
--   /meio autoprice on|off
local _, M = ...
local A, Q = M.Auction, M.AuctionRules
local UI = {}
M.AuctionUI = UI

local SILVER = 100
local WORD = { post = "Post", hold = "Post", vendor = "Vendor it", cannot = "Can't sell",
  search = "Searching", none = "No price" }
local TONE = { post = "good", hold = "warn", vendor = "warn", cannot = "bad" }
-- AuctionRules' rule names as TSM Auctioning calls them, which he knows
local RULE = { floor = "minimum price", normal = "normal price", ceiling = "maximum price" }

local function C(key, text) return "|cff" .. M.Tooltip.style[key] .. text .. "|r" end

-- an AH without copper takes whole silver: undercuts round down, floors round up
function UI.Silver(price, floor)
  if C_AuctionHouse.SupportsCopperValues and C_AuctionHouse.SupportsCopperValues() then
    return math.max(price, 1)
  end
  local p = math.floor(price / SILVER) * SILVER
  if floor and p < floor then p = math.ceil(floor / SILVER) * SILVER end
  return math.max(p, SILVER)
end

-- the search results for the item now in the Sell tab, as Auction.Aggregate's shape
function UI.LiveFromResults(key) return A.ItemSearch(key) end

-- why, in a few words: AuctionRules' reason is its working, kept for the hover
function UI.Explain(q)
  local Money = M.Money
  local sd = q.sellDay
  if q.action == "cannot" then return (q.reason:gsub("^[^:]+: ", "")) end
  if q.action == "vendor" then
    return ("a vendor pays %s, more than selling it here would bring in"):format(Money(q.price))
  end
  if q.action == "hold" and q.floor then
    return ("the cheapest (%s) is under your minimum price, so at your minimum")
      :format(Money(q.lowest))
  end
  if q.action == "hold" then return "no minimum price known for it: Blizzard's price kept" end
  if q.rule == "in a day" and sd then
    local under = sd.m < 0.005 and "1c" or ("%d%%"):format(sd.m * 100 + 0.5)
    local why = ("sells within a day ~%s, %s under the going price %s"):format(
      M.SellDay.Odds(sd.P), under, Money(sd.ref))
    if sd.dip then why = why .. " (the cheapest is a dip)" end
    if sd.jump then why = why .. " (the cheapest jumped)" end
    return why
  end
  if q.rule == "undercut" then
    return ("%s under the cheapest (%s)%s"):format(Money(q.lowest - q.price), Money(q.lowest),
      sd and sd.slow and "; a slow seller" or "")
  end
  if q.rule == "match" then return "the cheapest up is already yours" end
  local rule = RULE[q.rule] or q.rule
  if not q.lowest then return "none up, so your " .. rule end
  return ("the cheapest (%s) is over your maximum, so your %s"):format(Money(q.lowest), rule)
end

-- what to put in the box and the line to say: price (nil = leave it), tone, text
function UI.Decide(q)
  if q.action == "post" and q.price then
    return UI.Silver(q.price, q.floor), TONE.post, UI.Explain(q)
  end
  if q.action == "hold" and q.floor then
    return UI.Silver(q.floor, q.floor), TONE.hold, UI.Explain(q)
  end
  return nil, TONE[q.action] or "warn", UI.Explain(q)
end

------------------------------------------------------------------------------ The line
local function Line(sf)
  if not sf.meioLine then
    local fs = sf:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    -- under Create Auction: the rows above it are packed, the space below is empty
    fs:SetPoint("TOP", sf.PostButton, "BOTTOM", 0, -10)
    fs:SetPoint("LEFT", sf, "LEFT", 16, 0)
    fs:SetPoint("RIGHT", sf, "RIGHT", -16, 0)
    fs:SetJustifyH("CENTER")
    fs:SetWordWrap(true)
    fs:SetMaxLines(3)
    sf.meioLine = fs
    -- the line is text: a frame over it takes the hover
    local hit = CreateFrame("Frame", nil, sf)
    hit:SetAllPoints(fs)
    hit:EnableMouse(true)
    hit:SetScript("OnEnter", function(self)
      if fs:IsShown() then UI.LineTip(self, sf.meioQuote) end
    end)
    hit:SetScript("OnLeave", GameTooltip_Hide)
    sf.meioHit = hit
  end
  return sf.meioLine
end

local function Pair(left, right)
  GameTooltip:AddDoubleLine(left, right, 1, 0.82, 0, 1, 1, 1)
end

-- hover over the line: the three prices, and on Shift how each is worked out
function UI.LineTip(owner, q)
  if not q then return end
  -- below the line: above it are the price boxes it talks about
  GameTooltip:SetOwner(owner, "ANCHOR_BOTTOM")
  GameTooltip:SetText("Meionomics price", 1, 1, 1)
  GameTooltip:AddLine(UI.Explain(q), 0.85, 0.85, 0.85, true)
  local shift = IsShiftKeyDown()
  local rule = Q.Rule and q.floor and Q.Rule(q.itemID)
  for _, k in ipairs({ "floor", "normal", "ceiling" }) do
    if q[k] then
      local name = RULE[k]:gsub("^%l", string.upper)
      Pair(name, M.Money(q[k]) .. ((shift and rule) and C("grey", "  " .. rule[k]) or ""))
    end
  end
  if q.lowest then Pair("Cheapest up", M.Money(q.lowest)) end
  if shift then
    GameTooltip:AddLine(" ")
    GameTooltip:AddLine(q.reason, 0.8, 0.8, 0.8, true)
  else
    GameTooltip:AddLine("|cff999999Shift: more|r")
  end
  GameTooltip:AddLine("|cff999999A price you type is never replaced. /meio autoprice off "
    .. "stops this.|r", nil, nil, nil, true)
  GameTooltip:Show()
end

M.On("MODIFIER_STATE_CHANGED", function(_, key)
  if not (key == "LSHIFT" or key == "RSHIFT") then return end
  local sf = AuctionHouseFrame and AuctionHouseFrame.ItemSellFrame
  local hit = sf and sf.meioHit
  if hit and GameTooltip:IsShown() and GameTooltip:GetOwner() == hit then
    UI.LineTip(hit, sf.meioQuote)
  end
end)

local function Say(sf, action, price, tone, text, kept)
  local head = C("accent", "Meionomics") .. " " .. C(tone, WORD[action] or action)
  if price then head = head .. " " .. M.Money(price) end
  if kept then head = C("accent", "Meionomics") .. C("grey", " suggests ") .. M.Money(price)
    .. C("grey", " (yours kept)") end
  Line(sf):SetText(head .. C("grey", ": " .. text))
  Line(sf):Show()
end

------------------------------------------------------------------------------ The hook
-- items whose search has answered since they went in; an empty answer has no results to show it
local answered = {}

-- the price history panel beside the AH, with its Selling column for what's in the box
local function ShowPanel(sf)
  if not (M.History and sf.meioItem) then return end
  local qty = math.max(1, sf:GetQuantity() or 1)
  M.History.ShowSell(sf.meioKey or sf.meioItem, AuctionHouseFrame, { live = sf.meioLive,
    price = sf.PriceInput:GetAmount(), deposit = (sf:GetDepositAmount() or 0) / qty,
    floor = sf.meioFloor })
end

-- after Blizzard's own pick (UpdatePriceSelection runs on drop-in and on every search answer)
local function OnPriceSelection(sf)
  local loc, key = sf:GetItem(), sf.listDisplayedItemKey
  if not (loc and loc:IsValid()) then
    if sf.meioLine then sf.meioLine:Hide() end
    sf.meioItem, sf.meioKey = nil, nil
    if M.History then M.History.ShowSell(nil) end
    return
  end
  local itemID = C_Item.GetItemID(loc)
  local vkey = A.Key(C_Item.GetItemLink(loc))
  if sf.meioItem ~= itemID or sf.meioKey ~= vkey then
    sf.meioItem, sf.meioPrice, sf.meioLive, sf.meioFloor = itemID, nil, nil, nil
    sf.meioKey = vkey
    answered[itemID] = nil
  end
  -- the panel shows from the moment an item goes in, before any search answers
  if not key or M.db.autoPrice == false then
    if sf.meioLine then sf.meioLine:Hide() end
    return ShowPanel(sf)
  end
  -- results for an item that's no longer in the box, or none yet: wait for the answer
  if key.itemID ~= itemID then return end
  if not (answered[itemID] or C_AuctionHouse.HasSearchResults(key)) then
    sf.meioQuote = nil
    Say(sf, "search", nil, "grey", "waiting for the auction house")
    ShowPanel(sf)
    return
  end
  local live = UI.LiveFromResults(key)
  -- a suffix's own search isn't the whole item's (Auction.lua records the variant)
  if (key.itemSuffix or 0) == 0 then A.Live(itemID, live, M.Now()) end
  local qty = math.max(1, sf:GetQuantity() or 1)
  local q = Q.Quote(itemID, { lowest = live.comp, mine = live.mine,
    deposit = (sf:GetDepositAmount() or 0) / qty })
  q.itemID = itemID
  sf.meioQuote = q
  local price, tone, text = UI.Decide(q)
  local action = (q.action == "hold" and not price) and "none" or q.action
  if not live.comp and not live.mine and not (A.Get(itemID) or {}).market and not price then
    action, tone, text = "none", "grey", "none up and no price history, so Blizzard's is kept"
  end
  local amount = sf.PriceInput:GetAmount()
  -- Blizzard's default, its pick from the list (0 when it picks "none available"), or ours
  local untouched = amount == 0 or amount == sf:GetDefaultPrice()
    or amount == sf:GetSearchResultPrice() or amount == sf.meioPrice
  if price and untouched then
    sf.PriceInput:SetAmount(price)
    sf.meioPrice = price
    sf:UpdatePostState()
  end
  Say(sf, action, price, tone, text, price and not untouched)
  sf.meioLive, sf.meioFloor = live, q.floor
  ShowPanel(sf)
end

-- Trade goods still open the commodity Sell frame, but Forever's CalculateCommodityDeposit
-- returns nil and Blizzard's CanPostItem then errors comparing money with it on Post
local function FixCommodityDeposit()
  local cf = AuctionHouseFrame.CommoditiesSellFrame
  if not cf or cf.meioDeposit then return end
  cf.meioDeposit = true
  local blizzard = cf.GetDepositAmount
  cf.GetDepositAmount = function(self)
    local deposit = blizzard(self)
    if deposit then return deposit end
    local ok, asItem = pcall(C_AuctionHouse.CalculateItemDeposit, self:GetItem(),
      self:GetDuration(), self:GetQuantity())
    return ok and asItem or 0
  end
end

local function Safe(fn, ...)
  local ok, err = pcall(fn, ...)
  if not ok then geterrorhandler()(err) end
end

-- trade goods: the commodity Sell frame gets the panel too, but no auto price
local function OnCommodityItem(cf)
  local loc = cf:GetItem()
  if not (loc and loc:IsValid()) then
    cf.meioItem, cf.meioKey = nil, nil
    if M.History then M.History.ShowSell(nil) end
    return
  end
  cf.meioItem = C_Item.GetItemID(loc)
  cf.meioKey = A.Key(C_Item.GetItemLink(loc))
  ShowPanel(cf)
end

-- switching between the two Sell frames hides one around when the other gets the item: close
-- the panel only if neither holds one once that has settled
local function OnSellHide(self)
  self.meioItem, self.meioKey = nil, nil
  C_Timer.After(0, function()
    local ah = AuctionHouseFrame
    for _, f in ipairs({ ah.ItemSellFrame, ah.CommoditiesSellFrame }) do
      if f:IsVisible() and f.meioItem then return end
    end
    if M.History then M.History.ShowSell(nil) end
  end)
end

-- a typed price, quantity or duration: the Selling column's "In the box" row, at most 5/s
local function OnPostState(self)
  local shown = M.History and M.History.SellShown(self.meioKey or self.meioItem)
  if self.meioRedraw or not shown then return end
  self.meioRedraw = true
  C_Timer.After(0.2, function()
    self.meioRedraw = nil
    if self.meioItem then Safe(ShowPanel, self) end
  end)
end

local function Hook()
  local sf = AuctionHouseFrame and AuctionHouseFrame.ItemSellFrame
  if not sf or sf.meioHooked then return end
  sf.meioHooked = true
  hooksecurefunc(sf, "UpdatePriceSelection", function(self) Safe(OnPriceSelection, self) end)
  hooksecurefunc(sf, "UpdatePostState", OnPostState)
  sf:HookScript("OnHide", OnSellHide)
  local cf = AuctionHouseFrame.CommoditiesSellFrame
  if cf and cf.SetItem then
    hooksecurefunc(cf, "SetItem", function(self) Safe(OnCommodityItem, self) end)
    if cf.UpdatePostState then hooksecurefunc(cf, "UpdatePostState", OnPostState) end
    cf:HookScript("OnHide", OnSellHide)
  end
  FixCommodityDeposit()
end

-- posted: worth daily history from now on
hooksecurefunc(C_AuctionHouse, "PostItem", function(loc)
  local ok, id = pcall(C_Item.GetItemID, loc)
  if ok and id then A.Watch(id) end
end)

-- runs alongside the Sell tab's own handler, in either order: mark, then redo the pick
M.On("ITEM_SEARCH_RESULTS_UPDATED", function(_, key)
  local sf = AuctionHouseFrame and AuctionHouseFrame.ItemSellFrame
  if not (key and sf and sf:IsVisible() and sf.meioItem == key.itemID) then return end
  answered[key.itemID] = true
  local ok, err = pcall(OnPriceSelection, sf)
  if not ok then geterrorhandler()(err) end
end)

if C_AddOns.IsAddOnLoaded("Blizzard_AuctionHouseUI") then Hook() end
M.On("ADDON_LOADED", function(_, name)
  if name == "Blizzard_AuctionHouseUI" then Hook() end
end)

M.commands.autoprice = function(rest)
  if rest == "off" then M.db.autoPrice = false elseif rest == "on" then M.db.autoPrice = true end
  M.Print("Sell tab prices " .. M.OnOff(M.db.autoPrice ~= false))
end
