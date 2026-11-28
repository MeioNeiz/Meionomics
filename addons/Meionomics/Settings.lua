-- Options panel (Esc > Options > AddOns > Meionomics, or /meio settings): a section per group
-- of /meio help, each checkbox in the same words as its chat toggle. Settings write straight
-- into MeionomicsDB, in the form the chat toggles store, so both stay in step.
-- No "open window" buttons: closing Blizzard's panel from addon code commits its settings
-- tainted, and a window opened under it is hidden. Headers say how to open each instead.
local _, M = ...

local category, layout

local function Header(title, tip)
  if layout and CreateSettingsListSectionHeaderInitializer then
    layout:AddInitializer(CreateSettingsListSectionHeaderInitializer(title, tip))
  end
end

-- tbl()[key] read as on unless false; on writes onValue (nil where the code treats nil as on);
-- after(): run on a change
local function Toggle(var, tbl, key, onValue, name, tip, after)
  local setting = Settings.RegisterProxySetting(category, "MEIONOMICS_" .. var,
    Settings.VarType.Boolean, name, true,
    function() return tbl()[key] ~= false end,
    function(v)
      if v then tbl()[key] = onValue else tbl()[key] = false end
      if after then after() end
    end)
  Settings.CreateCheckbox(category, setting, tip)
end

local function CraftState() return M.db.craftUI end

-- options: { value, label, tooltip }, the first the default
local function Choice(var, key, name, tip, options)
  local setting = Settings.RegisterProxySetting(category, "MEIONOMICS_" .. var,
    Settings.VarType.String, name, options[1][1],
    function() return CraftState()[key] or options[1][1] end,
    function(v)
      CraftState()[key] = v
      if M.CraftUI then M.CraftUI.Refresh() end
    end)
  Settings.CreateDropdown(category, setting, function()
    local c = Settings.CreateControlTextContainer()
    for _, o in ipairs(options) do c:Add(o[1], o[2], o[3]) end
    return c:GetData()
  end, tip)
end

-- the panel cuts labels at about 20 characters
local SHORT = { usedIn = "Best use in recipe", vsMarket = "Buyout vs market" }

