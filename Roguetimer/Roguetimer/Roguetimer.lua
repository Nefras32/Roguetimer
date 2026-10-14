-- Roguetimer 0.1
-- Rogue timers for the Forever WoW 1.60 client (Interface 16001).
-- Starts finisher timers from successful spellcast events.

local MAXTIME = 30
local BAR_TEX = "Interface\\Buttons\\WHITE8X8"
local RUPTURE_SHADES = {
  { 1.00, 0.08, 0.08, 0.58 },
  { 0.78, 0.02, 0.16, 0.72 },
  { 0.92, 0.22, 0.04, 0.58 },
  { 0.58, 0.04, 0.06, 0.82 },
  { 1.00, 0.32, 0.28, 0.48 },
}

-- Identify spells by icon path (language-independent).
-- finisher consumes combo points; scaled duration depends on combo points.
local DEFS = {
  { key = "SND", tex = "Ability_Rogue_SliceDice", spellIDs = { 5171, 6774 }, color = { 1.00, 0.85, 0.10 }, finisher = true, scaled = true },
  { key = "RUP", tex = "Ability_Rogue_Rupture", spellIDs = { 1943, 8639, 8640, 11273, 11274, 11275 }, color = { 1.00, 0.30, 0.30 }, finisher = true, scaled = true },
  { key = "EXP", tex = "Ability_Warrior_Riposte", spellIDs = { 8647, 8649, 8650, 11197, 11198 }, color = { 0.45, 0.55, 0.80 }, finisher = true, scaled = true },
  { key = "GAR", tex = "Ability_Rogue_Garrote", spellIDs = { 703, 8631, 8632, 8633, 11289, 11290, 26839, 26884 }, color = { 0.55, 0.05, 0.05 }, fixed = 18, finisher = true },
}

local DEFAULTS = {
  width = 220,
  height = 18,
  spacing = 4,
  locked = true,
  showInactive = true,
}

local FB = {
  timers = {},      -- timers[targetName][key] = { start, dur }
  defByKey = {},
  bars = {},
  sndBonus = 0,
  sndTalentPoints = 0,
  options = {},
  pendingCP = 0,
  pendingTarget = nil,
  lastTargetKey = nil,
  targetGeneration = 0,
  inBattleground = false,
  debugSnd = false,
}
for _, d in ipairs(DEFS) do FB.defByKey[d.key] = d end

-- Finisher durations are calculated from combo points captured before the cast.
local function Duration(def, cp)
  cp = math.max(0, math.min(5, cp or 0))
  if def.key == "SND" then return (6 + 3 * cp) * (1 + FB.sndBonus)
  elseif def.key == "RUP" then return 6 + 2 * cp
  elseif def.key == "EXP" then return 30
  else return def.fixed end
end

------------------------------------------------------------
-- Helpers
------------------------------------------------------------
local function IsSecretValue(value)
  return type(issecretvalue) == "function" and issecretvalue(value)
end

local function GetCP()
  if type(UnitPower) == "function" then
    local comboPointPower = Enum and Enum.PowerType and Enum.PowerType.ComboPoints or 4
    local value = UnitPower("player", comboPointPower)
    if not IsSecretValue(value) and type(value) == "number" then return value end
    return 0
  end
  if type(GetComboPoints) == "function" then
    local value = GetComboPoints("player", "target")
    if not IsSecretValue(value) and type(value) == "number" then return value end
  end
  return 0
end

local function SafeUnitExists(unit)
  if type(UnitExists) ~= "function" then return false end
  local exists = UnitExists(unit)
  if IsSecretValue(exists) then return false end
  return exists == true
end

local function UnitTimerKey(unit)
  if unit == "player" then return "player" end
  if type(UnitGUID) == "function" then
    local guid = UnitGUID(unit)
    if not IsSecretValue(guid) and type(guid) == "string" and guid ~= "" then
      return guid
    end
  end
  return "target:" .. FB.targetGeneration
end

local function IsInBattleground()
  if type(_G.IsInBattleground) == "function" then
    local inBattleground = _G.IsInBattleground()
    if not IsSecretValue(inBattleground) then
      return inBattleground == true
    end
  end
  if type(IsInInstance) == "function" then
    local inInstance, instanceType = IsInInstance()
    if not IsSecretValue(inInstance) and inInstance == true
      and not IsSecretValue(instanceType) then
      return instanceType == "pvp"
    end
  end
  return false
end

local function TrackComboPoints()
  local targetKey
  if SafeUnitExists("target") then
    targetKey = UnitTimerKey("target")
  end
  FB.lastTargetKey = targetKey
  if targetKey ~= FB.pendingTarget then
    FB.pendingTarget = targetKey
    FB.pendingCP = 0
  end
  local cp = GetCP()
  if cp > 0 then FB.pendingCP = cp end
end

local function DebugInitialization()
  if not FB.debugSnd or not DEFAULT_CHAT_FRAME
    or type(DEFAULT_CHAT_FRAME.AddMessage) ~= "function" then
    return
  end
  local count = #FB.bars
  local shown = 0
  local states = {}
  for _, bar in ipairs(FB.bars) do
    local isShown = type(bar.IsShown) == "function" and bar:IsShown() or false
    if isShown then shown = shown + 1 end
    table.insert(states, tostring(bar.def.key) .. "=" .. tostring(isShown))
  end
  DEFAULT_CHAT_FRAME:AddMessage(string.format(
    "Roguetimer init: initialized=true anchorShown=%s barsCreated=%d barsShown=%d sndTalentPoints=%d {%s}",
    tostring(FB.anchor and FB.anchor:IsShown() or false),
    count, shown, FB.sndTalentPoints, table.concat(states, ",")))
