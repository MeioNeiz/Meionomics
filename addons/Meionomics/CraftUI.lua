-- Crafting panel: beside the profession window (or alone with /meio craft). Four views:
--   Profit    a verdict per recipe (CraftVerdict.lua), its reason under the name
--   Skill-up  orange/yellow/green recipes by verdict, cheapest per point first;
--             or (Route mode) the cheapest sequence of crafts to a target skill (CraftRoute)
--   Queue     queued crafts and the shopping list: bags, bank, mail, alts, then buy
--   Find      every recipe of his professions, known or not, also above his skill (/meio find)
-- Rows: left-click queues 1 (Shift 10), right-click removes; Ctrl-click types a count. Each
-- click shows what it did (row flash, queue badge, Queue tab count, footer line).
-- Hover: the short recipe ledger, the full one on Shift (as item tooltips).
-- Queue: "Craft next" crafts the next step in one batch, intermediates first. Headers sort.
-- "~" marks estimates: trainer requirements not seen yet, learning cost spread over points.
-- Look: Blizzard templates only (ButtonFrameTemplate, bottom tabs, column headers, dropdowns,
-- MinimalScrollBar), so it sits beside ProfessionsFrame as part of it.
local _, M = ...
local R, C = M.Recipes, M.Craft
local V = C.Value
local UI = {}
M.CraftUI = UI

local W, H = 480, 594
local LIST_TOP, LIST_BOTTOM = -84, 26   -- the inset holding the rows
local ROW_H = 20
local SORT_VERSION = 2   -- saved sort keys from before verdicts no longer exist
local DIFF = { orange = "ff8040", yellow = "ffff00", green = "40bf40", grey = "808080" }
local DIM, GOOD, BAD, ACCENT = "808080", "1eff00", "ff2020", "ffd100"
local BANK, ALT = "e8c56a", "ff9f4a"
local LABEL, VALUE = { 1, 0.82, 0 }, { 1, 1, 1 }
local SHOWS = { "known", "learnable", "all" }
local SHOW_DEFAULT = { profit = "known", skill = "learnable" }
local SHOW_TEXT = { known = "Known", learnable = "Known + learnable", all = "All seen" }

local frame, rows, offset = nil, {}, 0
local built   -- { list, view, shown } from the last Refresh
local state   -- M.db.craftUI: view; show, sort, flip per view; prof (standalone); auto

local function Hex(c, text) return "|cff" .. c .. text .. "|r" end
local function Money(c) return c and M.Money(c) or Hex(DIM, "-") end
local function Profit(p)
  if not p then return Hex(DIM, "?") end
  return p >= 0 and Hex(GOOD, M.Money(p)) or Hex(BAD, "-" .. M.Money(-p))
end
local function ItemName(id) return C_Item.GetItemNameByID(id) or ("item:" .. id) end
local function Pair(tt, left, right)
  tt:AddDoubleLine(left, right, LABEL[1], LABEL[2], LABEL[3], VALUE[1], VALUE[2], VALUE[3])
end

------------------------------------------------------------------------------ Profession
local function OpenProfession()
  local T = C_TradeSkillUI
  if not (T and T.IsTradeSkillReady and T.IsTradeSkillReady()) then return nil end
  if T.IsTradeSkillLinked() or T.IsTradeSkillGuild() or T.IsNPCCrafting() then return nil end
  local ok, b = pcall(T.GetBaseProfessionInfo)
  return ok and b and (b.parentProfessionName or b.professionName) or nil
end

