-- Meionomics: crafting profit, levelling routes, item prices and AH help for WoW Forever.
local addonName, M = ...
Meionomics = M

M.ACCENT = "|cfff2c94c"

local DEFAULTS = {}

-- the scenario swaps in a fixed clock
function M.Now() return time() end

function M.Print(msg) DEFAULT_CHAT_FRAME:AddMessage(M.ACCENT .. "Meionomics|r: " .. msg) end

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
  if M.OnLoad then M.OnLoad() end
end)

M.commands = {}
SLASH_MEIONOMICS1 = "/meio"
SLASH_MEIONOMICS2 = "/meionomics"
SlashCmdList.MEIONOMICS = function(msg)
  local cmd, rest = (msg or ""):match("^%s*(%S*)%s*(.-)%s*$")
  local fn = M.commands[cmd:lower()]
  if fn then return fn(rest) end
  M.Print("/meio craft, /meio find, /meio options, /meio fields [name], /meio quote <item>, "
    .. "/meio sell|mat <TSM price>, /meio source")
end
