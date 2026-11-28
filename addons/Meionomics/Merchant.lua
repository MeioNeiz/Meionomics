-- At a merchant: a strip under the merchant window, each button shown only when it has work.
--   Buy queue mats  the craft queue's shortfall (C.Shopping's buy column: after bags, bank,
--                   mail and alts) of what this merchant sells; one click buys exactly that
--   Sell junk       grey items, plus others whose Best is Vendor when the AH has a price to
--                   prove it (Mc.Junk says what never goes)
-- Nothing is ever bought or sold without a click. MeioQoL's restock buys at MERCHANT_SHOW: the
-- lists are worked out after it, and again whenever the bags change.
-- M.db.merchantButtons == false hides the strip.
local _, M = ...
local P, R, C = M.Prices, M.Recipes, M.Craft
local Mc = {}
M.Merchant = Mc

local LINE_ITEMS = 2  -- item names on a button before "+N more"
local SELL_GAP = 0.15 -- the server drops sales sent faster
local BUYBACK = 12

local function Hex(hex, text) return "|cff" .. hex .. text .. "|r" end
local function Dim(text) return Hex("a8a8a8", text) end
local function Name(id) return C_Item.GetItemNameByID(id) or ("item " .. id) end

local function Enabled() return not (M.db and M.db.merchantButtons == false) end

------------------------------------------------------------------------------ Buying
-- bought this visit, not in the bags yet: id -> { n, bags = count when bought }
local pending = {}
local function Pending(id)
  local p = pending[id]
  if not p then return 0 end
  local left = p.n - ((C_Item.GetItemCount(id, false) or 0) - p.bags)
  if left <= 0 then pending[id] = nil return 0 end
  return left
end

local function ItemInfo(i)
  if C_MerchantFrame and C_MerchantFrame.GetItemInfo then
    local ok, info = pcall(C_MerchantFrame.GetItemInfo, i)
    if ok and type(info) == "table" then return info end
    return nil
  end
  local _, _, price, stack, avail, purchasable, _, extended = GetMerchantItemInfo(i)
  return price and { price = price, stackCount = stack, numAvailable = avail,
    isPurchasable = purchasable, hasExtendedCost = extended }
end

-- what this merchant sells for gold: id -> { index, price (a lot), lot, avail (lots or nil),
-- each }, the cheapest each when it's listed twice
local function Stock()
  local out = {}
  for i = 1, (GetMerchantNumItems and GetMerchantNumItems() or 0) do
    local id = GetMerchantItemID(i)
    local info = id and ItemInfo(i)
    if info and not info.hasExtendedCost and info.isPurchasable ~= false
      and (info.price or 0) > 0 and info.numAvailable ~= 0 then
      local lot = math.max(1, info.stackCount or 1)
      local s = { index = i, price = info.price, lot = lot, each = info.price / lot,
        avail = (info.numAvailable or -1) >= 0 and info.numAvailable or nil }
      if not out[id] or s.each < out[id].each then out[id] = s end
    end
  end
  return out
end