end

local function ScanTalents()
  FB.sndBonus = 0
  FB.sndTalentPoints = 0
  if type(GetNumTalents) == "function" and type(GetTalentInfo) == "function" then
    for tab = 1, 3 do
      local count = GetNumTalents(tab)
      if type(count) == "number" then
        for i = 1, count do
          local _, icon, _, _, rank = GetTalentInfo(tab, i)
          if type(icon) == "string"
            and string.find(string.lower(icon), "ability_rogue_slicedice", 1, true)
            and type(rank) == "number" then
            FB.sndTalentPoints = rank
          end
        end
      end
    end
  end

  if FB.sndTalentPoints == 0 and C_ClassTalents and C_Traits
    and type(C_ClassTalents.GetActiveConfigID) == "function"
    and type(C_Traits.GetConfigInfo) == "function"
    and type(C_Traits.GetTreeNodes) == "function"
    and type(C_Traits.GetNodeInfo) == "function"
    and type(C_Traits.GetEntryInfo) == "function"
    and type(C_Traits.GetDefinitionInfo) == "function" then
    local talentSpellIDs = { [14179] = true, [14183] = true, [14184] = true }
    local configID = C_ClassTalents.GetActiveConfigID()
    local function IsValidID(value)
      return type(value) == "number" and value >= 1 and value <= 2147483647
        and value == math.floor(value)
    end
    local configInfo
    if IsValidID(configID) then
      configInfo = C_Traits.GetConfigInfo(configID)
    end
    for _, treeID in ipairs(configInfo and configInfo.treeIDs or {}) do
      if IsValidID(treeID) then
        for _, nodeID in ipairs(C_Traits.GetTreeNodes(treeID) or {}) do
          if IsValidID(nodeID) then
            local nodeInfo = C_Traits.GetNodeInfo(configID, nodeID)
            if nodeInfo and IsValidID(nodeInfo.activeEntry)
              and type(nodeInfo.ranksPurchased) == "number" then
              local entryInfo = C_Traits.GetEntryInfo(configID, nodeInfo.activeEntry)
              local definitionInfo = entryInfo and IsValidID(entryInfo.definitionID)
                and C_Traits.GetDefinitionInfo(entryInfo.definitionID)
              if definitionInfo and talentSpellIDs[definitionInfo.spellID] then
                FB.sndTalentPoints = nodeInfo.ranksPurchased
              end
            end
          end
        end
      end
    end
  end
  FB.sndBonus = FB.sndTalentPoints * 0.15
end

local function TrackFinisherCast(unit, castGUID, spellID)
  if unit ~= "player" then return end
  local def
  for _, candidate in ipairs(DEFS) do
    if candidate.finisher then
      for _, knownSpellID in ipairs(candidate.spellIDs or {}) do
        if spellID == knownSpellID then
          def = candidate
          break
        end
      end
    end
    if def then break end
  end
  if not def then return end

  local cp = FB.pendingCP
  if type(cp) ~= "number" or cp < 1 then cp = GetCP() end
  cp = math.max(1, math.min(5, cp or 1))
  local now = GetTime()
  local key
  if def.key == "SND" then
    key = UnitTimerKey("player")
  else
    key = FB.lastTargetKey
  end
  if not key then return end

  FB.timers[key] = FB.timers[key] or {}
  local duration = Duration(def, cp)
  FB.timers[key][def.key] = {
    start = now,
    dur = duration,
    source = "UNIT_SPELLCAST_SUCCEEDED",
  }
  FB.pendingCP = 0
  if FB.debugSnd and DEFAULT_CHAT_FRAME and DEFAULT_CHAT_FRAME.AddMessage then
    local expiration = now + duration
    DEFAULT_CHAT_FRAME:AddMessage(string.format(
      "Roguetimer %s: castConfirmed=true comboPoints=%d duration=%.1f expiration=%.1f remaining=%.1f",
      def.key, cp, duration, expiration, math.max(0, expiration - GetTime())))
  end
end

------------------------------------------------------------
-- UI
------------------------------------------------------------
local function Layout()
  local db = RoguetimerDB
  local W, H, S = db.width, db.height, db.spacing
  FB.anchor:SetWidth(W + H + 3)
  FB.anchor:SetHeight(4 * (H + S))
  for i, f in ipairs(FB.bars) do
    f:SetWidth(W); f:SetHeight(H)
    f:ClearAllPoints()
    f:SetPoint("TOPLEFT", FB.anchor, "TOPLEFT", H + 3, -(i - 1) * (H + S))
    f.icon:SetWidth(H); f.icon:SetHeight(H)
    f.ghost:SetHeight(H); f.fill:SetHeight(H)
    if f.ruptureCurrentFill then f.ruptureCurrentFill:SetHeight(H) end
    for _, layer in ipairs(f.ruptureLayers or {}) do
      layer:SetHeight(H)
    end
    f.text:SetFont(STANDARD_TEXT_FONT or "Fonts\\FRIZQT__.TTF", math.max(8, H - 6), "OUTLINE")
  end
  FB.anchor:EnableMouse(not db.locked)
  if type(FB.anchor.RegisterForDrag) == "function" then
    FB.anchor:RegisterForDrag("LeftButton")
  end
  if db.locked then FB.anchor.tint:Hide() else FB.anchor.tint:Show() end
  for _, bar in ipairs(FB.bars) do
    bar:EnableMouse(not db.locked)
    if type(bar.RegisterForDrag) == "function" then
      bar:RegisterForDrag("LeftButton")
    end
  end
  FB.anchor:Show()
