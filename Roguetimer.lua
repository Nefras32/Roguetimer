-- Roguetimer 0.2
-- Rogue timers for the Forever WoW 1.60 client (Interface 16001).
-- Starts finisher timers from successful spellcast events.

local MAXTIME = 30
local BAR_TEX = "Interface\\Buttons\\WHITE8X8"

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
  colors = {},
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
  lastExposeKey = nil,
  debug = false,
  lastErrors = {},
}
for _, d in ipairs(DEFS) do
  FB.defByKey[d.key] = d
  DEFAULTS.colors[d.key] = { d.color[1], d.color[2], d.color[3] }
end

local function GetBarColor(key)
  local color = RoguetimerDB.colors and RoguetimerDB.colors[key]
  local fallback = DEFAULTS.colors[key]
  if type(color) ~= "table"
    or type(color[1]) ~= "number" or color[1] < 0 or color[1] > 1
    or type(color[2]) ~= "number" or color[2] < 0 or color[2] > 1
    or type(color[3]) ~= "number" or color[3] < 0 or color[3] > 1 then
    return fallback
  end
  return color
end

local function ApplyBarColor(bar)
  local color = GetBarColor(bar.def.key)
  bar.ghost:SetVertexColor(color[1], color[2], color[3], 0.35)
  bar.fill:SetVertexColor(color[1], color[2], color[3], 0.78)
  if bar.ruptureCurrentFill then
    bar.ruptureCurrentFill:SetVertexColor(color[1], color[2], color[3], 1)
  end
  for _, layer in ipairs(bar.ruptureLayers or {}) do
    layer:SetVertexColor(color[1], color[2], color[3], layer.alpha or 0.55)
  end
  for _, layer in ipairs(bar.garroteLayers or {}) do
    layer:SetVertexColor(color[1], color[2], color[3], layer.alpha or 0.55)
  end
end

local function DebugMessage(message)
  if FB.debug and DEFAULT_CHAT_FRAME and type(DEFAULT_CHAT_FRAME.AddMessage) == "function" then
    DEFAULT_CHAT_FRAME:AddMessage("|cffffcc00Roguetimer debug:|r " .. tostring(message))
  end
end

local function ReportApiError(api, err)
  local key = "api:" .. api
  if FB.lastErrors[key] then return end
  FB.lastErrors[key] = tostring(err)
  if DEFAULT_CHAT_FRAME and type(DEFAULT_CHAT_FRAME.AddMessage) == "function" then
    DEFAULT_CHAT_FRAME:AddMessage("Roguetimer: " .. api .. " failed: " .. tostring(err))
  end
end

local function RunWithDiagnostics(context, callback, ...)
  if not FB.debug then return callback(...) end
  local args = { ... }
  local unpackArgs = unpack or table.unpack
  local ok, result = xpcall(function()
    return callback(unpackArgs(args))
  end, function(err)
    local key = "script:" .. context .. ":" .. tostring(err)
    if not FB.lastErrors[key] then
      FB.lastErrors[key] = true
      local trace = type(debugstack) == "function" and debugstack(2, 8, 8) or tostring(err)
      if DEFAULT_CHAT_FRAME and type(DEFAULT_CHAT_FRAME.AddMessage) == "function" then
        DEFAULT_CHAT_FRAME:AddMessage("Roguetimer error [" .. context .. "]: "
          .. tostring(err) .. "\n" .. tostring(trace))
      end
    end
    return err
  end)
  if not ok then error(result, 0) end
  return result
end

