-- Roguetimer 0.1
-- Rogue timers for the Forever WoW 1.60 client (Interface 16001).
-- Written for compatibility with Lua 5.0 (1.12 API) and Lua 5.1.

local MAXTIME = 30
local BAR_TEX = "Interface\\Buttons\\WHITE8X8"

-- Identify spells by icon path (language-independent).
-- finisher consumes combo points; scaled duration depends on combo points.
local DEFS = {
  { key = "SND", tex = "Ability_Rogue_SliceDice",   color = { 1.00, 0.85, 0.10 }, finisher = true, scaled = true },
  { key = "RUP", tex = "Ability_Rogue_Rupture",     color = { 1.00, 0.30, 0.30 }, finisher = true, scaled = true },
  { key = "GAR", tex = "Ability_Rogue_Garrote",     color = { 0.55, 0.05, 0.05 }, fixed = 18 },
  { key = "EXP", tex = "Ability_Warrior_Riposte",   color = { 0.45, 0.55, 0.80 }, finisher = true, fixed = 30 },
}

local DEFAULTS = {
  width = 220,
  height = 18,
  spacing = 4,
  locked = true,
  showInactive = false,
  showBackground = false,
  backgroundAlpha = 0.24,
}

local FB = {
  timers = {},      -- timers[targetName][key] = { start, dur }
  defByKey = {},
  bars = {},
  sndBonus = 0,
  options = {},
}
for _, d in ipairs(DEFS) do FB.defByKey[d.key] = d end

-- Vanilla durations; adjust these if the client uses different values.
local function Duration(def, cp)
  if def.key == "SND" then return (6 + 3 * cp) * (1 + FB.sndBonus)
  elseif def.key == "RUP" then return 6 + 2 * cp
  else return def.fixed end
end

------------------------------------------------------------
-- Helpers
------------------------------------------------------------
local function GetCP()
  if type(GetComboPoints) ~= "function" then return 0 end
  return GetComboPoints("player", "target") or 0
end

local function AuraInfo(unit, index, auraFunction, def)
  local a, b, c, duration, expiration = auraFunction(unit, index)
  if not a then return false, nil, nil, false end
  local matches = type(a) == "string" and string.find(a, def.tex, 1, true) ~= nil
  if not matches and type(b) == "string" then matches = string.find(b, def.tex, 1, true) ~= nil end
  if not matches and type(c) == "string" then matches = string.find(c, def.tex, 1, true) ~= nil end
  if not matches then return false, nil, nil, true end
  if type(duration) == "number" and duration > 0
    and type(expiration) == "number" and expiration > 0 then
    return true, duration, expiration, true
  end
  return true, nil, nil, true
end

local function FindAura(unit, auraFunction, def)
  if type(auraFunction) ~= "function" then return false, nil, nil end
  for i = 1, 40 do
    local present, duration, expiration, hasAura = AuraInfo(unit, i, auraFunction, def)
    if present then return true, duration, expiration end
    if not hasAura then break end
  end
  return false, nil, nil
end

local function PlayerBuff(def)
  local present, duration, expiration = FindAura("player", UnitBuff, def)
  if present then return true, duration, expiration end
  if def.key ~= "SND" or type(GetPlayerBuff) ~= "function"
    or type(GetPlayerBuffTexture) ~= "function" then
    return false, nil, nil
  end
  for i = 0, 31 do
    local index = GetPlayerBuff(i, "HELPFUL")
    if not index or index < 0 then break end
    local texture = GetPlayerBuffTexture(index)
    if type(texture) == "string" and string.find(texture, def.tex, 1, true) then
      if type(GetPlayerBuffTimeLeft) == "function" then
        local remaining = GetPlayerBuffTimeLeft(index)
        if type(remaining) == "number" and remaining > 0 then
          return true, nil, GetTime() + remaining
        end
      end
      return true, nil, nil
    end
  end
  return false, nil, nil
end

local function ScanTalents()
  FB.sndBonus = 0
  if type(GetNumTalents) ~= "function" or type(GetTalentInfo) ~= "function" then return end
  for tab = 1, 3 do
    local count = GetNumTalents(tab)
    if type(count) == "number" then
      for i = 1, count do
        local _, icon, _, _, rank = GetTalentInfo(tab, i)
        if icon and rank and string.find(icon, "Ability_Rogue_SliceDice", 1, true) then
          FB.sndBonus = rank * 0.15
        end
      end
    end
  end
end

