-- Item and trainer tooltips. Items: normally a compact block of the facts chosen in /meio
-- options (two per line where they fit); Shift shows everything as a ledger, with a stack column
-- when the hovered stack is more than one. Trainer recipes: see OnTrainer.
--
-- Three steps, so the look can change without touching the numbers:
--   Gather(itemID)               -> the facts
--   Compact(d) / Ledger(d)       -> rows, see T.Rows
--   T.Render(tt, rows)           -> tooltip lines; colours and wording live in T.style
local _, M = ...
local P, R = M.Prices, M.Recipes
local T = {}
M.Tooltip = T

T.style = {
  accent = "f2c94c", grey = "b4b4b4", dim = "959595", good = "4fe36a", bad = "ff5a5a",
  -- pink, not orange or yellow: those read as recipe difficulty
  warn = "ff80c8",
  label = { 0.78, 0.78, 0.78 }, value = { 1, 1, 1 },
  sep = " · ", indent = "  ",
  pctMark = 0.15,   -- min buyout this far under / over market value gets coloured
  colGap = 14,      -- between the each and stack columns
}
local S = T.style
local function C(key, text) return "|cff" .. S[key] .. text .. "|r" end

-- what the compact view can show, in order; defaults are the at-a-glance ones
T.FIELDS = {
  { key = "buyout", name = "Min buyout", on = true,
    tip = "Cheapest auction up now, and how many are up" },
  { key = "vsMarket", name = "Min buyout vs market", on = true,
    tip = "How far the cheapest auction is under or over market value" },
  { key = "sellDay", name = "Sells in a day", on = true,
    tip = "The best price that still sells within a day about 4 times in 5: a little under the "
      .. "cheapest rival, or above a dip that a day's sales will clear. Learnt from your own "
      .. "posts (a default guess until about 20 have ended). \"dip\" after the AH price: the "
      .. "cheapest is a temporary low" },
  { key = "soldPerDay", name = "Region sold per day", on = true,
    tip = "How many sell per day across the region" },
  { key = "saleRate", name = "Region sale rate", on = false,
    tip = "Share of region auctions that sell" },
  { key = "market", name = "Market value", on = false, tip = "This realm's market value" },
  { key = "regionMarket", name = "Region market value", on = false,
    tip = "Average market value across the region" },
  { key = "have", name = "You have", on = true,
    tip = "In this character's bags, bank, mail and auctions" },
  { key = "alts", name = "Alts have", on = true,
    tip = "On your other characters, warband and guild banks" },
  { key = "vendor", name = "Vendor price", on = false, tip = "What a vendor pays" },
  { key = "disenchant", name = "Disenchant value", on = true,
    tip = "Green or better gear: average value of what it disenchants into, after the AH cut. "
      .. "Gear shows a Best: line (vendor, AH or disenchant) instead" },
  { key = "convert", name = "Convert value", on = true,
    tip = "Cheapest way to get it by converting other items, e.g. essences (TSM loaded). "
      .. "Shown with Shift; at a glance only when it's under the AH price" },
  { key = "craft", name = "Crafting profit", on = true,
    tip = "For things your recorded recipes make or teach" },
  { key = "usedIn", name = "Best recipe it's used in", on = true,
    tip = "For materials: the most profitable recorded recipe" },
  { key = "group", name = "TSM group", on = false,
    tip = "The TSM group the item is in (TSM loaded), at a glance and with Shift" },
}

-- other tooltips that show items but should stay clean
local SKIP = { ShoppingTooltip1 = true, ShoppingTooltip2 = true, ItemRefShoppingTooltip1 = true,
  ItemRefShoppingTooltip2 = true }