local function DebugState()
  local timerCount = 0
  local errorCount = 0
  for _, targetTimers in pairs(FB.timers) do
    for _ in pairs(targetTimers) do timerCount = timerCount + 1 end
  end
  for _ in pairs(FB.lastErrors) do errorCount = errorCount + 1 end
  local target = "none"
  if type(UnitExists) == "function" then
    local existsOK, exists = pcall(UnitExists, "target")
    local existsIsSecret = type(issecretvalue) == "function" and issecretvalue(exists)
    if existsOK and not existsIsSecret and exists == true then
      if type(UnitName) == "function" then
        local nameOK, name = pcall(UnitName, "target")
        local nameIsSecret = type(issecretvalue) == "function" and issecretvalue(name)
        if nameOK and not nameIsSecret and type(name) == "string" then target = name end
      end
      if target == "none" then target = "unknown" end
    end
  end
  local instanceType = "unknown"
  if type(IsInInstance) == "function" then
    local ok, inInstance, kind = pcall(IsInInstance)
    local instanceIsSecret = type(issecretvalue) == "function" and issecretvalue(inInstance)
    local kindIsSecret = type(issecretvalue) == "function" and issecretvalue(kind)
    if ok and not instanceIsSecret then
      instanceType = inInstance == true and not kindIsSecret and (kind or "instance") or "world"
    end
  end
  if DEFAULT_CHAT_FRAME and type(DEFAULT_CHAT_FRAME.AddMessage) == "function" then
    DEFAULT_CHAT_FRAME:AddMessage(string.format(
      "Roguetimer: target=%s key=%s timers=%d instance=%s battleground=%s reportedErrors=%d",
      tostring(target), tostring(FB.lastTargetKey), timerCount,
      tostring(instanceType), tostring(FB.inBattleground), errorCount))
  end
end

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
    local ok, value = pcall(UnitPower, "player", comboPointPower)
    if ok then
      if not IsSecretValue(value) and type(value) == "number" then return value end
      return 0
    end
    ReportApiError("UnitPower", value)
  end
  if type(GetComboPoints) == "function" then
    local ok, value = pcall(GetComboPoints, "player", "target")
    if ok then
      if not IsSecretValue(value) and type(value) == "number" then return value end
    else
      ReportApiError("GetComboPoints", value)
    end
  end
  return 0
end

local function SafeUnitExists(unit)
  if type(UnitExists) ~= "function" then return false end
  local ok, exists = pcall(UnitExists, unit)
  if not ok then
    ReportApiError("UnitExists", exists)
    return false
  end
  if IsSecretValue(exists) then return false end
  return exists == true
end

local function UnitTimerKey(unit)
  if unit == "player" then return "player" end
  if type(UnitGUID) == "function" then
    local ok, guid = pcall(UnitGUID, unit)
    if not ok then
      ReportApiError("UnitGUID", guid)
    elseif not IsSecretValue(guid) and type(guid) == "string" and guid ~= "" then
      return guid
    end
  end
  if type(UnitName) == "function" then
    local ok, name = pcall(UnitName, unit)
    if ok and not IsSecretValue(name) and type(name) == "string" and name ~= "" then
      return "name:" .. name
    end
  end
  return "target:" .. FB.targetGeneration
end