-- crafting professions with recorded recipes, for the standalone cycle button
local function Professions()
  local seen, out = {}, {}
  for _, rec in pairs(R.All()) do
    if rec.prof and not seen[rec.prof] then
      seen[rec.prof] = true
      out[#out + 1] = rec.prof
    end
  end
  table.sort(out)
  return out
end

local function CurrentProfession()
  local open = OpenProfession()
  if open then return open end
  local list = Professions()
  if not tContains(list, state.prof) then state.prof = list[1] end
  return state.prof
end

------------------------------------------------------------------------------ Views
-- each: columns { title, width, sort key, name = the icon + name column, left = left-aligned },
-- rowH, Build(prof, rank) -> rows
-- a row: { icon, name, sub (second line), cells (the other columns, in order), tip = fn(tt),
--   click = fn(button), sort = {...}, x }; head = section heading, note = full-width line,
--   rule = divider line above, dim = faded
local VIEWS = {}

local function RecipeName(x)
  local c = x.colour and DIFF[x.colour] or "ffffff"
  if not x.known then c = x.learnable and (x.estLearn and "b8a05a" or "d8b24a") or DIM end
  return Hex(c, x.rec.name or ("recipe " .. x.rec.id))
end

local function Have(x)
  if x.bags > 0 then return Hex(GOOD, x.bags) end
  if x.all > 0 then return Hex(ACCENT, x.all) end
  return Hex(DIM, "0")
end

-- what one skill point costs (or earns: +); "~" when learning cost is spread or unknown
local function PerPoint(x)
  local per = x.perPointAll
  if not per then return Hex(DIM, "?") end
  local est = x.estPerPoint and "~" or ""
  if per <= 0 then return Hex(GOOD, est .. "+" .. M.Money(-per)) end
  return est .. M.Money(per)
end

local function VerdictCell(x) return x.v and Hex(x.v.colour, x.v.short) or "" end

local EditCount   -- (row, rec): the count box over a queue row

------------------------------------------------------------------------------ Find
-- WoW can't open URLs: a selected edit box to copy from
local URL_POPUP = {
  text = "%s\nCtrl+C to copy, Esc to close",
  button1 = CLOSE,
  hasEditBox = true,
  editBoxWidth = 320,
  OnShow = function(self, url)
    local box = self.editBox or (self.GetEditBox and self:GetEditBox())
    box:SetText(url)
    box:HighlightText()
    box:SetFocus()
  end,
  EditBoxOnEscapePressed = function(box) box:GetParent():Hide() end,
  EditBoxOnTextChanged = function(box, url)
    if box:GetText() ~= url then box:SetText(url) box:HighlightText() end
  end,
  timeout = 0,
  whileDead = true,
  hideOnEscape = true,
}
if StaticPopupDialogs then StaticPopupDialogs.MEIONOMICS_URL = URL_POPUP end

local function SearchAH(name)
  local ah = AuctionHouseFrame
  if not (ah and ah:IsShown() and ah.SearchBar and name) then return false end
  return pcall(function()
    if AuctionHouseFrameDisplayMode then ah:SetDisplayMode(AuctionHouseFrameDisplayMode.Buy) end
    ah.SearchBar:SetSearchText(name)
    ah.SearchBar:StartSearch()
  end)
end

-- the pattern (or the made item for a known recipe) on the open AH, else its Wowhead page
function UI.Find(rec)
  local item = select(6, C.Bands(rec))
  local known = R.KnownHere(rec)
  local target = known and rec.out or item
  local name = target and C_Item.GetItemNameByID(target)
  if name and SearchAH(name) then return UI.Say("Searching the AH for " .. name) end
  local url = C.WowheadURL(rec, not known and item or nil)
  StaticPopup_Show("MEIONOMICS_URL", "Wowhead: " .. (rec.name or ""), nil, url)
  UI.Say("Wowhead link for " .. (rec.name or "?") .. ": Ctrl+C to copy")
end

-- left adds 1 (Shift 10), right removes; Ctrl types a count; Alt finds it (AH or Wowhead)
local function QueueClick(rec)
  return function(button, row)
    if IsAltKeyDown() then return UI.Find(rec) end
    if IsControlKeyDown() then return EditCount(row, rec) end
    local n = IsShiftKeyDown() and 10 or 1
    local before = C.Queue()[rec.id] or 0
    C.Enqueue(rec, button == "RightButton" and -n or n)
    UI.QueueChanged()
    UI.Queued(rec, before)
  end
end

-- the shared recipe ledger (CraftRows.lua): short, every material and the full why on Shift
local function RecipeTip(x)
  return function(tt)
    tt:AddLine(RecipeName(x))
    local rows = C.RecipeRows(x.rec.id, { short = true, full = IsShiftKeyDown(), noHead = true,
      x = x, queued = C.Queue()[x.rec.id] or 0 })
    if rows then M.Tooltip.Render(tt, rows) end
  end
end

-- a few words under the name: where to get an unknown recipe, then the verdict's note
local function Sub(x)
  local where = C.LearnWhere and C.LearnWhere(x)
  local note = x.v.note and Hex(DIM, x.v.note)
  if not where then return note end
  local c = where == "pattern not available" and BAD or ACCENT
  return Hex(c, where) .. (note and (Hex(DIM, " · ") .. note) or "")
end

-- every recipe judged (V.ForProf), then the ones the show filter keeps
local function Judged(prof, rank, view)
  if not V then return {} end
  local c = V.ForProf(prof, view, rank)
  local show, out = state.show[view], {}
  for _, x in ipairs(c.all) do
    if x.known or show == "all" or (show == "learnable" and x.learnable) then
      V.Judge(x, c.ctx)
      out[#out + 1] = x
    end
  end
  return out
end

-- known recipes first unless mixed (state.mix), then by verdict
local function ByVerdict(a, b)
  if not state.mix then
    local ga, gb = V.Group(a.x), V.Group(b.x)
    if ga ~= gb then return ga < gb end
  end
  return V.Before(a.x, b.x)
end

local GROUPS = { "Known", "Learnable now", "Pattern not available" }

-- sorted by verdict: losers faded; a heading per group (known, learnable, can't get) when
-- there is more than one, else a rule above the first loser
local function FadeLosers(list, key, flipped)
  if key ~= "verdict" or flipped then return end
  local groups, seen = 0, {}
  for _, d in ipairs(list) do
    if d.x then
      d.dim = d.x.v.rank >= 5
      local g = V.Group(d.x)
      if not seen[g] then seen[g], groups = true, groups + 1 end
    end
  end
  if state.mix or groups < 2 then
    for _, d in ipairs(list) do
      if d.dim and not list.ruled then d.rule, list.ruled = true, true end
    end
    return
  end
  local out, last = {}, nil
  for _, d in ipairs(list) do
    local g = d.x and V.Group(d.x)
    if g and g ~= last then
      out[#out + 1] = { head = true, name = GROUPS[g] }
      last = g
    end
    out[#out + 1] = d
  end
  for i, d in ipairs(out) do list[i] = d end
end

VIEWS.profit = {
  title = "Profit",
  rowH = 32,
  columns = { { "Verdict", 78, "verdict", left = true }, { "Recipe", 136, "name", name = true },
    { "Each", 62, "each" }, { "/day (region)", 74, "day" }, { "Week", 62, "week" },
    { "Have", 38, "all" } },
  defaultSort = "verdict",
  compare = { verdict = ByVerdict },
  Build = function(prof, rank)
    local out = {}
    for _, x in ipairs(Judged(prof, rank, "profit")) do
      local each = x.real and x.real.each
      local s = x.sales
      out[#out + 1] = { icon = x.rec.icon, name = RecipeName(x), sub = Sub(x), x = x,
        recID = x.rec.id, sort = { name = x.rec.name or "", each = each,
          day = s and s.s and s.s.perDay, week = x.v.week, all = x.all },
        cells = { VerdictCell(x), x.rec.out and Profit(each) or Hex(DIM, "-"),
          s and not s.bound and s.s and s.s.perDay and M.Count(s.s.perDay) or Hex(DIM, "-"),
          x.v.week and Profit(x.v.week) or Hex(DIM, "-"), Have(x) },
        tip = RecipeTip(x), click = QueueClick(x.rec) }
    end
    return out
  end,
  Finish = FadeLosers,
}

VIEWS.skill = {
  title = "Skill-up",
  rowH = 32,
  columns = { { "Verdict", 78, "verdict", left = true }, { "Recipe", 160, "name", name = true },
    { "Chance", 46, "chance" }, { "Per point", 70, "perPoint" }, { "Cost", 78, "cost" } },
  defaultSort = "verdict",
  compare = { verdict = ByVerdict },
  ascending = { perPoint = true, cost = true, name = true },
  Build = function(prof, rank)
    local out = {}
    for _, x in ipairs(Judged(prof, rank, "skill")) do
      if x.chance and x.chance > 0 then
        local cost = x.lvl and x.lvl.mats.complete and x.lvl.mats.cost / x.lvl.n
        out[#out + 1] = { icon = x.rec.icon, name = RecipeName(x), sub = Sub(x), x = x,
          recID = x.rec.id, sort = { name = x.rec.name or "", chance = x.chance,
            perPoint = x.perPointAll, cost = cost },
          cells = { VerdictCell(x), Hex(DIFF[x.colour], ("%d%%"):format(x.chance * 100 + 0.5)),
            PerPoint(x), Money(cost) },
          tip = RecipeTip(x), click = QueueClick(x.rec) }
      end
    end
    out.prof, out.rank = prof, rank
    return out
  end,
  Finish = function(list, key, flipped)
    FadeLosers(list, key, flipped)
  end,
}

-- where the rest of a material comes from, after bags; "ok" when it is all in bags. Buying
-- leaves room only for a marker of the rest (the tooltip has it all).
local function Fetch(m)
  if m.buy > 0 then
    local more = m.alts > 0 and Hex(ALT, " +mail")
      or m.bank + m.mail > 0 and Hex(BANK, " +bank") or ""
    return Hex(BAD, m.buy) .. " " .. Money(m.price and m.price * m.buy) .. more
  end
  local parts = {}
  if m.alts > 0 then
    local a = m.fromAlts[1]
    parts[#parts + 1] = Hex(ALT, "mail: " .. (a and a.name or "alts")
      .. (#m.fromAlts > 1 and " +" .. (#m.fromAlts - 1) or ""))
  end
  if m.bank > 0 then parts[#parts + 1] = Hex(BANK, "bank") end
  if m.mail > 0 then parts[#parts + 1] = Hex(BANK, "mailbox") end
  if m.crafted > 0 then parts[#parts + 1] = Hex(ACCENT, "craft " .. m.crafted) end
  return #parts > 0 and table.concat(parts, Hex(DIM, ", ")) or Hex(GOOD, "ok")
end

local function MaterialTip(m)
  return function(tt)
    tt:SetItemByID(m.id)
    tt:AddLine(" ")
    Pair(tt, "Needed", m.need)
    if m.bags > 0 then Pair(tt, "In bags", m.bags) end
    if m.bank > 0 then Pair(tt, Hex(BANK, "From the bank"), m.bank) end
    if m.mail > 0 then Pair(tt, Hex(BANK, "From your mailbox"), m.mail) end
    for _, a in ipairs(m.fromAlts) do Pair(tt, Hex(ALT, "Mail from " .. a.name), a.n) end
    if m.crafted > 0 then Pair(tt, Hex(ACCENT, "Crafted first"), m.crafted) end
    if m.buy > 0 then
      Pair(tt, Hex(BAD, "Buy"), m.buy .. "  " .. Money(m.price and m.price * m.buy))
    end
  end
end

-- a craft step's state, for its Get cell: what stops it, else its profit or saving
local function StepState(s)
  if s.enchant then return Hex(DIM, "enchant by hand") end
  if not s.known then return Hex(BAD, "not known") end
  if s.can == 0 and s.missing[1] then
    return Hex(BAD, "needs " .. ItemName(s.missing[1][1]))
  end
  if s.queued then
    local e = R.Evaluate(s.rec)
    return Profit(e.profit and e.profit * s.n)
  end
  return s.saves and s.saves > 0 and Hex(DIM, "saves ") .. M.Money(s.saves) or ""
end

local function StepTip(s)
  local tip = RecipeTip(C.Info(s.rec, C.Rank(s.rec.prof)))
  return function(tt)
    tip(tt)
    tt:AddLine(" ")
    if s.enchant then
      tt:AddLine(Hex(DIM, "Enchants need a target item: cast it from the profession window"))
    elseif s.can < s.n then
      Pair(tt, "Craftable from bags", ("%d of %d"):format(s.can, s.n))
      for _, m in ipairs(s.missing) do
        Pair(tt, Hex(BAD, "Missing"), m[2] .. " " .. ItemName(m[1]))
      end
    end
  end
end

VIEWS.queue = {
  title = "Queue",
  columns = { { "Material / craft", 174, "name", name = true }, { "Need", 40 },
    { "Bags", 40 }, { "Bank", 40 }, { "Alts", 40 }, { "Get", 98 } },
  Build = function()
    local out = {}
    local shop = C.Shopping()
    out.shop = shop
    out.steps = C.CraftSteps(shop)
    local function Head(text, right)
      out[#out + 1] = { head = true, name = text, cells = { "", "", "", "", right or "" } }
    end
    Head("Crafts, in order", Hex(DIM, "profit"))
    for _, s in ipairs(out.steps) do
      local name = s.queued and Hex("ffffff", s.rec.name or s.rec.id) or (s.rec.name or s.rec.id)
      local can = s.can >= s.n and Hex(GOOD, s.can) or s.can > 0 and Hex(ACCENT, s.can)
        or Hex(DIM, "0")
      out[#out + 1] = { icon = s.rec.icon, dim = s.enchant or not s.known,
        recID = s.queued and s.rec.id or nil,
        name = ("%s %s"):format(name, Hex(DIM, "x" .. s.n)),
        cells = { "", can, "", "", StepState(s) },
        tip = StepTip(s), click = s.queued and QueueClick(s.rec) or nil }
    end
    if #out.steps == 0 then
      local hint = "Nothing queued: click recipes in Profit or Skill-up"
      out[#out + 1] = { name = Hex(DIM, hint) }
    end
    if #shop.mats > 0 then
      local total = Money(shop.buyCost) .. (shop.complete and "" or " +?")
      Head("Shopping list", Hex(ACCENT, total))
      local function N(v, c) return v > 0 and Hex(c, v) or Hex(DIM, "-") end
      for _, m in ipairs(shop.mats) do
        out[#out + 1] = { icon = C_Item.GetItemIconByID(m.id), name = ItemName(m.id),
          cells = { m.need, N(m.bags, "ffffff"), N(m.bank + m.mail, BANK), N(m.alts, ALT),
            Fetch(m) },
          tip = MaterialTip(m) }
      end
    end
    return out
  end,
}

------------------------------------------------------------------------------ Find view
-- Every recipe of his professions, recorded or only in the client data (CraftData: Enchanting
-- has no recorded ones), known or not, also above his skill: those are judged as at their
-- requirement. Same verdicts and order as the AH Patterns view (V.Judge, V.Before).
-- ~1000 C.Info calls are too slow for one frame: built a slice per frame per profession, kept
-- FIND_KEEP seconds; a stale build shows while the next one runs.
local FIND_KEEP, FIND_SLICE_MS, FIND_SLICE_MAX = 120, 4, 20
local FIND_GROUPS = { "known", "now", "later", "none" }
local FIND_GROUP_TEXT = { known = "Known", now = "Learnable now", later = "Learnable later",
  none = "Pattern not available" }
local FIND_GROUP_SHORT = { known = "Known", now = "Now", later = "Later", none = "No pattern" }
local WITHINS = { 10, 25, 50, 0 }   -- 0: any distance
local FIND_DEFAULT = { mode = "profit", prof = "all", within = 25,
  show = { known = true, now = true, later = true, none = false } }
local finds, finding = {}, {}   -- prof -> { rank, at, list }; prof -> { done, total }

local SRC_ICON = { ah = "Interface\\Icons\\INV_Misc_Coin_01",
  vendor = "Interface\\GossipFrame\\VendorGossipIcon",
  trainer = "Interface\\GossipFrame\\TrainerGossipIcon",
  drop = "Interface\\TargetingFrame\\UI-TargetingFrame-Skull",
  quest = "Interface\\GossipFrame\\AvailableQuestIcon",
  held = "Interface\\Icons\\INV_Misc_Bag_10" }
local VERDICT_ICON = { ["do"] = "ReadyCheck-Ready", level = "ReadyCheck-Waiting",
  slow = "ReadyCheck-Waiting", learn = "ReadyCheck-Waiting", loss = "ReadyCheck-NotReady",
  costly = "ReadyCheck-NotReady" }
local function Icon(path, size) return ("|T%s:%d:%d|t"):format(path, size or 12, size or 12) end

-- recorded recipes, and spell IDs for the rest (C.Recipe builds them, slowly: in the slices)
local function FindRecipes(prof)
  local recs, seen = {}, {}
  for id, rec in pairs(R.All()) do
    if rec.prof == prof and rec.mats then
      seen[id] = true
      recs[#recs + 1] = rec
    end
  end
  local p = R.Professions()[prof]
  if p and p.skillLine and M.CraftData then
    for id, d in pairs(M.CraftData) do
      if d[5] == p.skillLine and not seen[id] then recs[#recs + 1] = id end
    end
  end
  return recs
end

local function FindGroup(x, rank)
  if x.known then return "known" end
  if V.Unobtainable(x) or C.LearnWhere(x) == "pattern not available" then return "none" end
  if x.learn and rank < x.learn then return "later" end
  return "now"
end

-- the easiest way to get it, an icon and a few words: "AH 2 up 4g", "Name, Zone, limited 1g"
local function SourceText(x)
  if x.known then return nil end
  if x.learnFrom == "held" then return Icon(SRC_ICON.held) .. " " .. Hex(GOOD, "in your bags") end
  local first = {}
  for _, s in ipairs(C.LearnSources(x)) do
    if not (s.how == "ah" and s.none) then first[s.how] = first[s.how] or s end
  end
  local function Say(how, text) return Icon(SRC_ICON[how]) .. " " .. text end
  local s = first.ah
  if s then
    return Say("ah", ("AH %s up %s"):format(s.n or "?", Hex("ffffff", Money(s.price))))
  end
  s = first.vendor
  if s then
    return Say("vendor", Hex(ACCENT, s.who .. (s.zone and (", " .. s.zone) or ""))
      .. (s.limited and Hex(BAD, " limited") or "") .. (s.price and (" " .. Money(s.price)) or ""))
  end
  s = first.trainer
  if s then
    return Say("trainer", Hex(ACCENT, "Trainer") .. " " .. (s.est and "~" or "")
      .. Money(s.price))
  end
  s = first.drop
  if s then
    local more = s.n and s.n > 1 and Hex(DIM, " +" .. (s.n - 1)) or ""
    return Say("drop", Hex(ACCENT, (s.who or "?") .. (s.zone and (", " .. s.zone) or "")) .. more)
  end
  s = first.quest
  if s then return Say("quest", Hex(ACCENT, s.who)) end
  return Hex(BAD, "no source known")
end

local function FindStatus()
  for _, p in pairs(finding) do
    if p.total > 0 then return Hex(DIM, ("Reading recipes %d/%d"):format(p.done, p.total)) end
  end
end

-- phase 1 per recipe: C.Info at his rank (at its requirement when above it), its source;
-- phase 2, once the cheapest skill point is known: both verdicts
local function BuildFind(prof)
  if finding[prof] then return end
  local rank, max = C.Rank(prof)
  if not rank then return end
  local recs = FindRecipes(prof)
  local prog = { done = 0, total = #recs }
  finding[prof] = prog
  R.ResetCache()
  local list, pool, i, j, ctxP, ctxS = {}, {}, 0, 0, nil, nil
  local function Add(rec)
    if type(rec) == "number" then rec = C.Recipe(rec) end
    if not (rec and rec.mats) then return end
    local x = C.Info(rec, rank)
    if x.known or C.Learnable(x, rank) then pool[#pool + 1] = x end
    local group = FindGroup(x, rank)
    if not x.known and x.learn and rank < x.learn then
      x = C.Info(rec, x.learn)
      x.at = x.learn
    end
    x.group, x.src = group, SourceText(x)
    list[#list + 1] = x
  end
  local function Step()
    local stop, n = debugprofilestop() + FIND_SLICE_MS, 0
    local function More() return n < FIND_SLICE_MAX and (n == 0 or debugprofilestop() < stop) end
    while i < #recs and More() do
      i, n = i + 1, n + 1
      Add(recs[i])
    end
    if i >= #recs and not ctxP then
      local best, levelling = V.Best(pool), max and rank < max
      ctxP = { view = "profit", best = best, levelling = levelling }
      ctxS = { view = "skill", best = best, levelling = levelling }
    end
    while ctxP and j < #list and More() do
      j, n = j + 1, n + 1
      local x = list[j]
      x.vs = V.Judge(x, ctxS)
      x.vp = V.Judge(x, ctxP)
    end
    prog.done = i
    if i < #recs or j < #list then
      local status = frame and frame:IsShown() and state.view == "find" and not UI.said
        and FindStatus()
      if status then frame.status:SetText(status) end
      return C_Timer.After(0, Step)
    end
    finding[prof] = nil
    finds[prof] = { rank = rank, at = GetTime(), list = list }
    UI.RefreshSoon()
  end
  Step()
end

-- a recipe learnt or newly recorded: rebuilt on the next look (the old one shows meanwhile)
R.OnUpdate(function()
  for _, f in pairs(finds) do f.at = -math.huge end
end)

local function FindData(prof)
  local f = finds[prof]
  local fresh = f and f.rank == C.Rank(prof) and GetTime() - f.at < FIND_KEEP
  -- one profession at a time: the next starts on the refresh after one finishes
  if not fresh and not next(finding) then BuildFind(prof) end
  return f
end

local function FindProfs()
  local all = R.Professions()
  if all[state.find.prof] then return { state.find.prof } end
  local out = {}
  for prof in pairs(all) do out[#out + 1] = prof end
  table.sort(out)
  return out
end

local function FindKeep(x, rank, q)
  local f = state.find
  if not f.show[x.group] then return false end
  if x.at and f.within > 0 and x.at - rank > f.within then return false end
  if f.mode == "profit" and not x.rec.out then return false end
  if f.mode == "skill" and not (x.points and x.points > 0) then return false end
  return q == "" or (x.rec.name or ""):lower():find(q, 1, true) ~= nil
end

local function FindVerdict(x)
  local v = x.v
  local icon = VERDICT_ICON[v.key]
  return (icon and Icon("Interface\\RaidFrame\\" .. icon, 13) .. " " or "") .. Hex(v.colour, v.short)
end

-- requirement: red above his rank (dark red past his max), "~" estimated
local function ReqCell(x, rank, max)
  if not x.learn then return Hex(DIM, "-") end
  local text = (x.estLearn and "~" or "") .. x.learn
  if x.known then return Hex(DIM, text) end
  if x.at then return Hex(max and x.at > max and "a01010" or BAD, text) end
  return text
end

local function PayCell(x)
  if x.known or not x.payN then return Hex(DIM, "-") end
  if x.payDays then return ("%dd"):format(math.max(1, math.ceil(x.payDays))) end
  return ("%d cr"):format(x.payN)
end

local function FindTip(x, rank)
  return function(tt)
    tt:AddLine(RecipeName(x))
    if x.at then
      tt:AddLine(Hex(BAD, ("Needs %d, you have %d: shown as at %d"):format(x.at, rank, x.at)))
    end
    local rows = C.RecipeRows(x.rec.id, { short = true, full = IsShiftKeyDown(), noHead = true,
      x = x, rank = x.at or rank, queued = C.Queue()[x.rec.id] or 0 })
    if rows then M.Tooltip.Render(tt, rows) end
  end
end

-- known: queue it; not known: the pattern on the open AH, else its Wowhead page
local function FindClick(x)
  if x.known then return QueueClick(x.rec) end
  return function() UI.Find(x.rec) end
end

local FIND_COLUMNS = {
  profit = { { "Verdict", 82, "worth", left = true }, { "Recipe", 166, "name", name = true },
    { "Req", 34, "req" }, { "Each", 56, "each" }, { "/day", 54, "day" },
    { "Payback", 50, "pay" } },
  skill = { { "Verdict", 82, "worth", left = true }, { "Recipe", 166, "name", name = true },
    { "Req", 34, "req" }, { "Per point", 60, "perPoint" }, { "Pts", 40, "span" },
    { "Total", 60, "total" } },
}

local function FindRow(x, rank, max, mode)
  local sort = { name = x.rec.name or "", req = x.learn }
  local cells
  if mode == "skill" then
    local per = x.perPointAll
    local total = per and per * x.span
    sort.perPoint, sort.span, sort.total = per, x.span, total
    cells = { FindVerdict(x), ReqCell(x, rank, max), PerPoint(x), Hex(DIM, x.span),
      total and (total <= 0 and Hex(GOOD, "+" .. M.Money(-total)) or M.Money(total))
        or Hex(DIM, "?") }
  else
    local each, day = x.real and x.real.each, V.PerDay(x)
    sort.each, sort.day, sort.pay = each, day, not x.known and (x.payDays or x.payN) or nil
    cells = { FindVerdict(x), ReqCell(x, rank, max), Profit(each),
      day and Profit(day) or Hex(DIM, "-"), PayCell(x) }
  end
  local note = x.v.note and Hex(DIM, x.v.note)
  local sub = x.src and note and (x.src .. Hex(DIM, " · ") .. note) or x.src or note
  return { icon = x.rec.icon, name = RecipeName(x), sub = sub, x = x, recID = x.rec.id,
    sort = sort, cells = cells, tip = FindTip(x, rank), click = FindClick(x) }
end

VIEWS.find = {
  title = "Find",
  rowH = 32,
  anyProf = true,
  columns = FIND_COLUMNS.profit,
  defaultSort = "worth",
  compare = { worth = function(a, b) return V.Before(a.x, b.x) end },
  ascending = { name = true, req = true, perPoint = true, total = true, pay = true },
  Build = function()
    local f = state.find
    VIEWS.find.columns = FIND_COLUMNS[f.mode]
    local q = (f.text or ""):lower()
    local out = {}
    for _, prof in ipairs(FindProfs()) do
      local data = FindData(prof)
      if data then
        local max = select(2, C.Rank(prof))
        for _, x in ipairs(data.list) do
          if FindKeep(x, data.rank, q) then
            x.v = f.mode == "skill" and x.vs or x.vp
            out[#out + 1] = FindRow(x, data.rank, max, f.mode)
          end
        end
      end
    end
    return out
  end,
  -- by worth: losers faded below a rule
  Finish = function(list, key, flipped)
    if key ~= "worth" or flipped then return end
    for _, d in ipairs(list) do
      d.dim = d.x.v.rank >= 5
      if d.dim and not list.ruled then d.rule, list.ruled = true, true end
    end
  end,
}
------------------------------------------------------------------------------ Route
-- Skill-up's Route mode (state.route.on): the cheapest expected crafts from his rank to a target
-- (CraftRoute.lua). A plan takes 30-80 ms: kept ROUTE_KEEP seconds per profession, rank,
-- target and options, so bag and queue refreshes redraw it without planning again.
local ROUTE_KEEP, ROUTE_MAX = 120, 300
local ROUTE_DEFAULT = { on = false, resale = true, unverified = false }
local routes = {}   -- key -> { at, plan }
R.OnUpdate(function() wipe(routes) end)

-- the typed target per profession while above his rank, else the cap (or the next one)
local function RouteTarget(prof, rank, max)
  local to = state.route.to[prof]
  if not (to and to > rank) then to = C.Route.DefaultTarget(rank, max) end
  to = to and math.min(to, ROUTE_MAX)
  return to and to > rank and to or nil
end

local function RoutePlan(prof, rank, to)
  local r = state.route
  local key = table.concat({ prof, rank, to, tostring(r.resale), tostring(r.unverified) }, ":")
  local now = GetTime()
  local c = routes[key]
  if c and now - c.at < ROUTE_KEEP then return c.plan end
  for k, old in pairs(routes) do
    if now - old.at >= ROUTE_KEEP then routes[k] = nil end
  end
  c = { at = now, plan = C.Route.Plan(prof, rank, to,
    { resale = r.resale, unverified = r.unverified }) }
  routes[key] = c
  return c.plan
end

local function Plural(n, word) return ("%d %s%s"):format(n, word, n == 1 and "" or "s") end
local function Earns(net)
  if net <= 0 then return Hex(GOOD, "+" .. M.Money(-net)) end
  return M.Money(net)
end
local function Crafts(st)
  local n = math.ceil(st.crafts - 1e-6)
  return st.sd >= 0.5 and ("~" .. n) or tostring(n), n
end

local function SkippedTip(tt, plan)
  local s = plan.skipped
  if s.unverified > 0 then
    tt:AddLine(Hex(DIM, ("%s no trainer visit has confirmed: turn on \"~ Unverified trainer\"")
      :format(Plural(s.unverified, "recipe"))), nil, nil, nil, true)
  end
  if s.noSource > 0 then
    tt:AddLine(Hex(DIM, ("%s left out: pattern not available")
      :format(Plural(s.noSource, "recipe"))), nil, nil, nil, true)
  end
end

local function RouteSummary(plan)
  local text = ("%s · ~%s crafts%s · %s"):format(Plural(#plan.steps, "step"),
    M.Count(plan.crafts), plan.learn > 0 and (" · learn " .. M.Money(plan.learn)) or "",
    plan.net <= 0 and Hex(GOOD, "earns " .. M.Money(-plan.net))
      or ("costs " .. M.Money(plan.net)))
  return { note = true, name = Hex(ACCENT, ("%d-%d: "):format(plan.from, plan.reach)) .. text
    .. (plan.complete and "" or Hex(BAD, " +?")),
    tip = function(tt)
      tt:AddLine(("Route %d to %d"):format(plan.from, plan.reach))
      Pair(tt, "Materials to buy", Money(plan.buy) .. (plan.complete and "" or " +?"))
      if plan.heldValue > 0 then Pair(tt, "Materials you hold", Money(plan.heldValue)) end
      Pair(tt, "Learning", Money(plan.learn))
      Pair(tt, plan.resale and "Crafts sold" or "Crafts would sell for",
        Hex(plan.resale and GOOD or DIM, M.Money(plan.recoup)))
      Pair(tt, "Net", Earns(plan.net))
      tt:AddLine(" ")
      tt:AddLine(Hex(DIM, plan.resale and "Sells what sells here within a week, the rest to"
        .. " a vendor or disenchanted" or "Materials and learning only: crafts not sold"),
        nil, nil, nil, true)
      tt:AddLine(Hex(DIM, "Crafts are expected counts: yellow and green recipes don't always"
        .. " give a point (~)"), nil, nil, nil, true)
      SkippedTip(tt, plan)
    end }
end

-- before the first step that reaches a cap: train the next rank, then what it opens
local function StopRow(s, rank)
  local names = {}
  for _, c in ipairs(s.unlocks) do names[#names + 1] = c.rec.name or tostring(c.rec.id) end
  local head = s.at <= rank and "Train the next rank now"
    or ("At %d: train the next rank"):format(s.at)
  return { note = true, name = Hex(ACCENT, head)
    .. (#names > 0 and (Hex(DIM, " · then learn ") .. table.concat(names, ", ")) or ""),
    tip = function(tt)
      tt:AddLine(("Skill cap %d"):format(s.at))
      tt:AddLine(Hex(DIM, "Visit your trainer for the next rank to go past it"), nil, nil, nil,
        true)
      for _, c in ipairs(s.unlocks) do
        local how = c.how == "pattern" and (c.item and ItemName(c.item) or "pattern")
          or c.unverified and "trainer (not confirmed)" or "trainer"
        Pair(tt, c.rec.name or tostring(c.rec.id), ("%s%d, %s"):format(c.estLearn and "~" or "",
          c.learn, how))
      end
    end }
end

-- a pattern whose listings aren't known is costed at its usual price: an estimate
local function Guessed(c) return c.estFee or (c.src and c.src.how == "unknown") end

local function LearnCell(c)
  if c.how == "known" then return Hex(DIM, "known") end
  if c.held then return Hex(GOOD, "in bags") end
  return (Guessed(c) and "~" or "") .. Money(c.fee)
end

-- what the step's crafts do once made, under the name
local function Sells(o)
  if not o then return nil end
  if o.bound then return Hex(DIM, o.de and "bound: disenchant" or "bound: vendor") end
  if (o.day or 0) <= 0 then return Hex(DIM, o.de and "won't sell: disenchant" or "won't sell") end
  return Hex(DIM, "sells ~" .. M.Count(o.day) .. "/day")
end

local function RouteStepTip(st, plan)
  local tip = RecipeTip(st.x)
  return function(tt)
    tip(tt)
    tt:AddLine(" ")
    local text, n = Crafts(st)
    tt:AddLine(Hex(ACCENT, ("Route %d-%d"):format(st.from, st.to)))
    Pair(tt, "Crafts", st.sd >= 0.5 and ("%s (give or take %d)"):format(text, st.sd + 0.5) or n)
    Pair(tt, "Materials", Money(st.mats))
    if st.c.fee > 0 then Pair(tt, "Learning", (Guessed(st.c) and "~" or "") .. Money(st.c.fee)) end
    if st.value > 0 then Pair(tt, "Crafts sold", Hex(GOOD, M.Money(st.value))) end
    Pair(tt, "Net", Earns(st.net))
    local o = st.c.rec.out and plan.outputs[st.c.rec.out]
    if o and plan.resale and not o.bound and o.made > 0 then
      tt:AddLine(Hex(DIM, ("%s of %s to the AH (sells ~%s/day here), the rest %s"):format(
        M.Count(o.atAH), M.Count(o.made), M.Count(o.day or 0),
        o.de and "disenchanted" or "to a vendor")), nil, nil, nil, true)
    end
    if st.c.estFee then tt:AddLine(Hex(DIM, "~: trainer fee estimated")) end
    if st.c.src and st.c.src.how == "unknown" then
      tt:AddLine(Hex(DIM, "~: pattern's AH listings not known, costed at its usual price"),
        nil, nil, nil, true)
    end
  end
end

-- left queues the step's crafts, right takes them off; Alt finds it, Ctrl types a count
local function StepClick(st)
  return function(button, row)
    local rec = st.c.rec
    if IsAltKeyDown() then return UI.Find(rec) end
    if IsControlKeyDown() then return EditCount(row, rec) end
    local _, n = Crafts(st)
    local before = C.Queue()[rec.id] or 0
    C.Enqueue(rec, button == "RightButton" and -n or n)
    UI.QueueChanged()
    UI.Queued(rec, before)
  end
end

local function StepRow(st, plan)
  local c = st.c
  if not st.x then
    st.x = C.Info(c.rec, st.from)
    st.x.learnable = true
    -- the planner's pattern source when the Find view's sources have nothing
    local src = c.src and c.src.how == "unknown" and Hex(DIM, "pattern: " .. c.src.text)
    st.src = src or SourceText(st.x)
  end
  local x = st.x
  local sells = plan.resale and c.rec.out and Sells(plan.outputs[c.rec.out])
  local sub = st.src and sells and (st.src .. Hex(DIM, " · ") .. sells) or st.src or sells
  return { icon = c.rec.icon, name = RecipeName(x), sub = sub or nil, x = x, recID = c.rec.id,
    cells = { Hex(x.colour and DIFF[x.colour] or "ffffff", ("%d-%d"):format(st.from, st.to)),
      (Crafts(st)), LearnCell(c), Earns(st.net) },
    tip = RouteStepTip(st, plan), click = StepClick(st) }
end

local function RouteMatTip(m)
  return function(tt)
    tt:SetItemByID(m.id)
    tt:AddLine(" ")
    Pair(tt, "Needed", math.ceil(m.need - 1e-6))
    if m.held > 0 then
      Pair(tt, "You hold (bags, bank, mail, alts)", ("%s, worth %s"):format(M.Count(m.held),
        M.Money(m.heldCost)))
    end
    if m.buy > 0 then
      Pair(tt, m.crafted and Hex(ACCENT, "Craft") or Hex(BAD, "Buy"),
        ("%d x %s"):format(m.buy, Money(m.price)))
      if m.vendor then
        Pair(tt, "Sold by vendors", Money(m.vendor))
      elseif not m.crafted then
        local l = m.listed
        Pair(tt, "On the AH", l and ("%d (%s)"):format(l.qty, l.age and ("scan " .. C.Ago(l.age))
          or l.from or "TSM") or Hex(DIM, "not scanned"))
        if m.short then tt:AddLine(Hex(BAD, ("%d more than the AH has up"):format(m.short))) end
      end
    end
  end
end

local function MatRow(m)
  local get
  if m.buy <= 0 then
    get = Hex(GOOD, "held")
  else
    get = (m.crafted and Hex(ACCENT, "craft ") or "") .. Hex(m.short and BAD or "ffffff", m.buy)
      .. " " .. Money(m.price and m.cost)
  end
  local need = math.ceil(m.need - 1e-6)
  local held = math.floor(m.held)
  return { oneLine = true, icon = C_Item.GetItemIconByID(m.id), name = ItemName(m.id),
    cells = { "", need, held >= need and Hex(GOOD, held) or held > 0 and Hex(ACCENT, held)
      or Hex(DIM, "0"), get },
    tip = RouteMatTip(m) }
end

VIEWS.route = {
  title = "Skill-up",
  rowH = 32,
  columns = { { "Skill", 64, left = true }, { "Recipe", 178, name = true }, { "Crafts", 50 },
    { "Learn", 56 }, { "Cost", 94 } },
  Build = function(prof, rank)
    local out = {}
    local function Note(text) out[#out + 1] = { note = true, name = text } end
    if not C.Route then
      Note(Hex(BAD, "Restart the game: Meionomics has a new file"))
      return out
    end
    if not rank then
      Note(Hex(DIM, "No skill recorded for " .. prof))
      return out
    end
    local _, max = C.Rank(prof)
    local to = RouteTarget(prof, rank, max)
    out.to = to
    if not to then
      Note(Hex(DIM, ("Nothing to plan: %d is as far as it goes"):format(rank)))
      return out
    end
    local plan = RoutePlan(prof, rank, to)
    out.plan = plan
    out[#out + 1] = RouteSummary(plan)
    if plan.stuck then
      out[#out + 1] = { note = true, name = Hex(BAD,
        ("Stops at %d: no recipe you can get goes further"):format(plan.reach)),
        tip = function(tt)
          tt:AddLine(("No route to %d"):format(to))
          tt:AddLine(Hex(DIM, "Every recipe you know, can train or can buy the pattern of"
            .. " turns grey before it"), nil, nil, nil, true)
          SkippedTip(tt, plan)
        end }
    end
    local si = 1
    for _, st in ipairs(plan.steps) do
      while plan.stops[si] and st.to > plan.stops[si].at do
        out[#out + 1] = StopRow(plan.stops[si], rank)
        si = si + 1
      end
      out[#out + 1] = StepRow(st, plan)
    end
    if #plan.mats > 0 then
      table.sort(plan.mats, function(a, b)
        local ca, cb = a.cost + a.heldCost, b.cost + b.heldCost
        if ca ~= cb then return ca > cb end
        return a.id < b.id
      end)
      out[#out + 1] = { head = true, allCells = true, name = "Materials",
        cells = { "", Hex(DIM, "need"), Hex(DIM, "have"),
          Hex(ACCENT, M.Money(plan.buy) .. (plan.complete and "" or " +?")) } }
      for _, m in ipairs(plan.mats) do out[#out + 1] = MatRow(m) end
    end
    return out
  end,
}

local VIEW_ORDER = { "profit", "skill", "queue", "find" }
-- the view drawn: Skill-up shows its Route mode in its own columns
local function ViewKey()
  if state.view == "skill" and state.route.on then return "route" end
  return state.view
end

------------------------------------------------------------------------------ Crafting
-- One click crafts a whole step: CraftRecipe(id, n), the client repeating the cast. Each
-- success takes one off the queue (also for crafts made by hand from the profession window).
local CRAFT_STALE = 10   -- seconds without a success: the batch ended without an event
local crafting   -- { id, left, t } while a batch casts

local function StaleCheck()
  if crafting and GetTime() - crafting.t >= CRAFT_STALE then
    crafting = nil
    UI.Refresh()
  end
end

local function StartCraft(s)
  crafting = { id = s.rec.id, left = s.can, t = GetTime() }
  C_TradeSkillUI.CraftRecipe(s.rec.id, s.can)
  C_Timer.After(CRAFT_STALE, StaleCheck)
  UI.Refresh()
  UI.Say(("Crafting %d %s"):format(s.can, s.rec.name or s.rec.id))
end

local function OpenFor(prof)
  local p = R.Professions()[prof]
  local ok = p and p.skillLine and C_TradeSkillUI.OpenTradeSkill(p.skillLine)
  if not ok then M.Print("open " .. prof .. " from your spellbook to craft") end
end

-- the craft button for the queue as built: label, enabled, action
local function CraftAction(steps)
  if crafting then
    local rec = C.Recipe(crafting.id)
    return ("Crafting %s (%d left)"):format(rec and rec.name or "", crafting.left), false
  end
  local s = C.NextCraft(steps or {})
  if not s then
    return #(steps or {}) > 0 and "Nothing craftable from bags" or "Nothing queued", false
  end
  if OpenProfession() ~= s.rec.prof then
    return "Open " .. s.rec.prof, true, function() OpenFor(s.rec.prof) end
  end
  return ("Craft %d %s"):format(s.can, s.rec.name or s.rec.id), true,
    function() StartCraft(s) end
end

M.On("UNIT_SPELLCAST_SUCCEEDED", function(_, unit, _, spellID)
  if unit ~= "player" then return end
  local queued = C.Queue()[spellID]
  local mine = crafting and crafting.id == spellID
  if not (queued or mine) then return end
  if queued then C.Enqueue({ id = spellID }, -1) end
  if mine then
    crafting.left, crafting.t = crafting.left - 1, GetTime()
    if crafting.left <= 0 then
      crafting = nil
    else
      C_Timer.After(CRAFT_STALE, StaleCheck)
    end
  end
  UI.RefreshSoon()
end)
local function Stopped(_, unit, _, spellID)
  if unit == "player" and crafting and crafting.id == spellID then
    crafting = nil
    UI.Refresh()
  end
end
M.On("UNIT_SPELLCAST_INTERRUPTED", Stopped)
M.On("UNIT_SPELLCAST_FAILED", Stopped)

------------------------------------------------------------------------------ Count box
function EditCount(row, rec)
  local box = frame.countBox
  if not box then
    box = CreateFrame("EditBox", nil, frame, "InputBoxTemplate")
    box:SetSize(44, 18)
    box:SetNumeric(true)
    box:SetMaxLetters(4)
    box:SetAutoFocus(false)
    box:SetScript("OnEnterPressed", function(self)
      local n = tonumber(self:GetText()) or 0
      local before = C.Queue()[self.rec.id] or 0
      C.Enqueue(self.rec, n - before)
      self:Hide()
      UI.QueueChanged()
      UI.Queued(self.rec, before)
    end)
    box:SetScript("OnEscapePressed", function(self) self:Hide() end)
    box:SetScript("OnEditFocusLost", function(self) self:Hide() end)
    frame.countBox = box
  end
  box.rec = rec
  box:ClearAllPoints()
  box:SetPoint("RIGHT", row, "LEFT", VIEWS.queue.columns[1][2] + 40, 0)
  box:SetText(tostring(C.Queue()[rec.id] or 0))
  box:Show()
  box:SetFocus()
  box:HighlightText()
end

------------------------------------------------------------------------------ Frame
local function SortKey(view)
  local key = state.sort[state.view] or view.defaultSort
  return key, state.flip and state.flip[state.view]
end

local function Sorted(view, list)
  local key, flipped = SortKey(view)
  if not key then return list end
  local cmp = view.compare and view.compare[key]
  if cmp then
    table.sort(list, flipped and function(a, b) return cmp(b, a) end or cmp)
    return list
  end
  local asc = view.ascending and view.ascending[key]
  if flipped then asc = not asc end
  table.sort(list, function(a, b)
    local va, vb = a.sort[key], b.sort[key]
    if va == nil or vb == nil or va == vb then
      if va == vb then return (a.sort.name or "") < (b.sort.name or "") end
      return vb == nil
    end
    if asc then return va < vb end
    return va > vb
  end)
  return list
end

local function ShowTooltip(self)
  if not self.data or not self.data.tip then return end
  -- just past the panel's right edge, or over the profession window when the screen ends
  GameTooltip:SetOwner(self, "ANCHOR_NONE")
  if frame:GetRight() + 360 > UIParent:GetRight() then
    GameTooltip:SetPoint("TOPRIGHT", self, "TOPLEFT", -16, 0)
  else
    GameTooltip:SetPoint("TOPLEFT", self, "TOPRIGHT", 16, 0)
  end
  self.data.tip(GameTooltip)
  GameTooltip:Show()
end

local function ListWidth(view)
  local w = 0
  for _, col in ipairs(view.columns) do w = w + col[2] end
  return w
end

local function MakeRow(i)
  local b = CreateFrame("Button", nil, frame.list)
  b:RegisterForClicks("LeftButtonUp", "RightButtonUp")
  b.rule = b:CreateTexture(nil, "BORDER")
  b.rule:SetColorTexture(1, 0.82, 0, 0.35)
  b.rule:SetHeight(1)
  b.rule:SetPoint("TOPLEFT")
  b.rule:SetPoint("TOPRIGHT")
  b:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
  b.icon = b:CreateTexture(nil, "ARTWORK")
  b.badge = b:CreateFontString(nil, "OVERLAY", "NumberFontNormal")
  b.badge:SetPoint("BOTTOMRIGHT", b.icon, "BOTTOMRIGHT", 2, -1)
  b.flash = b:CreateTexture(nil, "OVERLAY")
  b.flash:SetAllPoints()
  b.flash:SetBlendMode("ADD")
  b.flash:SetAlpha(0)
  b.name = b:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
  b.name:SetJustifyH("LEFT")
  b.name:SetWordWrap(false)
  b.sub = b:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
  b.sub:SetJustifyH("LEFT")
  b.sub:SetWordWrap(false)
  b.cells = {}
  b:SetScript("OnEnter", ShowTooltip)
  b:SetScript("OnLeave", function() GameTooltip:Hide() end)
  b:SetScript("OnClick", function(self, button)
    if self.data and self.data.click then self.data.click(button, self) end
  end)
  return b
end

local function HeaderClick(self)
  if not self.key then return end
  local cur = SortKey(VIEWS[state.view])
  state.flip = state.flip or {}
  if cur == self.key then
    state.flip[state.view] = not state.flip[state.view]
  else
    state.sort[state.view], state.flip[state.view] = self.key, false
  end
  offset = 0
  UI.Refresh()
end

-- Blizzard column header buttons over the inset, the sorted one highlighted
local function Layout(view)
  local x = 0
  local key = SortKey(view)
  for i, col in ipairs(view.columns) do
    local h = frame.heads[i]
    if not h then
      h = CreateFrame("Button", nil, frame, "ColumnDisplayButtonTemplate")
      h:SetScript("OnClick", HeaderClick)
      frame.heads[i] = h
    end
    h:ClearAllPoints()
    h:SetPoint("BOTTOMLEFT", frame.Inset, "TOPLEFT", 2 + x, -2)
    h:SetSize(col[2] + 2, 24)
    h:SetText(col[1])
    local fs = h:GetFontString()
    local sorted = col[3] ~= nil and col[3] == key
    if fs then fs:SetTextColor(1, sorted and 1 or 0.82, sorted and 1 or 0) end
    h.key = col[3]
    h:Show()
    x = x + col[2]
  end
  for i = #view.columns + 1, #frame.heads do frame.heads[i]:Hide() end
end

local function Cell(b, c)
  local fs = b.cells[c]
  if not fs then
    fs = b:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    fs:SetWordWrap(false)
    b.cells[c] = fs
  end
  return fs
end

-- one or two lines: name (and number cells) on top, the reason under the name
local function DrawRow(b, d, view, rowH)
  local twoLine = rowH > ROW_H
  local top = twoLine and -4 or 0
  local wide = d.head or d.note
  b:GetHighlightTexture():SetAlpha(d.head and 0 or 1)
  b:SetAlpha(d.dim and 0.55 or 1)
  b.rule:SetShown(d.rule == true)
  b.name:SetFontObject(d.head and "GameFontNormal"
    or (twoLine and not wide) and "GameFontHighlight" or "GameFontHighlightSmall")
  b.name:ClearAllPoints()
  b.sub:ClearAllPoints()
  b.icon:ClearAllPoints()
  b.icon:SetShown(d.icon ~= nil and not wide)
  local x, used = 0, 0
  for c, col in ipairs(view.columns) do
    if col.name then
      local size = rowH - 6
      b.icon:SetSize(size, size)
      b.icon:SetPoint("LEFT", x + 2, 0)
      if d.icon then b.icon:SetTexture(d.icon) end
      local nx = wide and 4 or x + size + 6
      local nameW = wide and ListWidth(view) - 8 or col[2] - size - 8
      b.name:SetPoint(twoLine and "TOPLEFT" or "LEFT", nx, twoLine and top or 0)
      b.name:SetWidth(nameW)
      b.sub:SetPoint("BOTTOMLEFT", nx, 4)
      b.sub:SetWidth(ListWidth(view) - nx - 4)
    else
      used = used + 1
      local fs = Cell(b, used)
      fs:ClearAllPoints()
      fs:SetPoint(twoLine and "TOPLEFT" or "LEFT", x + 2, twoLine and top - 1 or 0)
      fs:SetWidth(col[2] - 6)
      fs:SetJustifyH(col.left and "LEFT" or "RIGHT")
      fs:SetText(not wide and d.cells and d.cells[used]
        or wide and (c == #view.columns or d.allCells) and d.cells and d.cells[used] or "")
      fs:Show()
    end
    x = x + col[2]
  end
  for c = used + 1, #b.cells do b.cells[c]:Hide() end
  local queued = d.x and d.recID and C.Queue()[d.recID]
  b.badge:SetShown(queued ~= nil and not wide)
  b.badge:SetText(queued or "")
  b.name:SetText(d.name)
  b.sub:SetShown(twoLine and d.sub ~= nil and not wide)
  b.sub:SetText(d.sub or "")
end

-- headings and notes stay one line high in the two-line views
local function RowHeight(d, view)
  if d.head then return ROW_H + 4 end
  if d.note or d.oneLine then return ROW_H end
  return view.rowH or ROW_H
end

-- how many rows from first fit the list's height
local function Fits(list, first, view)
  local room, n = frame.list:GetHeight(), 0
  for i = first, #list do
    room = room - RowHeight(list[i], view)
    if room < 0 then break end
    n = n + 1
  end
  return math.max(1, n)
end

-- the scroll bar follows offset; dragging it moves offset (syncing stops the echo)
local syncing
local function SyncBar(list, shown)
  local extra = #list - shown
  syncing = true
  frame.bar:SetVisibleExtentPercentage(extra > 0 and shown / #list or 1)
  frame.bar:SetPanExtentPercentage(extra > 0 and math.min(1, 3 / extra) or 1)
  frame.bar:SetScrollPercentage(extra > 0 and offset / extra or 0, true)
  syncing = false
end

local function Draw(list, view)
  Layout(view)
  local width = ListWidth(view)
  -- the last offset that still fills the list to its bottom
  local last = #list
  while last > 1 and last - 1 + Fits(list, last - 1, view) > #list - 1 do last = last - 1 end
  offset = math.max(0, math.min(offset, last - 1))
  local shown = math.min(Fits(list, offset + 1, view), #list - offset)
  local y = 0
  for i = 1, math.max(shown, #rows) do
    local b = rows[i]
    if not b and i <= shown then
      b = MakeRow(i)
      rows[i] = b
    end
    local d = i <= shown and list[i + offset]
    if b then
      b.data = d or nil
      if d then
        local h = RowHeight(d, view)
        b:ClearAllPoints()
        b:SetPoint("TOPLEFT", frame.list, "TOPLEFT", 0, -y)
        b:SetSize(width, h)
        b:Show()
        DrawRow(b, d, view, h)
        y = y + h
      else
        b:Hide()
      end
    end
  end
  built.shown = #list - (last - 1)
  SyncBar(list, built.shown)
end

-- the clicks, keys in the label colour: "Click +1 · Shift +10 · ..."
local function Hints(list)
  local out = {}
  for i = 1, #list, 2 do out[#out + 1] = Hex(ACCENT, list[i]) .. " " .. list[i + 1] end
  return table.concat(out, Hex(DIM, " · "))
end
local ROW_HINTS = Hints({ "Click", "+1", "Shift", "+10", "Right", "-1", "Ctrl", "count",
  "Alt", "find" })
local QUEUE_HINTS = Hints({ "Click", "+1", "Right", "-1" })
local FIND_HINTS = Hints({ "Click", "queue / find", "Alt", "find", "Shift", "detail" })
local ROUTE_HINTS = Hints({ "Click", "queue step", "Right", "remove", "Alt", "find",
  "Shift", "detail" })

local function Status(list)
  if state.view == "queue" and list.shop then
    local s = list.shop
    local profit = s.profit + s.saves
    local saved = s.saves > 0 and Hex(DIM, " (" .. M.Money(s.saves) .. " saved)") or ""
    return ("Buy %s  Profit %s%s   %s"):format(Money(s.buyCost) .. (s.complete and "" or " +?"),
      Profit(profit), saved, QUEUE_HINTS)
  end
  if not V then return Hex(BAD, "Restart the game: Meionomics has a new file") end
  if state.view == "find" then
    return FindStatus() or (Hex("ffffff", #list) .. Hex(DIM, " recipes   ") .. FIND_HINTS)
  end
  local src = M.Prices.Source()
  return (ViewKey() == "route" and ROUTE_HINTS or ROW_HINTS)
    .. Hex(DIM, "   " .. (src and ("Prices: " .. src) or "No prices: visit the AH"))
end

local function SetTabs()
  for i, key in ipairs(VIEW_ORDER) do
    local t = frame.tabs[key]
    local count = key == "queue" and (" (" .. C.QueueCount() .. ")") or ""
    t:SetText(VIEWS[key].title .. count)
    PanelTemplates_TabResize(t, 0)
    if key == state.view then PanelTemplates_SetTab(frame, i) end
  end
end

function UI.Refresh()
  if not (frame and frame:IsShown()) then return end
  local prof = CurrentProfession()
  local rank, max = C.Rank(prof or "")
  local what = prof and (prof .. (rank and (" %d/%d"):format(rank, max or 0) or ""))
  local find = state.view == "find"
  if find then what = "find recipes" end
  frame:SetTitle(("Meionomics: %s"):format(what or "no recipes recorded"))
  SetTabs()
  local queue = state.view == "queue"
  local skill, route = state.view == "skill", ViewKey() == "route"
  frame.showMenu:SetShown(not (queue or find or route))
  frame.showMenu:GenerateMenu()
  frame.modeMenu:SetShown(skill)
  frame.modeMenu:GenerateMenu()
  frame.modeMenu:ClearAllPoints()
  frame.modeMenu:SetPoint("RIGHT", route and frame.routeTo or frame.showMenu, "LEFT",
    route and -10 or -6, 0)
  for _, w in ipairs(frame.routeBar) do w:SetShown(route) end
  frame.routeOpts:GenerateMenu()
  frame.profMenu:SetShown(not (queue or find) and OpenProfession() == nil and #Professions() > 1)
  frame.profMenu:SetWidth(route and 110 or 130)
  frame.profMenu:ClearAllPoints()
  frame.profMenu:SetPoint("RIGHT", skill and frame.modeMenu or frame.showMenu, "LEFT", -6, 0)
  frame.profMenu:GenerateMenu()
  frame.findBar:SetShown(find)
  if find then
    for _, d in ipairs(frame.findBar.menus) do d:GenerateMenu() end
  end
  local view = VIEWS[ViewKey()]
  local list = (prof or view.anyProf) and view.Build(prof, rank) or {}
  if view.defaultSort then Sorted(view, list) end
  if view.Finish then view.Finish(list, SortKey(view)) end
  built = { list = list, view = view }
  Draw(list, view)
  if route and not frame.routeTo:HasFocus() then
    frame.routeTo:SetText(list.to and tostring(list.to) or "")
  end
  frame.craftButton:SetShown(queue)
  if queue then
    local label, enabled, action = CraftAction(list.steps)
    frame.craftButton:SetText(label)
    frame.craftButton:SetEnabled(enabled)
    frame.craftButton.action = action
  end
  frame.status:SetText(UI.said and UI.said.text or Status(list))
end

-- verdicts don't depend on the queue: outside the Queue view an edit only redraws
function UI.QueueChanged()
  if not (frame and frame:IsShown()) then return end
  if state.view == "queue" or not built then return UI.Refresh() end
  SetTabs()
  Draw(built.list, built.view)
end

-- events come in bursts (a craft: bags, spellcast, recipes): one rebuild on the next frame
local pending
function UI.RefreshSoon()
  if pending or not (frame and frame:IsShown()) then return end
  pending = true
  C_Timer.After(0, function()
    pending = nil
    UI.Refresh()
  end)
end

------------------------------------------------------------------------------ Feedback
-- every click shows what it did: its row flashes (green added, red removed, grey nothing to
-- remove), "+10" rises beside the Queue tab, the footer says it for a few seconds.
-- Fades run on OnUpdate, not animation groups, so the workbench's snapshots show them too.
local FLASH = { add = { 0.1, 1, 0.2 }, remove = { 1, 0.2, 0.1 }, none = { 0.5, 0.5, 0.5 } }
local FADE_SECONDS, SAY_SECONDS, POP_RISE = 0.8, 4, 14
local fades = {}   -- region -> { t, from, at = anchor for a rising one }
local fader = CreateFrame("Frame")
fader:Hide()
fader:SetScript("OnUpdate", function(self, elapsed)
  for region, f in pairs(fades) do
    f.t = f.t + elapsed
    local k = math.min(1, f.t / FADE_SECONDS)
    region:SetAlpha(f.from * (1 - k))
    if f.at then
      region:SetPoint(f.at[1], f.at[2], f.at[3], f.at[4], f.at[5] + POP_RISE * k)
    end
    if k >= 1 then fades[region] = nil end
  end
  if not next(fades) then self:Hide() end
end)

local function Fade(region, from, at)
  fades[region] = { t = 0, from = from, at = at }
  region:SetAlpha(from)
  if at then
    region:ClearAllPoints()
    region:SetPoint(unpack(at))
  end
  fader:Show()
end

function UI.Say(text)
  if not frame then return end
  local said = { text = text }
  UI.said = said
  frame.status:SetText(text)
  C_Timer.After(SAY_SECONDS, function()
    if UI.said ~= said then return end
    UI.said = nil
    if built and frame:IsShown() then frame.status:SetText(Status(built.list)) end
  end)
end

local function FlashRow(recID, kind)
  for _, b in ipairs(rows) do
    if b:IsShown() and b.data and b.data.recID == recID then
      local c = FLASH[kind]
      b.flash:SetColorTexture(c[1], c[2], c[3])
      return Fade(b.flash, 0.3)
    end
  end
end

local function PopCount(delta)
  local tab = frame.tabs.queue
  if not frame.pop then
    frame.pop = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
  end
  frame.pop:SetText(Hex(delta > 0 and GOOD or BAD, (delta > 0 and "+" or "") .. delta))
  Fade(frame.pop, 1, { "LEFT", tab, "RIGHT", 4, 0 })
end

-- after a queue edit: rec had before queued, the queue now holds the rest
function UI.Queued(rec, before)
  if not (frame and frame:IsShown()) then return end
  local now = C.Queue()[rec.id] or 0
  local delta, name = now - before, rec.name or ("recipe " .. rec.id)
  if delta == 0 then
    FlashRow(rec.id, "none")
    return UI.Say(Hex(DIM, name .. (now > 0 and (": " .. now .. " queued") or " isn't queued")))
  end
  FlashRow(rec.id, delta > 0 and "add" or "remove")
  PopCount(delta)
  if SOUNDKIT then
    PlaySound(delta > 0 and SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON
      or SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_OFF)
  end
  local did = delta > 0 and Hex(GOOD, "Queued " .. delta) or Hex(BAD, "Removed " .. -delta)
  local left = now > 0 and (now .. " queued") or "none left"
  UI.Say(("%s %s %s"):format(did, name, Hex(DIM, "(" .. left .. ", "
    .. C.QueueCount() .. " in the queue)")))
end

-- Shift over a recipe row: redraw its hover (short <-> full)
M.On("MODIFIER_STATE_CHANGED", function(_, key)
  if not (key == "LSHIFT" or key == "RSHIFT") or not (frame and frame:IsShown()) then return end
  local owner = GameTooltip:IsShown() and GameTooltip:GetOwner()
  if owner and owner.data and owner:GetParent() == frame.list then ShowTooltip(owner) end
end)

-- scrolling only re-points the visible rows at the list built by the last Refresh
local function Scroll(delta)
  if not built then return UI.Refresh() end
  offset = math.max(0, offset - delta * 3)
  Draw(built.list, built.view)
end

local function BarScrolled(_, pct)
  if syncing or not built then return end
  local extra = #built.list - (built.shown or 0)
  if extra <= 0 then return end
  offset = math.floor(pct * extra + 0.5)
  Draw(built.list, built.view)
end

local function Tab(key, i)
  local t = CreateFrame("Button", "MeionomicsCraftFrameTab" .. i, frame, "PanelTabButtonTemplate")
  t:SetID(i)
  t:SetText(VIEWS[key].title)
  if i == 1 then
    t:SetPoint("TOPLEFT", frame, "BOTTOMLEFT", 12, 2)
  else
    t:SetPoint("LEFT", frame.tabs[VIEW_ORDER[i - 1]], "RIGHT", 3, 0)
  end
  t:SetScript("OnClick", function()
    PlaySound(SOUNDKIT.IG_CHARACTER_INFO_TAB)
    state.view, offset = key, 0
    UI.Refresh()
  end)
  return t
end

local function Dropdown(width, setup)
  local d = CreateFrame("DropdownButton", nil, frame, "WowStyle1DropdownTemplate")
  d:SetWidth(width)
  d:SetupMenu(setup)
  return d
end

local SavePlace   -- Docking, below

local function QueueRoute()
  local plan = built and built.list.plan
  if not (plan and #plan.steps > 0) then return UI.Say(Hex(DIM, "No route to queue")) end
  local before = C.QueueCount()
  C.Route.Enqueue(plan)
  local added = C.QueueCount() - before
  UI.QueueChanged()
  for _, st in ipairs(plan.steps) do FlashRow(st.c.rec.id, "add") end
  PopCount(added)
  if SOUNDKIT then PlaySound(SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON) end
  UI.Say(("%s %s"):format(Hex(GOOD, ("Queued the route: %d crafts"):format(added)),
    Hex(DIM, ("in %s (%d in the queue)"):format(Plural(#plan.steps, "step"), C.QueueCount()))))
end

-- Route mode's controls, right to left: Queue route, options, target box (the mode menu
-- sits left of them, anchored in Refresh)
local function CreateRouteBar()
  local queue = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
  queue:SetSize(88, 22)
  queue:SetPoint("TOPRIGHT", -10, -31)
  queue:SetText("Queue route")
  queue:SetScript("OnClick", QueueRoute)
  local opts = Dropdown(96, function(_, root)
    for _, o in ipairs({ { true, "Sell crafts" }, { false, "Materials only" } }) do
      root:CreateRadio(o[2], function() return state.route.resale == o[1] end, function()
        state.route.resale = o[1]
        UI.Refresh()
      end)
    end
    root:CreateDivider()
    root:CreateCheckbox("~ Unverified trainer", function() return state.route.unverified end,
      function()
        state.route.unverified = not state.route.unverified
        UI.Refresh()
      end)
  end)
  opts:SetPoint("RIGHT", queue, "LEFT", -6, 0)
  opts:SetSelectionText(function()
    return (state.route.resale and "Sell crafts" or "Mats only")
      .. (state.route.unverified and " ~" or "")
  end)
  local to = CreateFrame("EditBox", nil, frame, "InputBoxTemplate")
  to:SetSize(34, 20)
  to:SetPoint("RIGHT", opts, "LEFT", -10, 0)
  to:SetNumeric(true)
  to:SetMaxLetters(3)
  to:SetAutoFocus(false)
  to:SetJustifyH("CENTER")
  -- empty or not above his rank: back to the default target
  to:SetScript("OnEnterPressed", function(self)
    local prof = CurrentProfession()
    if prof then state.route.to[prof] = tonumber(self:GetText()) end
    self:ClearFocus()
    offset = 0
    UI.Refresh()
  end)
  to:SetScript("OnEscapePressed", function(self)
    self:ClearFocus()
    UI.Refresh()
  end)
  to:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
    GameTooltip:AddLine("Route to this skill")
    GameTooltip:AddLine(Hex(DIM, "Enter to plan; empty: your cap, or the next one there"))
    GameTooltip:Show()
  end)
  to:SetScript("OnLeave", function() GameTooltip:Hide() end)
  frame.routeTo, frame.routeOpts = to, opts
  frame.routeBar = { queue, opts, to }
  for _, w in ipairs(frame.routeBar) do w:Hide() end
end

-- Find's controls: name search, profession, mode, which recipes (groups, distance above skill)
local function FindChanged()
  offset = 0
  UI.Refresh()
end

local function FilterText()
  local f, parts = state.find, {}
  for _, g in ipairs(FIND_GROUPS) do
    if f.show[g] then
      local text = FIND_GROUP_SHORT[g]
      if g == "later" and f.within > 0 then text = "+" .. f.within end
      parts[#parts + 1] = text
    end
  end
  return #parts > 0 and table.concat(parts, ", ") or "Nothing"
end

local function CreateFindBar()
  local bar = CreateFrame("Frame", nil, frame)
  bar:SetPoint("TOPLEFT", 12, -28)
  bar:SetPoint("TOPRIGHT", -12, -28)
  bar:SetHeight(26)
  frame.findBar = bar
  local filter = Dropdown(130, function(_, root)
    for _, g in ipairs(FIND_GROUPS) do
      root:CreateCheckbox(FIND_GROUP_TEXT[g], function() return state.find.show[g] end, function()
        state.find.show[g] = not state.find.show[g]
        FindChanged()
      end)
    end
    root:CreateDivider()
    root:CreateTitle("Learnable later: within")
    for _, n in ipairs(WITHINS) do
      root:CreateRadio(n > 0 and (n .. " points") or "Any distance",
        function() return state.find.within == n end, function()
          state.find.within = n
          FindChanged()
        end)
    end
  end)
  filter:SetParent(bar)
  filter:SetPoint("TOPRIGHT", 0, -2)
  filter:SetSelectionText(FilterText)
  local mode = Dropdown(92, function(_, root)
    for _, m in ipairs({ { "profit", "Profit" }, { "skill", "Skill-up" } }) do
      root:CreateRadio(m[2], function() return state.find.mode == m[1] end, function()
        if state.find.mode ~= m[1] then
          state.flip = state.flip or {}
          state.sort.find, state.flip.find = nil, false
        end
        state.find.mode = m[1]
        FindChanged()
      end)
    end
  end)
  mode:SetParent(bar)
  mode:SetPoint("RIGHT", filter, "LEFT", -4, 0)
  mode:SetSelectionText(function() return state.find.mode == "skill" and "Skill-up" or "Profit" end)
  local prof = Dropdown(110, function(_, root)
    local list = { "all" }
    for name in pairs(R.Professions()) do list[#list + 1] = name end
    table.sort(list, function(a, b) return a == "all" or (b ~= "all" and a < b) end)
    for _, p in ipairs(list) do
      root:CreateRadio(p == "all" and "All professions" or p,
        function() return state.find.prof == p end, function()
          state.find.prof = p
          FindChanged()
        end)
    end
  end)
  prof:SetParent(bar)
  prof:SetPoint("RIGHT", mode, "LEFT", -4, 0)
  prof:SetSelectionText(function()
    return R.Professions()[state.find.prof] and state.find.prof or "All professions"
  end)
  local search = CreateFrame("EditBox", nil, bar, "SearchBoxTemplate")
  search:SetHeight(20)
  search:SetPoint("LEFT", 6, -1)
  search:SetPoint("RIGHT", prof, "LEFT", -8, 0)
  search:SetAutoFocus(false)
  search:HookScript("OnTextChanged", function(self)
    local text = self:GetText() or ""
    if text == (state.find.text or "") then return end
    state.find.text = text ~= "" and text or nil
    FindChanged()
  end)
  search:SetText(state.find.text or "")
  bar.search = search
  bar.menus = { filter, mode, prof }
  bar:Hide()
end

local function Create()
  frame = CreateFrame("Frame", "MeionomicsCraftFrame", UIParent, "ButtonFrameTemplate")
  ButtonFrameTemplate_HidePortrait(frame)
  frame:SetSize(W, H)
  frame:SetPoint("CENTER")
  frame:SetFrameStrata("HIGH")
  frame:SetToplevel(true)
  frame:EnableMouse(true)
  frame:SetMovable(true)
  frame:RegisterForDrag("LeftButton")
  frame:SetScript("OnDragStart", function(self) self:StartMoving() end)
  frame:SetScript("OnDragStop", function(self)
    self:StopMovingOrSizing()
    self:SetUserPlaced(false)   -- placed by SavePlace, not the client's layout cache
    SavePlace()
  end)
  tinsert(UISpecialFrames, frame:GetName())
  frame.tabs = {}
  for i, key in ipairs(VIEW_ORDER) do frame.tabs[key] = Tab(key, i) end
  PanelTemplates_SetNumTabs(frame, #VIEW_ORDER)

  frame.Inset:ClearAllPoints()
  frame.Inset:SetPoint("TOPLEFT", 8, LIST_TOP)
  frame.Inset:SetPoint("BOTTOMRIGHT", -8, LIST_BOTTOM)
  frame.list = CreateFrame("Frame", nil, frame.Inset)
  frame.list:SetPoint("TOPLEFT", 4, -3)
  frame.list:SetPoint("BOTTOMRIGHT", -18, 3)
  frame.bar = CreateFrame("EventFrame", nil, frame.Inset, "MinimalScrollBar")
  frame.bar:SetPoint("TOPRIGHT", -6, -6)
  frame.bar:SetPoint("BOTTOMRIGHT", -6, 6)
  frame.bar:SetHideIfUnscrollable(true)
  frame.bar:RegisterCallback(frame.bar.Event.OnScroll, BarScrolled, frame)

  frame.showMenu = Dropdown(175, function(_, root)
    for _, show in ipairs(SHOWS) do
      root:CreateRadio(SHOW_TEXT[show], function() return state.show[state.view] == show end,
        function()
          state.show[state.view], offset = show, 0
          UI.Refresh()
        end)
    end
    root:CreateDivider()
    root:CreateCheckbox("Known recipes first", function() return not state.mix end, function()
      state.mix = not state.mix
      UI.Refresh()
    end)
  end)
  frame.showMenu:SetSelectionText(function() return SHOW_TEXT[state.show[state.view]] end)
  frame.showMenu:SetPoint("TOPRIGHT", -12, -30)
  frame.craftButton = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
  frame.craftButton:SetSize(260, 22)
  frame.craftButton:SetPoint("TOPRIGHT", -10, -30)
  frame.craftButton:SetScript("OnClick", function(self) if self.action then self.action() end end)
  frame.profMenu = Dropdown(130, function(_, root)
    for _, prof in ipairs(Professions()) do
      root:CreateRadio(prof, function() return state.prof == prof end, function()
        state.prof, offset = prof, 0
        UI.Refresh()
      end)
    end
  end)
  frame.modeMenu = Dropdown(92, function(_, root)
    for _, m in ipairs({ { false, "Ranking" }, { true, "Route" } }) do
      root:CreateRadio(m[2], function() return state.route.on == m[1] end, function()
        state.route.on, offset = m[1], 0
        UI.Refresh()
      end)
    end
  end)
  frame.modeMenu:SetSelectionText(function() return state.route.on and "Route to" or "Ranking" end)
  CreateRouteBar()
  CreateFindBar()

  frame.heads = {}
  frame.status = frame:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
  frame.status:SetPoint("BOTTOMLEFT", 12, 8)
  frame.status:SetPoint("BOTTOMRIGHT", -12, 8)
  frame.status:SetJustifyH("LEFT")
  frame.status:SetWordWrap(false)
  frame:EnableMouseWheel(true)
  frame:SetScript("OnMouseWheel", function(_, delta) Scroll(delta) end)
  frame:SetScript("OnShow", function() UI.Refresh() end)
  frame:Hide()
end

------------------------------------------------------------------------------ Docking
-- beside Blizzard's profession window when it is open, so it follows that window when it moves;
-- otherwise where it was dragged. Dragging while docked sets the offset from the window.
-- Docked, it clears what sticks out of that window's right edge (Blizzard's profession tabs,
-- WhatsTraining's tab), measured each time since those come and go.

-- how far ProfessionsFrame's right side tabs reach past its edge, in this panel's units
local function TabsWidth(pf)
  local edge, scale = pf:GetRight(), pf:GetEffectiveScale()
  if not edge then return 0 end
  local reach = 0
  for _, child in ipairs({ pf:GetChildren() }) do
    local left, right = child:GetLeft(), child:GetRight()
    if child ~= frame and child:IsShown() and left and right and right - left < 100 then
      local s = child:GetEffectiveScale() / scale
      if (left + right) / 2 * s > edge then reach = math.max(reach, right * s - edge) end
    end
  end
  return math.ceil(reach * scale / frame:GetEffectiveScale())
end

local function Dock()
  local pf = ProfessionsFrame
  frame:ClearAllPoints()
  frame.docked = pf and pf:IsShown() or false
  if frame.docked then
    local at = state.dockAt or { 2, 0 }
    frame:SetPoint("TOPLEFT", pf, "TOPRIGHT", TabsWidth(pf) + at[1], at[2])
  elseif state.freeAt then
    frame:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", state.freeAt[1], state.freeAt[2])
  else
    frame:SetPoint("CENTER")
  end
end

function SavePlace()
  local left, top = frame:GetLeft(), frame:GetTop()
  if not (left and top) then return end
  local pf = ProfessionsFrame
  if frame.docked and pf and pf:IsShown() then
    -- in this panel's units: FlareUI's Ctrl+wheel may have scaled the profession window
    local s = pf:GetEffectiveScale() / frame:GetEffectiveScale()
    state.dockAt = {
      math.floor(left - pf:GetRight() * s - TabsWidth(pf) + 0.5),
      math.floor(top - pf:GetTop() * s + 0.5),
    }
  else
    state.freeAt = { math.floor(left + 0.5), math.floor(top + 0.5) }
  end
  Dock()
end

function UI.Show()
  if not frame then Create() end
  Dock()
  frame:Show()
  UI.Refresh()
end
function UI.Hide() if frame then frame:Hide() end end
function UI.Toggle() if frame and frame:IsShown() then UI.Hide() else UI.Show() end end

local hooked
local function HookProfessionsFrame()
  if hooked or not ProfessionsFrame then return end
  hooked = true
  ProfessionsFrame:HookScript("OnShow", function() if state.auto then UI.Show() end end)
  ProfessionsFrame:HookScript("OnHide", function()
    if frame and frame.docked then UI.Hide() end
  end)
end

local prevOnLoad = M.OnLoad
function M.OnLoad()
  if prevOnLoad then prevOnLoad() end
  M.db.craftUI = M.db.craftUI or {}
  state = M.db.craftUI
  state.view = VIEWS[state.view] and state.view or "profit"
  state.show = type(state.show) == "table" and state.show or {}
  for view, show in pairs(SHOW_DEFAULT) do
    if not SHOW_TEXT[state.show[view]] then state.show[view] = show end
  end
  if state.sortVersion ~= SORT_VERSION then
    state.sort, state.flip, state.sortVersion = {}, {}, SORT_VERSION
  end
  if state.auto == nil then state.auto = true end
  state.route = type(state.route) == "table" and state.route or {}
  for k, v in pairs(ROUTE_DEFAULT) do
    if state.route[k] == nil then state.route[k] = v end
  end
  state.route.to = type(state.route.to) == "table" and state.route.to or {}
  state.find = type(state.find) == "table" and state.find or {}
  for k, v in pairs(FIND_DEFAULT) do
    if state.find[k] == nil then state.find[k] = type(v) == "table" and CopyTable(v) or v end
  end
end

M.On("ADDON_LOADED", function(_, name)
  if name == "Blizzard_Professions" then HookProfessionsFrame() end
end)
M.On("PLAYER_LOGIN", HookProfessionsFrame)
-- next frame: Blizzard shows ProfessionsFrame on the same event, so it is there to dock to
M.On("TRADE_SKILL_SHOW", function()
  HookProfessionsFrame()
  C_Timer.After(0, function() if state.auto and OpenProfession() then UI.Show() end end)
end)
M.On("TRADE_SKILL_CLOSE", function()
  crafting = nil
  if frame and frame.docked then UI.Hide() end
end)
M.On("BAG_UPDATE_DELAYED", function() UI.RefreshSoon() end)
R.OnUpdate(function() UI.RefreshSoon() end)

M.commands.craft = function(rest)
  if rest == "auto" then
    state.auto = not state.auto
    local on = state.auto and "on" or "off"
    M.Print("crafting panel opens with the profession window: " .. on)
  elseif rest == "clear" then
    wipe(C.Queue())
    UI.Refresh()
  elseif rest == "reset" then
    state.dockAt, state.freeAt = nil, nil
    if frame then Dock() end
    M.Print("crafting panel back beside the profession window")
  else
    UI.Toggle()
  end
end

-- /meio find [name]: the Find view, with or without the profession window
M.commands.find = function(rest)
  state.view, offset = "find", 0
  if rest and rest ~= "" then state.find.text = rest end
  UI.Show()
  frame.findBar.search:SetText(state.find.text or "")
end
