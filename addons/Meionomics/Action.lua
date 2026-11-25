-- The one thing to do with an item, the same wording, place and colours on every tooltip and
-- list (item tooltips, AH browse, craft hover). Callers render it with A.Line / A.Rows, never
-- their own variant.
--   P.BestAction(itemID, bound[, link]) -> act or nil (item data not loaded)
--     act.verb    equip | learn | known | use | keep | craft | ah | vendor | disenchant | none
--     act.value   copper each for selling verbs (craft: what one is worth crafted)
--     act.reason  short why, or nil
--     act.runner  { verb, value }: the next best way to sell it
--     act.rec     craft: the recipe; act.flip { each, qty }: AH listings under vendor price
--     act.sale    P.SaleOptions + R.AHNet + craft, for the Shift comparison; act.ev P.Evidence
--   A.Line(act[, opts]) -> left, right: "Best: <icon> Vendor"   1s (opts.reason: the why too)
--   A.Rows(rows, act) appends the Shift comparison in T.Render's row shape
--   A.FlipLine(act) -> "Buy on AH, vendor: +4c each (12 up)" or nil
--   A.PriceLine(act[, opts]) -> "[bag] 16c   [coins] 21c" (R.AHNet price) or "Can't sell"
--   A.Compact(act[, opts]) -> the compact tooltip's rows, icons over words
local _, M = ...
local P, R = M.Prices, M.Recipes
local A = {}
M.Action = A

