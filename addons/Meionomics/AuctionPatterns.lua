-- Patterns view of the Browse tab: every recipe listed now (one row per pattern, its cheapest
-- buyout), judged by CraftVerdict as the Craft panel's Profit view does, with the row's
-- buyout as the learning cost. Known recipes hidden unless "Show known".
-- The full list (empty search) adds, below what is up: limited-stock vendor patterns with
-- where they are, then the watch list (Patterns.lua) not up now, faded, at its last price.
-- Watched patterns that are up get a star and a glow (and one chat line, Patterns.lua).
-- "Auctions" lists the selected pattern's auctions in the items view, to buy one.
local _, M = ...
local P, R, B, Pt = M.Prices, M.Recipes, M.AuctionBrowse, M.Patterns
local C, Hex = B.C, B.Hex

local RECIPE_CLASS = (Enum.ItemClass and Enum.ItemClass.Recipe) or 9
local DIFF = { orange = "ff8040", yellow = "ffff00", green = "40bf40", grey = "808080" }
local DIFF_RANK = { orange = 1, yellow = 2, green = 3, grey = 4 }
-- rows that can't be judged, after every verdict (CraftVerdict ranks run 1..7)
local OTHER_PROF, NO_RECIPE = 8, 9

------------------------------------------------------------------------------ Judging
-- per profession, once per search (C.Value.ForProf builds every recipe of it, so not for
-- professions he doesn't have)
local profs = {}

local function ForProf(prof)
  if not profs[prof] then
    profs[prof] = M.Craft.Rank(prof) and M.Craft.Value.ForProf(prof) or {}
  end
  return profs[prof]
end

local function Fill(r, c, x, v)
  r.x, r.rank, r.v = x, c.rank, v
  r.worth = v and v.rank or NO_RECIPE
  r.each = x.real and x.real.each
  r.learn, r.known, r.held = x.learn, x.known, x.learnFrom == "held"
  r.payN = not x.known and x.payN or nil
  r.diff = DIFF_RANK[x.colour]
  r.day = Pt.Worth(x, v)
  r.glow = r.day and true or nil
end

local function Judge(r, rec)
  local c = ForProf(rec.prof)
  if not c.rank then
    r.worth = OTHER_PROF
    return
  end
  local x, v = M.Craft.Value.JudgeRecipe(c, rec, r.unit, r.qty)
  if not x then
    r.worth = NO_RECIPE
    return
  end
  Fill(r, c, x, v)
end

function B.PatternRow(br)
  local id = br.itemKey.itemID
  local name, link, quality = C_Item.GetItemInfo(id)
  local market = P.Get(id, "market")
  local r = B.Named({ key = br.itemKey, itemID = id, link = link, name = name,
    quality = quality or 1, unit = br.minPrice, qty = br.totalQuantity or 1,
    mine = br.containsOwnerItem, market = market,
    pct = (market and br.minPrice) and br.minPrice / market * 100 or nil })
  local taught = R.TaughtBy(id)
  local rec = taught and taught[1]
  r.prof = rec and rec.prof
  if rec and rec.prof then Judge(r, rec) else r.worth = NO_RECIPE end
  return r
end

-- a pattern not up here: at a vendor (vendor = { npc, zone }) or last seen at price (est:
-- never seen, the market's)
local function Away(item, x, v, c, price, vendor, seen, est)
  local name, link, quality = C_Item.GetItemInfo(item)
  local market = P.Get(item, "market")
  local r = { key = { itemID = item }, itemID = item, link = link, name = name,
    quality = quality or 1,
    unit = price, qty = 0, market = market, prof = x.rec.prof, vendor = vendor,
    down = not vendor, faded = not vendor, lastT = seen and seen.t,
    est = est, pct = (market and price and not est) and price / market * 100 or nil }
  B.Named(r)
  Fill(r, c, x, v)
  -- the glow says "buy it now": not for what isn't up
  if r.down then r.glow = nil end
  return r
end

-- limited-stock vendors of an item (merchant visits): the latest seen
local function LimitedVendor(item)
  local best
  for npc, v in pairs(R.Vendors(item) or {}) do
    if v.limited and (not best or (v.t or 0) > (best.t or 0)) then
      best = { npc = npc, zone = v.zone, price = v.price, t = v.t }
    end
  end
  return best
end

-- the full list's rows that aren't up: limited vendor patterns, watched ones last seen
local function AwayRows(rows, up)
  Pt.EachCandidate(ForProf, function(item, x, v, price, seen, c, est)
    if up[item] then return end
    local vendor = LimitedVendor(item)
    if vendor and vendor.price then
      x, v = M.Craft.Value.JudgeRecipe(c, x.rec, vendor.price)
      rows[#rows + 1] = Away(item, x, v, c, vendor.price, vendor, seen)
    elseif Pt.Worth(x, v) then
      rows[#rows + 1] = Away(item, x, v, c, price, nil, seen, est)
    end
  end)
end

------------------------------------------------------------------------------ Cells
local function Name(r)
  local color = ITEM_QUALITY_COLORS[r.quality] or ITEM_QUALITY_COLORS[1]
  -- the icon says it's a pattern: "Pattern: " only takes room
  local text = color.hex .. (r.name:match("^[^:]+:%s*(.+)$") or r.name) .. "|r"
  local v = r.vendor
  if v then text = text .. "  " .. C("grey", v.npc .. (v.zone and (", " .. v.zone) or "")) end
  return text
end

local function Short(sec)
  if sec < 3600 then return ("%dm"):format(math.max(1, math.floor(sec / 60))) end
  if sec < 86400 then return ("%dh"):format(math.floor(sec / 3600)) end
  return ("%dd"):format(math.floor(sec / 86400))
end

local function Seen(r)
  local star = r.day and (Pt.STAR .. " ") or ""
  if r.vendor then return star .. M.Action.ICONS.vendor end
  if r.down then
    return star .. (r.lastT and Short(M.Now() - r.lastT) or C("dim", "never"))
  end
  return star .. C("good", "now")
end

-- up now, then vendors, then last seen longest ago
local function SeenKey(r)
  if r.vendor then return 1e9 end
  if r.down then return 2e9 - (r.lastT or 0) / 2 end
  return 0
end

local function Verdict(r)
  if r.v then return Hex(r.v.colour, r.v.short) end
  if r.worth == OTHER_PROF then return C("dim", r.prof or "?") end
  return C("dim", "Unknown recipe")
end

local function Each(r)
  if not r.each then return C("dim", "-") end
  local text = (r.each < 0 and "-" or "") .. M.Money(math.abs(r.each))
  return r.each > 0 and text or C("bad", text)
end

local function Skill(r)
  local colour = r.x and r.x.colour
  if not colour then return C("dim", "-") end
  return Hex(DIFF[colour], colour:sub(1, 1):upper() .. colour:sub(2))
end

local function Req(r)
  if not r.learn then return C("dim", "-") end
  local text = (r.x.estLearn and "~" or "") .. r.learn
  return r.rank and r.learn > r.rank and C("bad", text) or text
end

local function Known(r)
  if r.known then return C("good", "Known") end
  if r.held then return C("accent", "In bags") end
  return r.x and C("dim", "No") or C("dim", "-")
end

local function Payback(r)
  if not r.payN then return C("dim", "-") end
  return ("%d craft%s"):format(r.payN, r.payN == 1 and "" or "s")
end

local function Tier(r) return r.down and 2 or r.vendor and 1 or 0 end

-- up now before vendors before last seen; then the verdict, CraftVerdict's own order (week's
-- net, own mats), cheaper first
local function Worth(a, b, desc)
  if Tier(a) ~= Tier(b) then return Tier(a) < Tier(b) end
  if a.worth ~= b.worth then
    if desc then return a.worth > b.worth end
    return a.worth < b.worth
  end
  if a.v and b.v and a.v.rank == b.v.rank then
    local before, after = M.Craft.Value.Before(a.x, b.x), M.Craft.Value.Before(b.x, a.x)
    if before ~= after then
      if desc then return after end
      return before
    end
  end
  return (a.unit or 0) < (b.unit or 0)
end

------------------------------------------------------------------------------ The view
B.VIEWS.patterns = {
  sort = "worth",
  classFilters = { { classID = RECIPE_CLASS } },
  columns = {
    { key = "name", title = "Pattern", width = 0, text = Name,
      tip = "Hover a row for the recipe; double-click lists its auctions" },
    { key = "seen", title = "Seen", width = 50, tip = "Up now, or how long ago it was last seen",
      more = "Faded: on your watch list, not up now (never: not seen since the last full "
        .. "scan). Bag: a limited-stock vendor, named after the pattern. Star: worth learning, "
        .. M.Money(Pt.WATCH_MIN) .. "/day or more.",
      text = Seen },
    { key = "unit", title = "Buyout", width = 96, right = true,
      tip = "Its cheapest auction up now",
      more = "Faded rows: the price when last seen (~: never seen, the market value). Bag "
        .. "rows: the vendor's price.",
      text = function(r) return (r.est and "~" or "") .. M.Money(r.unit) end },
    { key = "pct", title = "% Mkt", width = 56, right = true, tip = B.PCT_TIP, more = B.PCT_MORE,
      text = function(r) return B.Pct(r.pct) end },
    { key = "worth", title = "Verdict", width = 100,
      tip = "Worth learning? The Craft panel's verdict at your skill",
      more = "Counts this buyout as the cost of learning it.",
      text = Verdict },
    { key = "each", title = "Profit each", width = 90, right = true, desc = true,
      tip = "Realistic profit per craft",
      more = "A week's batch, after the AH cut, with your own mats at what they'd sell for.",
      text = Each },
    { key = "diff", title = "Skill", width = 56,
      tip = "Its skill-up colour at your rank", text = Skill },
    { key = "learn", title = "Req", width = 40, right = true,
      tip = "Skill needed to learn it (red: above your rank, ~: estimated)", text = Req },
    { key = "known", title = "Known", width = 56, text = Known,
      tip = "Known: you have it. In bags: you hold it, not learnt yet." },
    { key = "payN", title = "Payback", width = 66, right = true,
      tip = "Crafts until the profit has paid for the pattern", text = Payback },
  },
  Hover = function(r, tt)
    tt:AddLine(" ")
    if r.vendor then
      tt:AddLine(M.Action.ICONS.vendor .. " " .. r.vendor.npc .. (r.vendor.zone and (", "
        .. r.vendor.zone) or "") .. ": " .. M.Money(r.unit) .. ", limited stock", 1, 1, 1)
    elseif r.down then
      tt:AddLine(r.lastT and ("Last on the AH %s ago at %s"):format(Short(M.Now() - r.lastT),
        M.Money(r.unit)) or "Not seen on the AH yet", 1, 1, 1)
    end
    if r.day then
      tt:AddLine(Pt.STAR .. " Watched: worth ~" .. M.Money(r.day) .. "/day once learnt",
        1, 0.82, 0)
    end
  end,
  compare = { worth = Worth,
    seen = function(a, b, desc)
      local x, y = SeenKey(a), SeenKey(b)
      if x == y then return Worth(a, b) end
      if desc then return x > y end
      return x < y
    end },
  FromBrowse = function(results)
    local full = (B.state.text or "") == ""
    Pt.FromBrowse(results, full)
    local rows, up = {}, {}
    for _, br in ipairs(results) do
      if br.minPrice and br.minPrice > 0 then
        local r = B.PatternRow(br)
        rows[#rows + 1], up[r.itemID] = r, true
        if r.day then Pt.Alert(r.itemID, r.day) end
      end
    end
    if full then AwayRows(rows, up) end
    return rows
  end,
  OnSearch = function()
    wipe(profs)
    if R.ResetCache then R.ResetCache() end
  end,
  Keep = function(r) return M.db.patternsKnown or not r.known end,
  Filter = function(f, anchor)
    local g = CreateFrame("Frame", nil, f)
    g:SetSize(220, 24)
    g:SetPoint("LEFT", anchor, "RIGHT", 14, 0)
    local known = CreateFrame("CheckButton", nil, g, "UICheckButtonTemplate")
    known:SetSize(24, 24)
    known:SetPoint("LEFT")
    local label = g:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    label:SetPoint("LEFT", known, "RIGHT", 1, 0)
    label:SetText("Show known")
    known:SetChecked(M.db.patternsKnown and true or false)
    B.LabelClicks(known, label)
    B.Help(known, { "Show known", "Also list patterns you already know" })
    known:SetScript("OnClick", function(self)
      M.db.patternsKnown = self:GetChecked() or nil
      B.Refresh()
    end)
    f.showKnown = known
    local scan = CreateFrame("Button", nil, g, "UIPanelButtonTemplate")
    scan:SetSize(80, 22)
    scan:SetPoint("LEFT", label, "RIGHT", 14, 0)
    scan:SetText("Scan all")
    scan:SetScript("OnClick", function()
      f.search:SetText("")
      B.Search("")
    end)
    B.Help(scan, { "Scan all patterns", "Every recipe pattern on the AH, all pages",
      "Clears the search box. Updates last-seen prices and the watch list, so patterns that "
        .. "aren't up show when they were last seen." })
    f.scanPatterns = scan
    return g
  end,
  status = function(n)
    local up, watched, vendor = 0, 0, 0
    for _, r in ipairs(B.state.rows) do
      if r.down then watched = watched + 1 elseif r.vendor then vendor = vendor + 1 else
        up = up + 1
      end
    end
    local checked = Pt.Checked()
    return ("%d patterns up"):format(up)
      .. (n > 0 and (", %d known hidden"):format(n) or "")
      .. (vendor > 0 and (", %d at vendors"):format(vendor) or "")
      .. (watched > 0 and (", %d watched not up"):format(watched) or "")
      .. (checked and (" | all checked %s ago"):format(Short(M.Now() - checked))
        or C("dim", " | never fully scanned: Scan all"))
  end,
  reading = function() return "Searching..." end,
  empty = "Every recipe pattern up now; type to narrow it down",
  none = function(text)
    if text == "" then return "No recipe patterns are up right now." end
    return ("No pattern up matches \"%s\".\nScan all lists every one."):format(text)
  end,
  hidden = function(n)
    return ("You know all %d patterns found.\nTick Show known to list them anyway."):format(n)
  end,
  action = { text = "Auctions",
    help = function(r)
      local line = "List the selected pattern's auctions, to buy one"
      if not r then line = "Select a pattern first; this lists its auctions to buy one" end
      if r and r.vendor then line = "That one is sold by a vendor, named after it" end
      if r and r.down then line = "That one isn't up on the AH right now" end
      return { "Auctions", line }
    end,
    enabled = function(r) return r ~= nil and not (r.down or r.vendor) end,
    run = function(r)
      if not (r and not (r.down or r.vendor)) then return end
      B.SetView("items")
      B.panel.search:SetText(r.name)
      B.SearchKeys({ r.key }, r.name)
    end },
}