end

local UpdateBars

local function BuildUI()
  local db = RoguetimerDB
  local a = CreateFrame("Frame", "RoguetimerAnchor", UIParent)
  FB.anchor = a
  a:SetMovable(true)
  a:SetClampedToScreen(true)
  if db.x and db.y then
    a:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", db.x, db.y)
  else
    a:SetPoint("CENTER", UIParent, "CENTER", 0, -150)
  end
  a.tint = a:CreateTexture(nil, "BACKGROUND")
  a.tint:SetTexture(BAR_TEX)
  a.tint:SetVertexColor(0.2, 0.6, 1, 0.25)
  a.tint:SetAllPoints(a)
  if type(a.RegisterForDrag) == "function" then a:RegisterForDrag("LeftButton") end
  a:SetScript("OnDragStart", function()
    if not RoguetimerDB.locked then a:StartMoving() end
  end)
  local function SaveAnchorPosition()
    a:StopMovingOrSizing()
    local x, y = a:GetLeft(), a:GetTop()
    if x and y then
      RoguetimerDB.x, RoguetimerDB.y = x, y
      a:ClearAllPoints()
      a:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", x, y)
    end
  end
  a:SetScript("OnDragStop", SaveAnchorPosition)

  for i, def in ipairs(DEFS) do
    local c = def.color
    local f = CreateFrame("Frame", nil, a)
    f.def = def
    if not f.bg then
      f.bg = f:CreateTexture(nil, "BACKGROUND")
      f.bg:SetTexture(BAR_TEX)
      f.bg:SetVertexColor(0.035, 0.045, 0.06, 0.9)
      f.bg:SetAllPoints(f)
    end
    f:SetScript("OnDragStart", function()
      if not RoguetimerDB.locked then a:StartMoving() end
    end)
    f:SetScript("OnDragStop", SaveAnchorPosition)
    f.ghost = f:CreateTexture(nil, "BORDER")
    f.ghost:SetTexture(BAR_TEX); f.ghost:SetVertexColor(c[1], c[2], c[3], 0.35)
    f.ghost:SetPoint("TOPLEFT", f, "TOPLEFT", 0, 0)
    f.fill = f:CreateTexture(nil, "ARTWORK")
    f.fill:SetTexture(BAR_TEX); f.fill:SetVertexColor(c[1], c[2], c[3], 0.78)
    f.fill:SetPoint("TOPLEFT", f, "TOPLEFT", 0, 0)
    if def.key == "RUP" then
      f.ruptureLayers = {}
      f.ruptureCurrentFill = f:CreateTexture(nil, "ARTWORK")
      f.ruptureCurrentFill:SetTexture(BAR_TEX)
      f.ruptureCurrentFill:SetVertexColor(1, 0.12, 0.12, 1)
      f.ruptureCurrentFill:SetPoint("TOPLEFT", f, "TOPLEFT", 0, 0)
      f.ruptureCurrentFill:SetHeight(db.height)
      f.ruptureCurrentFill:Hide()
    end
    f.icon = f:CreateTexture(nil, "ARTWORK")
    f.icon:SetTexture("Interface\\Icons\\" .. def.tex)
    f.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
    f.icon:SetPoint("RIGHT", f, "LEFT", -3, 0)
    f.text = f:CreateFontString(nil, "OVERLAY")
    f.text:SetFont(STANDARD_TEXT_FONT or "Fonts\\FRIZQT__.TTF", 12, "OUTLINE")
    f.text:SetJustifyH("RIGHT")
    f.text:SetPoint("RIGHT", f, "RIGHT", -4, 0)
    f:Show()
    FB.bars[i] = f
  end
  Layout()
  a:Show()
end

local function SetOptionText(region, text, size, color)
  region:SetFont(FB.optionFont or STANDARD_TEXT_FONT or "Fonts\\FRIZQT__.TTF", size or 12, "OUTLINE")
  region:SetText(text)
  if color then region:SetTextColor(color[1], color[2], color[3]) end
end

local function CreatePanelButton(parent, text, width, height)
  local button = CreateFrame("Button", nil, parent)
  button:SetWidth(width)
  button:SetHeight(height)
  button.fill = button:CreateTexture(nil, "BACKGROUND")
  button.fill:SetTexture(BAR_TEX)
  button.fill:SetVertexColor(0.12, 0.16, 0.22, 0.95)
  button.fill:SetAllPoints(button)
  button.label = button:CreateFontString(nil, "OVERLAY")
  button.label:SetPoint("CENTER", button, "CENTER", 0, 0)
  SetOptionText(button.label, text, 12, { 0.95, 0.82, 0.48 })
  button:SetScript("OnEnter", function()
    button.fill:SetVertexColor(0.27, 0.20, 0.10, 1)
    button.label:SetTextColor(1, 0.92, 0.68)
  end)
  button:SetScript("OnLeave", function()
    button.fill:SetVertexColor(0.12, 0.16, 0.22, 0.95)
    button.label:SetTextColor(0.95, 0.82, 0.48)
  end)
  return button