A.VERBS = {
  equip = { "Equip", "3fd0ff" }, learn = { "Learn", "8fa8ff" }, use = { "Use", "ffd24d" },
  keep = { "Keep", "ffd24d" }, craft = { "Craft into", "ffffff" }, ah = { "AH", "4fe36a" },
  vendor = { "Vendor", "c8c8c8" }, disenchant = { "Disenchant", "b073ff" },
  known = { "Known", "a8a8a8" }, none = { "No AH data", "a8a8a8" },
}
A.LABEL = "ffd100"
-- The verdict is to be seen, not read: Blizzard's own art, one per verb. Vendor (a sack, square)
-- and AH (the auctioneer's coin stack, round) must never look alike: the gossip vendor bag was a
-- dark blob at line height
local function Tex(path) return "|T" .. path .. ":0:0:0:0:64:64:5:59:5:59|t" end
A.ICONS = {
  vendor = Tex("Interface\\Icons\\INV_Misc_Bag_10"),
  ah = "|TInterface\\Minimap\\Tracking\\Auctioneer:0|t",
  disenchant = Tex("Interface\\Icons\\INV_Enchant_DustStrange"),
  craft = Tex("Interface\\Icons\\Trade_BlackSmithing"),
  keep = "|TInterface\\PetBattles\\PetBattle-LockIcon:0|t",
  equip = "|A:bags-greenarrow:0:0|a",
  learn = Tex("Interface\\Icons\\INV_Misc_Book_09"),
  use = "|TInterface\\Cursor\\Interact:0|t",
  -- grey ?, apart from UNSURE's gold one
  none = "|TInterface\\GossipFrame\\IncompleteQuestIcon:0|t",
}
local UNSURE = "|TInterface\\RaidFrame\\ReadyCheck-Waiting:0|t"
local MARK = "|TInterface\\ChatFrame\\ChatFrameExpandArrow:0|t"
local CRAFT_NAME = 20
local GOOD, FADED = "4fe36a", "d0d0d0"
-- locked boxes a vendor pays for (ItemSparse LockID, SellPrice > 0); rogues buy them on the AH to
-- level lockpicking. Junkboxes are locked too but vendors won't take them.
local LOCKBOX = { [4632] = true, [4633] = true, [4634] = true, [4636] = true, [4637] = true,
  [4638] = true, [5758] = true, [5759] = true, [5760] = true, [6354] = true, [6355] = true,
  [13875] = true, [13918] = true }
local SELL = { "vendor", "ah", "disenchant", "craft" }
local SELLS = { vendor = true, ah = true, disenchant = true, craft = true }
-- a runner-up this close to the winner is worth a glance
local CLOSE = 0.85

local function Hex(hex, text) return "|cff" .. hex .. text .. "|r" end
local function Dim(text) return Hex("a8a8a8", text) end

------------------------------------------------------------------------------ Selling
-- the best known recipe using it, by profit: its value per unit of this item is the item's own
-- price plus the recipe's profit shared over the units it takes (also returned: that share)
local function CraftUse(itemID)
  local best, bestE
  for _, rec in ipairs(R.UsedIn(itemID) or {}) do
    if rec.out and next(rec.known or {}) then
      local e = R.Evaluate(rec)
      if e.profit and e.profit > 0 and (not best or R.Before(rec, e, best, bestE)) then
        best, bestE = rec, e
      end
    end
  end
  if not best then return nil end
  local price = R.MatPrice(itemID)
  for _, m in ipairs(best.mats) do
    if m[1] == itemID and price then
      return price + bestE.profit / m[2], best, bestE.profit / m[2]
    end
  end
end

-- P.SaleOptions plus: the AH at R.AHNet's price (sells in a day, else the safe price; not
-- counted when confidence is low: no guesses, unless only the prices disagree, which the safe
-- price allows for), crafting it
function A.Sale(itemID, bound)
  local s = P.SaleOptions(itemID, bound)
  local ok = P.Auctionable(itemID)
  s.ev = ok and not bound and P.Evidence(itemID) or nil
  local ev = s.ev
  -- the craft lines' value (R.AHNet), so the price line and "sells" never disagree
  local net, _, day
  if ok and not bound then net, _, day = R.AHNet(itemID) end
  if net then
    s.ah = math.floor(net + 0.5)
    s.safe = ev and ev.level ~= "high" and not day or nil
  elseif s.ah and ev and ev.price then
    s.ah = math.min(s.ah, math.floor(ev.price * (1 - P.AH_CUT) + 0.5))
    s.safe = ev.level ~= "high"
  end
  if s.ah and ev and ev.level == "low" and not ev.spreadOnly and not s.why.ah then
    s.why.ah = "price unsure"
  end
  local share
  s.craft, s.rec, share = CraftUse(P.Id(itemID))
  local alt, altK
  for _, k in ipairs(SELL) do
    local v = s[k]
    if v and v > 0 and not s.why[k] then
      if v > (s.value or 0) then
        s.runner, s.method, s.value = s.method, k, v
      elseif not s.runner or v > s[s.runner] then
        s.runner = k
      end
      if k ~= "craft" and (not alt or v > alt) then alt, altK = v, k end
    end
  end
  -- what crafting adds per unit over the best other way to sell it (else over its mat price)
  if s.craft then
    s.gain = alt and (s.craft - alt) or share
    s.gainVs = altK or "mats"
  end
  return s
end

-- how many of it the craft queue's recipes take
local function Queued(itemID)
  local Cr = M.Craft
  if not (Cr and Cr.Queue) then return nil end
  local n = 0
  for id, crafts in pairs(Cr.Queue()) do
    local rec = M.db.recipes[id]
    for _, m in ipairs(rec and rec.mats or {}) do
      if m[1] == itemID then n = n + m[2] * crafts end
    end
  end
  return n > 0 and n or nil
end

-- listings under what a vendor pays: buy, then vendor. Our scan counts them; else TSM's min
local function Flip(itemID, vendor)
  if not vendor then return nil end
  local own = M.Auction and M.Auction.Get(itemID)
  if own and own.flipQty then return { each = own.flipEach, qty = own.flipQty } end
  local gain = P.FlipGain(vendor, P.Get(itemID, "minBuyout"))
  if gain then return { each = gain } end
end

local BIS_UPGRADE = 0.05 -- Forever Leveling BiS's least gain it calls an upgrade

