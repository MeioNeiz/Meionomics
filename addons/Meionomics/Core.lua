-- Meionomics: crafting profit, levelling routes, item prices and AH help for WoW Forever.
local addonName, M = ...
Meionomics = M

-- the family colour our addons share for their chat prefix
M.ACCENT = "|cffb090ff"

local DEFAULTS = {}

-- the scenario swaps in a fixed clock
function M.Now() return time() end

function M.Print(msg) DEFAULT_CHAT_FRAME:AddMessage(M.ACCENT .. "Meionomics:|r " .. msg) end

-- chat words: commands in Blizzard gold, on green, off red
function M.Cmd(text) return "|cffffd100" .. text .. "|r" end
function M.OnOff(on) return on and "|cff80ff80on|r" or "|cffff8080off|r" end

-- the gold cap: a listing dearer than this can't be bought (joke prices, 9,999,999g), and its
-- price overflows string.format
M.MAX_COPPER = 2^31 - 1

-- 12g 34s / 5s 6c / 7c / 7g: two units at most (no room for copper on gold), zero ones dropped
-- as Blizzard does.
-- digits, units: hex colours for the numbers and the g/s/c letters (nil: line colour, coin
-- colours); colour codes don't nest reliably, so each piece gets its own
function M.Money(c, digits, units)
  if not c then return "|cff808080-|r" end
  local neg = c < 0
  c = math.floor(math.abs(c) + 0.5)
  local g, s, cp = math.floor(c / 10000), math.floor(c / 100) % 100, c % 100
  local function N(n) return digits and ("|cff" .. digits .. n .. "|r") or n end
  local function U(hex, u) return "|cff" .. (units or hex) .. u .. "|r" end
  local text
  if g >= 100 then
    text = N(BreakUpLargeNumbers(g)) .. U("ffd700", "g")
  elseif g > 0 then
    text = N(g) .. U("ffd700", "g") .. (s > 0 and (" " .. N(s) .. U("c7c7cf", "s")) or "")
  elseif s > 0 then
    text = N(s) .. U("c7c7cf", "s") .. (cp > 0 and (" " .. N(cp) .. U("eda55f", "c")) or "")
  else
    text = N(cp) .. U("eda55f", "c")
  end
  return (neg and N("-") or "") .. text
end

-- 0.4 / 3.2 / 87 / 10.6k
function M.Count(n)
  if not n then return "-" end
  if n >= 10000 then return ("%.1fk"):format(n / 1000) end
  if n >= 1000 then return BreakUpLargeNumbers(math.floor(n + 0.5)) end
  if n >= 10 then return ("%d"):format(n + 0.5) end
  return ("%.1f"):format(n)
end

local events = CreateFrame("Frame")
M.events = events
local handlers = {}
function M.On(event, fn)
  if not handlers[event] then
    handlers[event] = {}
    events:RegisterEvent(event)
  end
  table.insert(handlers[event], fn)
end
events:SetScript("OnEvent", function(_, event, ...)
  for _, fn in ipairs(handlers[event]) do fn(event, ...) end
end)

M.On("ADDON_LOADED", function(_, name)
  if name ~= addonName then return end
  MeionomicsDB = MeionomicsDB or {}
  M.db = MeionomicsDB
  for k, v in pairs(DEFAULTS) do
    if M.db[k] == nil then M.db[k] = v end
  end
  M.SeedRealms()
  if M.OnLoad then M.OnLoad() end
end)

------------------------------------------------------------------------------ Realm
-- Since 2026-11-20 GetRealmName() is "" at login on Forever (and for a while after /reload):
-- keyed by it, AH data went to ah["-Alliance"]. The realm comes from the client when it has
-- it, else from the name an earlier session saw for this character's server (6942 in
-- Player-6942-...), else nil: callers wait for M.OnRealm rather than invent a key.
-- db.realms: server id -> realm name, written whenever GetRealmName() gives one.

local function Named(s) return type(s) == "string" and s:find("%S") and s or nil end

-- "Player-6942-00C16049" -> 6942
function M.ServerID(guid)
  return type(guid) == "string" and tonumber(guid:match("^Player%-(%d+)%-")) or nil
end

-- the form GetNormalizedRealmName gives: no spaces or hyphens
local function Normalize(name) return (name:gsub("[%s%-]", "")) end