end

local function CreateOptions()
  local panel = CreateFrame("Frame", "RoguetimerOptions", UIParent)
  FB.options = panel
  FB.optionFont = STANDARD_TEXT_FONT or "Fonts\\FRIZQT__.TTF"
  panel:SetWidth(350)
  panel:SetHeight(520)
  panel:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
  panel:SetFrameStrata("DIALOG")
  panel:EnableMouse(true)
  panel:SetMovable(true)
  panel:RegisterForDrag("LeftButton")
  panel:SetScript("OnDragStart", function(self) self:StartMoving() end)
  panel:SetScript("OnDragStop", function(self) self:StopMovingOrSizing() end)
  panel.background = panel:CreateTexture(nil, "BACKGROUND")
  panel.background:SetTexture(BAR_TEX)
  panel.background:SetVertexColor(0.025, 0.035, 0.055, 0.98)
  panel.background:SetAllPoints(panel)
  if type(panel.SetBackdrop) == "function" then
    panel:SetBackdrop({
      bgFile = BAR_TEX,
      edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
      tile = true,
      tileSize = 16,
      edgeSize = 14,
      insets = { left = 4, right = 4, top = 4, bottom = 4 },
    })
    panel:SetBackdropColor(0.025, 0.035, 0.055, 0.97)
    panel:SetBackdropBorderColor(0.72, 0.48, 0.16, 1)
  end

  local title = panel:CreateFontString(nil, "OVERLAY")
  title:SetPoint("TOPLEFT", panel, "TOPLEFT", 20, -17)
  SetOptionText(title, "ROGUETIMER", 19, { 1, 0.78, 0.32 })
  local subtitle = panel:CreateFontString(nil, "OVERLAY")
  subtitle:SetPoint("TOPLEFT", panel, "TOPLEFT", 21, -44)
  SetOptionText(subtitle, "COMBAT TIMERS  /  DISPLAY SETTINGS", 9, { 0.62, 0.72, 0.82 })

  local headerRule = panel:CreateTexture(nil, "ARTWORK")
  headerRule:SetTexture(BAR_TEX)
  headerRule:SetVertexColor(0.72, 0.48, 0.16, 0.9)
  headerRule:SetHeight(1)
  headerRule:SetPoint("TOPLEFT", panel, "TOPLEFT", 20, -62)
  headerRule:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -20, -62)

  local close = CreatePanelButton(panel, "X", 25, 25)
  close:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -15, -14)
  close.label:SetFont(STANDARD_TEXT_FONT or "Fonts\\FRIZQT__.TTF", 14, "OUTLINE")
  close.label:SetTextColor(0.88, 0.72, 0.68)
  close:SetScript("OnEnter", function()
    close.fill:SetVertexColor(0.48, 0.12, 0.12, 1)
    close.label:SetTextColor(1, 0.9, 0.88)
  end)
  close:SetScript("OnLeave", function()
    close.fill:SetVertexColor(0.12, 0.16, 0.22, 0.95)
    close.label:SetTextColor(0.88, 0.72, 0.68)
  end)
  close:SetScript("OnClick", function() panel:Hide() end)

  local function AddSectionHeading(text, y)
    local heading = panel:CreateFontString(nil, "OVERLAY")
    heading:SetPoint("TOPLEFT", panel, "TOPLEFT", 21, y)
    SetOptionText(heading, text, 10, { 1, 0.78, 0.32 })
    local rule = panel:CreateTexture(nil, "ARTWORK")
    rule:SetTexture(BAR_TEX)
    rule:SetVertexColor(0.28, 0.34, 0.42, 0.65)
    rule:SetHeight(1)
    rule:SetPoint("LEFT", heading, "RIGHT", 10, -3)
    rule:SetPoint("RIGHT", panel, "RIGHT", -20, -3)
  end

  AddSectionHeading("TRACKED TIMERS", -76)

  local function AddToggle(label, y, getValue, setValue, icon)
    local row = CreatePanelButton(panel, "", 314, 27)
    row:SetPoint("TOPLEFT", panel, "TOPLEFT", 18, y)
    row.icon = row:CreateTexture(nil, "ARTWORK")
    row.icon:SetWidth(20)
    row.icon:SetHeight(20)
    row.icon:SetPoint("LEFT", row, "LEFT", 6, 0)
    row.icon:SetTexture("Interface\\Icons\\" .. (icon or "Ability_Warrior_Riposte"))
    row.label = row:CreateFontString(nil, "OVERLAY")
    row.label:SetPoint("LEFT", row, "LEFT", 32, 0)
    SetOptionText(row.label, label, 11, { 0.91, 0.93, 0.97 })
    row.state = row:CreateFontString(nil, "OVERLAY")
    row.state:SetPoint("RIGHT", row, "RIGHT", -8, 0)
    local function Refresh()
      if getValue() then
        SetOptionText(row.state, "ON", 10, { 0.95, 0.82, 0.48 })
      else
        SetOptionText(row.state, "OFF", 10, { 0.72, 0.48, 0.45 })
      end
    end
    row:SetScript("OnClick", function()
      setValue(not getValue())
      Refresh()
      UpdateBars()
    end)
    row.Refresh = Refresh
    Refresh()
    return row
  end

  for index, def in ipairs(DEFS) do
    RoguetimerDB.bars[def.key] = RoguetimerDB.bars[def.key] ~= false
    AddToggle(def.key .. "  -  " .. ({
      SND = "Slice and Dice",
      RUP = "Rupture",
      GAR = "Garrote",
      EXP = "Expose Armor",
    })[def.key], -96 - (index - 1) * 30,
      function() return RoguetimerDB.bars[def.key] end,
      function(value) RoguetimerDB.bars[def.key] = value end,
      def.tex)
  end

  AddSectionHeading("DISPLAY & SIZE", -226)
  AddToggle("Hide bars without an active timer", -246,
    function() return not RoguetimerDB.showInactive end,
    function(value) RoguetimerDB.showInactive = not value end,
    "INV_Misc_PocketWatch_01")

  local function AddSizeControl(label, y, key, minimum, maximum, step)
    local text = panel:CreateFontString(nil, "OVERLAY")
    text:SetPoint("TOPLEFT", panel, "TOPLEFT", 24, y)
    SetOptionText(text, label, 11, { 0.84, 0.88, 0.94 })
    local value = panel:CreateFontString(nil, "OVERLAY")
    value:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -64, y)
    SetOptionText(value, tostring(RoguetimerDB[key]), 11, { 1, 0.78, 0.32 })
    local minus = CreatePanelButton(panel, "-", 24, 22)
    minus:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -42, y + 4)
    local plus = CreatePanelButton(panel, "+", 24, 22)
    plus:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -14, y + 4)
    local function Adjust(direction)
      RoguetimerDB[key] = math.max(minimum, math.min(maximum, RoguetimerDB[key] + step * direction))
      value:SetText(tostring(RoguetimerDB[key]))
      Layout()
      UpdateBars()
    end
    minus:SetScript("OnClick", function() Adjust(-1) end)
    plus:SetScript("OnClick", function() Adjust(1) end)
  end

  AddSizeControl("Bar width", -286, "width", 100, 420, 20)
  AddSizeControl("Bar height", -316, "height", 12, 36, 2)

  AddSectionHeading("BAR POSITION", -356)
  local lock = CreatePanelButton(panel, "", 274, 26)
  lock:SetWidth(314)
  lock:SetPoint("TOPLEFT", panel, "TOPLEFT", 18, -376)
  lock.label:SetText("")
  lock.status = lock:CreateFontString(nil, "OVERLAY")
  lock.status:SetPoint("CENTER", lock, "CENTER", 0, 0)
  local function RefreshLock()
    local label = RoguetimerDB.locked and "Position locked" or "Drag bars to move"
    SetOptionText(lock.status, label, 11, { 0.9, 0.82, 0.61 })
  end
  lock:SetScript("OnClick", function()
    RoguetimerDB.locked = not RoguetimerDB.locked
    RefreshLock()
    Layout()
    UpdateBars()
  end)
  RefreshLock()

  local function SetAnchorPosition(x, y)
    RoguetimerDB.x, RoguetimerDB.y = x, y
    FB.anchor:ClearAllPoints()
    FB.anchor:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", x, y)
  end

  local function CenterAnchor(axis)
    local screenWidth, screenHeight = UIParent:GetWidth(), UIParent:GetHeight()
    local anchorWidth, anchorHeight = FB.anchor:GetWidth(), FB.anchor:GetHeight()
    local x = FB.anchor:GetLeft() or (screenWidth - anchorWidth) / 2
    local y = FB.anchor:GetTop() or (screenHeight + anchorHeight) / 2 - 150
    if axis == "horizontal" then
      x = (screenWidth - anchorWidth) / 2
    else
      y = (screenHeight + anchorHeight) / 2
    end
    SetAnchorPosition(x, y)
  end

  local centerVertical = CreatePanelButton(panel, "CENTER VERTICALLY", 152, 27)
  centerVertical:SetPoint("TOPLEFT", panel, "TOPLEFT", 18, -416)
  centerVertical.label:SetFont(FB.optionFont, 10, "OUTLINE")
  centerVertical:SetScript("OnClick", function() CenterAnchor("vertical") end)

  local centerHorizontal = CreatePanelButton(panel, "CENTER HORIZONTALLY", 152, 27)
  centerHorizontal:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -18, -416)
  centerHorizontal.label:SetFont(FB.optionFont, 10, "OUTLINE")
  centerHorizontal:SetScript("OnClick", function() CenterAnchor("horizontal") end)

  local resetPosition = CreatePanelButton(panel, "RESET BAR POSITION", 314, 27)
  resetPosition:SetPoint("TOPLEFT", panel, "TOPLEFT", 18, -450)
  resetPosition:SetScript("OnClick", function()
    RoguetimerDB.x, RoguetimerDB.y = nil, nil
    FB.anchor:ClearAllPoints()
    FB.anchor:SetPoint("CENTER", UIParent, "CENTER", 0, -100)
  end)
  local footer = panel:CreateFontString(nil, "OVERLAY")
  footer:SetPoint("BOTTOM", panel, "BOTTOM", 0, 18)
  SetOptionText(footer, "Changes apply immediately", 9, { 0.55, 0.62, 0.7 })
  panel:Hide()

  if Minimap then
    local button = CreateFrame("Button", "RoguetimerMinimapButton", Minimap)
    FB.minimapButton = button
    button:SetWidth(32)
    button:SetHeight(32)
    button:SetMovable(true)
    button:RegisterForDrag("LeftButton")
    button:SetFrameStrata("MEDIUM")
    if type(button.SetFrameLevel) == "function"
      and type(Minimap.GetFrameLevel) == "function" then
      button:SetFrameLevel(Minimap:GetFrameLevel() + 8)
    end
    if type(button.SetClampedToScreen) == "function" then
      button:SetClampedToScreen(true)
    end
    button.icon = button:CreateTexture(nil, "ARTWORK")
    button.icon:SetTexture("Interface\\Icons\\Ability_Warrior_Riposte")
    button.icon:SetWidth(20)
    button.icon:SetHeight(20)
    button.icon:SetPoint("CENTER", button, "CENTER", 0, 0)
    button.border = button:CreateTexture(nil, "OVERLAY")
    button.border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
    button.border:SetWidth(54)
    button.border:SetHeight(54)
    button.border:SetPoint("TOPLEFT", button, "TOPLEFT", 0, 0)
    local function PositionMinimapButton(angle)
      angle = angle or RoguetimerDB.minimapAngle or 220
      RoguetimerDB.minimapAngle = angle
      local radians = angle * math.pi / 180
      local minimapWidth = type(Minimap.GetWidth) == "function" and Minimap:GetWidth() or 140
      local minimapHeight = type(Minimap.GetHeight) == "function" and Minimap:GetHeight() or minimapWidth
      local radiusX = minimapWidth / 2 + 5
      local radiusY = minimapHeight / 2 + 5
      local shape = type(GetMinimapShape) == "function" and GetMinimapShape() or "ROUND"
      local x, y
      if shape == "ROUND" then
        x, y = math.cos(radians) * radiusX, math.sin(radians) * radiusY
      else
        local diagonalX = math.sqrt(2 * radiusX * radiusX)
        local diagonalY = math.sqrt(2 * radiusY * radiusY)
        x = math.max(-radiusX, math.min(math.cos(radians) * diagonalX, radiusX))
        y = math.max(-radiusY, math.min(math.sin(radians) * diagonalY, radiusY))
      end
      button:ClearAllPoints()
      button:SetPoint("CENTER", Minimap, "CENTER",
        x, y)
    end
    local function UpdateMinimapButtonPosition()
      if type(GetCursorPosition) ~= "function"
        or type(Minimap.GetCenter) ~= "function"
        or type(Minimap.GetEffectiveScale) ~= "function" then
        return
      end

      local x, y = GetCursorPosition()
      local mx, my = Minimap:GetCenter()
      local scale = Minimap:GetEffectiveScale()
      local dx, dy = x / scale - mx, y / scale - my
      local angle
      if type(math.atan2) == "function" then
        angle = math.atan2(dy, dx) * 180 / math.pi
      elseif dx > 0 then
        angle = math.atan(dy / dx) * 180 / math.pi
      elseif dx < 0 then
        angle = math.atan(dy / dx) * 180 / math.pi + 180
      elseif dy > 0 then
        angle = 90
      else
        angle = -90
      end
      PositionMinimapButton(angle)
    end
    local dragging = false
    button:SetScript("OnDragStart", function()
      dragging = true
    end)
    button:SetScript("OnUpdate", function()
      if dragging then UpdateMinimapButtonPosition() end
    end)
    button:SetScript("OnDragStop", function()
      dragging = false
      UpdateMinimapButtonPosition()
    end)
    PositionMinimapButton()
    button:SetScript("OnClick", function()
      if panel:IsShown() then panel:Hide() else panel:Show() end
    end)
    button:SetScript("OnEnter", function()
      if GameTooltip then
        GameTooltip:SetOwner(button, "ANCHOR_LEFT")
        GameTooltip:AddLine("Roguetimer", 1, 0.78, 0.32)
        GameTooltip:AddLine("Click to open options", 0.85, 0.88, 0.94)
        GameTooltip:Show()
      end
    end)
    button:SetScript("OnLeave", function()
      if GameTooltip then GameTooltip:Hide() end
    end)
  end