------------------------------------------------------------
-- Debuff timer logic (throttled to about five checks per second).
------------------------------------------------------------
local function CheckTargetAuras()
  if type(UnitExists) ~= "function" or type(UnitName) ~= "function" then return end
  local now = GetTime()
  local targetExists = UnitExists("target")
  local units = {
    { token = "player", name = UnitName("player"), auraFunction = UnitBuff },
  }
  if targetExists then
    table.insert(units, { token = "target", name = UnitName("target"), auraFunction = UnitDebuff })
  end

  for _, unit in ipairs(units) do
    local name = unit.name or unit.token
    FB.timers[name] = FB.timers[name] or {}
    local timers = FB.timers[name]
    for _, def in ipairs(DEFS) do
      local shouldScan = (unit.token == "player" and def.key == "SND")
        or (unit.token == "target" and def.key ~= "SND")
      if shouldScan then
        local present, duration, expiration = FindAura(unit.token, unit.auraFunction, def)
        if unit.token == "player" and not present then
          present, duration, expiration = PlayerBuff(def)
        end
        if present then
          if type(expiration) == "number" and expiration > now and type(duration) == "number" and duration > 0 then
            timers[def.key] = { start = expiration - duration, dur = duration }
          elseif not timers[def.key] or now > timers[def.key].start + timers[def.key].dur then
            local cp = def.scaled and GetCP() or 0
            timers[def.key] = { start = now, dur = Duration(def, cp) }
          end
        else
          timers[def.key] = nil
        end
      end
    end
    if unit.token == "target" and type(UnitIsDead) == "function" and UnitIsDead("target") then
      FB.timers[name] = nil
    end
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
    f.text:SetFont(STANDARD_TEXT_FONT or "Fonts\\FRIZQT__.TTF", math.max(8, H - 6), "OUTLINE")
  end
  FB.anchor:EnableMouse(not db.locked)
  if type(FB.anchor.RegisterForDrag) == "function" then
    FB.anchor:RegisterForDrag("LeftButton")
  end
  if db.locked then FB.anchor.tint:Hide() else FB.anchor.tint:Show() end
end

local function UpdateBarBackgrounds()
  local db = RoguetimerDB
  for _, bar in ipairs(FB.bars) do
    bar.bg:SetVertexColor(0.08, 0.18, 0.25, db.backgroundAlpha)
    if db.showBackground then bar.bg:Show() else bar.bg:Hide() end
  end
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
  a:SetScript("OnDragStop", function()
    a:StopMovingOrSizing()
    local x, y = a:GetLeft(), a:GetTop()
    if x and y then
      RoguetimerDB.x, RoguetimerDB.y = x, y
      a:ClearAllPoints()
      a:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", x, y)
    end
  end)

  for i, def in ipairs(DEFS) do
    local c = def.color
    local f = CreateFrame("Frame", nil, a)
    f.def = def
    f.bg = f:CreateTexture(nil, "BACKGROUND")
    f.bg:SetTexture(BAR_TEX); f.bg:SetVertexColor(0.08, 0.18, 0.25, db.backgroundAlpha); f.bg:SetAllPoints(f)
    if db.showBackground then f.bg:Show() else f.bg:Hide() end
    f.ghost = f:CreateTexture(nil, "BORDER")
    f.ghost:SetTexture(BAR_TEX); f.ghost:SetVertexColor(c[1], c[2], c[3], 0.35)
    f.ghost:SetPoint("TOPLEFT", f, "TOPLEFT", 0, 0)
    f.fill = f:CreateTexture(nil, "ARTWORK")
    f.fill:SetTexture(BAR_TEX); f.fill:SetVertexColor(c[1], c[2], c[3], 0.78)
    f.fill:SetPoint("TOPLEFT", f, "TOPLEFT", 0, 0)
    f.icon = f:CreateTexture(nil, "ARTWORK")
    f.icon:SetTexture("Interface\\Icons\\" .. def.tex)
    f.icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)
    f.icon:SetPoint("RIGHT", f, "LEFT", -3, 0)
    f.text = f:CreateFontString(nil, "OVERLAY")
    f.text:SetFont(STANDARD_TEXT_FONT or "Fonts\\FRIZQT__.TTF", 12, "OUTLINE")
    f.text:SetJustifyH("RIGHT")
    f.text:SetPoint("RIGHT", f, "RIGHT", -4, 0)
    FB.bars[i] = f
  end
  Layout()
end