-- character records made while GetRealmName() still worked know the realm of their server
function M.SeedRealms()
  local realms = M.db.realms or {}
  M.db.realms = realms
  for guid, c in pairs(type(M.db.chars) == "table" and M.db.chars or {}) do
    local id = M.ServerID(guid)
    if id and not realms[id] and type(c) == "table" and Named(c.realm) then
      realms[id] = c.realm
    end
  end
end

-- this character's realm as GetRealmName() names it ("CAMWOW EU4 Realm 8 PvP"), nil unknown
function M.Realm()
  local realms = M.db and M.db.realms
  local id = M.ServerID(UnitGUID("player"))
  local name = Named(GetRealmName())
  if name then
    if realms and id and realms[id] ~= name then realms[id] = name end
    return name
  end
  local norm = Named(GetNormalizedRealmName and GetNormalizedRealmName())
  if norm and realms then
    for _, r in pairs(realms) do
      if Normalize(r) == norm then return r end
    end
  end
  return realms and realms[id] or nil
end

-- "CAMWOW EU4 Realm 8 PvP-Alliance", nil while the realm or faction is unknown
function M.RealmKey()
  local realm, faction = M.Realm(), Named(UnitFactionGroup("player"))
  return realm and faction and (realm .. "-" .. faction) or nil
end

-- GetNormalizedRealmName(), else ours without spaces
function M.NormalizedRealm()
  local norm = Named(GetNormalizedRealmName and GetNormalizedRealmName())
  if norm then return norm end
  local realm = M.Realm()
  return realm and Normalize(realm)
end