-- link: the item as shown, so a random suffix's stats count (the bare itemID has none)
local function Upgrade(itemID, link)
  local api = ForeverLevelingBiS_API
  if not (type(link) == "string" and tonumber(link:match("item:(%d+)")) == itemID) then
    link = select(2, C_Item.GetItemInfo(itemID))
  end
  if not (api and (api.version or 1) >= 2 and link) then return nil end
  local ok, gain = pcall(api.GetGain, link)
  return ok and type(gain) == "number" and gain >= BIS_UPGRADE and gain or nil
end

local function LearnVerb(rec)
  if R.KnownHere(rec) then return "known" end
  local rank = M.Craft and M.Craft.Rank(rec.prof or "")
  if not rank then return nil end
  local learn, _, _, grey, _, _, est = M.Craft.Bands(rec)
  if not learn then return nil end
  if rank < learn then return "keep", ("learn at %s%d"):format(est and "~" or "", learn) end
  if grey and rank >= grey then return "learn", "no skill-ups" end
  return "learn", "learnable now"
end

local function Usable(itemID, minLevel)
  if minLevel and minLevel > (UnitLevel("player") or 0) then return false end
  local ok, usable = pcall(C_Item.IsUsableItem, itemID)
  return ok and usable and true or false
end

------------------------------------------------------------------------------ The action
local function SellReason(s)
  local m = s.method
  if m == "vendor" and s.ah and not s.why.ah then
    return ("AH %s %s vendor %s"):format(M.Money(s.ah), s.ah < s.vendor and "<" or "=",
      M.Money(s.vendor))
  end
  if m == "vendor" and s.why.ah then return s.why.ah == "slow" and "AH slow" or s.why.ah end
  if m == "ah" then
    local per = s.s and s.s.perDay
    local text = per and ("sells %s/day in region"):format(M.Count(per))
    return s.safe and ((text and (text .. ", ") or "") .. "safe price") or text
  end
  if m == "craft" then return nil end
end

-- key: an itemID or a variant key (P.Id): the sale is priced by it, the rest goes by the itemID.
-- link: the item as shown (suffix, enchant), for the upgrade check; else the variant's own
function P.BestAction(key, bound, link)
  local itemID = P.Id(key)
  local _, _, quality, _, minLevel, _, _, _, _, _, _, classID = C_Item.GetItemInfo(itemID)
  if not quality then return nil end
  local s = A.Sale(key, bound)
  local act = { id = itemID, sale = s, ev = s.ev, rec = s.method == "craft" and s.rec or nil,
    flip = not bound and Flip(key, s.vendor) or nil }
  local function Sell()
    if s.method then
      act.verb, act.value, act.reason = s.method, s.value, SellReason(s)
      if s.method == "craft" then act.rec = s.rec end
      local r = s.runner
      -- vendor over AH: the reason already gives both prices
      if s.method == "vendor" and r == "ah" then r = nil end
      act.runner = r and { r, s[r] } or nil
    elseif s.ah then
      act.verb, act.value = "ah", s.ah
      act.reason = s.why.ah == "slow" and "slow seller" or s.why.ah
    elseif P.Auctionable(itemID) and not bound then
      act.verb = "none"
    else
      act.verb, act.reason = "keep", "can't be sold"
    end
  end
  local function Hold(verb, reason)
    act.verb, act.reason = verb, reason
    local m = s.method
    act.runner = m and { m, s.value } or nil
  end
  if quality == 0 then
    if s.vendor then act.verb, act.value = "vendor", s.vendor else Sell() end
    return act
  end
  if classID == 12 then Hold("keep", "quest item") return act end
  if classID == 13 then Hold("keep", "key") return act end
  if classID == 2 or classID == 4 then
    if not link and M.Auction and M.Auction.IsVariant(key) then link = M.Auction.Link(key) end
    local gain = Upgrade(itemID, link)
    if gain then Hold("equip", ("%+.1f upgrade"):format(gain)) else Sell() end
    return act
  end
  -- the AH whenever it has a price, low confidence or not: vendors pay pennies for them
  if LOCKBOX[itemID] and s.ah then
    act.verb, act.value, act.reason = "ah", s.ah, "rogues buy them for lockpicking"
    act.runner = s.vendor and { "vendor", s.vendor } or nil
    return act
  end
  local queued = Queued(itemID)
  if queued then Hold("keep", queued .. " for queued crafts") return act end
  if classID == 9 then
    local taught = R.TaughtBy(itemID)
    local verb, reason
    if taught and taught[1] then verb, reason = LearnVerb(taught[1]) end
    if verb then Hold(verb, reason) else Sell() end
    return act
  end
  if classID == 0 then
    if Usable(itemID, minLevel) then Hold("use") else Sell() end
    if not SELLS[act.verb] then return act end
    act.reason = act.reason and ("can't use, " .. act.reason) or "can't use"
    return act
  end
  Sell()
  return act
