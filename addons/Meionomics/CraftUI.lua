-- Crafting panel: beside the profession window (or alone with /meio craft). Four views:
--   Profit    a verdict per recipe (CraftVerdict.lua), its reason under the name
--   Skill-up  orange/yellow/green recipes by verdict, cheapest per point first;
--             or (Route mode) the cheapest sequence of crafts to a target skill (CraftRoute)
--   Queue     queued crafts and the shopping list: bags, bank, mail, alts, then buy
--   Find      every recipe of his professions, known or not, also above his skill (/meio find)
-- What if (profession menu, /meio whatif): Profit, Skill-up and Route for any crafting
--   profession at any skill, learnt or not, from every recipe in the client data.
-- Character (profession menu): an alt's professions and known recipes (R.SetViewer), as at its
--   last login. Not saved; the Queue tab, a profession window or hiding the panel ends it.
-- Rows: left-click queues 1 (Shift 10), right-click removes; Ctrl-click types a count. Each
-- click shows what it did (row flash, queue badge, Queue tab count, footer line).
-- Hover: the short recipe ledger, the full one on Shift (as item tooltips).
-- Queue: "Craft next" crafts the next step in one batch, intermediates first; enchants one
--   cast per press, all on one item it picks (C.EnchantTarget). Headers sort.
--   Bulk mode waits until a step's whole count is in bags (one batch per recipe), Queue mode
--   crafts what bags allow now. Key binding and /meio craft next press the button.
--   Shop for (same menu, /meio craft price|speed): Cheapest crafts intermediates when cheaper,
--   Fastest buys them ready-made. Mats on other characters (same menu, /meio craft alts):
--   counted or not, each alt can be left out (C.UsesAlt); routes and verdicts follow it too.
-- "~" marks estimates: trainer requirements not seen yet, learning cost spread over points.
-- Look: Blizzard templates only (ButtonFrameTemplate, bottom tabs, column headers, dropdowns,
-- MinimalScrollBar), so it sits beside ProfessionsFrame as part of it.
local _, M = ...
local R, C = M.Recipes, M.Craft
local V = C.Value
local UI = {}
M.CraftUI = UI

local W, H = 480, 594   -- also the smallest size; the grip resizes up to MAX_W, MAX_H
local MAX_W, MAX_H = 1000, 1200
local LIST_TOP, LIST_BOTTOM = -84, 26   -- the inset holding the rows
local ROW_H = 20
local SORT_VERSION = 2   -- saved sort keys from before verdicts no longer exist
local DIFF = { orange = "ff8040", yellow = "ffff00", green = "40bf40", grey = "a0a0a0" }
local DIM, GOOD, BAD, ACCENT = "b4b4b4", "4fe36a", "ff5a5a", "ffd100"
local STALE = "c8c8c8"   -- digits of an old price: a shade under white, coin letters kept
local BANK, ALT = "e8c56a", "ff9f4a"
local LABEL, VALUE = { 1, 0.82, 0 }, { 1, 1, 1 }
local SHOWS = { "known", "learnable", "all" }
local SHOW_DEFAULT = { profit = "known", skill = "learnable" }
local SHOW_TEXT = { known = "Known", learnable = "Known + learnable", all = "All seen" }
-- Options > Keybindings > AddOns, under the Meionomics heading
BINDING_HEADER_MEIONOMICS = "Meionomics"
BINDING_NAME_MEIONOMICS_CRAFT_NEXT = "Craft next in queue"
BINDING_NAME_MEIONOMICS_CRAFT_ONE = "Craft 1 of next in queue"
BINDING_NAME_MEIONOMICS_CRAFT_TOGGLE = "Show or hide the crafting panel"
local CRAFT_MODES = {
  { "bulk", "Bulk", "One batch per recipe: waits until all its materials are in your bags, "
    .. "then crafts the lot. Fewest presses." },
  { "queue", "Queue", "Crafts whatever your bags allow now, in order; the rest in later "
    .. "batches once you fetch the materials." },
}
local SHOP_FOR = {
  { "price", "Cheapest", "Crafts intermediates such as bolts from raw materials when that "
    .. "costs less than buying them." },
  { "speed", "Fastest", "Buys intermediates ready-made when the AH sells them: fewer "
    .. "purchases and no extra crafts, at a higher price." },
}

local frame, rows, offset = nil, {}, 0
local built   -- { list, view, shown } from the last Refresh
local state   -- M.db.craftUI: view; show, sort, flip per view; prof (standalone); auto
local ColWidth   -- Frame, below

local function Hex(c, text) return "|cff" .. c .. text .. "|r" end
local function Money(c) return c and M.Money(c) or Hex(DIM, "-") end
local function Profit(p)
  if not p then return Hex(DIM, "?") end
  return p >= 0 and Hex(GOOD, M.Money(p)) or Hex(BAD, "-" .. M.Money(-p))
end
-- e: R.Evaluate's; on prices older than R.STALE dimmed with a ~, the row's tooltip says how old
local function ProfitAged(p, e)
  if p and e and e.stale then return Hex(DIM, "~") .. M.Money(p, STALE) end
  return Profit(p)
end
local function Plural(n, word) return ("%d %s%s"):format(n, word, n == 1 and "" or "s") end
local function ItemName(id) return C_Item.GetItemNameByID(id) or ("item:" .. id) end
local function Pair(tt, left, right)
  tt:AddDoubleLine(left, right, LABEL[1], LABEL[2], LABEL[3], VALUE[1], VALUE[2], VALUE[3])
end

-- hover help on a control: { title, line, more } (more on Shift), or a function returning
-- one; MODIFIER_STATE_CHANGED redraws it
local MUTED = "999999"
local function ShowHelp(self)
  local h = self.meioHelp
  if type(h) == "function" then h = h(self) end
  if not h then return end
  GameTooltip:Hide()   -- a Shift redraw re-anchors from scratch
  GameTooltip:SetOwner(self, self.meioAnchor or "ANCHOR_BOTTOM")
  GameTooltip:SetText(h[1], 1, 1, 1)
  if h[2] then GameTooltip:AddLine(h[2], LABEL[1], LABEL[2], LABEL[3], true) end
  if h[3] and IsShiftKeyDown() then
    GameTooltip:AddLine(h[3], 0.8, 0.8, 0.8, true)
  elseif h[3] then
    M.Tooltip.ShiftHint(GameTooltip)
  end
  GameTooltip:Show()
end

local function Help(widget, help, anchor)
  widget.meioHelp, widget.meioAnchor = help, anchor
  if widget.meioHelpHooked then return end
  widget.meioHelpHooked = true
  if widget.SetMotionScriptsWhileDisabled then widget:SetMotionScriptsWhileDisabled(true) end
  widget:HookScript("OnEnter", ShowHelp)
  widget:HookScript("OnLeave", GameTooltip_Hide)
  if widget:HasScript("OnMouseDown") then widget:HookScript("OnMouseDown", GameTooltip_Hide) end
end

------------------------------------------------------------------------------ Profession
local function OpenProfession()
  local T = C_TradeSkillUI
  if not (T and T.IsTradeSkillReady and T.IsTradeSkillReady()) then return nil end
  if T.IsTradeSkillLinked() or T.IsTradeSkillGuild() or T.IsNPCCrafting() then return nil end
  local ok, b = pcall(T.GetBaseProfessionInfo)
  return ok and b and (b.parentProfessionName or b.professionName) or nil
end

local function CharName(key)
  local c = R.Chars()[key]
  local name = c and c.name or "?"
  local col = c and c.class and RAID_CLASS_COLORS and RAID_CLASS_COLORS[c.class]
  return col and col:WrapTextInColorCode(name) or name, name
end