local function IsInBattleground()
  if type(_G.IsInBattleground) == "function" then
    local ok, inBattleground = pcall(_G.IsInBattleground)
    if not ok then
      ReportApiError("IsInBattleground", inBattleground)
    elseif not IsSecretValue(inBattleground) then
      return inBattleground == true
    end
  end
  if type(IsInInstance) == "function" then
    local ok, inInstance, instanceType = pcall(IsInInstance)
    if not ok then
      ReportApiError("IsInInstance", inInstance)
    elseif not IsSecretValue(inInstance) and inInstance == true
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
  if not FB.debug or not DEFAULT_CHAT_FRAME
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
    "Roguetimer debug: initialized=true anchorShown=%s barsCreated=%d barsShown=%d sndTalentPoints=%d {%s}",
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
  if def.key == "EXP" then FB.lastExposeKey = key end
  DebugMessage(string.format("%s applied to %s for %.1fs (%d combo points)",
    def.key, tostring(key), duration, cp))
  FB.pendingCP = 0
  if FB.debug and DEFAULT_CHAT_FRAME and DEFAULT_CHAT_FRAME.AddMessage then
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
  FB.anchor:SetHeight(#DEFS * (H + S))
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
    f.ghost:SetTexture(BAR_TEX)
    f.ghost:SetPoint("TOPLEFT", f, "TOPLEFT", 0, 0)
    f.fill = f:CreateTexture(nil, "ARTWORK")
    f.fill:SetTexture(BAR_TEX)
    f.fill:SetPoint("TOPLEFT", f, "TOPLEFT", 0, 0)
    if def.key == "RUP" then
      f.ruptureLayers = {}
      f.ruptureCurrentFill = f:CreateTexture(nil, "ARTWORK")
      f.ruptureCurrentFill:SetTexture(BAR_TEX)
      f.ruptureCurrentFill:SetPoint("TOPLEFT", f, "TOPLEFT", 0, 0)
      f.ruptureCurrentFill:SetHeight(db.height)
      f.ruptureCurrentFill:Hide()
    elseif def.key == "GAR" then
      f.garroteLayers = {}
    elseif def.key == "EXP" then
      f.inactiveOverlay = f:CreateTexture(nil, "ARTWORK")
      f.inactiveOverlay:SetTexture(BAR_TEX)
      f.inactiveOverlay:SetVertexColor(0.55, 0.55, 0.55, 0.45)
      f.inactiveOverlay:SetAllPoints(f)
      f.inactiveOverlay:Hide()
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
    ApplyBarColor(f)
  end
  Layout()
  a:Show()
end

local function SetOptionText(region, text, size, color)
  region:SetFont(STANDARD_TEXT_FONT or "Fonts\\FRIZQT__.TTF", size or 12, "")
  region:SetText(text)
  if color then region:SetTextColor(color[1], color[2], color[3]) end
end

local function CreatePanelButton(parent, text, width, height)
  local button = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
  button:SetWidth(width)
  button:SetHeight(height)
  button:SetText(text)
  button.label = button:GetFontString()
  if button.label then
    button.label:SetFont(STANDARD_TEXT_FONT or "Fonts\\FRIZQT__.TTF", 12, "")
  end
  return button
end

local function CreateOptions()
  local panel = CreateFrame("Frame", "RoguetimerOptions", UIParent)
  FB.options = panel
  panel:SetWidth(440)
  panel:SetHeight(410)
  panel:SetFrameStrata("DIALOG")
  panel:SetClampedToScreen(true)
  panel:EnableMouse(true)
  panel:SetMovable(true)
  panel:RegisterForDrag("LeftButton")
  panel:SetScript("OnDragStart", function(self) self:StartMoving() end)
  panel:SetScript("OnDragStop", function(self) self:StopMovingOrSizing() end)
  panel:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
  panel.background = panel:CreateTexture(nil, "BACKGROUND")
  panel.background:SetTexture(BAR_TEX)
  panel.background:SetVertexColor(0.04, 0.05, 0.07, 0.98)
  panel.background:SetAllPoints(panel)
  if type(panel.SetBackdrop) == "function" then
    panel:SetBackdrop({
      bgFile = BAR_TEX,
      edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
      tile = true,
      tileSize = 16,
      edgeSize = 16,
      insets = { left = 4, right = 4, top = 4, bottom = 4 },
    })
    panel:SetBackdropColor(0.04, 0.05, 0.07, 0.98)
    panel:SetBackdropBorderColor(0.45, 0.48, 0.52, 1)
  end
  local titleBar = CreateFrame("Frame", nil, panel)
  titleBar:SetPoint("TOPLEFT", panel, "TOPLEFT", 8, -8)
  titleBar:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -8, -8)
  titleBar:SetHeight(44)
  titleBar:EnableMouse(true)
  titleBar:RegisterForDrag("LeftButton")
  titleBar:SetScript("OnDragStart", function() panel:StartMoving() end)
  titleBar:SetScript("OnDragStop", function() panel:StopMovingOrSizing() end)
  local title = panel:CreateFontString(nil, "OVERLAY")
  title:SetPoint("LEFT", titleBar, "LEFT", 12, 0)
  SetOptionText(title, "Roguetimer", 14)
  local description = panel:CreateFontString(nil, "OVERLAY")
  description:SetPoint("LEFT", title, "RIGHT", 12, 0)
  SetOptionText(description, "Timer and display settings", 12)
  local close = CreateFrame("Button", nil, panel, "UIPanelCloseButton")
  close:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -5, -5)
  close:SetScript("OnClick", function() panel:Hide() end)

  local function AddSectionHeading(text, y)
    local heading = panel:CreateFontString(nil, "OVERLAY")
    heading:SetPoint("TOPLEFT", panel, "TOPLEFT", 16, y)
    SetOptionText(heading, text, 12)
  end

  AddSectionHeading("TRACKED TIMERS / BAR COLORS", -56)

  local function AddTrackedBarRow(def, index, label)
    local toggleIndex = (FB.toggleIndex or 0) + 1
    FB.toggleIndex = toggleIndex
    local rowName = "RoguetimerOptionToggle" .. toggleIndex
    local row = CreateFrame("CheckButton", rowName, panel, "InterfaceOptionsCheckButtonTemplate")
    local y = -72 - (index - 1) * 28
    row:SetSize(24, 24)
    row:SetPoint("TOPLEFT", panel, "TOPLEFT", 12, y)
    row:SetChecked(RoguetimerDB.bars[def.key] ~= false)
    local text = row.Text or row.text or _G[rowName .. "Text"]
    if text then
      text:SetText("")
      text:Hide()
    end
    row:SetScript("OnClick", function()
      RoguetimerDB.bars[def.key] = row:GetChecked() and true or false
      UpdateBars()
    end)

    local icon = panel:CreateTexture(nil, "ARTWORK")
    icon:SetSize(20, 20)
    icon:SetPoint("LEFT", row, "RIGHT", 5, 0)
    icon:SetTexture("Interface\\Icons\\" .. def.tex)
    icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)

    local name = panel:CreateFontString(nil, "OVERLAY")
    name:SetPoint("LEFT", icon, "RIGHT", 6, 0)
    name:SetWidth(205)
    name:SetJustifyH("LEFT")
    SetOptionText(name, label, 12)

    local swatch = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    swatch:SetSize(36, 22)
    swatch:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -88, y + 1)
    swatch:SetText("")
    swatch.texture = swatch:CreateTexture(nil, "ARTWORK")
    swatch.texture:SetTexture(BAR_TEX)
    swatch.texture:SetPoint("TOPLEFT", swatch, "TOPLEFT", 4, -4)
    swatch.texture:SetPoint("BOTTOMRIGHT", swatch, "BOTTOMRIGHT", -4, 4)

    local reset = CreatePanelButton(panel, "Reset", 58, 22)
    reset:SetPoint("LEFT", swatch, "RIGHT", 5, 0)

    local function RefreshColor()
      local color = GetBarColor(def.key)
      swatch.texture:SetVertexColor(color[1], color[2], color[3], 1)
      UpdateBars()
    end
    local function SetColor(r, g, b)
      RoguetimerDB.colors[def.key] = {
        math.max(0, math.min(1, r)),
        math.max(0, math.min(1, g)),
        math.max(0, math.min(1, b)),
      }
      RefreshColor()
    end
    swatch:SetScript("OnClick", function()
      local picker = ColorPickerFrame
      if not picker then
        DEFAULT_CHAT_FRAME:AddMessage("Roguetimer: this client has no color picker.")
        return
      end
      local color = GetBarColor(def.key)
      local previous = { r = color[1], g = color[2], b = color[3] }
      local function RestoreColor(oldColor)
        if oldColor then SetColor(oldColor.r, oldColor.g, oldColor.b) end
      end
      if type(picker.SetupColorPickerAndShow) == "function" then
        picker:SetupColorPickerAndShow({
          r = color[1], g = color[2], b = color[3], hasOpacity = false,
          swatchFunc = function()
            local r, g, b = picker:GetColorRGB()
            SetColor(r, g, b)
          end,
          cancelFunc = RestoreColor,
        })
      else
        picker.hasOpacity = false
        picker.func = function()
          local r, g, b = picker:GetColorRGB()
          SetColor(r, g, b)
        end
        picker.cancelFunc = RestoreColor
        picker.previousValues = previous
        picker:SetColorRGB(color[1], color[2], color[3])
        picker:Show()
      end
    end)
    reset:SetScript("OnClick", function()
      local color = DEFAULTS.colors[def.key]
      SetColor(color[1], color[2], color[3])
    end)
    RefreshColor()
  end

  for index, def in ipairs(DEFS) do
    RoguetimerDB.bars[def.key] = RoguetimerDB.bars[def.key] ~= false
    AddTrackedBarRow(def, index, ({
      SND = "Slice and Dice",
      RUP = "Rupture",
      GAR = "Garrote",
      EXP = "Expose Armor",
    })[def.key])
  end

  AddSectionHeading("DISPLAY & SIZE", -194)
  local function AddToggle(label, y, getValue, setValue)
    local toggleIndex = (FB.toggleIndex or 0) + 1
    FB.toggleIndex = toggleIndex
    local rowName = "RoguetimerOptionToggle" .. toggleIndex
    local row = CreateFrame("CheckButton", rowName, panel, "InterfaceOptionsCheckButtonTemplate")
    row:SetPoint("TOPLEFT", panel, "TOPLEFT", 12, y)
    row:SetChecked(getValue())
    local text = row.Text or row.text or _G[rowName .. "Text"]
    if text then
      text:SetText(label)
      text:SetFont(STANDARD_TEXT_FONT or "Fonts\\FRIZQT__.TTF", 12, "")
    else
      local labelText = row:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
      labelText:SetPoint("LEFT", row, "RIGHT", 2, 0)
      labelText:SetFont(STANDARD_TEXT_FONT or "Fonts\\FRIZQT__.TTF", 12, "")
      labelText:SetText(label)
    end
    local function Refresh()
      row:SetChecked(getValue())
    end
    row:SetScript("OnClick", function()
      setValue(row:GetChecked() and true or false)
      Refresh()
      UpdateBars()
    end)
    row.Refresh = Refresh
    Refresh()
    return row
  end

  AddToggle("Hide bars without an active timer", -210,
    function() return not RoguetimerDB.showInactive end,
    function(value) RoguetimerDB.showInactive = not value end)

  local function AddSizeControl(label, y, key, minimum, maximum, step)
    local text = panel:CreateFontString(nil, "OVERLAY")
    text:SetPoint("TOPLEFT", panel, "TOPLEFT", 24, y)
    SetOptionText(text, label, 12)
    local value = panel:CreateFontString(nil, "OVERLAY")
    value:SetWidth(42)
    value:SetJustifyH("CENTER")
    SetOptionText(value, tostring(RoguetimerDB[key]), 12)
    local minus = CreatePanelButton(panel, "-", 24, 22)
    local plus = CreatePanelButton(panel, "+", 24, 22)
    plus:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -18, y + 1)
    value:SetPoint("RIGHT", plus, "LEFT", -6, 0)
    minus:SetPoint("RIGHT", value, "LEFT", -6, 0)
    local function Adjust(direction)
      RoguetimerDB[key] = math.max(minimum, math.min(maximum, RoguetimerDB[key] + step * direction))
      value:SetText(tostring(RoguetimerDB[key]))
      Layout()
      UpdateBars()
    end
    minus:SetScript("OnClick", function() Adjust(-1) end)
    plus:SetScript("OnClick", function() Adjust(1) end)
  end

  AddSizeControl("Bar width", -238, "width", 100, 420, 20)
  AddSizeControl("Bar height", -264, "height", 12, 36, 2)

  AddSectionHeading("BAR POSITION", -294)
  local lock = CreatePanelButton(panel, "", 184, 26)
  lock:SetPoint("TOPLEFT", panel, "TOPLEFT", 18, -312)
  local function RefreshLock()
    lock:SetText(RoguetimerDB.locked and "Unlock Position" or "Lock Position")
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

  local centerVertical = CreatePanelButton(panel, "Center Vertically", 184, 26)
  centerVertical:SetPoint("TOPLEFT", panel, "TOPLEFT", 18, -344)
  centerVertical:SetScript("OnClick", function() CenterAnchor("vertical") end)

  local centerHorizontal = CreatePanelButton(panel, "Center Horizontally", 184, 26)
  centerHorizontal:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -18, -344)
  centerHorizontal:SetScript("OnClick", function() CenterAnchor("horizontal") end)

  local resetPosition = CreatePanelButton(panel, "Reset Position", 184, 26)
  resetPosition:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -18, -312)
  resetPosition:SetScript("OnClick", function()
    RoguetimerDB.x, RoguetimerDB.y = nil, nil
    FB.anchor:ClearAllPoints()
    FB.anchor:SetPoint("CENTER", UIParent, "CENTER", 0, -100)
  end)
  panel:Hide()
  local function OpenOptions()
    panel:Show()
  end
  FB.openOptions = OpenOptions

  if Minimap then
    local button = CreateFrame("Button", "RoguetimerMinimapButton", UIParent)
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
      if type(x) ~= "number" or type(y) ~= "number"
        or type(mx) ~= "number" or type(my) ~= "number"
        or type(scale) ~= "number" or scale <= 0 then
        return
      end
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
      if type(InCombatLockdown) == "function" and InCombatLockdown() then
        DebugMessage("minimap button drag ignored during combat")
        return
      end
      dragging = true
    end)
    button:SetScript("OnUpdate", function()
      if dragging then
        if type(InCombatLockdown) == "function" and InCombatLockdown() then
          dragging = false
          return
        end
        UpdateMinimapButtonPosition()
      end
    end)
    button:SetScript("OnDragStop", function()
      if not dragging then return end
      dragging = false
      UpdateMinimapButtonPosition()
    end)
    PositionMinimapButton()
    button:SetScript("OnClick", function()
      OpenOptions()
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
  FB.anchor:Show()
  local now = GetTime()
  local W = db.width
  local cp = GetCP()
  local targetExists = SafeUnitExists("target")
  local targetIsDead = false
  if targetExists and type(UnitIsDeadOrGhost) == "function" then
    local ok, isDead = pcall(UnitIsDeadOrGhost, "target")
    if not ok then
      ReportApiError("UnitIsDeadOrGhost", isDead)
    elseif not IsSecretValue(isDead) and isDead == true then
      targetIsDead = true
    end
  end
  if targetExists and not targetIsDead and type(UnitIsDead) == "function" then
    local ok, isDead = pcall(UnitIsDead, "target")
    if not ok then
      ReportApiError("UnitIsDead", isDead)
    elseif not IsSecretValue(isDead) and isDead == true then
      targetIsDead = true
    end
  end
  local targetAlive = targetExists and not targetIsDead
  local targetKey = targetExists and UnitTimerKey("target") or nil
  local exposeKey = FB.lastExposeKey
  local exposeTimer = exposeKey and FB.timers[exposeKey] and FB.timers[exposeKey].EXP
  if exposeTimer and exposeTimer.start + exposeTimer.dur <= now then
    FB.timers[exposeKey].EXP = nil
    exposeTimer = nil
    FB.lastExposeKey = nil
  end
  if not exposeTimer then
    local newestStart = 0
    for unitKey, timers in pairs(FB.timers) do
      local timer = timers.EXP
      if timer and timer.start + timer.dur > now and timer.start > newestStart then
        newestStart = timer.start
        exposeKey, exposeTimer = unitKey, timer
      elseif timer then
        timers.EXP = nil
      end
    end
    FB.lastExposeKey = exposeKey
  end
  local activeRuptures = {}
  local activeGarrotes = {}
  local currentTargetRupture
  local currentTargetGarrote

  if targetExists and not targetAlive and targetKey and FB.timers[targetKey] then
    FB.timers[targetKey].RUP = nil
    FB.timers[targetKey].GAR = nil
    FB.timers[targetKey].EXP = nil
    if FB.lastExposeKey == targetKey then
      FB.lastExposeKey = nil
      exposeKey, exposeTimer = nil, nil
    end
  end

  if targetAlive and targetKey and FB.timers[targetKey] then
    currentTargetRupture = FB.timers[targetKey].RUP
    currentTargetGarrote = FB.timers[targetKey].GAR
  end

  for unitKey, timers in pairs(FB.timers) do
    local rupture = timers.RUP
    if rupture and rupture.start + rupture.dur > now then
      table.insert(activeRuptures, {
        key = unitKey,
        timer = rupture,
      })
    elseif rupture then
      timers.RUP = nil
    end
    local garrote = timers.GAR
    if garrote and garrote.start + garrote.dur > now then
      table.insert(activeGarrotes, { key = unitKey, timer = garrote })
    elseif garrote then
      timers.GAR = nil
    end
  end
  table.sort(activeRuptures, function(a, b)
    return tostring(a.key) < tostring(b.key)
  end)
  table.sort(activeGarrotes, function(a, b)
    return tostring(a.key) < tostring(b.key)
  end)

  for _, f in ipairs(FB.bars) do
    local def = f.def
    local remaining, ghost = 0, 0
    local enabled = db.bars[def.key] ~= false
    ApplyBarColor(f)

    if def.key == "SND" then
      local playerKey = UnitTimerKey("player")
      if FB.timers[playerKey] and FB.timers[playerKey][def.key] then
        local timer = FB.timers[playerKey][def.key]
        remaining = math.max(0, timer.start + timer.dur - now)
      end
    elseif def.key == "RUP" and currentTargetRupture then
      remaining = math.max(0, currentTargetRupture.start + currentTargetRupture.dur - now)
    elseif def.key == "GAR" and currentTargetGarrote then
      remaining = math.max(0, currentTargetGarrote.start + currentTargetGarrote.dur - now)
    elseif def.key == "GAR" then
      for _, garrote in ipairs(activeGarrotes) do
        remaining = math.max(remaining, garrote.timer.start + garrote.timer.dur - now)
      end
    elseif def.key == "EXP" and exposeTimer then
      remaining = math.max(0, exposeTimer.start + exposeTimer.dur - now)
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
      if f.inactiveOverlay then
        if remaining > 0 and targetKey ~= exposeKey then
          f.inactiveOverlay:Show()
        else
          f.inactiveOverlay:Hide()
        end
      end
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
            layer.alpha = 0.35 + ((layerIndex - 1) % 5) * 0.1
            local color = GetBarColor(def.key)
            layer:SetVertexColor(color[1], color[2], color[3], layer.alpha)
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
      elseif def.key == "GAR" then
        local visibleGarrotes = {}
        local primaryGarrote = currentTargetGarrote
        if not primaryGarrote and activeGarrotes[1] then
          primaryGarrote = activeGarrotes[1].timer
        end
        for _, garrote in ipairs(activeGarrotes) do
          if garrote.timer ~= primaryGarrote then
            table.insert(visibleGarrotes, garrote)
          end
        end
        local layerIndex = 0
        for _, garrote in ipairs(visibleGarrotes) do
          layerIndex = layerIndex + 1
          local layer = f.garroteLayers[layerIndex]
          if not layer then
            layer = f:CreateTexture(nil, "ARTWORK")
            layer:SetTexture(BAR_TEX)
            layer:SetPoint("TOPLEFT", f, "TOPLEFT", 0, 0)
            layer:SetHeight(f:GetHeight())
            f.garroteLayers[layerIndex] = layer
          end
          layer.alpha = 0.35 + ((layerIndex - 1) % 5) * 0.1
          local color = GetBarColor(def.key)
          layer:SetVertexColor(color[1], color[2], color[3], layer.alpha)
          local layerWidth = math.min(
            garrote.timer.start + garrote.timer.dur - now, MAXTIME) / MAXTIME * W
          if layerWidth >= 1 then
            layer:SetWidth(layerWidth)
            layer:Show()
          else
            layer:Hide()
          end
        end
        for i = layerIndex + 1, #f.garroteLayers do
          f.garroteLayers[i]:Hide()
        end
        local currentWidth = primaryGarrote
          and math.min(primaryGarrote.start + primaryGarrote.dur - now, MAXTIME) / MAXTIME * W
          or 0
        if primaryGarrote and currentWidth >= 1 then
          f.fill:SetWidth(currentWidth)
          f.fill:Show()
        else
          f.fill:Hide()
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
      elseif def.key == "GAR" then
        f.fill:Hide()
        for _, layer in ipairs(f.garroteLayers or {}) do layer:Hide() end
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
  if inBattleground ~= FB.inBattleground then
    FB.inBattleground = inBattleground
    DebugMessage("battleground state changed: " .. tostring(inBattleground))
  end
  TrackComboPoints()
  UpdateBars()
end

local function HandleEvent(self, e, a1, ...)
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
    if type(RoguetimerDB.colors) ~= "table" then RoguetimerDB.colors = {} end
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
      if k ~= "colors" and RoguetimerDB[k] == nil then RoguetimerDB[k] = v end
    end
    for _, def in ipairs(DEFS) do
      local color = RoguetimerDB.colors[def.key]
      if type(color) ~= "table"
        or type(color[1]) ~= "number" or color[1] < 0 or color[1] > 1
        or type(color[2]) ~= "number" or color[2] < 0 or color[2] > 1
        or type(color[3]) ~= "number" or color[3] < 0 or color[3] > 1 then
        RoguetimerDB.colors[def.key] = {
          DEFAULTS.colors[def.key][1],
          DEFAULTS.colors[def.key][2],
          DEFAULTS.colors[def.key][3],
        }
      end
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
    FB.targetGeneration = FB.targetGeneration + 1
    FB.pendingCP = 0
    FB.pendingTarget = nil
    TrackComboPoints()
    DebugMessage("target changed: " .. tostring(FB.lastTargetKey))
    UpdateBars()
  elseif e == "PLAYER_TALENT_UPDATE" then
    ScanTalents()
  elseif e == "UNIT_SPELLCAST_SUCCEEDED" then
    TrackFinisherCast(a1, ...)
  end
end

ev:SetScript("OnEvent", function(...)
  return RunWithDiagnostics("event", HandleEvent, ...)
end)

local function HandleUpdate(self, elapsed)
  if not active then return end
  FB.updateElapsed = (FB.updateElapsed or 0) + (elapsed or 0)
  if FB.updateElapsed < 0.1 then return end
  FB.updateElapsed = FB.updateElapsed % 0.1
  TrackComboPoints()
  UpdateBars()
end

ev:SetScript("OnUpdate", function(...)
  return RunWithDiagnostics("update", HandleUpdate, ...)
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
    FB.debug = not FB.debug
    DEFAULT_CHAT_FRAME:AddMessage("Roguetimer diagnostics " .. (FB.debug and "enabled" or "disabled"))
    DebugInitialization()
    DebugState()
  elseif cmd == "status" then
    DebugState()
  elseif cmd == "width" and tonumber(val) then db.width = tonumber(val); Layout()
  elseif cmd == "height" and tonumber(val) then db.height = tonumber(val); Layout()
  elseif cmd == "options" then
    FB.openOptions()
  elseif cmd == "reset" or cmd == "center" then
    db.x, db.y = nil, nil
    FB.anchor:ClearAllPoints()
    FB.anchor:SetPoint("CENTER", UIParent, "CENTER", 0, -100)
  else
    DEFAULT_CHAT_FRAME:AddMessage("Roguetimer: /roguetimer options | unlock | lock | debug | status | width N | height N | center")
  end
end