-- fn(realm, key) once both are known: at login, else as soon as they are (polled: no event
-- says so). Per-realm tables are bound and migrated here.
local realmFns, realmKnown = {}, false
function M.OnRealm(fn)
  if realmKnown then return fn(M.Realm(), M.RealmKey()) end
  realmFns[#realmFns + 1] = fn
end

local function TryRealm()
  local key = M.RealmKey()
  if not key then return false end
  realmKnown = true
  local realm = M.Realm()
  for _, fn in ipairs(realmFns) do
    local ok, err = pcall(fn, realm, key)
    if not ok then geterrorhandler()(err) end
  end
  realmFns = {}
  return true
end

-- t[realm-faction] tables kept under "-Faction" while the realm was "" -> merged into the
-- realm's own with merge(dst, src), then dropped. A key missing on the realm side moves.
function M.MergeBlankRealm(t, realm, merge)
  local blank = {}
  for k in pairs(t) do
    if type(k) == "string" and k:find("^%-") then blank[#blank + 1] = k end
  end
  for _, k in ipairs(blank) do
    local key = realm .. k
    t[key] = t[key] and merge(t[key], t[k]) or t[k]
    t[k] = nil
  end
end

M.OnRealm(function()
  local realms = M.db.realms
  for guid, c in pairs(type(M.db.chars) == "table" and M.db.chars or {}) do
    local realm = realms[M.ServerID(guid) or 0]
    if realm and type(c) == "table" and not Named(c.realm) then c.realm = realm end
  end
end)

M.On("PLAYER_LOGIN", function()
  if TryRealm() then return end
  local ticker
  ticker = C_Timer.NewTicker(1, function()
    if TryRealm() then ticker:Cancel() end
  end)
end)

------------------------------------------------------------------------------ /meio
M.commands = {}

local function Db(key, sub)
  local t = M.db and M.db[key]
  if sub then return type(t) == "table" and t[sub] or nil end
  return t
end

-- current values for the help lines; nil-or-true keys are on unless set false
M.toggles = {
  craftAuto = function() return Db("craftUI", "auto") ~= false end,
  worthBank = function() return Db("worth", "bank") ~= false end,
  history = function() return Db("history") ~= false end,
  autoScan = function() return Db("autoScan") ~= false end,
  autoPrice = function() return Db("autoPrice") ~= false end,
  ahDetail = function() return Db("ahDetail") == true end,
  tooltips = function() return Db("tooltips") ~= false end,
}

-- a string starts a group; each command { name, args, one line, state key, detail }, detail
-- lines { usage, text, state key } for /meio help <name>. A command missing here still shows,
-- under Other, so none is ever hidden.
local HELP = {
  "Windows",
  { "craft", "", "crafting panel: profit, skill-ups, queue", detail = {
    { "/meio craft", "open or close the panel" },
    { "/meio craft auto", "open it with the profession window, or not", "craftAuto" },
    { "/meio craft bulk||queue", "Bulk waits for a recipe's whole batch, Queue crafts what "
      .. "your bags allow now" },
    { "/meio craft price||speed", "craft intermediates when cheaper, or buy them ready-made" },
    { "/meio craft alts [on||off]", "count mats on other characters, or only this one's "
      .. "(pick alts in the Queue tab's menu)" },
    { "/meio craft bank||mail||guild [on||off]", "count mats in your bank, mailbox or the guild "
      .. "bank, or leave them out" },
    { "/meio craft next", "craft the next queued step (also a key binding)" },
    { "/meio craft one", "craft just 1 of the next queued step (also a key binding)" },
    { "/meio craft stop [skill||next]", "Craft next stops at that skill, or the next point; "
      .. "empty: off" },
    { "/meio craft clear", "empty the queue" },
    { "/meio craft reset", "put the panel back beside the profession window" },
  } },
  { "find", "[name]", "find a recipe, known or not", detail = {
    { "/meio find [name]", "every recipe of your professions, known or not, above your skill "
      .. "too; opens without the profession window" },
  } },
  { "flips", "[name]", "crafting chains that make money, all characters", detail = {
    { "/meio flips [name]", "materials bought or crafted the cheapest way by any of your "
      .. "characters (bolts, bars, essences combined or split), the result sold, vendored or "
      .. "disenchanted; ranked by profit a day" },
  } },
  { "whatif", "[profession] [skill]", "crafting panel at another skill", detail = {
    { "/meio whatif [profession] [skill]", "profit and skill-up routes at any skill, learnt "
      .. "or not, e.g. /meio whatif tailoring 150" },
    { "/meio whatif off", "back to your own skill" },
  } },
  { "worth", "[tab]", "what your items are worth, any character",
    detail = {
      { "/meio worth [bags||bank||gear||mail||all]",
        "open or close the Worth window on a tab" },
      { "/meio worth bank on||off", "open it beside the bank", "worthBank" },
    } },
  { "history", "<item>", "an item's price history", detail = {
    { "/meio history <item link or ID>", "30 days of prices for an item, anywhere" },
    { "/meio history on||off", "show it beside the auction window when you pick an item",
      "history" },
    { "/meio history reset", "put its free window back in the middle" },
  } },
  { "reset", "", "put the windows back where they start" },
  "Auction house",
  { "autoscan", "on||off", "scan the AH when it opens", "autoScan" },
  { "autoprice", "on||off", "price the Sell tab for you", "autoPrice" },
  { "quote", "<item>", "sell, vendor or keep an item, and why", detail = {
    { "/meio quote <item link or ID>", "Shift-click an item to link it" },
  } },
  { "sells", "<item>", "how fast an item sells", detail = {
    { "/meio sells <item link or ID>", "sold per day, sale rate, listings up, days to clear" },
  } },
  { "posts", "", "how your posts sold, by undercut" },
  { "snipe", "[on||off||add||list...]", "deal alarms and the AH tab's Sniper", detail = {
    { "/meio snipe", "settings and every subcommand" },
    { "/meio snipe add <item> <max>", "alarm when it's up at or under max, e.g. 5g or 50s" },
    { "/meio snipe remove <item>", "stop watching it; list: every watched item" },
    { "/meio snipe pct <n>", "a deal is under n% of market (default 50)" },
    { "/meio snipe profit <gold>", "and makes this much after the AH cut (default 1g)" },
    { "/meio snipe big <gold>", "raid warning, and phone with phone on (default 10g)" },
    { "/meio snipe phone on||off", "big deals as a screenshot the MeioSnipe companion sends" },
    { "/meio snipe test", "a pretend big deal, to try the alarm and the phone" },
  } },
  "Prices",
  { "source", "", "where prices come from" },
  { "sell", "[TSM price]", "TSM price string for item values", detail = {
    { "/meio sell", "show the price string items are valued at" },
    { "/meio sell <TSM price>", "set it, e.g. /meio sell first(DBMarket, DBHistorical)" },
  } },
  { "mat", "[TSM price]", "TSM price string for materials", detail = {
    { "/meio mat", "show the price string materials cost" },
    { "/meio mat <TSM price>", "set it, e.g. /meio mat MatPrice" },
  } },
  { "legacy", "[forget||<profession>]", "Working Overtime: how it applies, what it saves",
    detail = {
      { "/meio legacy", "what your crafts say about how the bonus applies" },
      { "/meio legacy forget", "clear that evidence and start again" },
      { "/meio legacy <profession> [from] [to]",
        "what it saves levelling, e.g. tailoring 150 225 (takes a few seconds)" },
    } },
  "Tooltip",
  { "tooltips", "on||off", "prices and crafting on item and trainer tooltips", "tooltips" },
  { "fields", "[name]", "facts the compact tooltip shows", detail = {
    { "/meio fields", "list them, green ones shown" },
    { "/meio fields <name>", "turn one on or off (also in Settings)" },
  } },
  { "ahdetail", "on||off", "full tooltips at the AH, no Shift", "ahDetail" },
}
local ALIASES = { help = true, ["?"] = true, options = true, settings = true }
local MUTED = "|cff999999"

local function Line(usage, text, key)
  local now = key and M.toggles[key] and (" (now " .. M.OnOff(M.toggles[key]()) .. ")") or ""
  return "  " .. M.Cmd(usage) .. " - " .. text .. now
end

local function Find(name)
  for _, e in ipairs(HELP) do
    if type(e) == "table" and e[1] == name then return e end
  end
end

local function Help()
  local out = DEFAULT_CHAT_FRAME
  M.Print("crafting profit, item prices and auction house help")
  for _, e in ipairs(HELP) do
    if type(e) == "string" then
      out:AddMessage(MUTED .. e .. "|r")
    elseif M.commands[e[1]] then
      local usage = "/meio " .. e[1] .. (e[2] ~= "" and (" " .. e[2]) or "")
      out:AddMessage(Line(usage, e[3], e[4]))
    end
  end
  local other = {}
  for name in pairs(M.commands) do
    if not (ALIASES[name] or Find(name)) then other[#other + 1] = name end
  end
  if #other > 0 then
    table.sort(other)
    out:AddMessage(MUTED .. "Other|r")
    for _, name in ipairs(other) do out:AddMessage(Line("/meio " .. name, "")) end
  end
  out:AddMessage(MUTED .. "Help|r")
  out:AddMessage(Line("/meio help <command>", "more on one command"))
  out:AddMessage("  Settings: Esc > Options > AddOns > Meionomics (" .. M.Cmd("/meio settings")
    .. ")")
end

M.commands.help = function(rest)
  local name = (rest or ""):lower():gsub("^/?meio%s*", "")
  if name == "" then return Help() end
  local e = Find(name)
  if not e then
    return M.Print(('no command "%s": %s lists them'):format(name, M.Cmd("/meio help")))
  end
  M.Print(e[3])
  local out = DEFAULT_CHAT_FRAME
  for _, d in ipairs(e.detail or { { "/meio " .. e[1] .. (e[2] ~= "" and (" " .. e[2]) or ""),
    e[3], e[4] } }) do
    out:AddMessage(Line(d[1], d[2], d[3]))
  end
end
M.commands["?"] = M.commands.help

M.commands.tooltips = function(rest)
  if rest == "off" then M.db.tooltips = false elseif rest == "on" then M.db.tooltips = nil end
  M.Print("item and trainer tooltips " .. M.OnOff(M.toggles.tooltips()))
end

M.commands.ahdetail = function(rest)
  if rest == "on" or rest == "off" then M.db.ahDetail = rest == "on" end
  M.Print("full tooltips at the auction house " .. M.OnOff(M.toggles.ahDetail()))
end

-- /meio reset: each window module adds how to put itself back
local resets = {}
function M.OnReset(fn) resets[#resets + 1] = fn end
M.commands.reset = function()
  for _, fn in ipairs(resets) do
    local ok, err = pcall(fn)
    if not ok then geterrorhandler()(err) end
  end
  M.Print("windows back where they start")
end
-- the crafting panel's own /meio craft reset, without its chat line
M.OnReset(function()
  local s = M.db and M.db.craftUI
  if s then s.dockAt, s.freeAt = nil, nil end
  local f = MeionomicsCraftFrame
  if f and f:IsShown() and M.CraftUI then M.CraftUI.Show() end
end)

SLASH_MEIONOMICS1 = "/meio"
SLASH_MEIONOMICS2 = "/meionomics"
SlashCmdList.MEIONOMICS = function(msg)
  local cmd, rest = (msg or ""):match("^%s*(%S*)%s*(.-)%s*$")
  if cmd == "" then return Help() end
  local fn = M.commands[cmd:lower()]
  if fn then return fn(rest) end
  M.Print(('unknown command "%s"'):format(cmd))
  Help()
end
