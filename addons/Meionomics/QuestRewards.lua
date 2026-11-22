-- Quest reward choices: what each choice is worth to this character (P.BestAction: vendor,
-- disenchant only with our Enchanting, AH unless soulbound, craft) in a dark box under the
-- rewards, one A.Line row per choice with A.PriceLine under it. Best = an upgrade if any, else the most money. Our coin
-- marks the most money; RXPGuides' coin (its pick is the highest vendor price) is hidden so the
-- two never disagree. RXP's TOPRIGHT upgrade icon is left alone.
local _, M = ...
local P, A = M.Prices, M.Action
local Q = {}
M.QuestRewards = Q

local COIN = "Interface/GossipFrame/VendorGossipIcon.blp"
local PAD, GAP = 6, 2
local boxes = {}
local pending = {}

local function ItemID(link) return link and tonumber(link:match("item:(%d+)")) end

-- itemID, count, link (its random suffix) of choice i in the panel QuestInfo_Display just filled
local function Choice(i)
  if QuestInfoFrame.questLog then
    local _, _, count, _, _, id = GetQuestLogChoiceInfo(i)
    local link = GetQuestLogItemLink("choice", i)
    return id or ItemID(link), count, link
  end
  local _, _, count = GetQuestItemInfo("choice", i)
  local link = GetQuestItemLink("choice", i)
  return ItemID(link), count, link
end

local function NumChoices()
  if QuestInfoFrame.questLog then
    -- the quest map's details need the questID; vanilla's quest log takes none
    local questID = C_QuestLog.GetSelectedQuest and C_QuestLog.GetSelectedQuest()
    local ok, n = pcall(GetNumQuestLogChoices, questID, true)
    if not ok then ok, n = pcall(GetNumQuestLogChoices) end
    return ok and n or 0
  end
  return GetNumQuestChoices() or 0
end

local function Box(rewards)
  local b = boxes[rewards]
  if b then return b end
  b = CreateFrame("Frame", nil, rewards)
  b.bg = b:CreateTexture(nil, "BACKGROUND")
  b.bg:SetAllPoints()
  b.bg:SetColorTexture(0, 0, 0, 0.75)
  b.rows = {}
  b.coin = CreateFrame("Frame", nil, rewards)
  b.coin:SetSize(20, 20)
  b.coin.tex = b.coin:CreateTexture(nil, "OVERLAY")
  b.coin.tex:SetAllPoints()
  b.coin.tex:SetTexture(COIN)
  boxes[rewards] = b
  return b
end

local function Row(b, i)
  local r = b.rows[i]
  if r then return r end
  r = {}
  r.left = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  r.left:SetJustifyH("LEFT")
  r.right = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  r.right:SetJustifyH("RIGHT")
  r.price = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  r.price:SetJustifyH("LEFT")
  b.rows[i] = r
  return r
end

-- RXP's coin: a 20x20 texture at BOTTOMRIGHT of a reward button, in an unnamed child frame
local function HideRXPCoin(button, ours)
  for _, child in ipairs({ button:GetChildren() }) do
    if child ~= ours and not child:GetName() then
      for _, region in ipairs({ child:GetRegions() }) do
        if region:IsObjectType("Texture") and region:IsShown()
          and region:GetPoint(1) == "BOTTOMRIGHT" then
          child:Hide()
        end
      end
    end
  end
end

local function Label(id, count, best)
  local name, _, quality = C_Item.GetItemInfo(id)
  local color = ITEM_QUALITY_COLORS[quality or 1] or ITEM_QUALITY_COLORS[1]
  local text = color.hex .. (name or "?") .. "|r"
  if (count or 1) > 1 then text = text .. " x" .. count end
  return (best and ("|cff" .. A.LABEL .. "Best:|r ") or "") .. text .. "  "
end