end

------------------------------------------------------------------------------ Rendering
local function Icon(verb, rec)
  local out = verb == "craft" and rec and rec.out and C_Item.GetItemIconByID(rec.out)
  if out then return Tex(out) .. " " end
  return A.ICONS[verb] and (A.ICONS[verb] .. " ") or ""
end

-- a craft's recipe name in its difficulty colour at your rank, like the profession window
local function CraftName(rec, name)
  local C = M.Craft
  local hex = C and C.DiffHex and C.DiffHex(rec) or A.VERBS.craft[2]
  return Hex(hex, name or rec.name or "?")
end

local function VerbText(verb, rec)
  local v = A.VERBS[verb]
  if verb == "craft" and rec then
    return Icon(verb, rec) .. Hex(v[2], v[1] .. " ") .. CraftName(rec)
  end
  return Icon(verb, rec) .. Hex(v[2], v[1])
end

local function Value(verb, value)
  if not value then return nil end
  return (verb == "vendor" and "" or "~") .. M.Money(value)
end

local BAD = "ff5a5a"
local GAIN_VS = { ah = "AH", vendor = "vendor", disenchant = "disenchanting", mats = "mat price" }

-- a craft's worth is what it gains over selling the item, not what the made item fetches
local function Gain(s, n)
  local g = s and s.gain
  if not g then return nil end
  g = g * (n or 1)
  if g >= 0 then return Hex(GOOD, "+") .. M.Money(g, GOOD) end
  return Hex(BAD, "-") .. M.Money(-g, BAD)
end

local function Worth(act, verb, value, n)
  if verb == "craft" then return Gain(act.sale, n) end
  return Value(verb, value and value * (n or 1))
end

-- opts.label replaces "Best: "; opts.count: values are for that many; opts.reason: the why (Shift
-- only: at a glance the icon and colours say it); opts.prices: A.PriceLine follows, so no
-- vendor or AH runner-up
function A.Line(act, opts)
  opts = opts or {}
  local n = opts.count or 1
  local left = (opts.label or Hex(A.LABEL, "Best: ")) .. VerbText(act.verb, act.rec)
  if act.reason and opts.reason then left = left .. Dim(" · " .. act.reason) end
  local r = act.runner
  local hold = not SELLS[act.verb]
  if r and opts.prices and (r[1] == "vendor" or r[1] == "ah") then r = nil end
  if r and r[2] and (hold or (act.value and r[2] >= act.value * CLOSE)) then
    local name = r[1] == "craft" and "craft" or A.VERBS[r[1]][1]
    left = left .. Dim(" (" .. (hold and "sell: " or "") .. name .. " ")
      .. Worth(act, r[1], r[2], n) .. Dim(")")
  end
  return left, Worth(act, act.verb, act.value, n)
end

