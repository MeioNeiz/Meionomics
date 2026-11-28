-- At a profession trainer: one button under the window, "Train queue recipes", shown only when
-- this trainer teaches something the craft queue hasn't learnt yet and the skill allows it now.
-- One click trains all of them (as many as the gold covers, the queue's order first). Recipes
-- queued for a later rank are named in the tooltip, not trained. Nothing without a click.
-- M.db.merchantButtons == false hides it, with the merchant strip.
local _, M = ...
local R, C = M.Recipes, M.Craft
local Tr = {}
M.Trainer = Tr

local LINE_ITEMS = 2

local function Hex(hex, text) return "|cff" .. hex .. text .. "|r" end
local function Dim(text) return Hex("a8a8a8", text) end
local function Enabled() return not (M.db and M.db.merchantButtons == false) end

-- queued recipes not known yet -> their place in the queue's order
local function Unlearnt()
  local out = {}
  if C.QueueCount() == 0 then return out end
  for k, s in ipairs(C.CraftSteps()) do
    if not s.known and s.rec.id and not out[s.rec.id] then out[s.rec.id] = k end
  end
  return out
end

-- -> trainable now { { index, id, name, cost, order } } in queue order, later
-- { { name, req } }, total cost of the trainable
function Tr.List()
  local now, later, total = {}, {}, 0
  if not (GetNumTrainerServices and GetTrainerServiceInfo and R.TrainerRecipeID) then
    return now, later, total
  end
  local want = Unlearnt()
  if not next(want) then return now, later, total end
  for i = 1, GetNumTrainerServices() do
    local name, kind = GetTrainerServiceInfo(i)
    local id = (kind == "available" or kind == "unavailable") and R.TrainerRecipeID(i)
    if id and want[id] then
      if kind == "available" then
        local cost = GetTrainerServiceCost and GetTrainerServiceCost(i) or 0
        now[#now + 1] = { index = i, id = id, name = name or ("recipe " .. id), cost = cost,
          order = want[id] }
        total = total + cost
      else
        local req = GetTrainerServiceSkillReq and select(2, GetTrainerServiceSkillReq(i))
        later[#later + 1] = { name = name or ("recipe " .. id), req = req }
      end
    end
  end
  table.sort(now, function(a, b) return a.order < b.order end)
  table.sort(later, function(a, b) return (a.req or 0) < (b.req or 0) end)
  return now, later, total
end

function Tr.TrainAll()
  local now = Tr.List()
  local money, spent, picked, short = GetMoney(), 0, {}, {}
  for _, e in ipairs(now) do
    if spent + e.cost <= money then
      picked[#picked + 1] = e
      spent = spent + e.cost
    else
      short[#short + 1] = e.name
    end
  end
  -- a trained line can leave the list: highest index first keeps the others' indices
  table.sort(picked, function(a, b) return a.index > b.index end)
  local names = {}
  for _, e in ipairs(picked) do
    BuyTrainerService(e.index)
    table.insert(names, 1, e.name)
  end
  if #names > 0 then
    M.Print(("trained %s for %s"):format(table.concat(names, ", "), M.Money(spent)))
  end
  if #short > 0 then M.Print("not enough gold to train " .. table.concat(short, ", ")) end
  R.ResetCache()
  Tr.RefreshSoon(0.5)
end

------------------------------------------------------------------------------ Button
local button

local function Text(now, total)
  local names = {}
  for k, e in ipairs(now) do if k <= LINE_ITEMS then names[#names + 1] = e.name end end
  local text = table.concat(names, ", ")
  if #now > LINE_ITEMS then text = text .. (", +%d more"):format(#now - LINE_ITEMS) end
  return ("Train queue recipes: %s (%s)"):format(text, M.Money(total))
end

local function Pair(tt, left, right) tt:AddDoubleLine(left, right, 1, 1, 1, 1, 1, 1) end

local function Tooltip(tt)
  local now, later, total = Tr.List()
  tt:AddLine("Train for the craft queue")
  for _, e in ipairs(now) do Pair(tt, e.name, M.Money(e.cost)) end
  Pair(tt, "Total", M.Money(total))
  if total > GetMoney() then tt:AddLine(Hex("ff5a5a", "Not enough gold for all of it")) end
  if #later > 0 then
    tt:AddLine(" ")
    tt:AddLine(Dim("Queued for later, not trainable yet:"))
    for _, e in ipairs(later) do
      Pair(tt, Dim(e.name), Dim(e.req and ("at " .. e.req) or "later"))
    end
  end
  tt:AddLine(Dim("Click to train all of these"))
end

local function ShowTip(b)
  GameTooltip:SetOwner(b, "ANCHOR_RIGHT")
  Tooltip(GameTooltip)
  GameTooltip:Show()
end

local function Build()
  if button or not ClassTrainerFrame then return button end
  button = CreateFrame("Button", nil, ClassTrainerFrame, "UIPanelButtonTemplate")
  button:SetPoint("TOPLEFT", ClassTrainerFrame, "BOTTOMLEFT", 4, -4)
  button:SetSize(320, 22)
  button:SetScript("OnClick", function() Tr.TrainAll() end)
  button:SetScript("OnEnter", ShowTip)
  button:SetScript("OnLeave", GameTooltip_Hide)
  local fs = button:GetFontString()
  if fs then fs:SetWordWrap(false) fs:SetPoint("LEFT", 8, 0) fs:SetPoint("RIGHT", -8, 0) end
  return button
end

function Tr.Refresh()
  if not (ClassTrainerFrame and ClassTrainerFrame:IsShown() and Enabled()) then
    if button then button:Hide() end
    return
  end
  Build()
  local now, _, total = Tr.List()
  button:SetShown(#now > 0)
  if #now == 0 then return end
  button:SetText(Text(now, total))
  button:SetEnabled(GetMoney() >= now[1].cost)
  if GameTooltip:GetOwner() == button then ShowTip(button) end
end

local ticket = 0
function Tr.RefreshSoon(delay)
  ticket = ticket + 1
  local t = ticket
  C_Timer.After(delay or 0.2, function() if t == ticket then Tr.Refresh() end end)
end

-- after Recipes.lua's own scan (0.5s after the event) so the services are recorded
M.On("TRAINER_SHOW", function() Tr.RefreshSoon(0.7) end)
M.On("TRAINER_UPDATE", function() Tr.RefreshSoon(0.7) end)
M.On("PLAYER_MONEY", function()
  if button and button:IsShown() then Tr.RefreshSoon() end
end)
M.On("TRAINER_CLOSED", function() if button then button:Hide() end end)