function Q.Update()
  local rewards = QuestInfoFrame.rewardsFrame
  local b = rewards and boxes[rewards]
  if b then b:Hide(); b.coin:Hide() end
  local n = NumChoices()
  if not (rewards and rewards:IsShown()) or n < 2 then return end

  local choices, money, best = {}, nil, nil
  for i = 1, n do
    local id, count, link = Choice(i)
    local bind = id and select(14, C_Item.GetItemInfo(id))
    local act = id and P.BestAction(id, bind == 1, link)
    if id and not act then pending[id] = true end
    local c = { id = id, count = count or 1, act = act,
      button = rewards.RewardButtons and rewards.RewardButtons[i] }
    c.money = act and (act.sale.value or 0) * c.count or 0
    choices[i] = c
    if c.money > 0 and (not money or c.money > choices[money].money) then money = i end
    if not best and act and act.verb == "equip" then best = i end
  end
  best = best or money

  b = Box(rewards)
  local width = rewards:GetWidth()
  b:SetWidth(width)
  local y = -PAD
  for i, c in ipairs(choices) do
    local r = Row(b, i)
    local left, right
    if c.act then
      left, right = A.Line(c.act, { label = Label(c.id, c.count, i == best), count = c.count,
        prices = true })
    else
      left = Label(c.id or 0, c.count, false) .. "|cff8a8a8a(loading)|r"
    end
    r.right:SetText(right or "")
    r.right:ClearAllPoints()
    r.right:SetPoint("TOPRIGHT", b, "TOPRIGHT", -PAD, y)
    r.left:SetText(left)
    r.left:ClearAllPoints()
    r.left:SetPoint("TOPLEFT", b, "TOPLEFT", PAD, y)
    r.left:SetWidth(width - 2 * PAD - (right and r.right:GetStringWidth() + 6 or 0))
    r.left:Show(); r.right:Show()
    y = y - r.left:GetStringHeight()
    local prices = c.act and A.PriceLine(c.act, { count = c.count, under = true })
    r.price:SetText(prices or "")
    r.price:ClearAllPoints()
    r.price:SetPoint("TOPLEFT", b, "TOPLEFT", PAD + 10, y - 1)
    r.price:SetShown(prices ~= nil)
    if prices then y = y - 1 - r.price:GetStringHeight() end
    y = y - GAP - 2
  end
  for i = #choices + 1, #b.rows do
    local r = b.rows[i]
    r.left:Hide(); r.right:Hide(); r.price:Hide()
  end
  local h = -y - GAP - 2 + PAD

  -- grow the rewards frame so what follows (spacer, scroll extent) makes room for the box
  local top = rewards:GetHeight()
  rewards:SetHeight(top + 8 + h)
  b:ClearAllPoints()
  b:SetPoint("TOPLEFT", rewards, "TOPLEFT", 0, -(top + 8))
  b:SetHeight(h)
  b:Show()

  local pick = money and choices[money].button
  if pick then
    b.coin:SetParent(pick)
    b.coin:SetFrameLevel(pick:GetFrameLevel() + 2)
    b.coin:ClearAllPoints()
    b.coin:SetPoint("BOTTOMRIGHT", pick, "BOTTOMRIGHT", 0, 0)
    b.coin:Show()
  end
  -- RXP draws its coin on QUEST_COMPLETE / SelectQuestLogEntry, which may run after us
  C_Timer.After(0, function()
    for _, c in ipairs(choices) do
      if c.button then HideRXPCoin(c.button, b.coin) end
    end
  end)
end

hooksecurefunc("QuestInfo_Display", Q.Update)

M.On("GET_ITEM_INFO_RECEIVED", function(_, id)
  if not pending[id] then return end
  pending[id] = nil
  local rewards = QuestInfoFrame and QuestInfoFrame.rewardsFrame
  if rewards and rewards:IsVisible() then
    -- undo our growth before Update measures the frame again
    local b = boxes[rewards]
    if b and b:IsShown() then rewards:SetHeight(rewards:GetHeight() - 8 - b:GetHeight()) end
    Q.Update()
  end
end)