end

UpdateBars = function()
  local db = RoguetimerDB
  if FB.inBattleground then
    FB.anchor:Hide()
    return
  end
  local now = GetTime()
  local W = db.width
  local cp = GetCP()
  local targetExists = SafeUnitExists("target")
  local targetIsDead = false
  if targetExists and type(UnitIsDeadOrGhost) == "function" then
    local isDead = UnitIsDeadOrGhost("target")
    if not IsSecretValue(isDead) and isDead == true then targetIsDead = true end
  end
  if targetExists and not targetIsDead and type(UnitIsDead) == "function" then
    local isDead = UnitIsDead("target")
    if not IsSecretValue(isDead) and isDead == true then targetIsDead = true end
  end
  local targetAlive = targetExists and not targetIsDead
  local targetKey = targetExists and UnitTimerKey("target") or nil
  local activeRuptures = {}
  local currentTargetRupture

  if targetExists and not targetAlive and targetKey and FB.timers[targetKey] then
    FB.timers[targetKey].RUP = nil
    FB.timers[targetKey].GAR = nil
  end

  if targetAlive and targetKey and FB.timers[targetKey] then
    currentTargetRupture = FB.timers[targetKey].RUP
  end

  for unitKey, timers in pairs(FB.timers) do
    local timer = timers.RUP
    if timer and timer.start + timer.dur > now then
      table.insert(activeRuptures, {
        key = unitKey,
        timer = timer,
      })
    elseif timer then
      timers.RUP = nil
    end
  end
  table.sort(activeRuptures, function(a, b)
    return tostring(a.key) < tostring(b.key)
  end)

  for _, f in ipairs(FB.bars) do
    local def = f.def
    local remaining, ghost = 0, 0
    local enabled = db.bars[def.key] ~= false

    if def.key == "SND" then
      local playerKey = UnitTimerKey("player")
      if FB.timers[playerKey] and FB.timers[playerKey][def.key] then
        local timer = FB.timers[playerKey][def.key]
        remaining = math.max(0, timer.start + timer.dur - now)
      end
    elseif def.key == "RUP" and currentTargetRupture then
      remaining = math.max(0, currentTargetRupture.start + currentTargetRupture.dur - now)
    elseif targetKey and FB.timers[targetKey] and FB.timers[targetKey][def.key] then
      local tm = FB.timers[targetKey][def.key]
      remaining = tm.start + tm.dur - now
      if remaining < 0 then remaining = 0 end
    end
    if def.key ~= "GAR" and targetAlive and (not def.finisher or cp > 0) then
      ghost = Duration(def, cp)
    end

    if enabled and (remaining > 0 or ghost > 0 or db.showInactive or not db.locked) then
      f:Show()
      if f.bg then f.bg:Show() end
      local gw = math.min(ghost, MAXTIME) / MAXTIME * W
      local fw = math.min(remaining, MAXTIME) / MAXTIME * W
      if gw >= 1 then f.ghost:SetWidth(gw); f.ghost:Show() else f.ghost:Hide() end
      if def.key == "RUP" then
        f.fill:Hide()
        if f.ruptureCurrentFill then
          if targetAlive and remaining > 0 then
            f.ruptureCurrentFill:SetWidth(fw)
            f.ruptureCurrentFill:Show()
          else
            f.ruptureCurrentFill:Hide()
          end
        end
        local layerIndex = 0
        for _, rupture in ipairs(activeRuptures) do
          if rupture.timer ~= currentTargetRupture then
            layerIndex = layerIndex + 1
            local layer = f.ruptureLayers[layerIndex]
            if not layer then
              layer = f:CreateTexture(nil, "ARTWORK")
              layer:SetTexture(BAR_TEX)
              layer:SetPoint("TOPLEFT", f, "TOPLEFT", 0, 0)
              layer:SetHeight(f:GetHeight())
              f.ruptureLayers[layerIndex] = layer
            end
            local paletteIndex = (layerIndex - 1) % 5 + 1
            local shade = RUPTURE_SHADES[paletteIndex]
            layer:SetVertexColor(shade[1], shade[2], shade[3], shade[4])
            local layerWidth = math.min(
              rupture.timer.start + rupture.timer.dur - now, MAXTIME) / MAXTIME * W
            if layerWidth >= 1 then
              layer:SetWidth(layerWidth)
              layer:Show()
            else
              layer:Hide()
            end
          end
        end
        for i = layerIndex + 1, #f.ruptureLayers do
          f.ruptureLayers[i]:Hide()
        end
      elseif fw >= 1 then
        f.fill:SetWidth(fw)
        f.fill:Show()
      else
        f.fill:Hide()
      end
      local displayed = remaining > 0 and remaining or ghost
      if displayed > 0 then f.text:SetText(string.format("%.1f", displayed)) else f.text:SetText("") end
    else
      if def.key == "RUP" then
        f.fill:Hide()
        if f.ruptureCurrentFill then f.ruptureCurrentFill:Hide() end
        for _, layer in ipairs(f.ruptureLayers or {}) do layer:Hide() end
      end
      f:Hide()
    end
  end
