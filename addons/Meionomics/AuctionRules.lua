-- Posting prices. Q.Quote(itemID) says post / hold / vendor, at what price, and which rule set it.
-- Rules are small price expressions over our sources:
--   120% market | max(105% craft, vendor / 0.95, 80% market) | 1g50s | first(ownMarket, market)
-- sources: market, minBuyout, regionMarket, regionSale, historical, vendor, craft (cost to make one
-- with a recipe someone knows), ownMin, ownMarket (our scans only), sellDay (SellDay.lua)
-- With a rival up, the post goes at SellDay's price (best net that sells within a day 4 in 5)
-- when it clears the floor, else the plain undercut.
local _, M = ...
local Q = {}
M.AuctionRules = Q

local AH_CUT = 0.95
Q.DEFAULT = {
  undercut = 1,
  floor = "max(105% craft, vendor / 0.95, 80% market)",
  normal = "120% max(market, regionMarket)",
  ceiling = "300% market",
}

------------------------------------------------------------------------------ Expressions
local function Tokens(s)
  local out, i = {}, 1
  while i <= #s do
    local c = s:sub(i, i)
    if c:match("%s") then
      i = i + 1
    else
      local money = s:match("^%d+[gsc][%dgsc]*", i)
      local num = s:match("^%d+%.?%d*", i)
      local word = s:match("^%a+", i)
      if money and money:match("[gsc]$") and #money > #(num or "") then
        local v = 0
        for n, u in money:gmatch("(%d+)([gsc])") do
          v = v + tonumber(n) * (u == "g" and 10000 or u == "s" and 100 or 1)
        end
        out[#out + 1] = { "num", v }
        i = i + #money
      elseif num then
        out[#out + 1] = { "num", tonumber(num) }
        i = i + #num
      elseif word then
        out[#out + 1] = { "word", word }
        i = i + #word
      elseif c:match("[%%%(%),%+%-%*/]") then
        out[#out + 1] = { c }
        i = i + 1
      else
        error("unexpected '" .. c .. "'")
      end
    end
  end
  return out
end

local function Parse(s)
  local toks, pos = Tokens(s), 1
  local function peek() return toks[pos] and toks[pos][1] end
  local function take(kind)
    local t = toks[pos]
    if not t or (kind and t[1] ~= kind) then error("expected " .. (kind or "more")) end
    pos = pos + 1
    return t
  end
  local expr
  local function factor()
    local t = take()
    if t[1] == "num" then
      if peek() == "%" then
        take()
        return { "pct", t[2], factor() }
      end
      return { "num", t[2] }
    elseif t[1] == "word" then
      if peek() == "(" then
        take()
        local args = { expr() }
        while peek() == "," do
          take()
          args[#args + 1] = expr()
        end
        take(")")
        return { "fn", t[2]:lower(), args }
      end
      return { "src", t[2] }
    elseif t[1] == "(" then
      local e = expr()
      take(")")
      return e
    end
    error("unexpected " .. t[1])
  end
  local function term()
    local left = factor()
    while peek() == "*" or peek() == "/" do left = { take()[1], left, factor() } end
    return left
  end
  function expr()
    local left = term()
    while peek() == "+" or peek() == "-" do left = { take()[1], left, term() } end
    return left
  end
  local tree = expr()
  if pos <= #toks then error("unexpected " .. toks[pos][1]) end
  return tree
end

local parsed = {}
function Q.Parse(s)
  if parsed[s] == nil then
    local ok, tree = pcall(Parse, s)
    parsed[s] = ok and tree or false
  end
  return parsed[s] or nil
end

-- cost to make one, with the best recipe any of our characters knows
function Q.CraftCost(itemID)
  local R = M.Recipes
  local known = {}
  for _, rec in ipairs(R.Making(itemID) or {}) do
    if rec.known and next(rec.known) then known[#known + 1] = rec end
  end
  if #known == 0 then return nil end
  local rec, e = R.Best(known)
  if not (e and e.complete) then return nil end
  return e.cost / R.Made(rec), rec
end

local SOURCE_NAMES = { craft = "craft cost", minBuyout = "min buyout",
  regionMarket = "region market", regionSale = "region sale avg", ownMin = "our min buyout",
  ownMarket = "our market", sellDay = "sells in a day" }

local function Source(name, itemID)
  if name == "craft" then return (Q.CraftCost(itemID)) end
  if name == "sellDay" then
    local sd = M.SellDay.Quote(itemID)
    return sd and sd.price
  end
  if name == "ownMin" or name == "ownMarket" then
    local a = M.Auction.Get(itemID)
    return a and (name == "ownMin" and a.min or a.market) or nil
  end
  if M.Prices.SOURCES[name] or name == "vendor" then return M.Prices.Get(itemID, name) end
end

local function Num(v)
  return (v == math.floor(v)) and tostring(v) or ("%.2f"):format(v):gsub("0+$", "")
end

-- value, why ("105% craft cost 50s 22c")
local function Eval(node, itemID)
  local kind = node[1]
  if kind == "num" then return node[2], nil end
  if kind == "src" then
    local v = Source(node[2], itemID)
    return v, (SOURCE_NAMES[node[2]] or node[2]) .. " " .. M.Money(v)
  end
  if kind == "pct" then
    local v, why = Eval(node[3], itemID)
    return v and v * node[2] / 100, node[2] .. "% " .. (why or "")
  end
  if kind == "fn" then
    local best, bestWhy
    for _, arg in ipairs(node[3]) do
      local v, why = Eval(arg, itemID)
      if v then
        if node[2] == "first" then return v, why end
        local better = not best
          or (node[2] == "max" and v > best) or (node[2] == "min" and v < best)
        if better then best, bestWhy = v, why end
      end
    end
    return best, bestWhy
  end
  local a, aw = Eval(node[2], itemID)
  local b, bw = Eval(node[3], itemID)
  local left, right = aw or (a and Num(a)) or "?", bw or (b and Num(b)) or "?"
  local why = left .. " " .. kind .. " " .. right
  if kind == "+" or kind == "-" then why = "(" .. why .. ")" end
  if not (a and b) then return nil, why end
  if kind == "+" then return a + b, why end
  if kind == "-" then return a - b, why end
  if kind == "*" then return a * b, why end
  if b == 0 then return nil, why end
  return a / b, why
end

-- a rule string: ours, else a TSM custom price when TSM is loaded and accepts it
function Q.Eval(str, itemID)
  local tree = Q.Parse(str)
  if tree then
    local v, why = Eval(tree, itemID)
    return v and math.floor(v + 0.5), why
  end
  if not M.Prices.Valid(str) then return nil, "not a valid price: " .. str end
  return M.Prices.Custom(str, itemID), "TSM " .. str
end

------------------------------------------------------------------------------ Rules
function Q.Rule(itemID)
  local rules = M.db.rules or {}
  local item = rules.items and rules.items[itemID] or {}
  local r = {}
  for k, v in pairs(Q.DEFAULT) do r[k] = item[k] or rules[k] or v end
  return r
end

-- "cheapest 55s is a dip (3 from 1 seller), sells within a day ~4 in 5 at 2% under 57s
-- (default guess)"
function Q.SellDayWhy(sd)
  local under = sd.m == 0 and "1c" or ("%d%%"):format(sd.m * 100 + 0.5)
  return ("%ssells within a day ~%s at %s under %s (%s)"):format(M.SellDay.DipText(sd),
    M.SellDay.Odds(sd.P), under, M.Money(sd.ref), M.SellDay.Basis(sd.fit))
end

-- { action = "post" | "hold" | "vendor" | "cannot", price, rule, reason, lowest, mine,
--   floor, normal, ceiling, sellDay (SellDay.Quote) }
-- opts: lowest / mine (live search, else our last scan), deposit (copper for this post)
function Q.Quote(itemID, opts)
  opts = opts or {}
  M.Recipes.ResetCache()
  local rule = Q.Rule(itemID)
  local q = {}
  local ok, why = M.Prices.Auctionable(itemID)
  if not ok then
    q.action, q.rule, q.reason = "cannot", "bind", "can't be auctioned: " .. why
    return q
  end
  local floorWhy, normalWhy, ceilWhy
  q.floor, floorWhy = Q.Eval(rule.floor, itemID)
  q.normal, normalWhy = Q.Eval(rule.normal, itemID)
  q.ceiling, ceilWhy = Q.Eval(rule.ceiling, itemID)
  local scan = M.Auction.Get(itemID)
  q.lowest = opts.lowest or (scan and scan.comp)
  q.mine = opts.mine or (scan and scan.mine)
  local function Set(action, price, ruleName, detail)
    q.action, q.price, q.rule = action, price and math.floor(price + 0.5), ruleName
    q.reason = ruleName .. ": " .. detail
  end
  if not q.floor then
    Set("hold", nil, "floor", "no floor price (" .. rule.floor .. ")")
    return q
  end
  -- normal can't sit under the floor or over the ceiling
  local normal, nRule, nWhy = q.normal, "normal", normalWhy
  if not normal or normal < q.floor then normal, nRule, nWhy = q.floor, "floor", floorWhy end
  if q.ceiling and normal > q.ceiling and q.ceiling >= q.floor then
    normal, nRule, nWhy = q.ceiling, "ceiling", ceilWhy
  end
  if not q.lowest then
    Set("post", normal, nRule, "no competition, " .. nWhy)
  elseif q.ceiling and q.lowest > q.ceiling then
    Set("post", normal, nRule, ("competition %s over ceiling (%s), %s"):format(
      M.Money(q.lowest), ceilWhy, nWhy))
  elseif q.mine and q.mine <= q.lowest then
    Set("post", math.max(q.mine, q.floor), "match", "lowest is ours at " .. M.Money(q.mine))
  else
    local sd = M.SellDay.Quote(itemID, { comp = q.lowest, deposit = opts.deposit,
      floor = q.floor })
    q.sellDay = sd
    if sd and sd.price then
      Set("post", sd.price, "in a day", Q.SellDayWhy(sd))
    elseif q.lowest - rule.undercut < q.floor then
      Set("hold", nil, "floor", ("competition %s under floor %s (%s)"):format(
        M.Money(q.lowest), M.Money(q.floor), floorWhy))
    else
      Set("post", q.lowest - rule.undercut, "undercut",
        ("%s under %s"):format(M.Money(rule.undercut), M.Money(q.lowest))
        .. (sd and sd.slow and ", slow: not 4 in 5 within a day even 12% under" or ""))
    end
  end
  -- not worth the AH when a vendor pays more than the sale nets. The deposit comes back on a
  -- sale, so it only costs on expiries: SellDay's net prices that in when it has odds, else
  -- a sale nets the price less the cut (rounded, so a floor of vendor / 0.95 isn't a copper short)
  local vendor = M.Prices.Get(itemID, "vendor")
  local price = q.price or q.floor
  local net, how = price * AH_CUT, "after the 5% cut"
  if q.sellDay then
    net, how = M.SellDay.Net(q.sellDay, price).v, "after the cut and deposits lost on expiries"
  end
  net = math.floor(net + 0.5)
  if vendor and net < vendor then
    q.vendorFrom = q.rule
    Set("vendor", vendor, "vendor", ("vendor pays %s, more than the %s an AH sale nets %s")
      :format(M.Money(vendor), M.Money(net), how))
  end
  return q
end

M.commands.quote = function(rest)
  local id = tonumber(rest) or tonumber((rest or ""):match("item:(%d+)"))
  if not id then return M.Print("/meio quote <item link or ID>") end
  local q = Q.Quote(id)
  M.Print(("%s %s: %s"):format(q.action, q.price and M.Money(q.price) or "", q.reason))
end