------------------------------------------------------------------------------ Formatting
local function Join(...)
  local out = {}
  for i = 1, select("#", ...) do
    local v = select(i, ...)
    if v and v ~= "" then out[#out + 1] = v end
  end
  return table.concat(out, C("grey", S.sep))
end

-- e: R.Evaluate's; on prices older than R.STALE the figure is dimmed and says how old
local function Profit(p, e)
  if not p then return C("grey", "?") end
  if e and e.stale then
    return C("dim", p >= 0 and "+" or "") .. M.Money(p, S.dim, S.dim)
      .. C("warn", " old " .. R.AgeShort(e.age))
  end
  return p >= 0 and C("good", "+" .. M.Money(p)) or C("bad", "-" .. M.Money(-p))
end

-- how old the AH price is ("3m ago" ours, "2d old" app data, its source named with full): a
-- warning past R.STALE
local function AgeTag(d, full)
  if not d.age then return "" end
  local text = R.AgeShort(d.age) .. (d.ageOwn and " ago" or full and " old (TSM)" or " old")
  return " " .. C(d.age > R.STALE and "warn" or "dim", text)
end

-- red under the "nobody buys it" lines that also make crafts "Slow seller" (Prices.lua)
local function Sold(n)
  local key = n < P.SELLS_PER_DAY and "bad" or n < 5 and "warn" or "good"
  return C(key, M.Count(n))
end
local function PerDay(n) return n and (Sold(n) .. C("grey", "/day in region")) end
local function Pct(f) return ("%d%%"):format(math.floor(f * 100 + 0.5)) end
local function Rate(f)
  return C(f < P.SELLS_RATE and "bad" or f < 0.25 and "warn" or "good", Pct(f))
end

-- min buyout against market value: "-8%"
local function VsMarket(d)
  if not (d.minBuyout and d.market) then return nil end
  local pct = d.minBuyout / d.market - 1
  local text = ("%+d%%"):format(math.floor(pct * 100 + 0.5))
  if pct <= -S.pctMark then return C("good", text) end
  if pct >= S.pctMark then return C("warn", text) end
  return C("dim", text)
end

local function ClassName(name, class)
  local c = class and RAID_CLASS_COLORS and RAID_CLASS_COLORS[class]
  return c and ("|c%s%s|r"):format(c.colorStr, name) or name
end

local function Where(me)
  return Join(
    me.bags > 0 and (C("grey", "bags ") .. me.bags),
    (me.bank or 0) > 0 and (C("grey", "bank ") .. me.bank),
    (me.mail or 0) > 0 and (C("grey", "mail ") .. me.mail),
    (me.auctions or 0) > 0 and (C("grey", "on AH ") .. me.auctions))
end

-- by any character: alts craft for each other
local function Known(rec) return rec.known and next(rec.known) ~= nil end
local function NotKnown(rec) return Known(rec) and "" or C("dim", " (not known)") end

-- in its difficulty colour at your rank, like the profession window
local function RecName(rec)
  local hex = M.Craft and M.Craft.DiffHex and M.Craft.DiffHex(rec)
  local name = rec.name or "?"
  return hex and ("|cff" .. hex .. name .. "|r") or name
end
-- a recipe item's recipe for this character: known, learnable, too low, or past grey. nil when
-- the profession isn't this character's (then NotKnown says whether anyone knows it)
local function LearnState(rec)
  if R.KnownHere(rec) then return "known", "grey" end
  local rank = M.Craft.Rank(rec.prof or "")
  local learn, _, _, grey, _, _, estLearn = M.Craft.Bands(rec)
  if not (rank and learn) then return nil end
  if rank < learn then
    return ("needs %s%d more skill"):format(estLearn and "~" or "", learn - rank), "bad"
  end
  if grey and rank >= grey then return "learnable, no skill-ups", "grey" end
  return "learnable now", "good"
end
-- Shift heading: "Teaches X (learnable now)"; no state when known, "Known by" says so
local function Teaches(rec)
  local state, tone = LearnState(rec)
  if state == "known" then return "Teaches " .. (rec.name or "?") end
  local tail = state and C(tone, " (" .. state .. ")") or NotKnown(rec)
  return "Teaches " .. (rec.name or "?") .. tail
end
-- compact: the item's title already names the recipe, so just the state
local function TeachesShort(rec)
  local state, tone = LearnState(rec)
  if not state then return "Teaches" .. NotKnown(rec) end
  return C(tone, state:sub(1, 1):upper() .. state:sub(2))
end

local function Plural(n, word) return n .. " " .. word .. (n == 1 and "" or "s") end

------------------------------------------------------------------------------ Facts
-- bound: soulbound now (a bag or equipped item); nil goes by the bind type
-- key: an itemID, or a variant key (P.Id) for a random-suffix item we have AH data on
-- link: the item as shown, for the Best line's upgrade check (a suffix's stats)
local function Gather(key, bound, link)
  local itemID = P.Id(key)
  local d = { id = itemID, variant = key ~= itemID }
  for k in pairs(P.SOURCES) do d[k] = P.Get(key, k) end
  d.vendor = P.Get(itemID, "vendor")
  d.inv = M.Inventory.Get(itemID)
  d.hasAH = d.minBuyout or d.market or d.regionMarket
  d.age, d.ageOwn = P.Age(key)
  local classID = select(12, C_Item.GetItemInfo(itemID))
  if classID == 2 or classID == 4 then d.disenchant = P.Disenchant(itemID) end
  d.convert = P.Convert(itemID)
  d.group = M.db.fields.group and P.Group(itemID)
  local ok, why = P.Auctionable(itemID)
  -- IsBound is true for quest items too: their own reason says more
  if ok and bound then ok, why = false, "soulbound" end
  if not ok then d.hasAH, d.noAH = nil, why end
  -- before BestAction: its AH price and the craft lines' share R.AHNet's cache
  R.ResetCache()
  d.act = P.BestAction(key, bound, link)
  d.ev = d.hasAH and (d.act and d.act.ev or P.Evidence(key)) or nil
  d.sd = d.hasAH and M.SellDay.Quote(key) or nil
  local recs = R.Making(itemID)
  if recs then
    d.craft, d.e = R.Best(recs)
  else
    recs = R.TaughtBy(itemID)
    if recs then d.craft, d.e = R.Best(recs); d.teaches = d.craft ~= nil end
  end
  -- as a material: the recipes making something, most profitable first
  local uses = R.UsedIn(itemID)
  if uses then
    d.usedIn = #uses
    d.uses = {}
    for _, rec in ipairs(uses) do
      if rec.out then
        local e = R.Evaluate(rec)
        if e.profit then d.uses[#d.uses + 1] = { rec = rec, e = e } end
      end
    end
    table.sort(d.uses, function(a, b) return R.Before(a.rec, a.e, b.rec, b.e) end)
    for _, u in ipairs(d.uses) do
      if Known(u.rec) then d.bestKnown = u break end
    end
  end
  return d
end

------------------------------------------------------------------------------ Rows
-- { kind = "gap" | "head" | "row", left, right, mid, best }: mid is an extra column (unused
-- now: per-item prices only); best and bestLast: the verdict block's first and last rows
-- (T.bestLine, T.bestLast)
local function Add(rows, kind, left, right, mid)
  rows[#rows + 1] = { kind = kind, left = left, right = right, mid = mid }
end

local function Age(sec)
  if sec < 3600 then return math.max(1, math.floor(sec / 60)) .. "m" end
  if sec < 86400 then return math.floor(sec / 3600) .. "h" end
  return math.floor(sec / 86400) .. "d"
end

local LEVEL = {
  high = { "good", "High" }, medium = { "warn", "Medium" }, low = { "bad", "Low" },
}

-- Shift: how far to trust the AH figures above (P.Evidence)
local function EvidenceRows(rows, ev, Money)
  local lv = LEVEL[ev.level]
  Add(rows, "row", "Price confidence", C(lv[1], lv[2]))
  if #ev.reasons > 0 then Add(rows, "row", C("dim", table.concat(ev.reasons, S.sep))) end
  if ev.level ~= "high" then Money("Safe price", ev.price) end
  local ages = Join(ev.scanAge and ("scan " .. Age(ev.scanAge)),
    ev.realmAge and ((P.Source() or "app") .. " realm " .. Age(ev.realmAge)),
    ev.regionAge and ("region " .. Age(ev.regionAge)))
  if ages ~= "" then Add(rows, "row", C("dim", "Data: " .. ages)) end
end

-- Shift: your own auction history (TSM's ledger and accounting)
-- MeioStats (wow-stats' addon, optional): lifetime totals from TSM's full ledger, vendor too
local function Totals(itemID)
  local api = MeioStats and MeioStats.Money and MeioStats.Money.ItemTotals
  if not api then return nil end
  local ok, t = pcall(api, itemID)
  return ok and type(t) == "table" and t or nil
end

local BASIS = { buy = " vs buy", craft = " vs mats" }   -- craft: today's mats, past sales

local function TotalsRow(rows, t)
  if (t.sold or 0) > 0 then
    local vendor = (t.vendor or 0) > 0 and C("dim", S.sep .. ("%d vendor"):format(t.vendor)) or ""
    local profit = t.profit and (Profit(t.profit) .. C("dim", BASIS[t.basis] or ""))
    Add(rows, "row", ("Your sales (%d)"):format(t.sold) .. vendor,
      Join(t.revenue and M.Money(t.revenue), profit))
  elseif (t.bought or 0) > 0 then
    Add(rows, "row", ("Your buys (%d)"):format(t.bought), t.spent and M.Money(t.spent))
  end
end

local function HistoryRows(rows, ev, Money, totals)
  local now = M.Now()
  for _, k in ipairs({ "sale", "buy" }) do
    local t = ev[k]
    if t then
      local when = (" (%s ago, %s)"):format(Age(now - t.time), Plural(t.n, k))
      Add(rows, "row", "Your last " .. k .. C("dim", when), M.Money(t.price))
    end
  end
  if totals then TotalsRow(rows, totals) end
  -- the totals row's revenue / sold already says it
  if not (totals and (totals.sold or 0) > 0) then Money("Your avg sale", ev.avgSell) end
  Money("Your avg buy", ev.avgBuy)
end

-- compact: self-labelled snippets, short ones two to a line, wide ones (recipe names) alone
-- a recipe's materials, one row each: "  4x Bolt of Mageweave (have 12)", their cost
local function MatRows(rec)
  local out = {}
  for _, m in ipairs(rec.mats or {}) do
    local h = M.Craft.Have(m[1])
    local mine = h.bags + h.bank + h.mail
    local price = R.MatPrice(m[1])
    out[#out + 1] = { C("grey", ("  %dx "):format(m[2]))
      .. (C_Item.GetItemNameByID(m[1]) or ("item " .. m[1]))
      .. (mine > 0 and C("dim", (" (have %d)"):format(mine)) or ""),
      price and M.Money(price * m[2]) or C("grey", "no price") }
  end
  return out
end

local function CompactFacts(d, on)
  local short, wide = {}, {}
  local function Short(text) if text then short[#short + 1] = text end end
  -- with a Best line, A.PriceLine carries the AH price (the safe one) instead
  if d.hasAH and not d.act then
    local vs = on.vsMarket and VsMarket(d)
    if on.buyout then
      local up = d.numAuctions and C("dim", " (" .. d.numAuctions .. ")") or ""
      local dip = d.sd and (d.sd.dip and C("warn", " dip") or d.sd.jump and C("warn", " jump"))
        or ""
      Short((d.minBuyout and (C("grey", "AH ") .. M.Money(d.minBuyout)
        .. (vs and (" " .. vs) or "") .. dip .. up) or C("grey", "AH none up")) .. AgeTag(d))
    elseif vs then
      Short(C("grey", "vs market ") .. vs)
    end
    if on.soldPerDay and d.soldPerDay then
      local rate = on.saleRate and d.saleRate
        and (C("grey", S.sep) .. Rate(d.saleRate) .. C("grey", " sell")) or ""
      Short(PerDay(d.soldPerDay) .. rate)
    elseif on.saleRate and d.saleRate then
      Short(Rate(d.saleRate) .. C("grey", " sell"))
    end
    if d.ev then Short(C("grey", "Conf ") .. C(LEVEL[d.ev.level][1], LEVEL[d.ev.level][2])) end
  end
  if on.sellDay and d.sd then
    if d.sd.price then
      -- with a Best line the AH line (and its dip mark) isn't shown
      local dip = d.act and (d.sd.dip and C("warn", " dip") or d.sd.jump and C("warn", " jump"))
        or ""
      Short(C("grey", "Day ") .. M.Money(d.sd.price)
        .. C("dim", " (" .. M.SellDay.Odds(d.sd.P) .. ")") .. dip)
    elseif d.sd.slow then
      Short(C("warn", "Slow seller"))
    end
  end
  if d.hasAH and not d.act then
    if on.market and d.market then Short(C("grey", "Market ") .. M.Money(d.market)) end
    if on.regionMarket and d.regionMarket then
      Short(C("grey", "Region ") .. M.Money(d.regionMarket))
    end
  end
  local inv = d.inv
  if inv and on.have and inv.me.total > 0 then
    local bank = inv.me.total - inv.me.bags
    local where = bank > 0 and C("grey", " (" .. bank .. " bank)") or ""
    Short(C("grey", "Have ") .. inv.me.total .. where)
  end
  local others = inv and (inv.altTotal + inv.warband + inv.guild) or 0
  if on.alts and others > 0 then Short(C("grey", "Alts ") .. others) end
  -- the Best: line already weighs both
  if on.vendor and d.vendor and not d.act then
    Short(C("grey", "Vendor ") .. M.Money(d.vendor))
  end
  if on.disenchant and d.disenchant and not d.act then
    Short(C("grey", "Disenchant ~") .. M.Money(d.disenchant))
  end
  local ah = d.minBuyout or d.market
  if on.convert and d.convert and not (ah and ah <= d.convert) then
    Short(C("grey", "Convert ") .. M.Money(d.convert))
  end
  local rec, e = d.craft, d.e
  if on.craft and rec then
    -- the verdict line already says "Known"
    local what = d.teaches and not (d.act and d.act.verb == "known") and TeachesShort(rec)
      or ((rec.prof or "Craft") .. NotKnown(rec))
    -- what the mats cost is Shift's only
    local right
    if rec.out then
      local sells = e.noAH and C("grey", "no AH price")
        or e.value and (C("grey", "sells ") .. M.Money(e.value))
      right = Join(sells, not e.noAH and Profit(e.profit, e) or nil)
    end
    wide[#wide + 1] = { what, right ~= "" and right or nil }
    -- a pattern: is it worth buying? demand for what it makes, crafts to earn its price back
    if d.teaches and rec.out then
      local perDay = P.Get(rec.out, "soldPerDay")
      local cost = d.minBuyout or d.market
      local payback = M.Recipes.Payback(cost, e.profit)
      local demand = perDay and (C("grey", "Made item ") .. PerDay(perDay))
      local back = payback and (C("grey", "pays back in ") .. Plural(payback, "craft"))
      if demand or back then wide[#wide + 1] = { demand or " ", back } end
    end
  end
  -- uses[1] is the most profitable: when even that loses money the line is noise
  local top = d.uses and d.uses[1]
  local best = top and top.e.profit > 0 and (d.bestKnown or top)
  if on.usedIn and best and not (d.act and d.act.verb == "craft") then
    wide[#wide + 1] = { C("grey", "Best use: ") .. RecName(best.rec)
      .. NotKnown(best.rec), Profit(best.e.profit, best.e) }
  end
  if d.group then wide[#wide + 1] = { C("grey", "TSM group: ") .. d.group } end
  return short, wide
end

-- after the price line's AH value, dimmed: min buyout vs market and how many are up
local function PriceAfter(d)
  local on = M.db.fields
  local pct = on.vsMarket and d.minBuyout and d.market
    and ("%+d%%"):format(math.floor((d.minBuyout / d.market - 1) * 100 + 0.5))
  local up = on.buyout and d.numAuctions and ("(" .. d.numAuctions .. ")")
  local text = (pct and up) and (pct .. " " .. up) or pct or up
  return (text and C("dim", text) or "") .. AgeTag(d)
end

local function Compact(d)
  local short, wide = CompactFacts(d, M.db.fields)
  if #short == 0 and #wide == 0 and not d.act then return nil end
  -- no leading blank: tidiers place the block, and a blank above Best reads as a gap
  local rows = {}
  if d.act then
    -- shopping: what to do with it once bought reads oddly, but the prices still help
    local compact = M.Action.Compact(d.act, { shopping = d.shopping, after = PriceAfter(d) })
    for i, r in ipairs(compact) do
      Add(rows, "row", r[1], r[2])
      rows[#rows].best = i == 1 and not d.shopping or nil
    end
    local flip = not d.shopping and M.Action.FlipLine(d.act)
    if flip then Add(rows, "row", flip) end
    if #compact > 0 and not d.shopping then rows[#rows].bestLast = true end
  end
  for i = 1, #short, 2 do Add(rows, "row", short[i], short[i + 1]) end
  for _, w in ipairs(wide) do Add(rows, "row", w[1], w[2]) end
  return rows
end

-- everything, one fact per line under small headings; prices per item (a stack column was
-- misread against the AH's each), one total for what you hold
local function Ledger(d)
  local rows = {}
  local function Money(label, v)
    if v then Add(rows, "row", label, M.Money(v)) end
  end
  Add(rows, "head", "Meionomics", C("dim", "each"))
  if d.act then
    M.Action.Rows(rows, d.act)
    rows[2].best = true
  end
  if d.noAH then Add(rows, "row", C("dim", "Can't be auctioned: " .. d.noAH)) end
  local ev = d.ev
  if d.hasAH then
    if d.variant then
      Add(rows, "row", C("dim", "AH prices for this suffix" .. S.sep .. "region sales: all"))
    end
    local sellers = ev and ev.sellers and (", " .. Plural(ev.sellers, "seller")) or ""
    local up = d.numAuctions and C("dim", " (" .. d.numAuctions .. " up" .. sellers .. ")") or ""
    if d.minBuyout then
      local vs = VsMarket(d)
      Money("Min buyout" .. up .. (vs and (" " .. vs) or "") .. AgeTag(d, true), d.minBuyout)
    else
      Add(rows, "row", "Min buyout", C("grey", "none up"))
    end
    Money("Market value", d.market)
    M.Ledger.SellDayRows(rows, d.sd)
    if d.soldPerDay then
      -- colour codes don't nest: the dim text is closed around the coloured rate
      local rate = d.saleRate
        and (C("dim", " (") .. Rate(d.saleRate) .. C("dim", " sell)")) or ""
      Add(rows, "row", "Region sold/day" .. rate, Sold(d.soldPerDay))
    end
    if ev then EvidenceRows(rows, ev, Money) end
  end
  if not d.act then Money("Disenchant (avg)", d.disenchant) end
  if M.db.fields.convert then Money("Convert value", d.convert) end
  -- TSM Accounting, while TSM is loaded (our own ledger comes with the AH and bank phases)
  local totals = Totals(d.id)
  if ev then
    HistoryRows(rows, ev, Money, totals)
  elseif totals then
    TotalsRow(rows, totals)
  end
  if d.group then Add(rows, "row", "TSM group", d.group) end
  local inv = d.inv
  if inv then
    Add(rows, "row", "You have " .. inv.me.total, Where(inv.me))
    local value = d.act and d.act.value
    if value and inv.me.total > 1 then
      Add(rows, "row", "Your " .. inv.me.total, M.Money(value * inv.me.total))
    end
    for i, alt in ipairs(inv.alts) do
      if i > 4 then
        Add(rows, "row", C("dim", "+" .. (#inv.alts - 4) .. " more alts"))
        break
      end
      Add(rows, "row", ClassName(alt.name, alt.class), tostring(alt.total))
    end
    if inv.warband > 0 then Add(rows, "row", "Warband bank", tostring(inv.warband)) end
    if inv.guild > 0 then Add(rows, "row", "Guild bank", tostring(inv.guild)) end
  end
  local rec, e = d.craft, d.e
  -- a recipe item: the crafting panel's recipe block (skill-up bands, learning cost, known by)
  local recipeRows = rec and d.teaches
    and M.Craft.RecipeRows(rec.id, { noHead = true, mats = true,
      outLabel = "|cff" .. M.Action.LABEL .. "Output:|r " })
  if recipeRows then
    Add(rows, "head", Teaches(rec))
    for _, r in ipairs(recipeRows) do rows[#rows + 1] = r end
  elseif rec then
    Add(rows, "head", (d.teaches and ("Teaches " .. (rec.name or "?"))
      or ((rec.prof or "Craft") .. " craft")) .. NotKnown(rec))
    Add(rows, "row", "Materials", M.Money(e.complete and e.cost or nil))
    for _, m in ipairs(MatRows(rec)) do Add(rows, "row", m[1], m[2]) end
    if rec.out then
      local made = R.Made(rec)
      Add(rows, "row", e.where == "vendor" and "Sells to vendor" or "Sells, after 5% cut",
        M.Money(e.value) .. (made > 1 and C("dim", " (" .. made .. " made)") or ""))
      Add(rows, "row", "Profit",
        Join(Profit(e.profit, e), PerDay(P.Get(rec.out, "soldPerDay"))))
    end
    local who = R.KnownBy(rec)
    if #who > 0 then Add(rows, "row", C("dim", "Known by " .. table.concat(who, ", "))) end
  end
  if d.usedIn then
    Add(rows, "head", "Used in " .. Plural(d.usedIn, "recipe"),
      #d.uses > 0 and C("dim", "profit per craft") or nil)
    -- known recipes first; the best unknown one too when it beats them
    local shown = {}
    for _, u in ipairs(d.uses) do
      if #shown == 3 then break end
      if Known(u.rec) then shown[#shown + 1] = u end
    end
    local top = d.uses[1]
    if top and not Known(top.rec) then
      if #shown == 0 then
        for i = 1, math.min(3, #d.uses) do shown[i] = d.uses[i] end
      else
        shown[#shown + 1] = top
      end
    end
    for _, u in ipairs(shown) do
      Add(rows, "row", RecName(u.rec) .. NotKnown(u.rec),
        Join(Profit(u.e.profit, u.e), PerDay(P.Get(u.rec.out, "soldPerDay"))))
    end
  end
  return rows
end

------------------------------------------------------------------------------ Writs
-- Forever's Craftsman's Writs each start a quest asking for the item they name. Found by
-- recipe spell name (client data, always there), else by output name (only once cached)
local WRIT = "^Craftsman's Writ: (.+)$"
local byCraftName

local function CraftsNamed(name)
  if not byCraftName then
    byCraftName = {}
    local function Index(key, id)
      if type(key) ~= "string" then return end
      local ids = byCraftName[key] or {}
      byCraftName[key] = ids
      for _, have in ipairs(ids) do if have == id then return end end
      ids[#ids + 1] = id
    end
    for id, d in pairs(M.CraftData or {}) do
      if d[7] ~= 0 then
        Index(C_Spell.GetSpellName(id), id)
        Index(C_Item.GetItemNameByID(d[7]), id)
      end
    end
    for _, ids in pairs(byCraftName) do table.sort(ids) end
  end
  return byCraftName[name]
end

-- recipe spell for a writ: the variant you know, else the first
local function WritRecipe(itemID)
  local name = C_Item.GetItemNameByID(itemID)
  local want = type(name) == "string" and name:match(WRIT)
  local ids = want and CraftsNamed(want)
  if not ids then return nil, want end
  for _, id in ipairs(ids) do
    local rec = M.Craft.Recipe(id)
    if rec and R.KnownHere(rec) then return id end
  end
  return ids[1]
end

local function WritRows(itemID, full)
  local id, want = WritRecipe(itemID)
  if not id then
    return want and { { kind = "head", left = "Writ wants " .. want },
      { kind = "row", left = C("dim", "no recipe found for it") } } or nil
  end
  local rec = M.Craft.Recipe(id)
  local rows = M.Craft.RecipeRows(id, { noHead = true, short = not full, full = full })
  if not (rec and rows) then return nil end
  local h = rec.out and M.Craft.Have(rec.out)
  local mine = h and (h.bags + h.bank + h.mail) or 0
  local state = R.KnownHere(rec) and C("good", "known") or C("bad", "not known")
  table.insert(rows, 1, { kind = "head", left = "Writ wants " .. (rec.name or want),
    right = C("dim", (rec.prof or "?") .. " ") .. state })
  if mine > 0 then
    table.insert(rows, 2, { kind = "row", left = "You have", right = tostring(mine) })
  end
  return rows
end

------------------------------------------------------------------------------ Drawing
-- extra font strings for the each column, per tooltip, hidden again when it clears
local pools = {}
local function Release(tt)
  if T.bestLine then T.bestLine[tt] = nil end
  if T.bestLast then T.bestLast[tt] = nil end
  local pool = pools[tt]
  if not pool then return end
  for _, fs in ipairs(pool) do fs:Hide() end
  pool.used = 0
  if pool.minWidth then
    tt:SetMinimumWidth(0)
    pool.minWidth = nil
  end
end

local function MidString(tt)
  local pool = pools[tt]
  if not pool then
    pool = { used = 0 }
    pools[tt] = pool
    tt:HookScript("OnHide", Release)
    pcall(tt.HookScript, tt, "OnTooltipCleared", Release)
  end
  pool.used = pool.used + 1
  local fs = pool[pool.used]
  if not fs then
    fs = tt:CreateFontString(nil, "ARTWORK", "GameTooltipText")
    fs:SetJustifyH("RIGHT")
    pool[pool.used] = fs
  end
  return fs
end

local function LineString(tt, side, i)
  local key = "Text" .. side .. i
  return tt[key] or (tt:GetName() and _G[tt:GetName() .. key])
end

local function Secret(v) return issecretvalue ~= nil and issecretvalue(v) end

-- nil when secret: Forever hides sizes of a tooltip anchored to a restricted frame (e.g. a
-- Questie minimap pin), and arithmetic on one errors
local function Width(fs)
  local w = fs:GetStringWidth()
  if not Secret(w) then return w end
end

-- no widths to line a column up with: each and stack values share the right-hand text
local function InlineMids(tt, mids)
  Release(tt)
  for _, m in ipairs(mids) do
    local r = LineString(tt, "Right", m[1])
    if r and m[3] then r:SetText(m[2] .. C("dim", " / ") .. m[3]) end
  end
end

-- T.bestLine[tt] .. T.bestLast[tt]: line indexes of the compact verdict block (1-3 rows), for
-- tooltip tidiers moving it (nil: none; the Shift ledger's Best row has no bestLast)
T.bestLine = setmetatable({}, { __mode = "k" })
T.bestLast = setmetatable({}, { __mode = "k" })

-- one "Shift: more" per tooltip across our addons (conventions: tooltip.meioShiftHint)
local hintHooked = {}
local function ShiftHint(tt)
  if tt.meioShiftHint then return end
  tt.meioShiftHint = true
  if not hintHooked[tt] then
    hintHooked[tt] = true
    pcall(tt.HookScript, tt, "OnTooltipCleared", function(t) t.meioShiftHint = nil end)
  end
  tt:AddLine("|cff999999Shift: more|r")
end
T.ShiftHint = ShiftHint

function T.Render(tt, rows)
  Release(tt)
  local headed = rows[1] and rows[1].kind == "head"
  local lc, vc = S.label, S.value
  local mids = {}
  for _, r in ipairs(rows) do
    if r.kind == "gap" then
      tt:AddLine(" ")
    elseif r.kind == "hint" then
      ShiftHint(tt)
    elseif r.kind == "head" then
      tt:AddDoubleLine(C("accent", r.left), r.right or " ")
    else
      local left = (headed and S.indent or "") .. r.left
      if r.right then
        tt:AddDoubleLine(left, r.right, lc[1], lc[2], lc[3], vc[1], vc[2], vc[3])
      else
        tt:AddLine(left, lc[1], lc[2], lc[3])
      end
    end
    if r.best then T.bestLine[tt] = tt:NumLines() end
    if r.bestLast then T.bestLast[tt] = tt:NumLines() end
    if r.mid then mids[#mids + 1] = { tt:NumLines(), r.mid, r.right } end
  end
  if #mids == 0 then return end
  -- the each column sits left of the widest stack value; widen the tooltip to make room
  local leftW, rightW, midW = 0, 0, 0
  local placed = {}
  for _, m in ipairs(mids) do
    local l, r = LineString(tt, "Left", m[1]), LineString(tt, "Right", m[1])
    if l and r then
      local fs = MidString(tt)
      fs:SetText(m[2])
      local lw, rw, mw = Width(l), Width(r), Width(fs)
      if not (lw and rw and mw) then return InlineMids(tt, mids) end
      leftW, rightW, midW = math.max(leftW, lw), math.max(rightW, rw), math.max(midW, mw)
      placed[#placed + 1] = { fs, l }
    end
  end
  for _, p in ipairs(placed) do
    p[1]:ClearAllPoints()
    p[1]:SetPoint("TOP", p[2], "TOP")
    p[1]:SetPoint("RIGHT", tt, "RIGHT", -(10 + rightW + S.colGap), 0)
    p[1]:Show()
  end
  local pool = pools[tt]
  pool.minWidth = leftW + S.colGap + midW + S.colGap + rightW
  tt:SetMinimumWidth(pool.minWidth)
end

-- Rows for an item, or nil when there's nothing to say. full: the Shift ledger; qty: unused
-- (prices are per item); bound: soulbound now, nil goes by the bind type; shopping: on sale at
-- a merchant (compact: no Best line). For other addons drawing the block their own way.
local function BuildRows(itemID, full, bound, shopping, link)
  local d = Gather(itemID, bound, link)
  d.shopping = shopping
  local rows
  if d.hasAH or d.inv or d.craft or d.usedIn or d.vendor or d.disenchant or d.convert
    or d.group or d.act then
    if full then rows = Ledger(d) else rows = Compact(d) end
  end
  local writ = WritRows(P.Id(itemID), full)
  if not writ then return rows end
  rows = rows or {}
  for _, r in ipairs(writ) do rows[#rows + 1] = r end
  return rows
end

-- Blizzard re-sets bag and merchant tooltips every 0.2s while hovered, and Gather re-scores
-- every recipe an item feeds: that stuttered the game and made the tooltip shimmer
local MEMO_SECONDS = 1
local memo, memoAt = {}, 0

-- link: the item as shown (suffix, enchant), for the Best line's upgrade check
function T.Rows(itemID, full, qty, bound, shopping, link)
  local now = GetTime()
  if now - memoAt > MEMO_SECONDS then
    wipe(memo)
    memoAt = now
  end
  local key = strjoin("|", itemID, tostring(full), tostring(bound), tostring(shopping),
    link and link:match("item:([^|]*)") or "")
  local rows = memo[key]
  if rows == nil then
    rows = BuildRows(itemID, full, bound, shopping, link) or false
    memo[key] = rows
  end
  return rows or nil
end

-- a bag or equipped item that has bound (BoE once worn); nil elsewhere
local function HoveredBound(tt)
  local info = tt.GetProcessingTooltipInfo and tt:GetProcessingTooltipInfo()
  local args = info and info.getterArgs
  if not (args and ItemLocation and C_Item.IsBound) then return nil end
  local ok, loc = pcall(function()
    if info.getterName == "GetBagItem" then
      return ItemLocation:CreateFromBagAndSlot(args[1], args[2])
    elseif info.getterName == "GetInventoryItem" and args[1] == "player" then
      return ItemLocation:CreateFromEquipmentSlot(args[2])
    end
  end)
  if not (ok and loc) then return nil end
  local okBound, bound = pcall(C_Item.IsBound, loc)
  if okBound and not Secret(bound) then return bound end
end

-- the ledger without Shift while the AH (Blizzard's or TSM's) is open
local ahOpen = false
pcall(M.On, "AUCTION_HOUSE_SHOW", function() ahOpen = true end)
pcall(M.On, "AUCTION_HOUSE_CLOSED", function() ahOpen = false end)
local function AHFull() return ahOpen and M.db.ahDetail == true end

-- the shown item's random-suffix variant (Auction.lua A.Key) when our scans have seen it, so its
-- prices are its own rather than the whole itemID's; else itemID. Second: the shown link
local function PriceKey(tt, itemID)
  local A = M.Auction
  if not (A and TooltipUtil and TooltipUtil.GetDisplayedItem) then return itemID end
  local ok, _, link = pcall(TooltipUtil.GetDisplayedItem, tt)
  if not ok or type(link) ~= "string" or Secret(link) then return itemID end
  local key = A.Key(link)
  if A.IsVariant(key) and A.Base(key) == itemID and A.Get(key) then return key, link end
  return itemID, link
end

-- the block for itemID at the end of tt as it is now. Set T.external = true to place it yourself
-- (a tooltip tidier calling T.Draw after its own lines); Meionomics then stops adding it.
function T.Draw(tt, itemID)
  if not M.toggles.tooltips() then return Release(tt) end
  local full = AHFull() or IsShiftKeyDown()
  local info = tt.GetProcessingTooltipInfo and tt:GetProcessingTooltipInfo()
  local shopping = info and info.getterName == "GetMerchantItem"
  local key, link = PriceKey(tt, itemID)
  local rows = T.Rows(key, full, 1, HoveredBound(tt), shopping, link)
  if rows then T.Render(tt, rows) else Release(tt) end
end

local function OnItem(tt, data)
  if T.external or SKIP[tt:GetName() or ""] then return end
  if type(data) ~= "table" or type(data.id) ~= "number" or Secret(data.id) then return end
  T.Draw(tt, data.id)
end

-- MeioTooltipFold adds Leveling BiS's verdict to item tooltips (it sets blockOff): on a trainer
-- line showing the item made, a second BiS row would only contradict it
local function FoldsBis(tt)
  local api = ForeverLevelingBiS_API
  if not (api and api.blockOff and TooltipUtil and TooltipUtil.GetDisplayedItem) then
    return false
  end
  local ok, _, link = pcall(TooltipUtil.GetDisplayedItem, tt)
  return ok and type(link) == "string"
end

-- trainer lines that teach a recipe: the crafting panel's recipe block (CraftRows.lua); Shift lists
-- every material. Item services (a recipe whose tooltip is its output) get the item block.
local function OnTrainer(tt)
  if not M.toggles.tooltips() then return end
  local info = tt.GetProcessingTooltipInfo and tt:GetProcessingTooltipInfo()
  if not (info and info.getterName == "GetTrainerService" and info.getterArgs) then return end
  local index = info.getterArgs[1]
  local id = R.TrainerRecipeID(index)
  if not id then return end
  -- RecipeRows falls back to DB2 data, so record on what is missing: the fee and skill
  local rec = R.All()[id]
  if not (rec and rec.train) then R.RecordTrainerService(index) end
  local rows = M.Craft.RecipeRows(id, { short = true, full = IsShiftKeyDown(),
    noBis = FoldsBis(tt), atTrainer = true })
  if not rows then return end
  tt:AddLine(" ")
  T.Render(tt, rows)
end

------------------------------------------------------------------------------ Setup
local prevOnLoad = M.OnLoad
function M.OnLoad()
  if prevOnLoad then prevOnLoad() end
  M.db.fields = M.db.fields or {}
  for _, f in ipairs(T.FIELDS) do
    if M.db.fields[f.key] == nil then M.db.fields[f.key] = f.on end
  end
end

M.On("PLAYER_LOGIN", function()
  if not (TooltipDataProcessor and Enum.TooltipDataType) then return end
  TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Item, function(tt, data)
    local ok, err = pcall(OnItem, tt, data)
    if not ok then geterrorhandler()(err) end
  end)
  -- a post call, not a SetTrainerService hook: Blizzard's Shift rebuild skips SetTrainerService
  TooltipDataProcessor.AddTooltipPostCall(TooltipDataProcessor.AllTypes or "ALL", function(tt)
    local ok, err = pcall(OnTrainer, tt)
    if not ok then geterrorhandler()(err) end
  end)
end)

-- Shift pressed or released over an item or trainer line: redraw (compact <-> ledger)
-- Our rebuild runs Blizzard's whole tooltip build tainted, so only where nothing else redraws:
-- owners with UpdateTooltip (bag slots, merchant) are re-set by Blizzard every 0.2s anyway.
M.On("MODIFIER_STATE_CHANGED", function(_, key)
  if not (key == "LSHIFT" or key == "RSHIFT") or not GameTooltip:IsShown() or AHFull()
    or not M.toggles.tooltips() then
    return
  end
  local owner = GameTooltip:GetOwner()
  if owner and owner.UpdateTooltip then return end
  local info = GameTooltip.GetPrimaryTooltipInfo and GameTooltip:GetPrimaryTooltipInfo()
  local data = info and info.tooltipData
  local isItem = data and data.type == Enum.TooltipDataType.Item
  if isItem or (info and info.getterName == "GetTrainerService") then
    GameTooltip:RebuildFromTooltipInfo()
  end
end)

M.commands.fields = function(rest)
  local f = M.db.fields
  if rest ~= "" then
    if f[rest] == nil then return M.Print("no field " .. rest) end
    f[rest] = not f[rest]
  end
  local out = {}
  for _, def in ipairs(T.FIELDS) do
    out[#out + 1] = (f[def.key] and "|cff4fe36a" or "|cff6f6f6f") .. def.key .. "|r"
  end
  M.Print("compact tooltip, green = shown (/meio fields <name> toggles): "
    .. table.concat(out, " "))
end