local function Register()
  if category or not (Settings and Settings.RegisterVerticalLayoutCategory) then return end
  category, layout = Settings.RegisterVerticalLayoutCategory("Meionomics")
  local db = function() return M.db end

  Header("Crafting panel", "Profit, skill-up routes and a craft queue beside the profession "
    .. "window. /meio craft opens it anywhere, /meio find searches recipes.")
  Toggle("CRAFT_AUTO", CraftState, "auto", true, "Open automatically", "The crafting panel "
    .. "opens with the profession window, beside it. Off: open it with /meio craft "
    .. "(/meio craft auto).")
  Choice("CRAFT_MODE", "craftMode", "Craft mode", "How Craft next works through the queue.", {
    { "bulk", "Bulk", "One batch per recipe once all its materials are in your bags. Fewest "
      .. "presses." },
    { "queue", "Queue", "Crafts what your bags allow now, the rest in later batches." },
  })
  Choice("SHOP_FOR", "shopFor", "Shop for", "How the shopping list gets intermediates such as "
    .. "bolts.", {
    { "price", "Cheapest", "Craft intermediates from raw materials when that costs less." },
    { "speed", "Fastest", "Buy intermediates ready-made when the AH has them." },
  })
  Toggle("ALT_MATS", CraftState, "altMats", nil, "Use alts' mats", "The shopping list, "
    .. "routes and verdicts count mats on your other characters (mail them over). Off: only "
    .. "this character's. The Queue tab's menu leaves out single alts (/meio craft alts).",
    function() if M.CraftUI then M.CraftUI.AltsChanged() end end)
  local function From() return CraftState().useFrom end
  for _, f in ipairs({ { "BANK", "bank", "Use bank mats", "your bank" },
    { "MAIL", "mail", "Use mailbox mats", "your mailbox" },
    { "GUILD", "guild", "Use guild bank", "the guild bank" } }) do
    Toggle("FROM_" .. f[1], From, f[2], nil, f[3], "The shopping list, routes and verdicts "
      .. "count mats in " .. f[4] .. ". Off: they're left out, and bought or crafted "
      .. "instead (/meio craft " .. f[2] .. " on||off).",
      function() if M.CraftUI then M.CraftUI.AltsChanged() end end)
  end

  Header("Worth window", "What every item is worth, per character and place. /meio worth "
    .. "opens it anywhere.")
  Toggle("WORTH_BANK", function() return M.db.worth end, "bank", nil,
    "Open at the bank", "The Worth window opens on its Bank tab beside your bank, and "
    .. "closes with it (/meio worth bank on||off).")

  Header("Merchants", "Buttons under a vendor's or trainer's window, shown only when they "
    .. "have work.")
  Toggle("MERCHANT_BUTTONS", db, "merchantButtons", nil, "Merchant buttons", "Buy queue mats "
    .. "(what the craft queue still needs from this vendor), Sell junk (greys, and items a "
    .. "vendor pays most for, never gear) and Train queue recipes (what the queue hasn't "
    .. "learnt that this trainer teaches now). Nothing is bought, sold or trained without a "
    .. "click.")

  Header("Auction house", "Scans, Sell tab prices and price history while the AH is open.")
  Toggle("AUTO_SCAN", db, "autoScan", nil, "AH scan on opening", "Scan every listing when you "
    .. "open the auction house, for prices, history and the Browse tab's deals "
    .. "(/meio autoscan on||off).")
  Toggle("AUTO_PRICE", db, "autoPrice", true, "Sell tab prices", "Sell tab prices from "
    .. "Meionomics: fills the price from its rules, with a line saying which rule set it. A "
    .. "price you type is never replaced (/meio autoprice on||off).")
  Toggle("HISTORY", db, "history", nil, "Price history", "Price history beside the auction "
    .. "window: picking an item in the AH (Blizzard's or TSM's) shows its prices and sell "
    .. "chances (/meio history on||off). /meio history <item> shows it anywhere.")

  Header("Item tooltips", "What item tooltips show at a glance. Hold Shift for everything.")
  Toggle("TOOLTIPS", db, "tooltips", nil, "Add to tooltips", "Prices, stock and crafting "
    .. "profit on item tooltips, recipe details on trainer lines and the crafted item beside "
    .. "a recipe's tooltip. Off: Meionomics leaves tooltips alone (/meio tooltips on||off).")
  local full = Settings.RegisterAddOnSetting(category, "MEIONOMICS_AH_DETAIL", "ahDetail",
    M.db, Settings.VarType.Boolean, "Full tooltips at AH", false)
  Settings.CreateCheckbox(category, full, "While the auction house is open, item tooltips show "
    .. "everything, as with Shift, without holding it (/meio ahdetail on||off).")
  for _, f in ipairs(M.Tooltip.FIELDS) do
    local setting = Settings.RegisterAddOnSetting(category, "MEIONOMICS_FIELD_" .. f.key:upper(),
      f.key, M.db.fields, Settings.VarType.Boolean, SHORT[f.key] or f.name, f.on)
    Settings.CreateCheckbox(category, setting, f.tip)
  end

  if CreateSettingsButtonInitializer then
    Header("Windows", "/meio help lists every chat command. Prices: /meio sell, /meio mat "
      .. "and /meio source.")
    layout:AddInitializer(CreateSettingsButtonInitializer("Window positions", "Reset positions",
      function() M.commands.reset() end, "Put the crafting panel and the Worth window back "
      .. "where they start (same as /meio reset).", true))
  end
  Settings.RegisterAddOnCategory(category)
end

M.On("PLAYER_LOGIN", function()
  local ok, err = pcall(Register)
  if not ok then geterrorhandler()(err) end
end)

M.commands.options = function()
  if category then
    Settings.OpenToCategory(category:GetID())
  else
    M.commands.fields("")
  end
end
M.commands.settings = M.commands.options
