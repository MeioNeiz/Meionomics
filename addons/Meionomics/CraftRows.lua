-- One recipe as a ledger in Tooltip.lua's row format ({ kind = "gap" | "head" | "row", left,
-- right }), drawn with M.Tooltip.Render: the crafting panel's recipe hover, trainer tooltips
-- (hooked in Tooltip.lua) and the recipe item's Shift ledger show the same block. Order: the
-- item made (Ledger.lua's sale rows, its Leveling BiS gain), costs, profit, learning and where, skill-ups, verdict.
--   M.Craft.RecipeRows(recipeID, opts) -> rows, or nil when the recipe isn't recorded
--   opts.full     every material with its cost and what you have (else one total line)
--   opts.short    the panel's default hover: Best line, cost, profit, skill-ups, verdict note;
--                 what its columns show and the detail wait for Shift (opts.full)
--   opts.mats     list the materials without opts.full (the recipe item's Shift ledger)
--   opts.noHead   leave out the "Recipe" heading (the caller has its own)
--   opts.noBis    leave out the Leveling BiS rows (TooltipFold already shows its verdict)
--   opts.atTrainer  a trainer's own tooltip: no rows on where to learn it
--   opts.x        the panel's judged C.Info (adds the verdict last)
--   opts.queued   n queued: a line when above 0
--   opts.rank     judge at this rank (Find: recipes above his skill, as at their requirement)
--   opts.outLabel in place of the item made's "Best: " (the recipe item's own Best: is above)
local _, M = ...
local R, C = M.Recipes, M.Craft

local DIFF = { orange = "ff8040", yellow = "ffff00", green = "40bf40", grey = "808080" }
local MAX_VENDORS = 3
local function Hex(c, text) return "|cff" .. c .. text .. "|r" end
local function S(key) return M.Tooltip.style[key] end
local function Dim(text) return Hex(S("dim"), text) end
local function Grey(text) return Hex(S("grey"), text) end
local function Money(c) return c and M.Money(c) or Grey("-") end
-- e: R.Evaluate's; on prices older than R.STALE the figure is dimmed and says how old
local function Profit(p, e)
  if not p then return Grey("?") end
  if e and e.stale then
    return Dim(p >= 0 and "+" or "") .. M.Money(p, S("dim"), S("dim"))
      .. Hex(S("warn"), " old " .. R.AgeShort(e.age))
  end
  return p >= 0 and Hex(S("good"), "+" .. M.Money(p)) or Hex(S("bad"), "-" .. M.Money(-p))
end
local function ItemName(id) return C_Item.GetItemNameByID(id) or ("item:" .. id) end
local function Learn(x) return x.learn and ((x.estLearn and "~" or "") .. x.learn) or "?" end
local function Plural(n, word) return ("%d %s%s"):format(n, word, n == 1 and "" or "s") end
local function Join(...)
  local out = {}
  for i = 1, select("#", ...) do
    local v = select(i, ...)
    if v and v ~= "" then out[#out + 1] = v end
  end
  return table.concat(out, S("sep"))
end

-- Forever Leveling BiS on the item made, for its main spec: "[up] +6.1 (+8%)" as its own
-- tooltips say it; nil when it isn't gear or FLBiS isn't loaded
local BIS_MEDIA = "Interface\\AddOns\\ForeverLevelingBiS\\Media\\"
local BIS_STEP = 0.05 -- FLBiS's smallest gain worth an arrow
local function BisArrow(name, hex)
  local r, g, b = tonumber(hex:sub(1, 2), 16), tonumber(hex:sub(3, 4), 16),
    tonumber(hex:sub(5, 6), 16)
  return ("|T%s%s:0:0:0:0:32:32:0:32:0:32:%d:%d:%d|t "):format(BIS_MEDIA, name, r, g, b)
end
local NOT_FOR_YOU = Grey("not for you")

-- where it stands for its slot, in FLBiS's tier colours: "Best in slot", "86% of best, #3 Waist";
-- " at 35" for gear you can wear only later. Needs patch 62 (API.GetStanding). Second result:
-- the standing itself
local function BisStanding(itemID)
  local api = ForeverLevelingBiS_API
  if not (api and api.GetStanding) then return nil end
  local ok, st = pcall(api.GetStanding, itemID)
  if not (ok and st and st.ratio) then return nil end
  local at = st.level and (" at %d"):format(st.level) or ""
  if st.best then return Hex("ff8000", "Best in slot" .. at), st end
  local tier = (st.ratio > 0.85 and "a335ee") or (st.ratio > 0.5 and "0070dd") or "9d9d9d"
  return Hex(tier, ("%d%% of best, #%d %s%s"):format(math.floor(st.ratio * 100), st.rank,
    st.label or "", at)), st
end

-- "+4.2 (+18%)" with its arrow; base: the worn item's score
local function GainText(gain, base)
  if math.abs(gain) < BIS_STEP then return Grey("no change") end
  local text = ("%+.1f"):format(gain)
  local pct = base and base > 0 and gain / base * 100
  if pct and math.abs(pct) >= 1 and math.abs(pct) < 1000 then
    pct = pct < 0 and math.ceil(pct - 0.5) or math.floor(pct + 0.5)
    text = text .. (" (%+d%%)"):format(pct)
  end
  if gain > 0 then return BisArrow("TipUp", S("good")) .. Hex(S("good"), text) end
  return BisArrow("TipDown", S("bad")) .. Hex(S("bad"), text)
end

local function BisGain(itemID)
  local api = ForeverLevelingBiS_API
  if not (api and (api.version or 1) >= 2) then return nil end
  local ok, score, loading = pcall(api.ScoreItem, itemID)
  if not ok then return nil end
  if loading then return Dim("loading") end
  if not score then return nil end
  local gain, wait
  ok, gain, wait = pcall(api.GetGain, itemID)
  if not ok then return nil end
  if wait then return Dim("loading") end
  if not gain then return NOT_FOR_YOU end
  -- score - gain: what it replaces
  return GainText(gain, score - gain)
end

-- "you have 40" (bags, bank, mail), alts apart
local function Have(h)
  local mine = h.bags + h.bank + h.mail
  return Join(mine > 0 and ("you have " .. mine), h.alts > 0 and ("alts " .. h.alts))
end

-- the learn rank first, coloured by what the recipe is at that rank; thresholds at or below it
-- are dropped. A recorded trainer requirement can sit above DB2's yellow (or even grey).
local function SkillUps(x)
  local est = x.estBands and "~" or ""
  local learn = x.learn
  local at = learn and C.Colour(learn, x.yellow, x.green, x.grey) or "orange"
  local parts = { Hex(DIFF[at], at .. " " .. Learn(x)) }
  for _, b in ipairs({ { "yellow", x.yellow }, { "green", x.green }, { "grey", x.grey } }) do
    if not learn or b[2] > learn then
      parts[#parts + 1] = Hex(DIFF[b[1]], b[1] .. " " .. est .. b[2])
    end
  end
  return Join(unpack(parts))
end

local function Place(who, zone)
  return (who or "?") .. (zone and zone ~= "" and (", " .. zone) or "")
end

-- one row per way to learn it; says so when there is none
local function WhereRows(Add, x)
  local any, vendors = false, 0
  for _, src in ipairs(C.LearnSources(x)) do
    local h = src.how
    if h == "trainer" then
      any = true
      if src.who then
        Add("row", "  Trainer: " .. Place(src.who, src.zone),
          Join(src.need and ("needs " .. src.need), src.price and src.price > 0
            and Money(src.price) or (src.price == 0 and "free")))
      else
        Add("row", "  Trainer " .. Dim("(none visited yet)"),
          Join("needs " .. Learn(x), src.price and ("~" .. M.Money(src.price))))
      end
    elseif h == "vendor" then
      any, vendors = true, vendors + 1
      if vendors <= MAX_VENDORS then
        Add("row", "  Vendor: " .. Place(src.who, src.zone),
          Join(src.limited and Hex(S("warn"), "limited"), src.price and Money(src.price)))
      end
    elseif h == "drop" then
      any = true
      local more = src.n > 1 and Dim((" +%d more"):format(src.n - 1)) or ""
      Add("row", "  Drop: " .. Place(src.who, src.zone) .. more)
    elseif h == "quest" then
      any = true
      Add("row", "  Quest: " .. (src.who or "?"))
    elseif h == "ah" then
      if not src.none then any = true end
      Add("row", "  Auction House", src.none and Dim(src.text) or src.text)
    end
  end
  if vendors > MAX_VENDORS then
    Add("row", Dim(("  +%d more vendors"):format(vendors - MAX_VENDORS)))
  end
  if not any then
    Add("row", Hex(S("bad"), "  Not learnable from any known source"))
  end
end

-- the pattern item's "Requires" lines other than the skill (reputation, favour, level): the
-- recorded recipe data doesn't carry them
local function RequiresRows(Add, x)
  local item = not x.known and x.item
  if not (item and C_TooltipInfo and C_TooltipInfo.GetItemByID) then return end
  local ok, data = pcall(C_TooltipInfo.GetItemByID, item)
  if not (ok and data and data.lines) then return end
  local prof = x.rec.prof
  for _, line in ipairs(data.lines) do
    local text = line.leftText
    if type(text) == "string" and not (issecretvalue and issecretvalue(text))
      and text:find("^Requires") and not (prof and text:find(prof, 1, true)) then
      Add("row", Hex(S("bad"), "  " .. text))
    end
  end
end

-- "Costs to craft" includes a whole station placement (one craft); a batch shares one
local function StationRows(Add, x, st)
  if not st then return end
  if #st.parts == 0 then
    Add("row", Hex(S("warn"), "  needs a " .. st.name))
    return
  end
  local cost = st.complete and Money(st.cost) or Grey("no price")
  Add("row", Hex(S("warn"), "  incl. " .. st.name .. " + campfire"), cost)
  local n = x.real and x.real.n or 1
  local share = st.complete and n > 1
    and (", %s each over %d"):format(M.Money(st.cost / n), n) or ""
  Add("row", Dim("  one per 15 min of crafting" .. share))
end

-- crafts until learning pays for itself
local function Payback(x, e) return x.payN or R.Payback(x.learnCost, e.profit) end

local function LearningRows(Add, x, e)
  -- known: the "Known by" row says so
  if x.known then return end
  if x.learnFrom == "held" then
    Add("row", "Learning", Hex(S("good"), "pattern in your bags"))
  else
    local cost = x.learnCost
    local from = x.learnFrom == "trainer" and "trainer" or "pattern"
    local n = Payback(x, e)
    local pay = n and Dim(", pays back after " .. Plural(n, "craft")) or ""
    Add("row", "Learning (" .. from .. ")" .. pay,
      cost and ((x.learnEst and "~" or "") .. M.Money(cost)) or Grey("?"))
  end
  if x.learn and x.tooLow then
    local rank = x.rank or C.Rank(x.rec.prof or "")
    Add("row", Hex(S("bad"), ("  needs %s %s (you %d)"):format(Learn(x), x.rec.prof or "skill",
      rank or 0)))
  end
  RequiresRows(Add, x)
  WhereRows(Add, x)
end

function C.RecipeRows(recipeID, opts)
  opts = opts or {}
  local rec = C.Recipe(recipeID)
  if not (rec and rec.mats) then return nil end
  local rank = opts.rank or (opts.x and opts.x.rank) or C.Rank(rec.prof or "")
  local x = opts.x
  if not x then
    R.ResetCache()
    x = C.Info(rec, rank)
    C.Learnable(x, rank)
  end
  local e = x.e
  local rows = {}
  local function Add(kind, left, right)
    rows[#rows + 1] = { kind = kind, left = left, right = right }
  end

  if not opts.noHead then
    Add("head", "Recipe", x.known and Dim("known") or Dim("not known"))
  end
  local brief = opts.short and not opts.full
  if rec.out and brief and M.Action then
    local act = M.Prices.BestAction(rec.out)
    if act then Add("row", M.Action.Line(act, { label = opts.outLabel })) end
  elseif rec.out and M.Ledger then
    M.Ledger.SaleRows(rows, rec.out, { label = opts.outLabel })
  end
  local bis = rec.out and not opts.noBis
  local gain = bis and BisGain(rec.out)
  local standing, st = nil, nil
  if bis then standing, st = BisStanding(rec.out) end
  -- gear you can wear only later: GetGain has nothing, its standing carries the gain
  if gain == NOT_FOR_YOU and st and st.gain then gain = GainText(st.gain, st.base) end
  if standing then
    Add("row", "Leveling BiS", standing)
    if gain and gain ~= NOT_FOR_YOU then Add("row", "  vs worn", gain) end
  elseif gain then
    Add("row", "Leveling BiS", gain)
  end

  local short = e.complete and "" or Hex(S("bad"), " +?")
  local can = x.all > 0 and not brief and Dim((" (enough for %d)"):format(x.all)) or ""
  Add("row", "Costs to craft" .. (opts.full and "" or can), Money(e.cost) .. short)
  if opts.full or opts.mats then
    for _, m in ipairs(rec.mats) do
      local price = R.MatPrice(m[1])
      local have = Have(C.Have(m[1]))
      Add("row", ("  %dx %s%s"):format(m[2], ItemName(m[1]),
        have ~= "" and Dim(" (" .. have .. ")") or ""),
        price and Money(price * m[2]) or Grey("no price"))
    end
  end
  StationRows(Add, x, e.station)
  if e.value then
    local made = R.Made(rec)
    local level = select(3, R.SellValue(rec.out))
    local how = e.where == "vendor" and "sold to a vendor"
      or ("after the 5% AH cut" .. (level and level ~= "high" and ", safe price" or ""))
    local each = made > 1 and (", %g made"):format(made) or ""
    Add("row", "Profit each" .. (brief and "" or Dim(" (" .. how .. each .. ")")),
      Profit(e.profit, e))
  end

  if not brief then
    LearningRows(Add, x, e)
  elseif not x.known then
    local held = x.learnFrom == "held"
    Add("row", "Learn" .. (held and Dim(" (pattern in your bags)") or ""),
      x.learnCost and ((x.learnEst and "~" or "") .. M.Money(x.learnCost)) or Grey("?"))
    local n = x.learnFrom ~= "held" and Payback(x, e)
    if n then Add("row", Dim("  pays back after " .. Plural(n, "craft"))) end
    if x.learn and x.tooLow then
      Add("row", Hex(S("bad"), ("  needs %s (you %d)"):format(Learn(x), rank or 0)))
    end
    RequiresRows(Add, x)
    if not (held or opts.atTrainer) then WhereRows(Add, x) end
  end

  if x.grey then
    Add("row", "Skill-ups", SkillUps(x))
    if rank and x.chance and not x.tooLow then
      local pct = Hex(DIFF[x.colour], ("%d%%"):format(x.chance * 100 + 0.5))
      local per = not brief and x.perPointAll
      local value
      if per then
        local tilde = x.estPerPoint and "~" or ""
        value = per <= 0 and Hex(S("good"), tilde .. "earns " .. M.Money(-per))
          or (tilde .. M.Money(per))
        value = value .. Dim(" a point")
      end
      Add("row", ("  at %d: %s chance"):format(rank, pct), value)
    end
  end

  local who = not brief and R.KnownBy(rec) or {}
  if #who > 0 then Add("row", "Known by", table.concat(who, ", ")) end
  -- outside the panel (trainer): judged as its Profit view would
  local v = x.v or (C.Value and C.Value.JudgeOne(x))
  if v then
    local why = v.reason
    if brief then why = v.note end
    Add("row", "Verdict", Hex(v.colour, v.label))
    if why and why ~= "" then Add("row", Dim(why)) end
  end
  if opts.queued and opts.queued > 0 then Add("row", "Queued", Hex(S("good"), opts.queued)) end
  if brief then Add("hint") end
  return rows
end