local function SetOptionText(region, text, size, color)
  region:SetFont(STANDARD_TEXT_FONT or "Fonts\\FRIZQT__.TTF", size or 12, "OUTLINE")
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
  panel:SetWidth(310)
  panel:SetHeight(455)
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
  title:SetPoint("TOPLEFT", panel, "TOPLEFT", 18, -16)
  SetOptionText(title, "ROGUETIMER", 18, { 1, 0.78, 0.32 })
  local subtitle = panel:CreateFontString(nil, "OVERLAY")
  subtitle:SetPoint("TOPLEFT", panel, "TOPLEFT", 19, -41)
  SetOptionText(subtitle, "Combat bars  |  Display & layout", 10, { 0.62, 0.72, 0.82 })

  local function AddToggle(label, y, getValue, setValue, icon)
    local row = CreatePanelButton(panel, "", 274, 27)
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
        SetOptionText(row.state, "ON", 10, { 0.35, 0.9, 0.58 })
        row.fill:SetVertexColor(0.11, 0.21, 0.19, 1)
      else
        SetOptionText(row.state, "OFF", 10, { 0.72, 0.48, 0.45 })
        row.fill:SetVertexColor(0.18, 0.14, 0.16, 1)
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

  AddToggle("Hide bars without an active timer", -68,
    function() return not RoguetimerDB.showInactive end,
    function(value) RoguetimerDB.showInactive = not value end,
    "INV_Misc_PocketWatch_01")
  for index, def in ipairs(DEFS) do
    RoguetimerDB.bars[def.key] = RoguetimerDB.bars[def.key] ~= false
    local row = AddToggle(def.key .. "  -  " .. ({
      SND = "Slice and Dice",
      RUP = "Rupture",
      GAR = "Garrote",
      EXP = "Expose Armor",
    })[def.key], -101 - (index - 1) * 31,
      function() return RoguetimerDB.bars[def.key] end,
      function(value) RoguetimerDB.bars[def.key] = value end,
      def.tex)
    row.label:SetPoint("LEFT", row, "LEFT", 32, 0)
  end

  AddToggle("Show colored bar backgrounds", -225,
    function() return RoguetimerDB.showBackground end,
    function(value) RoguetimerDB.showBackground = value; UpdateBarBackgrounds() end,
    "INV_Misc_StoneTablet_05")
  local opacity = panel:CreateFontString(nil, "OVERLAY")
  opacity:SetPoint("TOPLEFT", panel, "TOPLEFT", 24, -255)
  SetOptionText(opacity, "Background opacity", 11, { 0.84, 0.88, 0.94 })
  local opacityValue = panel:CreateFontString(nil, "OVERLAY")
  opacityValue:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -64, -255)
  SetOptionText(opacityValue, "", 11, { 1, 0.78, 0.32 })
  local function RefreshOpacity()
    opacityValue:SetText(string.format("%d%%", math.floor(RoguetimerDB.backgroundAlpha * 100 + 0.5)))
  end
  local opacityMinus = CreatePanelButton(panel, "-", 24, 22)
  opacityMinus:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -42, -251)
  opacityMinus:SetScript("OnClick", function()
    RoguetimerDB.backgroundAlpha = math.max(0.05, RoguetimerDB.backgroundAlpha - 0.05)
    RefreshOpacity()
    UpdateBarBackgrounds()
  end)
  local opacityPlus = CreatePanelButton(panel, "+", 24, 22)
  opacityPlus:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -14, -251)
  opacityPlus:SetScript("OnClick", function()
    RoguetimerDB.backgroundAlpha = math.min(0.8, RoguetimerDB.backgroundAlpha + 0.05)
    RefreshOpacity()
    UpdateBarBackgrounds()
  end)
  RefreshOpacity()

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
  AddSizeControl("Bar height", -313, "height", 12, 36, 2)

  local lock = CreatePanelButton(panel, "", 274, 26)
  lock:SetPoint("TOPLEFT", panel, "TOPLEFT", 18, -342)
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
  end)
  RefreshLock()

  local center = CreatePanelButton(panel, "CENTER BARS", 132, 27)
  center:SetPoint("TOPLEFT", panel, "TOPLEFT", 18, -376)
  center:SetScript("OnClick", function()
    RoguetimerDB.x, RoguetimerDB.y = nil, nil
    FB.anchor:ClearAllPoints()
    FB.anchor:SetPoint("CENTER", UIParent, "CENTER", 0, -100)
  end)
  local close = CreatePanelButton(panel, "CLOSE", 132, 27)
  close:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -18, -376)
  close:SetScript("OnClick", function() panel:Hide() end)
  panel:Hide()

  if Minimap then
    local button = CreateFrame("Button", "RoguetimerMinimapButton", Minimap)
    FB.minimapButton = button
    button:SetWidth(32)
    button:SetHeight(32)
    button:SetMovable(true)
    button:RegisterForDrag("LeftButton")
    button:SetFrameStrata("MEDIUM")
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
      local buttonWidth = type(button.GetWidth) == "function" and button:GetWidth() or 32
      local radius = math.max(0, minimapWidth / 2 - buttonWidth / 2 - 4)
      button:ClearAllPoints()
      button:SetPoint("CENTER", Minimap, "CENTER",
        math.cos(radians) * radius, math.sin(radians) * radius)
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
  local now = GetTime()
  local W = db.width
  local cp = GetCP()
  local hasTarget = type(UnitExists) == "function"
    and UnitExists("target")
    and type(UnitCanAttack) == "function"
    and UnitCanAttack("player", "target")
    and (type(UnitIsDead) ~= "function" or not UnitIsDead("target"))
  local tname = hasTarget and type(UnitName) == "function" and UnitName("target") or nil

  for _, f in ipairs(FB.bars) do
    local def = f.def
    local remaining, ghost = 0, 0
    local enabled = db.bars[def.key] ~= false

    if def.key == "SND" then
      local playerName = type(UnitName) == "function" and UnitName("player") or "player"
      local present, _, expiration = PlayerBuff(def)
      if present and type(expiration) == "number" then
        remaining = math.max(0, expiration - now)
      elseif FB.timers[playerName] and FB.timers[playerName][def.key] then
        local timer = FB.timers[playerName][def.key]
        remaining = math.max(0, timer.start + timer.dur - now)
      end
    elseif tname and FB.timers[tname] and FB.timers[tname][def.key] then
      local tm = FB.timers[tname][def.key]
      remaining = tm.start + tm.dur - now
      if remaining < 0 then remaining = 0 end
    end
    if hasTarget and (not def.finisher or cp > 0) then
      ghost = Duration(def, cp)
    end

    if enabled and (remaining > 0 or ghost > 0 or db.showInactive or not db.locked) then
      f:Show()
      local gw = math.min(ghost, MAXTIME) / MAXTIME * W
      local fw = math.min(remaining, MAXTIME) / MAXTIME * W
      if gw >= 1 then f.ghost:SetWidth(gw); f.ghost:Show() else f.ghost:Hide() end
      if fw >= 1 then f.fill:SetWidth(fw); f.fill:Show() else f.fill:Hide() end
      local displayed = remaining > 0 and remaining or ghost
      if displayed > 0 then f.text:SetText(string.format("%.1f", displayed)) else f.text:SetText("") end
    else
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