end

------------------------------------------------------------
-- Events / update loop
------------------------------------------------------------
local ev = CreateFrame("Frame", "RoguetimerEvents", UIParent)
local function RegisterEvent(name)
  local ok = pcall(ev.RegisterEvent, ev, name)
  if not ok and DEFAULT_CHAT_FRAME and DEFAULT_CHAT_FRAME.AddMessage then
    DEFAULT_CHAT_FRAME:AddMessage("Roguetimer: client does not support event " .. name)
  end
end
RegisterEvent("ADDON_LOADED")
RegisterEvent("PLAYER_ENTERING_WORLD")
RegisterEvent("PLAYER_TARGET_CHANGED")
RegisterEvent("ZONE_CHANGED_NEW_AREA")
RegisterEvent("UNIT_SPELLCAST_SUCCEEDED")
RegisterEvent("PLAYER_TALENT_UPDATE")

local active = false

local function RefreshInstanceState()
  local inBattleground = IsInBattleground()
  if inBattleground == FB.inBattleground then return end
  FB.inBattleground = inBattleground
  if inBattleground then
    FB.timers = {}
    FB.pendingCP = 0
    FB.pendingTarget = nil
    FB.lastTargetKey = nil
    FB.anchor:Hide()
  else
    FB.anchor:Show()
    TrackComboPoints()
    UpdateBars()
  end