-- "[bag] 16c   [coins] 21c", this order: icons, no words ("if we have icons do we need
-- text"). The winner green behind a gold arrow, the other faded; opts.faded: both faded, no
-- arrow (Best is something else). AH is only ever R.AHNet's price (A.Sale): faded
-- with a gold ? when confidence is low or it doesn't sell, a grey ? with no AH data, left
-- out when it
-- can't be auctioned. "Can't sell" when neither takes it. opts.count: for that many;
-- opts.after: appended to the AH value; opts.under: nil when only a vendor takes it and Best
-- is Vendor (the A.Line above already gives the price)
function A.PriceLine(act, opts)
  opts = opts or {}
  local n = opts.count or 1
  local s, ev = act.sale, act.ev
  local noAH = not P.Auctionable(act.id) or s.why.ah == "soulbound"
  if noAH and not s.vendor then return Dim("Can't sell") end
  if noAH and act.verb == "vendor" and opts.under then return nil end
  local win = not opts.faded and (SELLS[act.verb] and act.verb or s.method)
  local function Part(k, v)
    local icon = A.ICONS[k]
    if k ~= win then return icon .. " " .. M.Money(v * n, FADED) end
    return MARK .. icon .. " " .. M.Money(v * n, GOOD)
  end
  local parts = {}
  if s.vendor then parts[1] = Part("vendor", s.vendor) end
  if noAH then
  elseif not ev then
    parts[#parts + 1] = A.ICONS.ah .. " " .. A.ICONS.none
  elseif s.why.ah or not s.ah then
    -- on a small region most items sell slowly: a bare ? hid the price on nearly every tooltip
    local price = s.ah and (M.Money(s.ah * n, FADED) .. " ") or ""
    parts[#parts + 1] = A.ICONS.ah .. " " .. price .. UNSURE
      .. (opts.after and (" " .. opts.after) or "")
  else
    parts[#parts + 1] = Part("ah", s.ah) .. (opts.after and (" " .. opts.after) or "")
  end
  return table.concat(parts, "   ")
end

-- the compact tooltip's rows ({ left, right } each), icons over words. Best Vendor or AH: the
-- price line alone, its arrow marks Best. Anything else:
-- its icon and value (Craft: the output's name, as its icon alone doesn't say what it becomes;
-- no value: its word), then the price line faded as the fallback. opts.shopping: the price
-- line only; opts.after: PriceLine's
function A.Compact(act, opts)
  opts = opts or {}
  local verb = act.verb
  if opts.shopping or verb == "vendor" or verb == "ah" then
    return { { A.PriceLine(act, { after = opts.after }) } }
  end
  local v = A.VERBS[verb]
  local what
  if verb == "craft" and act.rec then
    local name = act.rec.name or "?"
    if #name > CRAFT_NAME then name = name:sub(1, CRAFT_NAME - 1) .. "..." end
    what = CraftName(act.rec, name)
  end
  local value = Worth(act, verb, act.value)
  local text = Icon(verb, act.rec) .. (what and (what .. (value and " " or "")) or "")
    .. (value or (what and "" or Hex(v[2], v[1])))
  return { { text }, { A.PriceLine(act, { faded = true, after = opts.after }) } }
end

function A.FlipLine(act)
  local f = act.flip
  if not f then return nil end
  local up = f.qty and Dim((" (%d up)"):format(f.qty)) or ""
  return Hex("4fe36a", "Buy on AH, vendor: +") .. M.Money(f.each) .. Dim(" each") .. up
end

-- every way to sell it, the winner coloured, the others with why they lose or don't count
function A.Rows(rows, act, label)
  local function Add(kind, left, right)
    rows[#rows + 1] = { kind = kind, left = left, right = right }
  end
  local left, right = A.Line(act, { reason = true, label = label })
  Add("row", left, right)
  local s = act.sale
  for _, k in ipairs(SELL) do
    local why = s.why[k]
    if s[k] or why then
      local name = ({ vendor = "Vendor", ah = "AH after cut", disenchant = "Disenchant",
        craft = "Craft into " })[k]
      if k == act.verb then name = Hex(A.VERBS[k][2], name) end
      if k == "craft" then name = name .. (s.rec and CraftName(s.rec) or "?") end
      local notes = k == "ah" and s.safe and "safe price" or nil
      if k == "craft" and s.gainVs then notes = "vs " .. GAIN_VS[s.gainVs] end
      if why then notes = notes and (notes .. ", " .. why) or why end
      if notes then name = name .. Dim(" (" .. notes .. ")") end
      Add("row", "  " .. name, Worth(act, k, s[k]))
    end
  end
  local flip = A.FlipLine(act)
  if flip then Add("row", "  " .. flip) end
  return rows
end