local active = false
local acc = 0

ev:SetScript("OnEvent", function(self, e, a1)
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
    if type(RoguetimerDB.showBackground) ~= "boolean" then RoguetimerDB.showBackground = DEFAULTS.showBackground end
    if type(RoguetimerDB.backgroundAlpha) ~= "number" then RoguetimerDB.backgroundAlpha = DEFAULTS.backgroundAlpha end
    RoguetimerDB.backgroundAlpha = math.max(0.05, math.min(0.8, RoguetimerDB.backgroundAlpha))
    if type(RoguetimerDB.bars) ~= "table" then RoguetimerDB.bars = {} end
    for _, def in ipairs(DEFS) do
      if RoguetimerDB.bars[def.key] == nil then RoguetimerDB.bars[def.key] = true end
    end
    local _, class = UnitClass("player")
    if class ~= "ROGUE" then return end
    active = true
    BuildUI()
    UpdateBarBackgrounds()
    CreateOptions()
    ScanTalents()
  elseif not active then
    return
  elseif e == "PLAYER_ENTERING_WORLD" then
    ScanTalents()
  end
end)

ev:SetScript("OnUpdate", function(self, elapsed)
  if not active then return end
  elapsed = elapsed or arg1 or 0
  acc = acc + elapsed
  if acc >= 0.2 then
    acc = 0
    CheckTargetAuras()
  end
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
  if cmd == "unlock" then db.locked = false; Layout()
  elseif cmd == "lock" then db.locked = true; Layout()
  elseif cmd == "width" and tonumber(val) then db.width = tonumber(val); Layout()
  elseif cmd == "height" and tonumber(val) then db.height = tonumber(val); Layout()
  elseif cmd == "options" then
    FB.options:Show()
  elseif cmd == "reset" or cmd == "center" then
    db.x, db.y = nil, nil
    FB.anchor:ClearAllPoints()
    FB.anchor:SetPoint("CENTER", UIParent, "CENTER", 0, -100)
  else
    DEFAULT_CHAT_FRAME:AddMessage("Roguetimer: /roguetimer options | unlock | lock | width N | height N | center")
  end
end