-- the shown character's crafting professions, else any with recorded recipes
local function Professions()
  local seen, out = {}, {}
  local lines = C.Lines()
  for prof in pairs(R.Professions()) do
    if lines[prof] then out[#out + 1] = prof end
  end
  if #out > 0 then
    table.sort(out)
    return out
  end
  for _, rec in pairs(R.All()) do
    if rec.prof and not seen[rec.prof] then
      seen[rec.prof] = true
      out[#out + 1] = rec.prof
    end
  end
  table.sort(out)
  return out
end

-- What if: a profession and skill that aren't his, for Profit, Skill-up and Route (every
-- recipe in the client data, learnable at that skill). Not saved; opening a profession ends it.
local whatIf   -- { prof, rank }

-- the open window is his own: not what an alt's view shows
local function OpenHere() return not R.Viewer() and OpenProfession() or nil end

local function CurrentProfession()
  if whatIf then return whatIf.prof end
  local open = OpenHere()
  if open then return open end
  local list = Professions()
  if not tContains(list, state.prof) then state.prof = list[1] end
  return state.prof
end

local function RankOf(prof)
  if whatIf and whatIf.prof == prof then return whatIf.rank, C.CapAt(whatIf.rank) end
  return C.Rank(prof)
end

-- prof nil: back to his own. A profession of his, picked while no other one is open: simply
-- that one. Else what-if at rank, or his own rank in it, or 1.
function UI.WhatIf(prof, rank)
  offset = 0
  whatIf = nil
  if prof then
    local own = C.Rank(prof)
    local open = OpenHere()
    if not rank and own and (open == nil or open == prof) then
      state.prof = prof
    else
      whatIf = { prof = prof, rank = math.max(1, math.min(300, math.floor(rank or own or 1))) }
    end
  end
  UI.Refresh()
end

-- key nil: back to this character. Keeps the profession when the alt has it too; back home,
-- the one shown before leaving.
local ownProf
function UI.ViewAs(key)
  if key == R.Me() then key = nil end
  if key == R.Viewer() then return end
  local prof = CurrentProfession()
  if not R.Viewer() then ownProf = state.prof end
  offset, whatIf = 0, nil
  R.SetViewer(key)
  if key and prof and R.Professions()[prof] then
    state.prof = prof
  elseif not key and ownProf then
    state.prof = ownProf
  end
  UI.Refresh()
end

-- characters with a crafting profession: this one first, then by name
local function Crafters()
  local lines, out = C.Lines(), {}
  for key, c in pairs(R.Chars()) do
    for prof in pairs(type(c) == "table" and c.profs or {}) do
      if lines[prof] then
        out[#out + 1] = key
        break
      end
    end
  end
  local me = R.Me()
  table.sort(out, function(a, b)
    if (a == me) ~= (b == me) then return a == me end
    return select(2, CharName(a)) < select(2, CharName(b))
  end)
  return out
end

-- queueing is for crafts made here: an alt's recipes would wait in the wrong queue
local function AltShown()
  local key = R.Viewer()
  if not key then return false end
  UI.Say(Hex(DIM, ("Log in on %s to queue its crafts"):format(select(2, CharName(key)))))
  return true
end

local WHATIF_POPUP = {
  text = "What if: %s at skill (1-300)",
  button1 = OKAY,
  button2 = CANCEL,
  hasEditBox = true,
  editBoxWidth = 60,
  OnShow = function(self, prof)
    local box = self.editBox or (self.GetEditBox and self:GetEditBox())
    box:SetText(tostring(RankOf(prof) or ""))
    box:HighlightText()
    box:SetFocus()
  end,
  OnAccept = function(self, prof)
    local box = self.editBox or (self.GetEditBox and self:GetEditBox())
    local n = tonumber(box:GetText())
    if n then UI.WhatIf(prof, n) end
  end,
  EditBoxOnEnterPressed = function(box, prof)
    local n = tonumber(box:GetText())
    box:GetParent():Hide()
    if n then UI.WhatIf(prof, n) end
  end,
  EditBoxOnEscapePressed = function(box) box:GetParent():Hide() end,
  timeout = 0,
  whileDead = true,
  hideOnEscape = true,
}
if StaticPopupDialogs then StaticPopupDialogs.MEIONOMICS_WHATIF = WHATIF_POPUP end

-- the show filter in effect: what-if has nothing "known" worth asking about
local function ShowOf(view)
  local show = state.show[view]
  if whatIf and show == "known" then return "learnable" end
  return show
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
  -- "Enchant Bracer - Lesser Stamina" -> "Bracer - Lesser Stamina": the part that differs
  -- fits the column; the tooltip has the full name
  local name = x.rec.name and x.rec.name:gsub("^Enchant (.- %- )", "%1")
  return Hex(c, name or ("recipe " .. x.rec.id))
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
-- WoW can't open URLs, and CopyToClipboard is Blizzard-only: a selected edit box the user
-- copies from; Ctrl+C there says so in chat and closes it. Popup edit boxes are shared
-- between dialogs, hence the hook keyed on meioURL.
local function CopiedHook(box)
  if box.meioHooked then return end
  box.meioHooked = true
  box:HookScript("OnKeyDown", function(b, key)
    if not (b.meioURL and key == "C" and IsControlKeyDown()) then return end
    M.Print("copied to clipboard: " .. b.meioURL)
    b.meioURL = nil
    C_Timer.After(0, function() b:GetParent():Hide() end)
  end)
  box:HookScript("OnHide", function(b) b.meioURL = nil end)
end

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
    CopiedHook(box)
    box.meioURL = url
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

-- the pattern (or the made item for a known recipe) on the open AH, else (or with link) its
-- Wowhead page
function UI.Find(rec, link)
  local item = select(6, C.Bands(rec))
  local known = R.KnownHere(rec)
  local target = known and rec.out or item
  local name = target and C_Item.GetItemNameByID(target)
  if not link and name and SearchAH(name) then return UI.Say("Searching the AH for " .. name) end
  local url = C.WowheadURL(rec, not known and item or nil)
  StaticPopup_Show("MEIONOMICS_URL", "Wowhead: " .. (rec.name or ""), nil, url)
  UI.Say("Wowhead link for " .. (rec.name or "?") .. ": Ctrl+C to copy")
end

-- left adds 1 (Shift 10), right removes; Ctrl types a count; Alt finds it (AH or Wowhead),
-- Shift+Alt always Wowhead
-- count: what a plain click queues, else 1 (Shift: 10)
local function QueueClick(rec, count)
  return function(button, row)
    if IsAltKeyDown() then return UI.Find(rec, IsShiftKeyDown()) end
    if AltShown() then return end
    if IsControlKeyDown() then return EditCount(row, rec) end
    local n = count or IsShiftKeyDown() and 10 or 1
    local before = C.Queue()[rec.id] or 0
    C.Enqueue(rec, button == "RightButton" and -n or n)
    UI.QueueChanged()
    UI.Queued(rec, before)
  end
end

local function LinkHint(tt, x)
  if not x.known then tt:AddLine(Hex(DIM, "Shift+Alt-click: Wowhead link")) end
end

-- the shared recipe ledger (CraftRows.lua): short, every material and the full why on Shift
local function RecipeTip(x)
  return function(tt)
    tt:AddLine(RecipeName(x))
    local rows = C.RecipeRows(x.rec.id, { short = true, full = IsShiftKeyDown(),
      noHead = true, x = x, queued = C.Queue()[x.rec.id] or 0 })
    if rows then M.Tooltip.Render(tt, rows) end
    LinkHint(tt, x)
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

-- Profit and Skill-up name search; not saved, so a forgotten filter doesn't hide recipes
-- after a relog
local search = ""

-- every word anywhere in the name: "shadow weave" finds Shadoweave, "gloves shadow" too
local function NameMatches(rec, q)
  local name = (rec.name or ""):lower()
  for word in q:gmatch("%S+") do
    if not name:find(word, 1, true) then return false end
  end
  return true
end

-- every recipe judged (V.ForProf), then the ones the show filter and search keep
local function Judged(prof, rank, view)
  if not V then return {} end
  local c = V.ForProf(prof, view, rank, whatIf and { max = select(2, RankOf(prof)) })
  local show, out, q = ShowOf(view), {}, search:lower()
  for _, x in ipairs(c.all) do
    if (x.known or show == "all" or (show == "learnable" and x.learnable))
        and NameMatches(x.rec, q) then
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

-- Profit's head section: what his mats earn crafted (V.HeldProfit); list.top, kept above
-- the sorted rows
local function HeldTop(list)
  local plan = V.HeldProfit(list)
  if #plan.steps == 0 then return nil end
  local top = { { head = true, allCells = true, name = "With your mats",
    cells = { "", "", "", Profit(plan.gain), "" } } }
  local function Breakdown(tt, s)
    Pair(tt, "Crafted and sold", Money(s.value))
    Pair(tt, "Your mats, sold as they are", Money(s.heldCost))
    if s.buy > 0 then Pair(tt, "Mats to buy", Money(s.buy)) end
    Pair(tt, "Gain over selling the mats", Profit(s.gain))
  end
  top[2] = { note = true,
    name = Hex(ACCENT, Plural(plan.crafts, "craft")) .. Hex(DIM, " · ") .. Profit(plan.gain)
      .. Hex(DIM, " more than selling the mats") .. (plan.buy > 0 and Hex(DIM, " · buy ")
      .. M.Money(plan.buy) or "") .. Hex(DIM, " · click: queue them"),
    click = function()
      local n = 0
      for _, s in ipairs(plan.steps) do
        C.Enqueue(s.x.rec, s.crafts)
        n = n + s.crafts
      end
      UI.QueueChanged()
      UI.Say(Hex(GOOD, ("Queued %s from your mats"):format(Plural(n, "craft"))))
    end,
    tip = function(tt)
      tt:AddLine("Your mats: bags, bank and mail")
      Breakdown(tt, plan)
      tt:AddLine(" ")
      for _, m in ipairs(plan.mats) do
        Pair(tt, ItemName(m.id), m.used .. (m.bought > 0 and Hex(BAD, " +" .. m.bought .. " buy")
          or ""))
      end
      tt:AddLine(" ")
      tt:AddLine(Hex(DIM, "One craft at a time, the recipe earning most for the mats it uses,"
        .. " while that beats selling them. Mats cost what selling them would bring, so"
        .. " scarce ones go where they earn most. Alts' mats not counted"), nil, nil, nil, true)
      tt:AddLine(Hex(DIM, "Click: add them all to the queue"), nil, nil, nil, true)
    end }
  for _, s in ipairs(plan.steps) do
    local x, uses = s.x, {}
    for _, m in ipairs(x.rec.mats) do
      local n, buy = s.uses[m[1]], s.buys[m[1]]
      if n or buy then
        uses[#uses + 1] = n and (n .. " " .. ItemName(m[1])
          .. (buy and Hex(BAD, " +" .. buy .. " buy") or ""))
          or Hex(BAD, ("buy %d %s"):format(buy, ItemName(m[1])))
      end
    end
    local day = x.sales and not x.sales.bound and x.sales.s and x.sales.s.perDay
    top[#top + 1] = { icon = x.rec.icon, name = RecipeName(x), x = x, recID = x.rec.id,
      held = true,
      sub = Hex(DIM, "uses " .. table.concat(uses, ", ")),
      cells = { Hex(GOOD, "Craft " .. s.crafts), Profit(s.gain / s.crafts),
        day and M.Count(day) or Hex(DIM, "-"), Profit(s.gain), Have(x) },
      tip = function(tt)
        RecipeTip(x)(tt)
        tt:AddLine(" ")
        tt:AddLine(("With your mats: %s"):format(Plural(s.crafts, "craft")))
        Breakdown(tt, s)
        tt:AddLine(Hex(DIM, "Click: queue these. Each and Week here: the gain over selling"
          .. " the mats"), nil, nil, nil, true)
      end,
      click = QueueClick(x.rec, s.crafts) }
  end
  return top
end

VIEWS.profit = {
  title = "Profit",
  rowH = 32,
  columns = {
    { "Verdict", 78, "verdict", left = true, tip = "What to do with it: craft, wait or leave",
      more = "Best first; known recipes first unless the Show menu mixes them" },
    { "Recipe", 136, "name", name = true, tip = "Under the name: why, or where to learn it" },
    { "Each", 62, "each", tip = "Profit on one craft, after the 5% AH cut",
      more = "Materials at today's prices. Dimmed with ~: prices older than a day" },
    { "/day (region)", 74, "day", tip = "How many sell a day across the region (TSM)" },
    { "Week", 62, "week", tip = "Expected profit over a week, as fast as it sells" },
    { "Have", 38, "all", tip = "Crafts your materials cover",
      more = "Green: from bags now. Gold: with bank, mail and alts" } },
  defaultSort = "verdict",
  compare = { verdict = ByVerdict },
  Build = function(prof, rank)
    local out = {}
    local judged = Judged(prof, rank, "profit")
    -- his mats, his rank: not for an alt's recipes or a what-if skill
    out.top = not (whatIf or R.Viewer()) and HeldTop(judged) or nil
    for _, x in ipairs(judged) do
      local each = x.real and x.real.each
      local s = x.sales
      out[#out + 1] = { icon = x.rec.icon, name = RecipeName(x), sub = Sub(x), x = x,
        recID = x.rec.id, sort = { name = x.rec.name or "", each = each,
          day = s and s.s and s.s.perDay, week = x.v.week, all = x.all },
        cells = { VerdictCell(x), x.rec.out and ProfitAged(each, x.e) or Hex(DIM, "-"),
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
  columns = {
    { "Verdict", 78, "verdict", left = true, tip = "Worth levelling with, or not",
      more = "Best first; known recipes first unless the Show menu mixes them" },
    { "Recipe", 160, "name", name = true, tip = "Colour: orange, yellow, green at your skill" },
    { "Chance", 46, "chance", tip = "Chance of a skill point per craft at your skill" },
    { "Per point", 70, "perPoint", tip = "What one skill point costs after selling the crafts",
      more = "Green +: it earns. ~: estimate, learning cost spread over its points" },
    { "Mats each", 78, "cost", tip = "Materials for one craft at today's prices" } },
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
-- expected skill points: one decimal while small
local function Points(p)
  return p >= 9.95 and ("%d"):format(p + 0.5) or ("%.1f"):format(p)
end

-- expected points and, when chance makes it vary, a typical miss either way (1 sd): "+14 ±2"
local function PointsPM(p, var)
  local sd = math.floor(math.sqrt(var or 0) + 0.5)
  return "+" .. Points(p) .. (sd >= 1 and (" ±" .. sd) or "")
end

local function StepState(s)
  if not s.known then return Hex(BAD, "not known") end
  if s.can == 0 and s.missing[1] then
    return Hex(BAD, "needs " .. ItemName(s.missing[1][1]))
  end
  local tool = C.MissingTool(s.rec, true)
  if tool then
    return Hex(BAD, "needs " .. (C.ToolName(tool):match("(%a+)$") or "tool"):lower())
  end
  if s.tool then return Hex(ACCENT, "tool") end
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
    if s.points then
      Pair(tt, "Skill-ups, in queue order", PointsPM(s.points, s.var))
    end
    if s.stop then
      tt:AddLine(Hex(DIM, ("Queued for %s %d: Craft next stops there and takes the rest off"
        .. " the queue"):format(s.rec.prof, s.stop)), nil, nil, nil, true)
    end
    if s.tool then
      tt:AddLine(Hex(ACCENT, ("Added: queued enchants need a %s and you hold none"):format(s.tool)),
        nil, nil, nil, true)
    end
    local tool = C.MissingTool(s.rec, true)
    if tool then
      tt:AddLine(Hex(BAD, ("Needs a %s in your bags"):format(C.ToolName(tool))), nil, nil, nil,
        true)
    end
    if s.enchant then
      tt:AddLine(Hex(DIM, "Craft next casts one per press (the game only lets a click or key "
        .. "confirm a replace), on one item, unenchanted and worn first. The game asks before "
        .. "replacing an enchant you had; its own it replaces"),
        nil, nil, nil, true)
    end
    if s.can < s.n then
      Pair(tt, "Craftable from bags", ("%d of %d"):format(s.can, s.n))
      for _, m in ipairs(s.missing) do
        Pair(tt, Hex(BAD, "Missing"), m[2] .. " " .. ItemName(m[1]))
      end
    end
  end
end

VIEWS.queue = {
  title = "Queue",
  columns = {
    { "Material / craft", 174, name = true,
      tip = "Crafts in the order to make them, then their materials",
      more = "Intermediates such as bolts come first. +N: skill points expected" },
    { "Need", 40, tip = "Materials: how many the whole queue needs. Crafts: how many queued" },
    { "Bags", 40, tip = "Materials: in your bags. Crafts: how many your bags make now" },
    { "Bank", 40, tip = "Materials: in your bank or mailbox" },
    { "Alts", 40, tip = "Materials: on your alts" },
    { "Get", 98, tip = "Materials: what to buy (red) or fetch. Crafts: what stops it, else profit",
      more = "The total to buy is on the Shopping list line" } },
  Build = function()
    local out = {}
    local shop = C.Shopping()
    out.shop = shop
    out.steps = C.CraftSteps(shop)
    local function Head(text, right)
      out[#out + 1] = { head = true, name = text, cells = { "", "", "", "", right or "" } }
    end
    local gains = {}
    for prof, g in pairs(out.steps.gain or {}) do
      if g.points > 0 then
        gains[#gains + 1] = (" · %s %s"):format(prof, PointsPM(g.points, g.var))
      end
    end
    table.sort(gains)
    if #out.steps > 0 then
      Head("Crafts, in order" .. Hex(DIM, table.concat(gains)), Hex(DIM, "profit"))
    end
    for _, s in ipairs(out.steps) do
      local name = s.queued and Hex("ffffff", s.rec.name or s.rec.id) or (s.rec.name or s.rec.id)
      local can = s.can >= s.n and Hex(GOOD, s.can) or s.can > 0 and Hex(ACCENT, s.can)
        or Hex(DIM, "0")
      local points = s.points and s.points > 0 and " " .. Hex(GOOD, "+" .. Points(s.points)) or ""
      out[#out + 1] = { icon = s.rec.icon, dim = not s.known,
        recID = s.queued and s.rec.id or nil,
        name = name .. points,
        cells = { s.n, can, "", "", StepState(s) },
        tip = StepTip(s), click = s.queued and QueueClick(s.rec) or nil }
    end
    if #out.steps == 0 then
      local function Note(text) out[#out + 1] = { note = true, name = text } end
      Note(Hex(ACCENT, "Nothing queued yet"))
      Note(Hex(DIM, "Profit or Skill-up: click a recipe to queue 1, Shift-click for 10"))
      Note(Hex(DIM, "Skill-up > Route: Queue route adds a whole skill-up run"))
      Note(Hex(DIM, "Then Craft next (top right, or its key binding) makes them in order"))
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
local FIND_GROUPS = { "known", "now", "later", "none" }
local FIND_GROUP_TEXT = { known = "Known", now = "Learnable now", later = "Learnable later",
  none = "Pattern not available" }
local FIND_GROUP_SHORT = { known = "Known", now = "Now", later = "Later", none = "No pattern" }
local WITHINS = { 10, 25, 50, 0 }   -- 0: any distance
local FIND_DEFAULT = { mode = "profit", prof = "all", within = 25,
  show = { known = true, now = true, later = true, none = false } }
local SourceText, FindStatus   -- used by Route and the footer
do
local FIND_KEEP, FIND_SLICE_MS, FIND_SLICE_MAX = 120, 4, 20
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
function SourceText(x)
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

function FindStatus()
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
  local who = R.Viewer()
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
    finds[prof] = { rank = rank, at = GetTime(), list = list, who = who }
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
  local fresh = f and f.who == R.Viewer() and f.rank == C.Rank(prof)
    and GetTime() - f.at < FIND_KEEP
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
  return NameMatches(x.rec, q)
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
  if x.at then return Hex(max and x.at > max and "c84040" or BAD, text) end
  return text
end

local function PayCell(x)
  if x.known or not x.payN then return Hex(DIM, "-") end
  return ("%d sold"):format(V.PaySold(x))
end

local function FindTip(x, rank)
  return function(tt)
    tt:AddLine(RecipeName(x))
    if x.at then
      tt:AddLine(Hex(BAD, ("Needs %d, you have %d: shown as at %d"):format(x.at, rank, x.at)))
    end
    local rows = C.RecipeRows(x.rec.id, { short = true, full = IsShiftKeyDown(),
      noHead = true, x = x, rank = x.at or rank, queued = C.Queue()[x.rec.id] or 0 })
    if rows then M.Tooltip.Render(tt, rows) end
    LinkHint(tt, x)
  end
end

-- known: queue it; not known: the pattern on the open AH, else its Wowhead page
local function FindClick(x)
  if x.known then return QueueClick(x.rec) end
  return function() UI.Find(x.rec, IsShiftKeyDown() and IsAltKeyDown()) end
end

local FIND_COLUMNS = {
  profit = {
    { "Verdict", 76, "worth", left = true, tip = "Worth crafting to sell, learning included" },
    { "Recipe", 100, "name", name = true, tip = "Under the name: where to learn it" },
    { "Req", 30, "req", tip = "Skill to learn it; red: above yours" },
    { "Each", 52, "each", tip = "Profit on one craft, after the 5% AH cut" },
    { "Margin", 38, "margin", tip = "Profit as a share of the materials' cost" },
    { "Sells/day", 50, "sold", tip = "How many sell a day here" },
    { "Profit/day", 54, "day", tip = "Expected profit a day, as fast as it sells" },
    { "Payback", 46, "pay", tip = "How many must sell to pay for learning it" } },
  skill = {
    { "Verdict", 82, "worth", left = true, tip = "Worth levelling with, learning included" },
    { "Recipe", 166, "name", name = true, tip = "Under the name: where to learn it" },
    { "Req", 34, "req", tip = "Skill to learn it; red: above yours" },
    { "Per point", 60, "perPoint", tip = "What one skill point costs after selling the crafts" },
    { "Pts", 40, "span", tip = "Skill points it can give, from learning to grey" },
    { "Total", 60, "total", tip = "Per point times points: all its points" } },
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
    local s = x.sales
    local sold = s and not s.bound and s.day or nil
    local cost = x.real and x.real.mats.cost
    local margin = each and cost > 0 and each * x.real.n / cost or nil
    sort.each, sort.margin, sort.sold, sort.day = each, margin, sold, day
    sort.pay = not x.known and V.PaySold(x) or nil
    cells = { FindVerdict(x), ReqCell(x, rank, max), Profit(each),
      margin and Hex(margin >= 0 and GOOD or BAD, ("%d%%"):format(math.floor(margin * 100 + 0.5)))
        or Hex(DIM, "-"),
      sold and (sold < 0.05 and "<0.1" or M.Count(sold)) or Hex(DIM, s and s.bound and "vendor" or "-"),
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
end
------------------------------------------------------------------------------ Route
-- Skill-up's Route mode (state.route.on): the cheapest expected crafts from his rank to a target
-- (CraftRoute.lua). A plan takes 30-80 ms: kept ROUTE_KEEP seconds per profession, rank,
-- target and options, so bag and queue refreshes redraw it without planning again.
-- Scoped in do ... end: the main chunk's 200 local limit.
-- confirmedOnly: trainer recipes only once a trainer visit has shown them
-- useHeld: the route starts with what held mats level (C.Route.FromHeld), then plans the rest.
-- Off: one route, held mats at what they'd sell for, so it sells them when levelling with
-- something else costs less
local ROUTE_DEFAULT = { on = false, resale = true, confirmedOnly = false, useHeld = false }
do
local ROUTE_KEEP, ROUTE_MAX, ROUTE_ALTS = 120, 300, 5
local routes = {}   -- key -> { at, plan }
local job          -- the plan being made a slice a frame: { key, run = C.Route.Start's }
R.OnUpdate(function()
  wipe(routes)
  job = nil
end)
-- prof -> { id, from, to, target }: a step's recipe picked by hand (Shift-click), kept until
-- the rank passes it or the target changes; not saved
local picks = {}

-- the typed target per profession while above his rank, else the cap (or the next one)
local function RouteTarget(prof, rank, max)
  local to = state.route.to[prof]
  if not (to and to > rank) then to = C.Route.DefaultTarget(rank, max) end
  to = to and math.min(to, ROUTE_MAX)
  return to and to > rank and to or nil
end

local function RoutePick(prof, rank, to)
  local p = picks[prof]
  if p and (p.target ~= to or rank >= p.to) then picks[prof], p = nil, nil end
  return p
end

local function Planned(j)
  routes[j.key] = { at = GetTime(), plan = j.run.plan, err = j.run.err }
  if j.run.err then geterrorhandler()(j.run.err) end
end

local function Slice(j)
  if job ~= j then return end
  if not j.run.Step() then return C_Timer.After(0, function() Slice(j) end) end
  job = nil
  Planned(j)
  UI.RefreshSoon()
end

-- -> plan; nil and true while it is being made (a slice a frame, one at a time: the latest
-- asked for), nil after an error
local function RoutePlan(prof, rank, to, pick)
  local r = state.route
  local max = whatIf and select(2, RankOf(prof))
  local key = table.concat({ prof, rank, to, tostring(r.resale), tostring(r.confirmedOnly),
    pick and ("%d@%d-%d"):format(pick.id, pick.from, pick.to) or "", tostring(max) }, ":")
  local now = GetTime()
  local c = routes[key]
  if c and now - c.at < ROUTE_KEEP then return c.plan end
  for k, old in pairs(routes) do
    if now - old.at >= ROUTE_KEEP then routes[k] = nil end
  end
  if job and job.key == key then return nil, true end
  local j = { key = key, run = C.Route.Start(prof, rank, to,
    { resale = r.resale, unverified = not r.confirmedOnly, pin = pick, max = max }) }
  -- a small one is done in its first slice: no "planning" flash
  if j.run.Step() then
    Planned(j)
    return j.run.plan
  end
  job = j
  C_Timer.After(0, function() Slice(j) end)
  return nil, true
end

-- My mats: kept like routes, under its own key
local function HeldPlan(prof, rank, to)
  local r = state.route
  local max = whatIf and select(2, RankOf(prof))
  local key = table.concat({ "held", prof, rank, to, tostring(r.confirmedOnly), tostring(max) },
    ":")
  local now = GetTime()
  local c = routes[key]
  if c and now - c.at < ROUTE_KEEP then return c.plan end
  c = { at = now, plan = C.Route.FromHeld(prof, rank,
    { unverified = not r.confirmedOnly, max = max, to = to }) }
  routes[key] = c
  return c.plan
end

local function Earns(net)
  if net <= 0 then return Hex(GOOD, "+" .. M.Money(-net)) end
  return M.Money(net)
end
local function EarnsPer(net, points)
  if points <= 0 then return "" end
  return Earns(math.floor(net / points + 0.5))
end
local function Crafts(st)
  local n = math.ceil(st.crafts - 1e-6)
  return st.sd >= 0.5 and ("~" .. n) or tostring(n), n
end
-- against another route or step: "+50s, 3 more crafts"
local function Versus(money, crafts)
  local m = money > 0 and ("+" .. M.Money(money)) or Hex(GOOD, M.Money(money))
  local n = math.floor(math.abs(crafts) + 0.5)
  if n == 0 then return m end
  return ("%s, %d %s craft%s"):format(m, n, crafts > 0 and "more" or "fewer", n == 1 and "" or "s")
end

local function SkippedTip(tt, plan)
  local s = plan.skipped
  if s.unverified > 0 then
    tt:AddLine(Hex(DIM, ("%s no trainer visit has confirmed: turn off \"Confirmed trainer only\"")
      :format(Plural(s.unverified, "recipe"))), nil, nil, nil, true)
  end
  if s.noSource > 0 then
    tt:AddLine(Hex(DIM, ("%s left out: pattern not available or never seen")
      :format(Plural(s.noSource, "recipe"))), nil, nil, nil, true)
  end
end

-- cheapest: the route without the pick, when there is one
local function RouteSummary(plan, cheapest)
  local free = plan.held and plan.gross <= 0
  local text = ("%s · %s%s crafts%s · %s"):format(Plural(#plan.steps, "step"),
    plan.held and "" or "~", M.Count(plan.crafts),
    plan.learn > 0 and (" · learn " .. M.Money(plan.learn)) or "",
    free and Hex(GOOD, "nothing to buy")
    or (plan.net <= 0 and Hex(GOOD, "earns " .. M.Money(-plan.net))
      or ("costs " .. M.Money(plan.net)))
    .. (plan.reach > plan.from and Hex(DIM, " (" .. EarnsPer(plan.net, plan.reach - plan.from)
      .. " a point)") or ""))
  local more = cheapest and plan.net - cheapest.net
  if plan.heldFree or plan.held then
    text = text .. Hex(DIM, " · your mats free")
  elseif plan.heldValue > 0 then
    text = text .. Hex(DIM, " · your mats at sale price")
  end
  return { note = true, name = Hex(ACCENT, ("%d-%d: "):format(plan.from, plan.reach)) .. text
    .. (plan.complete and "" or Hex(BAD, " +?"))
    .. (more and (Hex(ACCENT, " · your pick ") .. Versus(more, 0) .. Hex(BAD, " · click: undo"))
      or ""),
    click = more and function()
      picks[plan.prof] = nil
      UI.Refresh()
    end or nil,
    tip = function(tt)
      tt:AddLine(plan.held and ("Your mats: %d to %d"):format(plan.from, plan.reach)
        or ("Route %d to %d"):format(plan.from, plan.reach))
      Pair(tt, "Materials to buy", Money(plan.buy) .. (plan.complete and "" or " +?"))
      if plan.heldFree or plan.held then
        Pair(tt, "Materials you hold", Hex(GOOD, "free, used first"))
      elseif plan.heldValue > 0 then
        Pair(tt, "Materials you hold (what they'd sell for)", Money(plan.heldValue))
      end
      Pair(tt, "Learning", Money(plan.learn))
      if plan.setup > 0 then Pair(tt, "Camp stations", Money(plan.setup)) end
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
      tt:AddLine(" ")
      if cheapest then
        local p = plan.pin
        Pair(tt, "Your pick", ("%s %d-%d"):format(p.c.rec.name or p.c.rec.id, p.from, p.to))
        Pair(tt, "Against the cheapest route", Versus(more, plan.crafts - cheapest.crafts))
        tt:AddLine(Hex(DIM, "Click here, or Shift-click a step: back to the cheapest"), nil,
          nil, nil, true)
      elseif plan.held then
        tt:AddLine(Hex(DIM, "One craft at a time, the most points for what it uses; scarce mats"
          .. " rationed. Queue route queues it all"), nil, nil, nil, true)
      else
        tt:AddLine(Hex(DIM, "Shift-click a step: other recipes for it"), nil, nil, nil, true)
      end
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

local function LearnCell(c, st)
  if c.how == "known" then return Hex(DIM, "known") end
  if st and st.learnt then return Hex(DIM, "at " .. st.learnt) end
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

-- "Star Belt 195-200, ~9 crafts": the alternative and what it takes over its points
local function AltName(a)
  local n = math.ceil(a.n - 1e-6)
  return ("%s %d-%d, ~%s"):format(a.c.rec.name or a.c.rec.id, a.from, a.to,
    Plural(n, "craft"))
end
-- against the step: "27s less, 1 more craft"
local function AltVersus(a)
  local money = a.delta < 0 and Hex(GOOD, M.Money(-a.delta) .. " less")
    or (M.Money(a.delta) .. " more")
  local n = math.floor(math.abs(a.crafts) + 0.5)
  if n == 0 then return money .. ", same crafts" end
  return ("%s, %d %s craft%s"):format(money, n, a.crafts > 0 and "more" or "fewer",
    n == 1 and "" or "s")
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
    if st.learnt then
      Pair(tt, "Learning", Hex(DIM, ("paid at %d"):format(st.learnt)))
    elseif st.fee > 0 then
      Pair(tt, "Learning", (Guessed(st.c) and "~" or "") .. Money(st.fee))
    end
    if st.setup > 0 then Pair(tt, st.c.station.name .. " + campfire", Money(st.setup)) end
    if st.value > 0 then Pair(tt, "Crafts sold", Hex(GOOD, M.Money(st.value))) end
    Pair(tt, "Net", Earns(st.net))
    local o = st.c.rec.out and plan.outputs[st.c.rec.out]
    local used = o and o.used or 0
    if used > 0 then
      tt:AddLine(Hex(DIM, ("%s of %s go into later steps"):format(M.Count(used),
        M.Count(o.made))), nil, nil, nil, true)
    end
    if o and plan.resale and not o.bound and o.made - used > 0.5 then
      tt:AddLine(Hex(DIM, ("%s of %s to the AH (sells ~%s/day here), the rest %s"):format(
        M.Count(o.atAH), M.Count(o.made - used), M.Count(o.day or 0),
        o.de and "disenchanted" or "to a vendor")), nil, nil, nil, true)
    end
    if st.c.estFee then tt:AddLine(Hex(DIM, "~: trainer fee estimated")) end
    if st.c.src and st.c.src.how == "unknown" then
      tt:AddLine(Hex(DIM, "~: pattern's AH listings not known, costed at its usual price"),
        nil, nil, nil, true)
    end
  end
end

-- Shift-click on a step: its alternatives, picking one plans the route around it
local function SwapMenu(row, st, plan)
  if not (MenuUtil and MenuUtil.CreateContextMenu) then return end
  local alts = C.Route.Alternatives(plan, st, ROUTE_ALTS * 2)
  MenuUtil.CreateContextMenu(row, function(_, root)
    root:CreateTitle(("Instead of %s, %d-%d"):format(st.c.rec.name or st.c.rec.id, st.from,
      st.to))
    if #alts == 0 then root:CreateTitle(Hex(DIM, "No other recipe gives points here")) end
    for _, a in ipairs(alts) do
      root:CreateButton(AltName(a) .. ": " .. AltVersus(a), function()
        picks[plan.prof] = { id = a.c.rec.id, from = a.from, to = a.to, target = plan.to }
        UI.Refresh()
      end)
    end
    if plan.pin then
      root:CreateDivider()
      root:CreateButton("Back to the cheapest route", function()
        picks[plan.prof] = nil
        UI.Refresh()
      end)
    end
  end)
end

-- Alternatives listed under their step in the list itself, not only on hover: steps open by
-- prof:from (outlives replans that keep the step), each plan's lists worked out once
local openAlts = {}
local ROUTE_ALTS_OPEN = 25

local function PlanAlts(plan, st)
  plan.altCache = plan.altCache or {}
  local alts = plan.altCache[st]
  if not alts then
    alts = C.Route.Alternatives(plan, st, ROUTE_ALTS_OPEN)
    plan.altCache[st] = alts
  end
  return alts
end

local function ColourAt(c, k)
  if k < c.yellow then return "orange" end
  if k < math.floor((c.yellow + c.grey) / 2) then return "yellow" end
  return k < c.grey and "green" or "grey"
end

local function UsePick(plan, a)
  picks[plan.prof] = { id = a.c.rec.id, from = a.from, to = a.to, target = plan.to }
  UI.Refresh()
end

local function AltToggleRow(st, plan)
  local key = plan.prof .. ":" .. st.from
  local open = openAlts[key]
  -- the range is the step's above it (and in the tooltip): the name column is too narrow for it
  return { oneLine = true, name = Hex(open and ACCENT or DIM, (open and "- " or "+ ")
      .. "Other recipes"), cells = { "", "", "", "", "" },
    tip = function(tt)
      tt:AddLine(("Instead of %s, %d-%d"):format(st.c.rec.name or st.c.rec.id, st.from, st.to))
      tt:AddLine(Hex(DIM, "Best first, counting the time extra crafts take, so not strictly by"
        .. " Cost. Cost is the whole stretch with that recipe: one that goes green early does"
        .. " its points, then this step's recipe the rest."), nil, nil, nil, true)
      tt:AddLine(Hex(DIM, "Click a recipe to use it"), nil, nil, nil, true)
    end,
    click = function()
      openAlts[key] = not open or nil
      UI.Refresh()
    end }
end

local function AltRow(a, st, plan)
  local c = a.c
  local n = math.ceil(a.n - 1e-6)
  -- learnt by another step: Alternatives charges no fee for it either
  local learn = LearnCell(c)
  for _, o in ipairs(plan.steps) do
    if o ~= st and o.c == c and c.how ~= "known" then
      learn = Hex(DIM, "at " .. (o.learnt or o.from))
      break
    end
  end
  -- the whole stretch with it, in the step's own terms (the rest at the step's rate)
  return { oneLine = true, dim = true, icon = c.rec.icon, name = c.rec.name or tostring(c.rec.id),
    recID = c.rec.id,
    cells = { Hex(DIFF[ColourAt(c, a.from)], ("%d-%d"):format(a.from, a.to)), "~" .. n,
      learn, EarnsPer(st.net + a.delta, st.to - st.from), Earns(st.net + a.delta) },
    tip = function(tt)
      a.x = a.x or C.Info(c.rec, a.from)
      RecipeTip(a.x)(tt)
      tt:AddLine(" ")
      tt:AddLine(Hex(ACCENT, ("Instead of %s, %d-%d"):format(st.c.rec.name or st.c.rec.id,
        st.from, st.to)))
      Pair(tt, AltName(a), AltVersus(a))
      if a.to < st.to then
        tt:AddLine(Hex(DIM, ("Goes green at %d: %s does the rest"):format(a.to,
          st.c.rec.name or "the step's recipe")), nil, nil, nil, true)
      end
      tt:AddLine(Hex(DIM, "Click to use it; the rest of the route is planned again"), nil, nil,
        nil, true)
    end,
    click = function(button)
      if IsAltKeyDown() then return UI.Find(c.rec, IsShiftKeyDown()) end
      if button == "LeftButton" then UsePick(plan, a) end
    end }
end

local function AddAltRows(out, st, plan)
  out[#out + 1] = AltToggleRow(st, plan)
  if not openAlts[plan.prof .. ":" .. st.from] then return end
  local alts = PlanAlts(plan, st)
  if #alts == 0 then
    out[#out + 1] = { oneLine = true, name = Hex(DIM, "No other recipe gives points here"),
      cells = { "", "", "", "", "" } }
  end
  for _, a in ipairs(alts) do out[#out + 1] = AltRow(a, st, plan) end
end

-- left queues the step's crafts, right takes them off; Alt finds it, Ctrl types a count,
-- Shift swaps the recipe
local function StepClick(st, plan)
  return function(button, row)
    local rec = st.c.rec
    if IsAltKeyDown() then return UI.Find(rec, IsShiftKeyDown()) end
    if IsShiftKeyDown() then return not plan.held and SwapMenu(row, st, plan) end
    if AltShown() then return end
    if IsControlKeyDown() then return EditCount(row, rec) end
    local _, n = Crafts(st)
    local before = C.Queue()[rec.id] or 0
    C.Enqueue(rec, button == "RightButton" and -n or n, st.to)
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
    st.src = st.learnt and Hex(DIM, ("learnt at %d"):format(st.learnt))
      or src or SourceText(st.x)
  end
  local x = st.x
  local sells = plan.resale and c.rec.out and Sells(plan.outputs[c.rec.out])
  local sub = st.src and sells and (st.src .. Hex(DIM, " · ") .. sells) or st.src or sells
  if st.tool then
    sub = Hex(ACCENT, ("%s: the steps after it need one"):format(st.tool))
  end
  local pin = plan.pin
  if pin and pin.c == c and pin.from < st.to and pin.to > st.from then
    sub = Hex(ACCENT, "your pick") .. (sub and (Hex(DIM, " · ") .. sub) or "")
  end
  return { icon = c.rec.icon, name = RecipeName(x), sub = sub or nil, x = x, recID = c.rec.id,
    cells = { Hex(x.colour and DIFF[x.colour] or "ffffff", ("%d-%d"):format(st.from, st.to)),
      (Crafts(st)), LearnCell(c, st), EarnsPer(st.net, st.to - st.from), Earns(st.net) },
    tip = RouteStepTip(st, plan), click = StepClick(st, plan) }
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
    if (m.kept or 0) >= 1 then
      Pair(tt, "Yours, kept to sell", Hex(GOOD, M.Count(math.floor(m.kept))))
      tt:AddLine(Hex(DIM, "They sell for more than buying new ones costs"), nil, nil, nil, true)
    end
    if (m.made or 0) > 0 then Pair(tt, "Made by earlier steps", M.Count(m.made)) end
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
  local count, cost
  if m.buy <= 0 then
    count, cost = "", Hex(GOOD, m.held < m.need - 1e-6 and "made" or "held")
  else
    count = (m.crafted and Hex(ACCENT, "craft ") or "") .. Hex(m.short and BAD or "ffffff", m.buy)
    cost = Money(m.price and m.cost)
  end
  local need = math.ceil(m.need - 1e-6)
  local held = math.floor(m.held)
  return { oneLine = true, icon = C_Item.GetItemIconByID(m.id), name = ItemName(m.id),
    cells = { "", need, held >= need and Hex(GOOD, held) or held > 0 and Hex(ACCENT, held)
      or Hex(DIM, "0"), count, cost },
    tip = RouteMatTip(m) }
end

VIEWS.route = {
  title = "Skill-up",
  rowH = 32,
  columns = {
    { "Skill", 54, left = true, tip = "The skill range of this step" },
    { "Recipe", 162, name = true, tip = "Under the name: where to learn it, how its crafts sell" },
    { "Crafts", 40, tip = "Crafts expected for the step",
      more = "~: yellow and green recipes don't always give a point" },
    { "Learn", 50, tip = "What learning it costs; known, or in your bags" },
    { "Per point", 60, tip = "The step's cost for each skill point it gives; green +: it earns",
      more = "Learning and selling included, as in Cost" },
    { "Cost", 76, tip = "The whole step's cost after selling its crafts; green +: it earns" } },
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
    local _, max = RankOf(prof)
    local to = RouteTarget(prof, rank, max)
    out.to = to
    if not to then
      Note(Hex(DIM, ("Nothing to plan: %d is as far as it goes"):format(rank)))
      return out
    end
    -- what held mats level first, then the route on from there
    local held = state.route.useHeld and HeldPlan(prof, rank, to)
    if held and #held.steps > 0 then
      out.heldPlan = held
      out[#out + 1] = { head = true, allCells = true, name = "With your mats",
        cells = { "", "", "", "", "" } }
      out[#out + 1] = RouteSummary(held)
      local si = 1
      for _, st in ipairs(held.steps) do
        while held.stops[si] and st.to > held.stops[si].at do
          out[#out + 1] = StopRow(held.stops[si], rank)
          si = si + 1
        end
        out[#out + 1] = StepRow(st, held)
      end
      table.sort(held.mats, function(a, b)
        if a.held ~= b.held then return a.held > b.held end
        return a.id < b.id
      end)
      for _, m in ipairs(held.mats) do out[#out + 1] = MatRow(m) end
      rank = held.reach
      if rank >= to then return out end
      out[#out + 1] = { head = true, allCells = true,
        name = ("Then %d to %d"):format(rank, to), cells = { "", "", "", "", "" } }
    end
    local pick = RoutePick(prof, rank, to)
    local plan, planning = RoutePlan(prof, rank, to, pick)
    if not plan then
      Note(Hex(DIM, planning and ("Planning the route to %d..."):format(to)
        or "No route: planning hit an error"))
      return out
    end
    if pick and not plan.pin then picks[prof] = nil end
    out.plan = plan
    out[#out + 1] = RouteSummary(plan, plan.pin and RoutePlan(prof, rank, to))
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
      if not st.tool then AddAltRows(out, st, plan) end
    end
    if #plan.mats > 0 then
      table.sort(plan.mats, function(a, b)
        local ca, cb = a.cost + a.heldCost, b.cost + b.heldCost
        if ca ~= cb then return ca > cb end
        return a.id < b.id
      end)
      out[#out + 1] = { head = true, allCells = true, name = "Materials",
        cells = { "", Hex(DIM, "need"), Hex(DIM, "have"), Hex(DIM, "get"),
          Hex(ACCENT, M.Money(plan.buy) .. (plan.complete and "" or " +?")) } }
      for _, m in ipairs(plan.mats) do out[#out + 1] = MatRow(m) end
    end
    return out
  end,
}
end

local VIEW_ORDER = { "profit", "skill", "queue", "find" }
-- the view drawn: Skill-up shows its Route mode in its own columns
local function ViewKey()
  if state.view == "skill" and state.route.on then return "route" end
  return state.view
end

------------------------------------------------------------------------------ Crafting
-- One click crafts a whole step: CraftRecipe(id, n), the client repeating the cast. Each
-- success takes one off the queue (also for crafts made by hand from the profession window).
-- With a skill to stop at, a batch is only as many as can't pass it with every craft a
-- skill-up (UpTo); the next press goes on from the rank reached. No API stops the client's
-- repeat, and CraftRecipe from a timer (a cast per success) is blocked (ADDON_ACTION_BLOCKED).
-- Enchants: one cast per click or key press. The second on an item raises the replace prompt,
-- and the client ignores ReplaceTradeskillEnchant outside a hardware event (from a timer the
-- prompt flashed and the chain died). The prompt's event is synchronous with CraftEnchant, so
-- confirming it for our own enchant works inside the press.
local CRAFT_STALE = 10   -- seconds without a success: the batch ended without an event
local crafting   -- { id, n, left, t, prof, stop, enchant = { loc, guid, ours } } while casting

-- the client's own batch still running (also between two casts). `crafting` can end before it
-- (a step's end reached, a stray FAILED, the window closed, /reload): a CraftRecipe then cut
-- the batch short. Recasts count only while casts still land: a stale count must not block
-- Craft next for good
local lastCast = 0
M.On("UNIT_SPELLCAST_SUCCEEDED", function(_, unit)
  if unit == "player" then lastCast = GetTime() end
end)
local function ClientCrafting()
  local okC, casting = pcall(function() return UnitCastingInfo("player") ~= nil end)
  if okC and casting then return true end
  if GetTime() - lastCast >= CRAFT_STALE then return false end
  local ok, left = pcall(C_TradeSkillUI.GetRemainingRecasts)
  return ok and type(left) == "number" and left > 0
end

local lastError   -- { text, t }: UI_ERROR_MESSAGE, why a cast was refused
M.On("UI_ERROR_MESSAGE", function(_, _, text)
  if type(text) == "string" then lastError = { text = text, t = GetTime() } end
end)

local function StaleCheck()
  if crafting and GetTime() - crafting.t >= CRAFT_STALE then
    if ClientCrafting() then
      crafting.t = GetTime()
      return C_Timer.After(CRAFT_STALE, StaleCheck)
    end
    crafting = nil
    UI.Refresh()
  end
end

-- an enchant's own part of its name: "Enchant Bracer - Minor Health" -> "Minor Health"
local function EnchantName(rec)
  local name = rec.name or tostring(rec.id)
  return name:match(" %- (.+)$") or name
end

-- of s's crafts, how many can't take the skill past stop even if each gives its points
-- (orange: skill-ups per craft, else at most one); all of them without a stop
local function UpTo(s, stop)
  local rank = stop and C.Rank(s.rec.prof)
  if not rank then return s.n end
  local _, yellow, _, _, ups = C.Bands(s.rec)
  local k, n = rank, 0
  while k < stop and n < s.n do
    k = k + ((yellow and k < yellow) and (ups or 1) or 1)
    n = n + 1
  end
  return n
end

-- n: how many, else all bags allow (an enchant: always one); stop: the skill to stop at
local function StartCraft(s, n, stop)
  if ClientCrafting() then
    local text = "Still crafting: press again once this batch ends"
    if frame and frame:IsShown() then return UI.Say(Hex(DIM, text)) end
    return M.Print(text)
  end
  n = s.enchant and 1 or math.min(n or s.can, s.can, UpTo(s, stop))
  crafting = { id = s.rec.id, n = n, left = n, t = GetTime(), prof = s.rec.prof, stop = stop }
  if s.enchant then
    -- set before the cast: the replace prompt fires inside CraftEnchant
    crafting.enchant = { loc = s.target.loc, guid = s.target.guid, ours = s.target.ours }
    C_TradeSkillUI.CraftEnchant(s.rec.id, 1, nil, s.target.loc)
  else
    C_TradeSkillUI.CraftRecipe(s.rec.id, n)
  end
  C_Timer.After(CRAFT_STALE, StaleCheck)
  if s.enchant then
    UI.Say(("Enchanting %s: %s"):format(s.target.link or "?", EnchantName(s.rec)))
  else
    UI.Say(("Crafting %d %s"):format(n, s.rec.name or s.rec.id))
  end
  -- after: what it reaches (C.PruneQueue) is the news
  UI.Refresh()
end

-- the skill Craft next stops at for a step: the nearer of Stop at skill (mode menu) and the
-- end of the route step it was queued for, else nil
local function StopAt(s)
  local stop = state.stopAt
  if stop == "next" then stop = (C.Rank(s.rec.prof) or 0) + 1 end
  if s.stop and not (stop and stop <= s.stop) then stop = s.stop end
  return stop
end

-- the replace prompt for the enchant Craft next put there: confirmed. Blizzard shows the popup
-- from the same event, maybe after this handler, so it is hidden a frame later
local function AutoReplace(event)
  if not (crafting and crafting.enchant and crafting.enchant.ours) then return end
  if event == "REPLACE_TRADESKILL_ENCHANT" then C_Item.ReplaceTradeskillEnchant()
  else C_Item.ReplaceEnchant() end
  C_Timer.After(0, function() StaticPopup_Hide(event) end)
end
M.On("REPLACE_TRADESKILL_ENCHANT", AutoReplace)
M.On("REPLACE_ENCHANT", AutoReplace)

local function OpenFor(prof)
  local p = R.Professions()[prof]
  local ok = p and p.skillLine and C_TradeSkillUI.OpenTradeSkill(p.skillLine)
  if not ok then M.Print("open " .. prof .. " from your spellbook to craft") end
end

-- nothing craftable: what stops the first step in order (bolts before the item): a recipe
-- not learnt, a material to buy or fetch, an enchant with nothing to go on. Anything still to
-- buy, for any step, comes before fetching, so one trip to the AH or vendor covers the queue
local function Blocker(steps, shop)
  local mats = {}
  for _, m in ipairs(shop and shop.mats or {}) do mats[m.id] = m end
  for _, s in ipairs(steps) do
    if s.known then
      for _, miss in ipairs(s.missing) do
        local m = mats[miss[1]]
        if m and m.buy > 0 then return ("Buy %d %s"):format(m.buy, ItemName(m.id)) end
      end
    end
  end
  for _, s in ipairs(steps) do
    if not s.known then return "Learn " .. (s.rec.name or "?") .. " first" end
    if s.noTarget then return "No item takes " .. EnchantName(s.rec) end
    local tool = C.MissingTool(s.rec, true)
    if tool then return ("Needs a %s in your bags"):format(C.ToolName(tool)) end
    for _, miss in ipairs(s.missing) do
      local m = mats[miss[1]]
      if m then
        local name = ItemName(m.id)
        if m.buy > 0 then return ("Buy %d %s"):format(m.buy, name) end
        if m.alts > 0 then
          local a = m.fromAlts[1]
          return ("Get %d %s from %s"):format(m.alts, name, a and a.name or "alts")
        end
        if m.bank > 0 then return ("Get %d %s from the bank"):format(m.bank, name) end
        if m.mail > 0 then return ("Get %d %s from the mailbox"):format(m.mail, name) end
      end
    end
  end
end

-- the craft button for the queue as built: label, enabled, action, and the step when the
-- action crafts
local function CraftAction(steps, shop)
  if crafting then
    local rec = C.Recipe(crafting.id)
    return ("Crafting %s (%d left)"):format(rec and rec.name or "", crafting.left), false
  end
  -- at the AH with something to buy: shop first (AuctionShop)
  local shopLabel, shopOn, shopRun
  if M.AuctionShop then shopLabel, shopOn, shopRun = M.AuctionShop.Step(shop) end
  if shopLabel then return shopLabel, shopOn, shopRun end
  local s = C.NextCraft(steps or {}, state.craftMode, OpenProfession())
  if not s then
    if #(steps or {}) == 0 then return "Nothing queued", false end
    if state.craftMode == "bulk" and C.NextCraft(steps) then
      return Blocker(steps, shop) or "Waiting for materials (Queue mode crafts part)", false
    end
    return Blocker(steps, shop) or "Nothing craftable from bags", false
  end
  if OpenProfession() ~= s.rec.prof then
    return "Open " .. s.rec.prof, true, function() OpenFor(s.rec.prof) end
  end
  local stop = StopAt(s)
  if stop and (C.Rank(s.rec.prof) or 0) >= stop then
    return ("%s %d reached"):format(s.rec.prof, stop), false, nil, s
  end
  local function Go() StartCraft(s, nil, stop) end
  local to = stop and (" to %d"):format(stop) or ""
  if s.enchant then
    local item = s.target.link and s.target.link:match("%[(.-)%]") or "item"
    -- one cast per press: "next point" says nothing
    if state.stopAt == "next" then to = "" end
    return ("%d%s: %s on %s"):format(s.can, to, EnchantName(s.rec), item), true, Go, s
  end
  return ("Craft %d %s%s"):format(math.min(s.can, UpTo(s, stop)), s.rec.name or s.rec.id, to),
    true, Go, s
end

-- the Craft button from a key binding or /meio next, panel open or not
-- one: craft only 1 of the step (the Craft 1 button)
function UI.CraftNext(one)
  if R.Viewer() then UI.ViewAs(nil) end
  local shop = C.Shopping()
  local label, enabled, action, s = CraftAction(C.CraftSteps(shop), shop)
  if one and s then return StartCraft(s, 1) end
  if enabled and action then return action() end
  if frame and frame:IsShown() then UI.Say(Hex(DIM, label)) else M.Print(label) end
end

M.On("UNIT_SPELLCAST_SUCCEEDED", function(_, unit, _, spellID)
  if unit ~= "player" then return end
  local queued = C.Queue()[spellID]
  local mine = crafting and crafting.id == spellID
  if not (queued or mine) then return end
  if queued then C.Enqueue({ id = spellID }, -1) end
  if mine then
    crafting.left, crafting.t = crafting.left - 1, GetTime()
    if crafting.enchant then C.MarkOurEnchant(crafting.id, crafting.enchant.guid) end
    if crafting.left <= 0 then
      crafting = nil
    else
      C_Timer.After(CRAFT_STALE, StaleCheck)
    end
  end
  UI.RefreshSoon()
end)
-- a moment later: a FAILED mid-batch (a Create click on the profession window) leaves the
-- client's batch running. A batch cut short says why, in chat to outlast the footer
local function Stopped(event, unit, _, spellID)
  if not (unit == "player" and crafting and crafting.id == spellID) then return end
  local c, at = crafting, GetTime()
  C_Timer.After(0.3, function()
    if crafting ~= c or ClientCrafting() then return end
    crafting = nil
    if c.left > 0 then
      local why = lastError and lastError.t >= at - 1 and lastError.text
        or event == "UNIT_SPELLCAST_INTERRUPTED" and "interrupted"
        or "the game refused the cast"
      local rec = C.Recipe(c.id)
      M.Print(("crafting stopped after %d of %d %s: %s"):format(c.n - c.left, c.n,
        rec and rec.name or c.id, why))
    end
    UI.Refresh()
  end)
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
    Help(box, { "Crafts queued", "Type a number: Enter sets it, Esc cancels" })
    frame.countBox = box
  end
  box.rec = rec
  box:ClearAllPoints()
  box:SetPoint("RIGHT", row, "LEFT", ColWidth(VIEWS.queue, VIEWS.queue.columns[1]) + 40, 0)
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
  local d = self.data
  M.ItemBeside.Show(GameTooltip, d.x and d.x.rec or (d.recID and M.Recipes.All()[d.recID]))
end

local function BaseWidth(view)
  local w = 0
  for _, col in ipairs(view.columns) do w = w + col[2] end
  return w
end

-- the name column takes whatever width the window has beyond the columns' own
function ColWidth(view, col)
  if not col.name then return col[2] end
  return col[2] + math.max(0, math.floor(frame.list:GetWidth() - BaseWidth(view)))
end

local function ListWidth(view) return math.max(BaseWidth(view), math.floor(frame.list:GetWidth())) end

local function MakeRow(i)
  local b = CreateFrame("Button", nil, frame.list)
  b:RegisterForClicks("LeftButtonUp", "RightButtonUp")
  b.stripe = b:CreateTexture(nil, "BACKGROUND")
  b.stripe:SetColorTexture(1, 1, 1, 0.05)
  b.stripe:SetAllPoints()
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
  b.sub = b:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
  b.sub:SetTextColor(0.8, 0.8, 0.8)
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
  if GameTooltip:GetOwner() == self then ShowHelp(self) end
end

-- a column's hover: what it shows, and whether a click sorts by it
local function HeaderHelp(h)
  local col = h.col
  if not col then return nil end
  local sort
  if not col[3] then
    sort = Hex(MUTED, "Not sortable")
  elseif col[3] == SortKey(VIEWS[state.view]) then
    sort = Hex(MUTED, "Sorted by this: click to reverse")
  else
    sort = Hex(MUTED, "Click: sort by this")
  end
  return { col[1], col.tip and (col.tip .. "\n" .. sort) or sort, col.more }
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
      Help(h, HeaderHelp)
      frame.heads[i] = h
    end
    h:ClearAllPoints()
    h:SetPoint("BOTTOMLEFT", frame.Inset, "TOPLEFT", 2 + x, -2)
    h:SetSize(ColWidth(view, col) + 2, 24)
    h:SetText(col[1])
    local fs = h:GetFontString()
    local sorted = col[3] ~= nil and col[3] == key
    if fs then
      fs:SetTextColor(1, sorted and 1 or 0.82, sorted and 1 or 0)
      -- over the cells: right-aligned ones end where the cell does (the list sits 2px right of
      -- the headers, cells 2px into their column)
      fs:ClearAllPoints()
      if col.name or col.left then
        fs:SetPoint("LEFT", 8, 0)
      else
        fs:SetPoint("RIGHT", -4, 0)
      end
    end
    h.key, h.col = col[3], col
    h:Show()
    x = x + ColWidth(view, col)
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
  b:SetAlpha(d.dim and 0.7 or 1)
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
      local nameW = wide and ListWidth(view) - 8 or ColWidth(view, col) - size - 8
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
    x = x + ColWidth(view, col)
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
        -- by list position, so a row keeps its stripe while scrolling
        b.stripe:SetShown((i + offset) % 2 == 0 and not d.head)
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
local ROUTE_HINTS = Hints({ "Click", "queue step", "Right", "remove", "Shift-click", "swap",
  "Alt", "find", "Shift", "detail" })
local ALT_HINTS = Hints({ "Alt", "find", "Shift", "detail" })   -- an alt's: nothing to queue

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
  -- each price is the newer of our own AH sighting and TSM's data (Prices.lua Newest): the
  -- footer says which our last full scan is
  local src = M.Prices.Source()
  local scan, tsm = M.Auction and M.Auction.ScanTime(), M.Prices.DataTime("realm")
  if scan and src == "TSM" then
    src = scan >= (tsm or 0) and ("AH scan " .. C.Ago(M.Now() - scan))
      or "TSM (newer than your scan)"
  end
  local hints = ViewKey() == "route" and ROUTE_HINTS or ROW_HINTS
  if R.Viewer() then hints = ALT_HINTS end
  return hints
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
  local rank, max = RankOf(prof or "")
  local what = prof and (prof .. (rank and (" %d/%d"):format(rank, max or 0) or ""))
  if whatIf then what = ("%s at %d %s"):format(prof, rank, Hex(ACCENT, "(what if)")) end
  local find = state.view == "find"
  if find then what = "find recipes" end
  if R.Viewer() and what then what = ("%s's %s"):format(CharName(R.Viewer()), what) end
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
  frame.routeQueue:SetEnabled(not (whatIf or R.Viewer()))
  frame.profMenu:SetShown(not (queue or find))
  frame.profMenu:SetWidth(route and 110 or skill and 100 or 130)
  frame.profMenu:ClearAllPoints()
  frame.profMenu:SetPoint("RIGHT", skill and frame.modeMenu or frame.showMenu, "LEFT", -6, 0)
  frame.profMenu:GenerateMenu()
  local searching = not (queue or find or route)
  frame.search:SetShown(searching)
  if searching then
    local leftmost = frame.profMenu:IsShown() and frame.profMenu
      or skill and frame.modeMenu or frame.showMenu
    frame.search:SetPoint("RIGHT", leftmost, "LEFT", -8, 0)
  end
  frame.findBar:SetShown(find)
  if find then
    for _, d in ipairs(frame.findBar.menus) do d:GenerateMenu() end
  end
  local view = VIEWS[ViewKey()]
  local list = (prof or view.anyProf) and view.Build(prof, rank) or {}
  if view.defaultSort then Sorted(view, list) end
  if view.Finish then view.Finish(list, SortKey(view)) end
  if list.top then
    if list[1] and not list[1].head then
      table.insert(list, 1, { head = true, name = "Every recipe" })
    end
    for i = #list.top, 1, -1 do table.insert(list, 1, list.top[i]) end
  end
  built = { list = list, view = view }
  Draw(list, view)
  if route and not frame.routeTo:HasFocus() then
    frame.routeTo:SetText(list.to and tostring(list.to) or "")
  end
  frame.craftButton:SetShown(queue)
  frame.oneButton:SetShown(queue)
  frame.clearButton:SetShown(queue)
  frame.clearButton:SetEnabled(next(C.Queue()) ~= nil)
  frame.craftMode:SetShown(queue)
  frame.craftMode:GenerateMenu()
  if queue then
    local label, enabled, action, s = CraftAction(list.steps, list.shop)
    frame.craftButton:SetText(label)
    frame.craftButton:SetEnabled(enabled)
    frame.craftButton.action = action
    frame.oneButton:SetEnabled(s ~= nil)
    frame.oneButton.action = s and function() StartCraft(s, 1) end
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

local function ClearQueue()
  local n = C.QueueCount()
  C.ClearQueue()
  UI.Refresh()
  return n
end

local CLEAR_POPUP = {
  text = "Clear the crafting queue (%s)?",
  button1 = YES,
  button2 = NO,
  OnAccept = function()
    local n = ClearQueue()
    UI.Say(Hex(BAD, ("Cleared %s from the queue"):format(Plural(n, "craft"))))
  end,
  timeout = 0,
  whileDead = true,
  hideOnEscape = true,
}

local function SetStop(text)
  local n = tonumber(text)
  state.stopAt = n and n > 0 and math.floor(n) or nil
  if frame then UI.Refresh() end
  return state.stopAt
end
-- whose mats count as held (C.UsesAlt): routes are planned again from the new holdings
function UI.AltsChanged()
  R.ResetCache()
  R.Changed()
  if frame then UI.Refresh() end
end
local function SetAltMats(on)
  if on then state.altMats = nil else state.altMats = false end
  UI.AltsChanged()
end

local function StopBox(dialog)
  return dialog.GetEditBox and dialog:GetEditBox() or dialog.editBox
end
local STOP_POPUP = {
  text = "Craft next stops at skill:",
  button1 = OKAY,
  button2 = CANCEL,
  hasEditBox = 1,
  OnShow = function(dialog)
    local box = StopBox(dialog)
    box:SetNumeric(true)
    box:SetText(type(state.stopAt) == "number" and tostring(state.stopAt) or "")
    box:SetFocus()
  end,
  OnAccept = function(dialog) SetStop(StopBox(dialog):GetText()) end,
  EditBoxOnEnterPressed = function(box)
    SetStop(box:GetText())
    box:GetParent():Hide()
  end,
  EditBoxOnEscapePressed = function(box) box:GetParent():Hide() end,
  timeout = 0,
  whileDead = true,
  hideOnEscape = true,
}

function UI.AskStop()
  StaticPopupDialogs.MEIONOMICS_STOP_AT = STOP_POPUP
  StaticPopup_Show("MEIONOMICS_STOP_AT")
end

function UI.AskClear()
  local n = C.QueueCount()
  if n == 0 then return UI.Say(Hex(DIM, "The queue is already empty")) end
  StaticPopupDialogs.MEIONOMICS_CLEAR_QUEUE = CLEAR_POPUP
  StaticPopup_Show("MEIONOMICS_CLEAR_QUEUE", Plural(n, "craft"))
end

-- queued crafts whose skill is reached (C.PruneQueue)
function C.OnPruned(gone)
  local parts = {}
  for _, g in ipairs(gone) do
    if crafting and crafting.id == g.rec.id then crafting = nil end
    parts[#parts + 1] = ("%s %d reached: %s x%d"):format(g.rec.prof, g.stop,
      g.rec.name or g.rec.id, g.n)
  end
  local text = Hex(GOOD, table.concat(parts, ", ")) .. Hex(DIM, " off the queue")
  if frame and frame:IsShown() then UI.Say(text) else M.Print(text) end
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
  if owner and owner.meioHelp and owner:IsMouseOver() then ShowHelp(owner) end
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

local TAB_HELP = {
  profit = { "Profit", "What pays to craft and sell",
    "A verdict per recipe from AH prices and how fast it sells. Click a recipe to queue it." },
  skill = { "Skill-up", "The cheapest way to level the profession",
    "Ranking: recipes by what a skill point costs. Route (menu above): the cheapest run of "
    .. "crafts to a target skill, queued in one click." },
  queue = function()
    local n, recipes = C.QueueCount(), 0
    for _ in pairs(C.Queue()) do recipes = recipes + 1 end
    local count = n > 0 and ("%s queued, %s"):format(Plural(n, "craft"), Plural(recipes, "recipe"))
      or "Nothing queued yet"
    return { "Queue", count, "Craft next makes the next step in one batch; the shopping list "
      .. "says what is in bags, bank, mail and alts, and what to buy." }
  end,
  find = { "Find", "Every recipe of your professions, learnt or not",
    "Also above your skill: where to learn it and whether it pays. /meio find <name>" },
}

local function Tab(key, i)
  local t = CreateFrame("Button", "MeionomicsCraftFrameTab" .. i, frame, "PanelTabButtonTemplate")
  t:SetID(i)
  t:SetText(VIEWS[key].title)
  if i == 1 then
    t:SetPoint("TOPLEFT", frame, "BOTTOMLEFT", 12, 2)
  else
    t:SetPoint("LEFT", frame.tabs[VIEW_ORDER[i - 1]], "RIGHT", 3, 0)
  end
  Help(t, TAB_HELP[key])
  t:SetScript("OnClick", function()
    PlaySound(SOUNDKIT.IG_CHARACTER_INFO_TAB)
    state.view, offset = key, 0
    if key == "queue" and R.Viewer() then return UI.ViewAs(nil) end
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

-- replaces the queue (an old route left in it mixed two plans); Shift adds to it. With your
-- mats' steps first when shown
local function QueueRoute()
  if AltShown() then return end
  local list = built and built.list
  local plans = {}
  for _, key in ipairs({ "heldPlan", "plan" }) do
    local p = list and list[key]
    if p and #p.steps > 0 then plans[#plans + 1] = p end
  end
  if #plans == 0 then return UI.Say(Hex(DIM, "No route to queue")) end
  local add = IsShiftKeyDown()
  local dropped = add and 0 or C.QueueCount()
  if not add then C.ClearQueue() end
  local before, nSteps = C.QueueCount(), 0
  for _, plan in ipairs(plans) do
    C.Route.Enqueue(plan)
    nSteps = nSteps + #plan.steps
    for _, st in ipairs(plan.steps) do FlashRow(st.c.rec.id, "add") end
  end
  local added = C.QueueCount() - before
  UI.QueueChanged()
  PopCount(added)
  if SOUNDKIT then PlaySound(SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON) end
  local rest = add and ("%d in the queue"):format(C.QueueCount())
    or dropped > 0 and ("replaced %s"):format(Plural(dropped, "queued craft")) or nil
  UI.Say(("%s %s"):format(Hex(GOOD, ("Queued the route: %d crafts"):format(added)),
    Hex(DIM, ("in %s%s"):format(Plural(nSteps, "step"), rest and (" (" .. rest .. ")")
      or ""))))
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
    root:CreateCheckbox("Confirmed trainer only", function() return state.route.confirmedOnly end,
      function()
        state.route.confirmedOnly = not state.route.confirmedOnly
        UI.Refresh()
      end)
    root:CreateCheckbox("Use my mats first", function() return state.route.useHeld end,
      function()
        state.route.useHeld = not state.route.useHeld
        UI.Refresh()
      end)
  end)
  opts:SetPoint("RIGHT", queue, "LEFT", -6, 0)
  opts:SetSelectionText(function()
    return (state.route.resale and "Sell crafts" or "Mats only")
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
  Help(to, { "Target skill", "Type a skill and press Enter to plan the route to it",
    "Empty: your cap, or the next one when you are at it" })
  Help(opts, { "Route options", "Sell crafts: their sales pay towards it. Mats only: not."
      .. " Confirmed trainer only: leave out trainer recipes no trainer visit has shown yet",
    "Use my mats first, off: the cheapest route, your mats (bags, bank, mail, alts) costed at"
      .. " what they'd sell for after the AH cut, so it sells them when levelling with something"
      .. " else costs less. On: what your mats level comes first, counted free (scarce ones"
      .. " rationed), then the route" })
  Help(queue, function(self)
    if not self:IsEnabled() then return { "Queue route", "What if: a plan to read, not to craft" } end
    return { "Queue route", "Replaces the queue with every step's crafts (Shift-click: adds"
      .. " them to it instead)",
      "Then the Queue tab: Craft next makes them in order. Right-click a step to take it off." }
  end)
  frame.routeTo, frame.routeOpts, frame.routeQueue = to, opts, queue
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
  Help(filter, { "Which recipes", "Known, learnable now, learnable later, no pattern",
    "Learnable later: within how many points above your skill" })
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
  Help(mode, { "Judge for", "Profit: crafting to sell. Skill-up: levelling" })
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
  Help(prof, { "Profession", "One of your professions, or all of them" })
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
  Help(search, { "Search", "Recipes whose name has every word you type" })
  bar.search = search
  bar.menus = { filter, mode, prof }
  bar:Hide()
end

local function CreateSearch()
  local box = CreateFrame("EditBox", nil, frame, "SearchBoxTemplate")
  box:SetHeight(20)
  box:SetPoint("LEFT", frame, "TOPLEFT", 18, -42)
  box:SetAutoFocus(false)
  box:HookScript("OnTextChanged", function(self)
    local text = self:GetText() or ""
    if text == search then return end
    search, offset = text, 0
    UI.Refresh()
  end)
  Help(box, { "Search", "Recipes whose name has every word you type",
    "Not saved, so a forgotten search doesn't hide recipes after a relog" })
  frame.search = box
end

local function CreateGrip()
  local grip = CreateFrame("Button", nil, frame)
  grip:SetSize(16, 16)
  grip:SetPoint("BOTTOMRIGHT", -3, 3)
  grip:SetFrameLevel(frame:GetFrameLevel() + 20)
  grip:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
  grip:SetHighlightTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Highlight")
  grip:SetPushedTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Down")
  grip:SetScript("OnMouseDown", function(_, button)
    if button == "LeftButton" then frame:StartSizing("BOTTOMRIGHT") end
  end)
  grip:SetScript("OnMouseUp", function()
    frame:StopMovingOrSizing()
    frame:SetUserPlaced(false)
    local w, h = math.floor(frame:GetWidth() + 0.5), math.floor(frame:GetHeight() + 0.5)
    state.size = (w ~= W or h ~= H) and { w, h } or nil
    SavePlace()
  end)
  grip:SetScript("OnDoubleClick", function()
    state.size = nil
    frame:SetSize(W, H)
  end)
  grip:SetScript("OnEnter", function(self)
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:AddLine("Drag to resize")
    GameTooltip:AddLine("Double-click: default size", 0.7, 0.7, 0.7)
    GameTooltip:Show()
  end)
  grip:SetScript("OnLeave", GameTooltip_Hide)
end

local function Create()
  frame = CreateFrame("Frame", "MeionomicsCraftFrame", UIParent, "ButtonFrameTemplate")
  -- an alt's view would otherwise go on judging tooltips with the panel gone
  frame:HookScript("OnHide", function() R.SetViewer(nil) end)
  ButtonFrameTemplate_HidePortrait(frame)
  local size = state.size or {}
  frame:SetSize(size[1] or W, size[2] or H)
  frame:SetResizable(true)
  frame:SetResizeBounds(W, H, MAX_W, MAX_H)
  frame:SetClampedToScreen(true)
  frame:SetPoint("CENTER")
  -- MEDIUM like Professions and the AH: with toplevel, the one clicked comes in front
  frame:SetFrameStrata("MEDIUM")
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
  -- the inset's marble texture is light enough to wash out small grey text
  local shade = frame.Inset:CreateTexture(nil, "BACKGROUND", nil, 7)
  shade:SetColorTexture(0, 0, 0, 0.45)
  shade:SetPoint("TOPLEFT", 3, -3)
  shade:SetPoint("BOTTOMRIGHT", -3, 3)
  frame.bar = CreateFrame("EventFrame", nil, frame.Inset, "MinimalScrollBar")
  frame.bar:SetPoint("TOPRIGHT", -6, -6)
  frame.bar:SetPoint("BOTTOMRIGHT", -6, 6)
  frame.bar:SetHideIfUnscrollable(true)
  frame.bar:RegisterCallback(frame.bar.Event.OnScroll, BarScrolled, frame)

  frame.showMenu = Dropdown(175, function(_, root)
    for _, show in ipairs(SHOWS) do
      local radio = root:CreateRadio(SHOW_TEXT[show],
        function() return ShowOf(state.view) == show end,
        function()
          state.show[state.view], offset = show, 0
          UI.Refresh()
        end)
      if whatIf and show == "known" then radio:SetEnabled(false) end
    end
    root:CreateDivider()
    root:CreateCheckbox("Known recipes first", function() return not state.mix end, function()
      state.mix = not state.mix
      UI.Refresh()
    end)
  end)
  frame.showMenu:SetSelectionText(function() return SHOW_TEXT[ShowOf(state.view)] end)
  frame.showMenu:SetPoint("TOPRIGHT", -12, -30)
  Help(frame.showMenu, { "Show", "Which recipes to list",
    "Known: what you can craft. Known + learnable: also what you could learn now. All seen: "
    .. "every recipe recorded. Known recipes first: keeps them above the rest." })
  frame.craftButton = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
  frame.craftButton:SetSize(220, 22)
  frame.craftButton:SetPoint("TOPRIGHT", -10, -30)
  frame.craftButton:SetScript("OnClick", function(self) if self.action then self.action() end end)
  -- long labels (enchant targets) end in "..." inside the button; the tooltip has it whole
  local text = frame.craftButton:GetFontString()
  text:ClearAllPoints()
  text:SetPoint("LEFT", 8, 0)
  text:SetPoint("RIGHT", -8, 0)
  text:SetWordWrap(false)
  Help(frame.craftButton, function(self)
    local key = GetBindingKey and GetBindingKey("MEIONOMICS_CRAFT_NEXT")
    local label = self:GetText() or ""
    local line = self:IsEnabled() and "Makes the next queued step in one batch (enchants: one "
      .. "per press, on the item named), or up to the Stop at skill in the menu on the left"
      or label == "Nothing queued" and "Queue recipes first: click them in Profit or Skill-up"
      or ("Can't craft yet: " .. label)
    return { self:IsEnabled() and label or "Craft next", line,
      "Intermediates first. Bulk waits until a step's whole count is in bags; Queue crafts what "
      .. "bags allow now. " .. (key and ("Key: " .. key) or "Key binding: Options > Keybindings "
      .. "> AddOns > Meionomics") .. "; /meio craft next" }
  end)
  frame.oneButton = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
  frame.oneButton:SetSize(64, 22)
  frame.oneButton:SetPoint("RIGHT", frame.craftButton, "LEFT", -6, 0)
  frame.oneButton:SetText("Craft 1")
  frame.oneButton:SetScript("OnClick", function(self) if self.action then self.action() end end)
  Help(frame.oneButton, function(self)
    local key = GetBindingKey and GetBindingKey("MEIONOMICS_CRAFT_ONE")
    return { "Craft 1", self:IsEnabled() and "Makes just one of the step Craft next would make"
      or "Nothing to craft yet: Craft next says why",
      (key and ("Key: " .. key) or "Key binding: Options > Keybindings > AddOns > Meionomics")
      .. "; /meio craft one" }
  end)
  frame.clearButton = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
  frame.clearButton:SetSize(60, 22)
  frame.clearButton:SetPoint("RIGHT", frame.oneButton, "LEFT", -6, 0)
  frame.clearButton:SetText("Clear")
  frame.clearButton:SetScript("OnClick", function() UI.AskClear() end)
  Help(frame.clearButton, { "Clear", "Empties the whole queue (asks first)",
    "Right-click a craft to take one off; Ctrl-click to type its count" })
  frame.craftMode = Dropdown(96, function(_, root)
    for _, m in ipairs(CRAFT_MODES) do
      local radio = root:CreateRadio(m[2], function() return state.craftMode == m[1] end,
        function()
          state.craftMode = m[1]
          UI.Refresh()
        end)
      radio:SetTooltip(function(tt)
        GameTooltip_SetTitle(tt, m[2])
        GameTooltip_AddNormalLine(tt, m[3])
      end)
    end
    root:CreateDivider()
    root:CreateTitle("Shop for")
    for _, m in ipairs(SHOP_FOR) do
      local radio = root:CreateRadio(m[2], function() return state.shopFor == m[1] end,
        function()
          state.shopFor = m[1]
          UI.Refresh()
        end)
      radio:SetTooltip(function(tt)
        GameTooltip_SetTitle(tt, m[2])
        GameTooltip_AddNormalLine(tt, m[3])
      end)
    end
    root:CreateDivider()
    root:CreateTitle("Mats on other characters")
    local function Mats(text, tip, on)
      local radio = root:CreateRadio(text, function() return C.UsesAlt() == on end,
        function() SetAltMats(on) end)
      radio:SetTooltip(function(tt)
        GameTooltip_SetTitle(tt, text)
        GameTooltip_AddNormalLine(tt, tip)
      end)
    end
    Mats("Use them", "The shopping list and routes count what your alts (and guild bank) "
      .. "hold: mail it over instead of buying. /meio craft alts on", true)
    Mats("This character's only", "Only your bags, bank and mailbox count; the rest is "
      .. "bought or crafted. /meio craft alts off", false)
    local others = M.Inventory.Others()
    if #others > 0 then
      local sub = root:CreateButton("Which alts")
      sub:SetEnabled(C.UsesAlt())
      sub:SetTooltip(function(tt)
        GameTooltip_SetTitle(tt, "Which alts")
        GameTooltip_AddNormalLine(tt, "Untick an alt to leave its mats out (a bank alt you "
          .. "keep stock on, say)")
      end)
      local names = {}
      for _, a in ipairs(others) do names[a.name] = (names[a.name] or 0) + 1 end
      for _, a in ipairs(others) do
        local col = a.class and RAID_CLASS_COLORS and RAID_CLASS_COLORS[a.class]
        local label = col and col:WrapTextInColorCode(a.name) or a.name
        if names[a.name] > 1 then
          label = label .. Hex(DIM, " " .. (a.key:match("%-(.+)$") or ""))
        end
        sub:CreateCheckbox(label, function() return C.UsesAlt(a.key) end,
          function()
            state.altSkip[a.key] = C.UsesAlt(a.key) or nil
            UI.AltsChanged()
          end)
      end
    end
    root:CreateDivider()
    root:CreateTitle("Stop at skill")
    local function Stop(text, tip, is, pick)
      local radio = root:CreateRadio(text, is, function()
        pick()
        UI.Refresh()
      end)
      radio:SetTooltip(function(tt)
        GameTooltip_SetTitle(tt, text)
        GameTooltip_AddNormalLine(tt, tip)
      end)
    end
    Stop("Don't stop", "Craft next makes the whole step", function() return not state.stopAt end,
      function() state.stopAt = nil end)
    Stop("Next skill point", "Craft next crafts one at a time until the skill goes up",
      function() return state.stopAt == "next" end, function() state.stopAt = "next" end)
    local n = type(state.stopAt) == "number" and state.stopAt
    Stop(n and ("Skill %d..."):format(n) or "Skill...", "Craft next crafts one at a time "
      .. "until the skill reaches the number you type. /meio craft stop <skill>",
      function() return n and true or false end, UI.AskStop)
  end)
  frame.craftMode:SetSelectionText(function()
    local mode = state.craftMode == "queue" and "Queue" or "Bulk"
    -- too narrow for both: a stop says more about what Craft next does now
    if state.stopAt then return "Stop " .. (state.stopAt == "next" and "+1" or state.stopAt) end
    if state.shopFor == "speed" then mode = mode .. ", fast" end
    return C.UsesAlt() and mode or mode .. ", own"
  end)
  frame.craftMode:SetPoint("RIGHT", frame.clearButton, "LEFT", -6, 0)
  Help(frame.craftMode, { "Batches and shopping", "Bulk or Queue: how Craft next batches",
    "Bulk: one batch per recipe once all its materials are in bags. Queue: whatever bags allow "
    .. "now. Shop for Cheapest crafts intermediates when cheaper, Fastest buys them ready-made. "
    .. "Own: mats on other characters left out." })
  frame.profMenu = Dropdown(130, function(_, root)
    local chars = Crafters()
    if #chars > 1 then
      local sub = root:CreateButton("Character: " .. CharName(R.Viewer() or R.Me()))
      for _, key in ipairs(chars) do
        local label = CharName(key)
        if key == R.Me() then label = label .. " (you)" end
        sub:CreateRadio(label, function() return (R.Viewer() or R.Me()) == key end,
          function() UI.ViewAs(key) end)
      end
      root:CreateDivider()
    end
    local mine = Professions()
    local function Radio(parent, prof)
      parent:CreateRadio(prof, function() return CurrentProfession() == prof end,
        function() UI.WhatIf(prof) end)
    end
    for _, prof in ipairs(mine) do Radio(root, prof) end
    local others = {}
    for prof in pairs(C.Lines()) do
      if not tContains(mine, prof) then others[#others + 1] = prof end
    end
    table.sort(others)
    if #others > 0 then
      local sub = root:CreateButton("Not learnt")
      for _, prof in ipairs(others) do Radio(sub, prof) end
    end
    root:CreateDivider()
    root:CreateButton("What if: set skill...", function()
      local prof = CurrentProfession()
      if prof then StaticPopup_Show("MEIONOMICS_WHATIF", prof, nil, prof) end
    end)
    if whatIf then
      root:CreateButton("Back to your own skill", function() UI.WhatIf(nil) end)
    end
  end)
  frame.profMenu:SetSelectionText(function()
    local prof = CurrentProfession() or ""
    if not R.Viewer() then return prof end
    return ("%s: %s"):format(CharName(R.Viewer()), prof)
  end)
  Help(frame.profMenu, { "Profession", "Which profession to show, and whose",
    "Opening a profession switches to it. Character: an alt's professions and recipes as at "
    .. "its last login. Not learnt and What if: any profession at any skill (/meio whatif)" })
  frame.modeMenu = Dropdown(92, function(_, root)
    for _, m in ipairs({ { false, "Ranking" }, { true, "Route" } }) do
      root:CreateRadio(m[2], function() return state.route.on == m[1] end, function()
        state.route.on, offset = m[1], 0
        UI.Refresh()
      end)
    end
  end)
  frame.modeMenu:SetSelectionText(function() return state.route.on and "Route to" or "Ranking" end)
  Help(frame.modeMenu, { "Ranking or Route", "Ranking: each recipe by what a point costs",
    "Route: the cheapest run of crafts from your skill to the target, ready to queue" })
  CreateRouteBar()
  CreateFindBar()
  CreateSearch()

  frame.heads = {}
  frame.status = frame:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
  frame.status:SetPoint("BOTTOMLEFT", 12, 8)
  frame.status:SetPoint("BOTTOMRIGHT", -22, 8)   -- clear of the resize grip
  frame.status:SetJustifyH("LEFT")
  frame.status:SetWordWrap(false)
  frame:EnableMouseWheel(true)
  frame:SetScript("OnMouseWheel", function(_, delta) Scroll(delta) end)
  frame:SetScript("OnShow", function(self) self:Raise() UI.Refresh() end)
  frame:SetScript("OnSizeChanged", function()
    if built and frame:IsShown() then Draw(built.list, built.view) end
  end)
  CreateGrip()
  frame:Hide()
end

------------------------------------------------------------------------------ Docking
-- beside Blizzard's profession window or TSM's crafting window when one is open, so it follows
-- that window when it moves; otherwise where it was dragged. Dragging while docked sets the
-- offset from that window (one saved offset each). No room on the right: on the left.
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

local tsmFrame   -- TSM's crafting window while shown (TSM_API.RegisterUICallback)

-- the window to dock to, its saved offset's key, how far its side tabs reach
local function Host()
  local pf = ProfessionsFrame
  if pf and pf:IsShown() then return pf, "dockAt", TabsWidth(pf) end
  if tsmFrame and tsmFrame:IsShown() then return tsmFrame, "dockAtTSM", 0 end
end

local function Dock()
  local host, key, tabs = Host()
  frame:ClearAllPoints()
  frame.docked = host ~= nil
  frame.dockLeft = nil
  if host then
    local at = state[key] or { 2, 0 }
    frame:SetPoint("TOPLEFT", host, "TOPRIGHT", tabs + at[1], at[2])
    local right, room = frame:GetRight(), UIParent:GetRight()
    local hostLeft = host:GetLeft()
    if right and room and hostLeft and right > room
        and hostLeft * host:GetEffectiveScale() / frame:GetEffectiveScale() > frame:GetWidth() then
      frame:ClearAllPoints()
      frame:SetPoint("TOPRIGHT", host, "TOPLEFT", -2, at[2])
      frame.dockLeft = true
    end
  elseif state.freeAt then
    frame:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", state.freeAt[1], state.freeAt[2])
  else
    -- where it sits beside the profession window at its default place, clear of the bags
    frame:SetPoint("TOPLEFT", UIParent, "TOPLEFT", 735, -116)
  end
end

function SavePlace()
  local left, top = frame:GetLeft(), frame:GetTop()
  if not (left and top) then return end
  local host, key, tabs = Host()
  if host and not frame.dockLeft then
    -- in this panel's units: FlareUI's Ctrl+wheel may have scaled the profession window
    local s = host:GetEffectiveScale() / frame:GetEffectiveScale()
    state[key] = {
      math.floor(left - host:GetRight() * s - tabs + 0.5),
      math.floor(top - host:GetTop() * s + 0.5),
    }
  elseif not host then
    state.freeAt = { math.floor(left + 0.5), math.floor(top + 0.5) }
  end
  Dock()
end

local function TSMShown(shown, f)
  tsmFrame = shown and f or nil
  if not frame then
    if shown and state.auto and OpenProfession() then UI.Show() end
    return
  end
  if shown then
    if frame:IsShown() then Dock() elseif state.auto and OpenProfession() then UI.Show() end
  elseif frame.docked then
    if ProfessionsFrame and ProfessionsFrame:IsShown() then Dock() else UI.Hide() end
  end
end

local function HookTSM()
  local api = TSM_API
  if UI.tsmHooked or not (api and api.RegisterUICallback) then return end
  UI.tsmHooked = pcall(api.RegisterUICallback, "CRAFTING", "Meionomics:CraftDock", TSMShown)
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
  if state.craftMode ~= "queue" then state.craftMode = "bulk" end
  if state.shopFor ~= "speed" then state.shopFor = "price" end
  if state.altMats ~= false then state.altMats = nil end
  state.altSkip = type(state.altSkip) == "table" and state.altSkip or {}
  state.route = type(state.route) == "table" and state.route or {}
  state.route.unverified = nil
  -- useHeld was on by default before: turned off once, then his choice
  if (state.route.heldVersion or 0) < 2 then
    state.route.useHeld, state.route.heldVersion = nil, 2
  end
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
M.On("PLAYER_LOGIN", function()
  HookProfessionsFrame()
  HookTSM()
end)
-- next frame: Blizzard shows ProfessionsFrame on the same event, so it is there to dock to
M.On("TRADE_SKILL_SHOW", function()
  whatIf = nil
  R.SetViewer(nil)
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
    M.Print("crafting panel opens with the profession window: " .. M.OnOff(state.auto))
  elseif rest == "clear" then
    M.Print(("queue cleared (%s)"):format(Plural(ClearQueue(), "craft")))
  elseif rest == "next" then
    UI.CraftNext()
  elseif rest == "one" then
    UI.CraftNext(true)
  elseif rest:match("^stop") then
    local arg = rest:match("^stop%s*(.*)$")
    if arg == "next" then state.stopAt = "next" else SetStop(arg) end
    if frame then UI.Refresh() end
    M.Print("Craft next stops at: " .. (state.stopAt == "next" and "the next skill point"
      or state.stopAt and ("skill " .. state.stopAt) or "nothing (whole step)"))
  elseif rest == "bulk" or rest == "queue" then
    state.craftMode = rest
    M.Print("craft mode: " .. rest)
    if frame then UI.Refresh() end
  elseif rest == "price" or rest == "speed" then
    state.shopFor = rest
    M.Print("shopping for " .. rest)
    if frame then UI.Refresh() end
  elseif rest:match("^alts") then
    local arg = rest:match("^alts%s*(.*)$")
    local on = arg == "on" or arg ~= "off" and not C.UsesAlt()
    SetAltMats(on)
    M.Print("queue uses mats on other characters: " .. M.OnOff(on))
  elseif rest == "reset" then
    state.dockAt, state.dockAtTSM, state.freeAt, state.size = nil, nil, nil, nil
    if frame then frame:SetSize(W, H) end
    if frame then Dock() end
    M.Print("crafting panel back to its default place and size")
  else
    UI.Toggle()
  end
end

-- /meio whatif [profession] [skill], /meio whatif off: the panel at a skill not his
M.commands.whatif = function(rest)
  rest = strtrim(rest or "")
  if rest == "off" then
    UI.WhatIf(nil)
    return M.Print("what if: off, back to your own skill")
  end
  local name, rank = rest:match("^(.-)%s*(%d*)$")
  rank = tonumber(rank)
  local prof
  if name ~= "" then
    local all = {}
    for p in pairs(C.Lines()) do all[#all + 1] = p end
    for _, p in ipairs(Professions()) do all[#all + 1] = p end
    for _, p in ipairs(all) do
      if p:lower():find(name:lower(), 1, true) == 1 then prof = p end
    end
    if not prof then return M.Print("what if: no profession called " .. name) end
  end
  if state.view == "queue" or state.view == "find" then state.view = "profit" end
  UI.WhatIf(prof or CurrentProfession(), rank)
  UI.Show()
end

-- /meio find [name]: the Find view, with or without the profession window
M.commands.find = function(rest)
  state.view, offset = "find", 0
  if rest and rest ~= "" then state.find.text = rest end
  UI.Show()
  frame.findBar.search:SetText(state.find.text or "")
end