end

ev:SetScript("OnEvent", function(self, e, a1, ...)
  e = e or event
  a1 = a1 or arg1
  if e == "ADDON_LOADED" then
    if a1 ~= "Roguetimer" then return end
    RoguetimerDB = RoguetimerDB or {}
    if ForeverBarsDB then
      for k, v in pairs(ForeverBarsDB) do
        if RoguetimerDB[k] == nil then RoguetimerDB[k] = v end
      end
    end
    ForeverBarsDB = nil
    if type(RoguetimerDB.settingsVersion) ~= "number" or RoguetimerDB.settingsVersion < 1 then
      RoguetimerDB.locked = DEFAULTS.locked
      RoguetimerDB.settingsVersion = 1
    end
    if RoguetimerDB.settingsVersion < 2 then
      RoguetimerDB.showInactive = DEFAULTS.showInactive
      RoguetimerDB.settingsVersion = 2
    end
    if RoguetimerDB.settingsVersion < 3 then
      RoguetimerDB.locked = DEFAULTS.locked
      RoguetimerDB.settingsVersion = 3
    end
    for k, v in pairs(DEFAULTS) do
      if RoguetimerDB[k] == nil then RoguetimerDB[k] = v end
    end
    if type(RoguetimerDB.width) ~= "number" then RoguetimerDB.width = DEFAULTS.width end
    if type(RoguetimerDB.height) ~= "number" then RoguetimerDB.height = DEFAULTS.height end
    if type(RoguetimerDB.spacing) ~= "number" then RoguetimerDB.spacing = DEFAULTS.spacing end
    RoguetimerDB.width = math.max(100, math.min(420, RoguetimerDB.width))
    RoguetimerDB.height = math.max(12, math.min(36, RoguetimerDB.height))
    RoguetimerDB.spacing = math.max(0, math.min(20, RoguetimerDB.spacing))
    if type(RoguetimerDB.locked) ~= "boolean" then RoguetimerDB.locked = DEFAULTS.locked end
    if type(RoguetimerDB.showInactive) ~= "boolean" then RoguetimerDB.showInactive = DEFAULTS.showInactive end
    RoguetimerDB.showBackground = nil
    RoguetimerDB.backgroundAlpha = nil
    if type(RoguetimerDB.bars) ~= "table" then RoguetimerDB.bars = {} end
    for _, def in ipairs(DEFS) do
      if RoguetimerDB.bars[def.key] == nil then RoguetimerDB.bars[def.key] = true end
    end
    local _, class = UnitClass("player")
    if class ~= "ROGUE" then return end
    active = true
    BuildUI()
    CreateOptions()
    ScanTalents()
    RefreshInstanceState()
  elseif not active then
    return
  elseif e == "PLAYER_ENTERING_WORLD" then
    ScanTalents()
    RefreshInstanceState()
  elseif e == "ZONE_CHANGED_NEW_AREA" then
    RefreshInstanceState()
  elseif e == "PLAYER_TARGET_CHANGED" then
    if FB.inBattleground then return end
    FB.targetGeneration = FB.targetGeneration + 1
    FB.pendingCP = 0
    FB.pendingTarget = nil
    TrackComboPoints()
    UpdateBars()
  elseif e == "PLAYER_TALENT_UPDATE" then
    ScanTalents()
  elseif e == "UNIT_SPELLCAST_SUCCEEDED" then
    if FB.inBattleground then return end
    TrackFinisherCast(a1, ...)
  end
end)

