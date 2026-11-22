-- Shared ledger sections in T.Render's row shape ({ kind = "gap" | "head" | "row", left, right,
-- mid }): the crafting panel's recipe hover, trainer tooltips and the item tooltip's Shift
-- ledger show an item's sale facts the same way. Styling stays in M.Tooltip.style.
-- The one place these labels live. Prices are this realm's (min buyout, market); sales are
-- the region's, measured ("Region sold/day"). Region prices only show inside Confidence's
-- reasons, never as a price row; the realm sales estimate (C.Value.Sales) never as a number.
--   L.SaleRows(rows, itemID, opts) appends: Sells for, price detail, Confidence (+ why),
--     Region sold/day, sale rate and listings, and the ways to sell it (best, disenchant, vendor)
--   opts.bound   soulbound now
--   opts.noBest  leave out the ways to sell it (Action.lua's Best: line and comparison)
--   opts.short   only the Best: line, not the comparison
--   opts.label   in place of "Best: " (a recipe item's ledger has its own Best: line above)
local _, M = ...
local P = M.Prices
local L = {}
M.Ledger = L

local function S() return M.Tooltip.style end
local function C(key, text) return "|cff" .. S()[key] .. text .. "|r" end
local function Pct(f) return ("%d%%"):format(math.floor(f * 100 + 0.5)) end
local function Join(...)
  local out = {}
  for i = 1, select("#", ...) do
    local v = select(i, ...)
    if v and v ~= "" then out[#out + 1] = v end
  end
  return table.concat(out, S().sep)
end
L.Join = Join

local function Age(sec)
  if sec < 3600 then return math.max(1, math.floor(sec / 60)) .. " min ago" end
  if sec < 86400 then return math.floor(sec / 3600) .. " h ago" end
  return math.floor(sec / 86400) .. " days ago"
end

L.LEVEL = { high = { "good", "High" }, medium = { "warn", "Medium" }, low = { "bad", "Low" } }
function L.Level(level)
  local lv = L.LEVEL[level]
  return lv and C(lv[1], lv[2]) or C("dim", "?")
end

-- the price to plan on (before the cut): market when confidence is high, else P.Evidence's
-- safe price; and whether it is the safe one
function L.Price(ev)
  if not ev then return nil end
  local market = ev.market or ev.min or ev.regionSale or ev.regionMarket
  if ev.level == "high" or not ev.price then return market, false end
  return ev.price, ev.price < (market or math.huge)
end

-- SellDay's price, its odds and what it rests on (sd: SellDay.Quote, nil adds nothing)
function L.SellDayRows(rows, sd)
  if not sd then return rows end
  local function Add(left, right) rows[#rows + 1] = { kind = "row", left = left, right = right } end
  if sd.price then
    Add("Sells in a day" .. C("dim", " (" .. M.SellDay.Odds(sd.P) .. ")"),
      M.Money(sd.price) .. C("dim", " each"))
    local dip = (sd.dip or sd.jump) and (M.SellDay.DipText(sd):gsub(", $", "")) or nil
    Add(C("dim", Join(dip, sd.fall and "the low has held: a real fall" or nil,
      M.SellDay.Basis(sd.fit))))
  elseif sd.slow then
    Add("Sells in a day", C("warn", "slow: not 4 in 5 even 12% under"))
  end
  return rows
end

function L.SaleRows(rows, itemID, opts)
  opts = opts or {}
  local function Add(kind, left, right)
    rows[#rows + 1] = { kind = kind, left = left, right = right }
  end
  local ok, noWhy = P.Auctionable(itemID)
  if ok and opts.bound then ok, noWhy = false, "soulbound" end
  local ev = ok and P.Evidence(itemID)
  if not ok then
    Add("row", "Sells for", C("dim", "can't be auctioned: " .. (noWhy or "?")))
  elseif ev then
    local price, safe = L.Price(ev)
    Add("row", "Sells for" .. (safe and C("dim", " (safe price)") or ""),
      M.Money(price) .. C("dim", " each"))
    local min = ev.min and ("min " .. M.Money(ev.min) .. (ev.from == "scan" and " now" or ""))
      or (ev.listed == 0 and "none up")
    local detail = Join(min, ev.market and ("market " .. M.Money(ev.market)))
    if detail ~= "" then Add("row", C("dim", detail)) end
    L.SellDayRows(rows, M.SellDay.Quote(itemID))
    Add("row", "Confidence", L.Level(ev.level))
    if #ev.reasons > 0 then Add("row", C("dim", table.concat(ev.reasons, S().sep))) end
    if ev.perDay then Add("row", "Region sold/day", M.Count(ev.perDay)) end
    local listed = ev.listed and (ev.listed .. " listed now"
      .. (ev.sellers and (" by " .. ev.sellers .. (ev.sellers == 1 and " seller" or " sellers"))
        or ""))
    local age = ev.scanAge and ev.from == "scan" and ("scan " .. Age(ev.scanAge))
    detail = Join(ev.rate and (Pct(ev.rate) .. " of listings sell"), listed, age)
    if detail ~= "" then Add("row", C("dim", detail)) end
  else
    Add("row", "Sells for", C("dim", "no AH data"))
  end
  if opts.noBest or not M.Action then return rows end
  local act = P.BestAction(itemID, opts.bound)
  if not act then return rows end
  if opts.short then
    local left, right = M.Action.Line(act, { label = opts.label })
    Add("row", left, right)
  else
    M.Action.Rows(rows, act, opts.label)
  end
  return rows
end
