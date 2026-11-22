-- The item a recipe makes, in a second tooltip beside the one about the recipe: Meio Craft rows
-- (CraftUI calls B.Show) and recipe items (patterns, plans, formulas). Enchants show the spell.
local _, M = ...
local R = M.Recipes
local B = {}
M.ItemBeside = B

local GAP = 2
local tip, owner, side, anchor, shown, pending
local hooked = {}

local function Secret(v) return issecretvalue ~= nil and issecretvalue(v) end
local function Num(v) if v and not Secret(v) then return v end end

-- Blizzard's comparison tooltips ("Equipped") sit beside the owner too, so go past any shown on
-- that side; returns the frame to anchor to and its outer edge
local function Beyond(dir)
  local oL, oR = Num(owner:GetLeft()), Num(owner:GetRight())
  local frame, edge = owner, dir == "right" and oR or oL
  if not (oL and oR) then return frame, edge end
  local mid = (oL + oR) / 2
  for _, sh in ipairs(owner.shoppingTooltips or {}) do
    local l, r = Num(sh:GetLeft()), Num(sh:GetRight())
    if sh:IsShown() and l and r then
      local onRight = (l + r) / 2 > mid
      if dir == "right" and onRight and r > edge then frame, edge = sh, r end
      if dir == "left" and not onRight and l < edge then frame, edge = sh, l end
    end
  end
  return frame, edge
end

-- the frame to anchor to on that side, and the room left beside it once we're there (< 0: off
-- screen); nil room when the owner's edges can't be read
local function Room(dir)
  local frame, edge = Beyond(dir)
  if not edge then return frame, nil end
  local need = tip:GetWidth() + GAP
  if dir == "right" then return frame, UIParent:GetRight() - edge - need end
  return frame, edge - UIParent:GetLeft() - need
end

-- outside the owner: right when it fits, else the side with more room; rechecked every frame
-- since the owner may still be moving into place when we're first shown, and comparisons can
-- appear after us
local function Place()
  if not owner then return end
  local rightFrame, right = Room("right")
  local leftFrame, left = Room("left")
  local want = "right"
  if right and left and right < 0 and left > right then
    want = "left"
  end
  local frame = want == "left" and leftFrame or rightFrame
  if want == side and frame == anchor then return end
  side, anchor = want, frame
  tip:ClearAllPoints()
  if want == "left" then
    tip:SetPoint("TOPRIGHT", frame, "TOPLEFT", -GAP, 0)
  else
    tip:SetPoint("TOPLEFT", frame, "TOPRIGHT", GAP, 0)
  end
end

local function Tip()
  if tip then return tip end
  tip = CreateFrame("GameTooltip", "MeionomicsItemBeside", UIParent, "GameTooltipTemplate")
  -- GameTooltip_OnUpdate redraws an item still "Retrieving item information" once it arrives;
  -- the template leaves OnUpdate unset, so without it the tooltip stays that way
  tip:SetScript("OnUpdate", function(self, elapsed)
    if pending then return B.Hide() end
    Place()
    if GameTooltip_OnUpdate and self.updateTooltipTimer then GameTooltip_OnUpdate(self, elapsed) end
  end)
  return tip
end

function B.Hide()
  owner, side, anchor, shown, pending = nil, nil, nil, nil, nil
  if tip then tip:Hide() end
end

-- rec: a Meionomics recipe record; tt: the shown tooltip it goes beside
function B.Show(tt, rec)
  if not (rec and (rec.out or rec.id)) then return B.Hide() end
  local t = Tip()
  pending = nil
  -- owners with UpdateTooltip (AH rows, bags) clear and refill tt every 0.2 s: keep ours as is
  if owner == tt and shown == rec and t:IsShown() then return Place() end
  t:SetOwner(UIParent, "ANCHOR_NONE")
  owner, side, anchor, shown = tt, nil, nil, rec
  if rec.out then t:SetItemByID(rec.out) else t:SetSpellByID(rec.id) end
  Place()
  t:Show()
  -- the width before Show was the last item's: placed again, in the same frame
  side, anchor = nil, nil
  Place()
  if not hooked[tt] then
    hooked[tt] = true
    tt:HookScript("OnHide", function(self) if owner == self then B.Hide() end end)
    -- cleared: refilled (same item, Show follows in this frame) or reused for something else
    -- without hiding (moving straight to another item); hidden next frame unless shown again
    tt:HookScript("OnTooltipCleared", function(self) if owner == self then pending = true end end)
  end
end

local function OnItem(tt, data)
  if tt == tip or tt ~= GameTooltip or not M.toggles.tooltips() then return end
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