-- -> { { id, n (items, whole lots), cost, s, m (C.Shopping row) } ... }, total cost
function Mc.BuyList()
  local list, total = {}, 0
  if C.QueueCount() == 0 then return list, total end
  local stock = Stock()
  if not next(stock) then return list, total end
  -- the AH short of a mat: the whole queue's, bought once while here. Gold short: only the
  -- crafts it covers, else vendor mats take gold the AH mats were counted on
  local shop = C.Shopping()
  if shop.limit and shop.limit.why ~= "gold" then shop = shop.full end
  for _, m in ipairs(shop.mats) do
    local s = stock[m.id]
    local want = s and m.buy - Pending(m.id) or 0
    if want > 0 then
      local lots = math.ceil(want / s.lot)
      if s.avail then lots = math.min(lots, s.avail) end
      if lots > 0 then
        local e = { id = m.id, n = lots * s.lot, cost = lots * s.price, s = s, m = m }
        list[#list + 1] = e
        total = total + e.cost
      end
    end
  end
  return list, total
end

-- one purchase takes at most a stack, in whole lots (as MeioQoL's restock does)
local function Buy(e)
  local i, lot = e.s.index, e.s.lot
  local maxStack = GetMerchantItemMaxStack and GetMerchantItemMaxStack(i) or lot
  local perBuy = math.max(lot, math.floor(maxStack / lot) * lot)
  local left = e.n
  while left > 0 do
    local q = math.min(left, perBuy)
    BuyMerchantItem(i, q)
    left = left - q
  end
  local p = pending[e.id] or { n = 0, bags = C_Item.GetItemCount(e.id, false) or 0 }
  p.n = p.n + e.n
  pending[e.id] = p
end

function Mc.BuyAll()
  local list = Mc.BuyList()
  local money, spent, bought, short = GetMoney(), 0, {}, {}
  for _, e in ipairs(list) do
    if spent + e.cost > money then
      -- what's left buys whole lots of this one
      local lots = math.floor((money - spent) / e.s.price)
      if lots > 0 then
        e.n, e.cost = lots * e.s.lot, lots * e.s.price
      else
        e.n = 0
      end
      short[#short + 1] = Name(e.id)
    end
    if e.n > 0 then
      Buy(e)
      spent = spent + e.cost
      bought[#bought + 1] = e.n .. " " .. Name(e.id)
    end
  end
  if #bought > 0 then
    M.Print(("bought %s for %s"):format(table.concat(bought, ", "), M.Money(spent)))
  end
  if #short > 0 then M.Print("not enough gold for all of " .. table.concat(short, ", ")) end
  R.ResetCache()
  Mc.Refresh()
end

------------------------------------------------------------------------------ Selling
-- skill-ups need them even when they sell for less than a vendor pays
local function MyMat(id)
  for _, rec in ipairs(R.UsedIn(id) or {}) do
    if next(rec.known or {}) then return true end
  end
end

-- why a bag item may go to the vendor -> reason, or nil when it stays. Grey items and MeioBags'
-- junk list always go, its keep list never; anything else only when P.BestAction says Vendor and
-- the AH price says so too, never when it is gear, soulbound, a quest item, needed by the craft
-- queue, a material of a known recipe or on MeioQoL's restock list.
-- Gear never: Leveling BiS can't rate what you can't wear yet, so a green weapon for a few levels
-- on looked like vendor trash and was sold.
function Mc.Junk(c, queued)
  local id = c.itemID
  if not id or c.hasNoValue or c.isLocked then return nil end
  local _, _, quality, _, _, _, _, _, _, _, vendor, classID = C_Item.GetItemInfo(id)
  if not (vendor and vendor > 0) then return nil end
  if c.quest or queued[id] then return nil end
  local bags = _G.MeioBags
  if bags and bags.IsKept and bags.IsKept(id) then return nil end
  if (quality or c.quality) == 0 then return "grey" end
  if bags and bags.IsJunk and bags.IsJunk(id) then return "on your MeioBags junk list" end
  if classID == 2 or classID == 4 then return nil end
  if c.isBound or MyMat(id) then return nil end
  local restock = MeioQoLCharDB and MeioQoLCharDB.restock
  if type(restock) == "table" and restock[id] then return nil end
  local act = P.BestAction(id, false)
  if not (act and act.verb == "vendor") then return nil end
  local s = act.sale or {}
  -- no AH price, or one too thin to trust, isn't proof it's worth only its vendor price
  if not s.ah or s.why.ah == "price unsure" then return nil end
  if s.why.ah == "slow" and not (s.s and s.s.perDay) then return nil end
  return act.reason or "vendor pays most"
end

local function Queued()
  local q = {}
  if C.QueueCount() > 0 then
    for _, m in ipairs(C.Shopping(true).mats) do q[m.id] = true end
  end
  return q
end

-- -> { { bag, slot, id, count, value, why } ... }, total value
function Mc.SellList()
  local list, total = {}, 0
  local queued = Queued()
  for bag = 0, NUM_BAG_SLOTS or 4 do
    for slot = 1, C_Container.GetContainerNumSlots(bag) or 0 do
      local c = C_Container.GetContainerItemInfo(bag, slot)
      if c and c.itemID then
        local q = C_Container.GetContainerItemQuestInfo
          and C_Container.GetContainerItemQuestInfo(bag, slot)
        c.quest = q and (q.isQuestItem or q.questID) and true or false
        local why = Mc.Junk(c, queued)
        if why then
          local n = c.stackCount or 1
          local value = select(11, C_Item.GetItemInfo(c.itemID)) * n
          list[#list + 1] = { bag = bag, slot = slot, id = c.itemID, count = n, value = value,
            why = why }
          total = total + value
        end
      end
    end
  end
  return list, total
end

local selling
function Mc.SellAll()
  if selling then return end
  local list, total = Mc.SellList()
  if #list == 0 then return end
  local i, sold, got = 0, 0, 0
  selling = C_Timer.NewTicker(SELL_GAP, function()
    i = i + 1
    local e = list[i]
    local open = MerchantFrame and MerchantFrame:IsShown()
    if not (e and open) then
      selling:Cancel()
      selling = nil
      if sold > 0 then
        M.Print(("sold %d item%s for %s"):format(sold, sold == 1 and "" or "s", M.Money(got)))
      end
      Mc.Refresh()
      return
    end
    -- the bags may have changed since the list was made
    if C_Container.GetContainerItemID(e.bag, e.slot) == e.id then
      C_Container.UseContainerItem(e.bag, e.slot)
      sold, got = sold + 1, got + e.value
    end
  end)
  Mc.Refresh()
  return total
end

------------------------------------------------------------------------------ Strip
local strip

local function Summary(names, more)
  local text = table.concat(names, ", ")
  if more > 0 then text = text .. (", +%d more"):format(more) end
  return text
end

local function BuyText(list, total)
  local names = {}
  for k, e in ipairs(list) do
    if k <= LINE_ITEMS then names[#names + 1] = e.n .. " " .. Name(e.id) end
  end
  return ("Buy queue mats: %s (%s)"):format(Summary(names, #list - LINE_ITEMS),
    M.Money(total))
end

local function SellText(list, total)
  local n = #list
  return ("Sell junk: %d item%s (%s)"):format(n, n == 1 and "" or "s", M.Money(total))
end

local function Pair(tt, left, right) tt:AddDoubleLine(left, right, 1, 1, 1, 1, 1, 1) end

local function HeldText(m)
  local parts = {}
  for _, k in ipairs({ "bags", "bank", "mail", "alts" }) do
    if (m[k] or 0) > 0 then parts[#parts + 1] = m[k] .. " " .. k end
  end
  if (m.crafted or 0) > 0 then parts[#parts + 1] = m.crafted .. " crafted" end
  return #parts > 0 and table.concat(parts, ", ") or "none"
end

local function BuyTooltip(tt)
  local list, total = Mc.BuyList()
  tt:AddLine("Buy for the craft queue")
  for _, e in ipairs(list) do
    Pair(tt, e.n .. " x " .. Name(e.id), M.Money(e.cost))
    if IsShiftKeyDown() then
      local m = e.m
      tt:AddLine(Dim(("   need %d, hold %s, short %d%s"):format(m.need, HeldText(m), m.buy,
        e.n > m.buy and (", sold in %ds"):format(e.s.lot) or "")))
    end
  end
  Pair(tt, "Total", M.Money(total))
  if total > GetMoney() then tt:AddLine(Hex("ff5a5a", "Not enough gold for all of it")) end
  if IsShiftKeyDown() then
    tt:AddLine(Dim("What the queue still needs after your bags, bank, mail and alts, as on its"
      .. " shopping list"), 1, 1, 1, true)
  else
    tt:AddLine(Dim("Click to buy exactly this. Shift: what the queue needs"))
  end
end

local function SellTooltip(tt)
  local list, total = Mc.SellList()
  local shift = IsShiftKeyDown()
  tt:AddLine("Sell to this vendor")
  for _, e in ipairs(list) do
    local left = (e.count > 1 and (e.count .. " x ") or "") .. Name(e.id)
    Pair(tt, left, M.Money(e.value))
    if shift then tt:AddLine(Dim("   " .. e.why)) end
  end
  Pair(tt, "Total", M.Money(total))
  if shift then
    tt:AddLine(Dim("Grey items, and others whose Best is Vendor with an AH price to prove it."
      .. " Never soulbound, quest items, queued or recipe mats, MeioQoL restock items or"
      .. " upgrades."), 1, 1, 1, true)
    if #list > BUYBACK then
      tt:AddLine(Dim(("Only the last %d can be bought back"):format(BUYBACK)))
    end
  else
    tt:AddLine(Dim("Click to sell them. Shift: why each one"))
  end
end

local function ShowTip(b)
  GameTooltip:SetOwner(b, "ANCHOR_RIGHT")
  b.tip(GameTooltip)
  GameTooltip:Show()
end

local function MakeButton(parent, tip, onClick)
  local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
  b:SetHeight(22)
  b.tip = tip
  b:SetScript("OnClick", onClick)
  b:SetScript("OnEnter", ShowTip)
  b:SetScript("OnLeave", GameTooltip_Hide)
  local fs = b:GetFontString()
  if fs then fs:SetWordWrap(false) fs:SetPoint("LEFT", 8, 0) fs:SetPoint("RIGHT", -8, 0) end
  return b
end

local function Build()
  if strip or not MerchantFrame then return strip end
  strip = CreateFrame("Frame", nil, MerchantFrame)
  -- under the Merchant/Buyback tabs: FlareUI writes its bulk-buy progress above the window
  strip:SetPoint("TOPLEFT", MerchantFrame, "BOTTOMLEFT", 4, -30)
  strip:SetSize(320, 22)
  strip.buy = MakeButton(strip, BuyTooltip, function() Mc.BuyAll() end)
  strip.sell = MakeButton(strip, SellTooltip, function() Mc.SellAll() end)
  return strip
end

local function Layout(shown)
  local prev
  for _, b in ipairs(shown) do
    b:ClearAllPoints()
    b:SetPoint("LEFT", strip, "LEFT")
    b:SetPoint("RIGHT", strip, "RIGHT")
    if prev then
      b:SetPoint("TOP", prev, "BOTTOM", 0, -2)
    else
      b:SetPoint("TOP", strip, "TOP")
    end
    prev = b
  end
end

function Mc.Refresh()
  if not (MerchantFrame and MerchantFrame:IsShown() and Enabled()) then
    if strip then strip:Hide() end
    return
  end
  Build()
  local shown = {}
  local buy, buyTotal = Mc.BuyList()
  strip.buy:SetShown(#buy > 0)
  if #buy > 0 then
    strip.buy:SetText(BuyText(buy, buyTotal))
    strip.buy:SetEnabled(GetMoney() >= math.min(buyTotal, buy[1].s.price))
    shown[#shown + 1] = strip.buy
  end
  local sell, sellTotal = Mc.SellList()
  strip.sell:SetShown(#sell > 0)
  if #sell > 0 then
    strip.sell:SetText(selling and "Selling..." or SellText(sell, sellTotal))
    strip.sell:SetEnabled(not selling)
    shown[#shown + 1] = strip.sell
  end
  Layout(shown)
  strip:SetShown(#shown > 0)
  local owner = GameTooltip:GetOwner()
  if strip:IsShown() and owner and owner:GetParent() == strip and owner:IsShown() then
    ShowTip(owner)
  end
end

-- bursts of bag and merchant events: one refresh a moment after the last
local ticket = 0
local function Soon(delay)
  ticket = ticket + 1
  local t = ticket
  C_Timer.After(delay or 0.2, function() if t == ticket then Mc.Refresh() end end)
end
Mc.RefreshSoon = Soon

M.On("MERCHANT_SHOW", function() Soon(0.3) end)
M.On("MERCHANT_UPDATE", function() Soon() end)
M.On("BAG_UPDATE_DELAYED", function()
  if MerchantFrame and MerchantFrame:IsShown() then Soon() end
end)
M.On("MERCHANT_CLOSED", function()
  wipe(pending)
  if strip then strip:Hide() end
end)
M.On("MODIFIER_STATE_CHANGED", function(_, key)
  if not (strip and strip:IsShown() and key and key:find("SHIFT")) then return end
  local owner = GameTooltip:GetOwner()
  if owner and owner:GetParent() == strip then ShowTip(owner) end
end)