ev:SetScript("OnUpdate", function(self, elapsed)
  if not active then return end
  if FB.inBattleground then return end
  TrackComboPoints()
  UpdateBars()
end)

------------------------------------------------------------
-- Slash commands
SLASH_ROGUETIMER1 = "/roguetimer"
SlashCmdList["ROGUETIMER"] = function(msg)
  if not active then return end
  local db = RoguetimerDB
  msg = string.lower(msg or "")
  local _, _, cmd, val = string.find(msg, "^(%S*)%s*(%S*)$")
  if cmd == "unlock" then db.locked = false; Layout(); UpdateBars()
  elseif cmd == "lock" then db.locked = true; Layout(); UpdateBars()
  elseif cmd == "debug" then
    FB.debugSnd = not FB.debugSnd
    DEFAULT_CHAT_FRAME:AddMessage("Roguetimer diagnostics " .. (FB.debugSnd and "enabled" or "disabled"))
    DebugInitialization()
  elseif cmd == "width" and tonumber(val) then db.width = tonumber(val); Layout()
  elseif cmd == "height" and tonumber(val) then db.height = tonumber(val); Layout()
  elseif cmd == "options" then
    FB.options:Show()
  elseif cmd == "reset" or cmd == "center" then
    db.x, db.y = nil, nil
    FB.anchor:ClearAllPoints()
    FB.anchor:SetPoint("CENTER", UIParent, "CENTER", 0, -100)
  else
    DEFAULT_CHAT_FRAME:AddMessage("Roguetimer: /roguetimer options | unlock | lock | debug | width N | height N | center")
  end
end
