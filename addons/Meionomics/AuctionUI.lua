-- Blizzard's Sell tab. When an item goes in and the AH's search for it answers, the price is set
-- from AuctionRules' quote and a line under it says which rule set it. A price the player typed is
-- never replaced and Post is never blocked. Posting an item makes it watched (daily history).
-- Forever lists everything as non-commodity items, so only ItemSellFrame is hooked; TSM's own AH
-- window doesn't show the Sell tab, so nothing here runs while it's in use.
--   /meio autoprice on|off
local _, M = ...
local A, Q = M.Auction, M.AuctionRules
local UI = {}
M.AuctionUI = UI

local SILVER = 100
local WORD = { post = "Post", hold = "Hold", vendor = "Vendor", cannot = "Can't sell",
  search = "Searching" }
local TONE = { post = "good", hold = "warn", vendor = "warn", cannot = "bad" }

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

-- the search results for the item now in the Sell tab, as Auction.Aggregate's shape. Item
-- search buyoutAmount is per item (Blizzard puts it straight into the per-item price box).
function UI.LiveFromResults(key)
  local CA = C_AuctionHouse
  local a = { qty = 0, n = 0 }
  for i = 1, CA.GetNumItemSearchResults(key) do
    local r = CA.GetItemSearchResultInfo(key, i)
    local unit = r and r.buyoutAmount
    if unit and unit > 0 then
      a.n, a.qty = a.n + 1, a.qty + (r.quantity or 1)
      a.min = math.min(a.min or unit, unit)
      if r.containsOwnerItem then
        a.mine = math.min(a.mine or unit, unit)
      else
        a.comp = math.min(a.comp or unit, unit)
      end
    end
  end
  return a
end

-- what to put in the box and the line to say: price (nil = leave it), tone, text
function UI.Decide(q)
  if q.action == "post" and q.price then
    return UI.Silver(q.price, q.floor), TONE.post, q.reason
  end
  if q.action == "hold" and q.floor then
    return UI.Silver(q.floor, q.floor), TONE.hold, q.reason .. ", asking the floor"
  end
  if q.action == "hold" then
    return nil, TONE.hold, q.reason .. ": Blizzard's price kept"
  end
  return nil, TONE[q.action] or "warn", q.reason
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
  end
  return sf.meioLine
end

local function Say(sf, action, price, tone, text, kept)
  local head = C("accent", "Meionomics") .. " " .. C(tone, WORD[action] or action)
  if price then head = head .. " " .. M.Money(price) end
  if kept then head = head .. C("grey", " (your price kept)") end
  Line(sf):SetText(head .. C("grey", ": " .. text))
  Line(sf):Show()
end

------------------------------------------------------------------------------ The hook
-- items whose search has answered since they went in; an empty answer has no results to show it
local answered = {}

-- after Blizzard's own pick (UpdatePriceSelection runs on drop-in and on every search answer)
local function OnPriceSelection(sf)
  local loc, key = sf:GetItem(), sf.listDisplayedItemKey
  if not (loc and loc:IsValid() and key) or M.db.autoPrice == false then
    if sf.meioLine then sf.meioLine:Hide() end
    return
  end
  local itemID = C_Item.GetItemID(loc)
  if sf.meioItem ~= itemID then
    sf.meioItem, sf.meioPrice = itemID, nil
    answered[itemID] = nil
  end
  -- results for an item that's no longer in the box, or none yet: wait for the answer
  if key.itemID ~= itemID then return end
  if not (answered[itemID] or C_AuctionHouse.HasSearchResults(key)) then
    Say(sf, "search", nil, "grey", "waiting for the auction house")
    return
  end
  local live = UI.LiveFromResults(key)
  A.Live(itemID, live, M.Now())
  local qty = math.max(1, sf:GetQuantity() or 1)
  local q = Q.Quote(itemID, { lowest = live.comp, mine = live.mine,
    deposit = (sf:GetDepositAmount() or 0) / qty })
  local price, tone, text = UI.Decide(q)
  if not live.comp and not live.mine and not (A.Get(itemID) or {}).market and not price then
    text = "no rivals, no history: Blizzard's price kept"
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
  Say(sf, q.action, price, tone, text, price and not untouched)
end

local function Hook()
  local sf = AuctionHouseFrame and AuctionHouseFrame.ItemSellFrame
  if not sf or sf.meioHooked then return end
  sf.meioHooked = true
  hooksecurefunc(sf, "UpdatePriceSelection", function(self)
    local ok, err = pcall(OnPriceSelection, self)
    if not ok then geterrorhandler()(err) end
  end)
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
  M.Print("Sell tab prices from Meionomics: " .. (M.db.autoPrice == false and "off" or "on"))
end
