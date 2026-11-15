-- The item a recipe makes, in a second tooltip beside the one about the recipe: Meio Craft rows
-- (CraftUI calls B.Show) and recipe items (patterns, plans, formulas). Enchants show the spell.
local _, M = ...
local R = M.Recipes
local B = {}
M.ItemBeside = B

local GAP = 2
local tip, owner, side
local hooked = {}

local function Secret(v) return issecretvalue ~= nil and issecretvalue(v) end

-- outside the owner, on the side with room; rechecked every frame since the owner may still be
-- moving into place when we're first shown
local function Place()
  if not owner then return end
  local right, screen = owner:GetRight(), UIParent:GetRight()
  local want = "right"
  if right and not Secret(right) and right + tip:GetWidth() + GAP > screen then want = "left" end
  if want == side then return end
  side = want
  tip:ClearAllPoints()
  if want == "left" then
    tip:SetPoint("TOPRIGHT", owner, "TOPLEFT", -GAP, 0)
  else
    tip:SetPoint("TOPLEFT", owner, "TOPRIGHT", GAP, 0)
  end
end

local function Tip()
  if tip then return tip end
  tip = CreateFrame("GameTooltip", "MeionomicsItemBeside", UIParent, "GameTooltipTemplate")
  tip:SetScript("OnUpdate", Place)
  return tip
end

function B.Hide()
  owner, side = nil, nil
  if tip then tip:Hide() end
end

-- rec: a Meionomics recipe record; tt: the shown tooltip it goes beside
function B.Show(tt, rec)
  if not (rec and (rec.out or rec.id)) then return B.Hide() end
  local t = Tip()
  t:SetOwner(UIParent, "ANCHOR_NONE")
  owner, side = tt, nil
  if rec.out then t:SetItemByID(rec.out) else t:SetSpellByID(rec.id) end
  Place()
  t:Show()
  if not hooked[tt] then
    hooked[tt] = true
    -- cleared: reused for something else without hiding (moving straight to another item)
    local function Gone(self) if owner == self then B.Hide() end end
    tt:HookScript("OnHide", Gone)
    tt:HookScript("OnTooltipCleared", Gone)
  end
end

local function OnItem(tt, data)
  if tt == tip or tt ~= GameTooltip then return end
  local itemID = data and data.id
  if not itemID or Secret(itemID) then return end
  local recs = R.TaughtBy(itemID)
  local rec = recs and recs[1]
  if not rec then return end
  B.Show(tt, rec)
end

M.On("PLAYER_LOGIN", function()
  if not (TooltipDataProcessor and Enum.TooltipDataType) then return end
  TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Item, function(tt, data)
    local ok, err = pcall(OnItem, tt, data)
    if not ok then geterrorhandler()(err) end
  end)
end)
