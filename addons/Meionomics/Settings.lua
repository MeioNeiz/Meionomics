-- Options panel (Esc > Options > AddOns > Meionomics, or /meio options): which facts the compact
-- tooltip shows, and the Sell tab's auto price. Settings write straight into MeionomicsDB.
local _, M = ...

local category

local function Register()
  if category or not (Settings and Settings.RegisterVerticalLayoutCategory) then return end
  local layout
  category, layout = Settings.RegisterVerticalLayoutCategory("Meionomics")
  if layout and CreateSettingsListSectionHeaderInitializer then
    layout:AddInitializer(CreateSettingsListSectionHeaderInitializer("Compact tooltip",
      "What item tooltips show at a glance. Hold Shift for everything."))
  end
  for _, f in ipairs(M.Tooltip.FIELDS) do
    local setting = Settings.RegisterAddOnSetting(category, "MEIONOMICS_FIELD_" .. f.key:upper(),
      f.key, M.db.fields, Settings.VarType.Boolean, f.name, f.on)
    Settings.CreateCheckbox(category, setting, f.tip)
  end
  if layout and CreateSettingsListSectionHeaderInitializer then
    layout:AddInitializer(CreateSettingsListSectionHeaderInitializer("Auction house",
      "Blizzard's Sell tab. /meio autoprice on|off does the same."))
  end
  local auto = Settings.RegisterAddOnSetting(category, "MEIONOMICS_AUTO_PRICE", "autoPrice", M.db,
    Settings.VarType.Boolean, "Auto price in Sell tab", true)
  Settings.CreateCheckbox(category, auto, "Fill the Sell tab's price from Meionomics' rules, "
    .. "with a line saying which rule set it. A price you type is never replaced.")
  local full = Settings.RegisterAddOnSetting(category, "MEIONOMICS_AH_DETAIL", "ahDetail",
    M.db, Settings.VarType.Boolean, "Full detail at the auction house", false)
  Settings.CreateCheckbox(category, full, "While the auction house is open, item tooltips show "
    .. "everything (as with Shift) without holding Shift.")
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
