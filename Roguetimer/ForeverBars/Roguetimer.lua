-- ForeverBars 0.1
-- Rogue-Balken fuer Forever WoW 1.60 (Interface 16001)
-- Bewusst kompatibel zu Lua 5.0 (1.12-API) und 5.1 geschrieben.

local MAXTIME = 30
local BAR_TEX = "Interface\\Buttons\\WHITE8X8"

-- Erkennung ueber Icon-Pfade (sprachunabhaengig)
-- finisher = verbraucht Combo Points, scaled = Dauer haengt von CP ab
local DEFS = {
  { key = "SND", tex = "Ability_Rogue_SliceDice",   color = { 1.00, 0.85, 0.10 }, finisher = true, scaled = true },
  { key = "RUP", tex = "Ability_Rogue_Rupture",     color = { 1.00, 0.30, 0.30 }, finisher = true, scaled = true },
  { key = "GAR", tex = "Ability_Rogue_Garrote",     color = { 0.55, 0.05, 0.05 }, fixed = 18 },
  { key = "EXP", tex = "Ability_Warrior_Riposte",   color = { 0.45, 0.55, 0.80 }, finisher = true, fixed = 30 },
}

local DEFAULTS = { width = 220, height = 18, spacing = 3, locked = true }

local FB = {
  timers = {},      -- timers[zielname][key] = { start, dur }
  pending = {},     -- pending[key] = { t, cp, target, failed }
  names = {},       -- kleingeschriebener Spellname -> def
  defByKey = {},
  bars = {},
  sndBonus = 0,
}
for _, d in ipairs(DEFS) do FB.defByKey[d.key] = d end

-- Dauern (Vanilla-Werte; bei Abweichung hier anpassen)
local function Duration(def, cp)
  if def.key == "SND" then return (6 + 3 * cp) * (1 + FB.sndBonus)
  elseif def.key == "RUP" then return 6 + 2 * cp
  else return def.fixed end
end

------------------------------------------------------------
-- Hilfsfunktionen
------------------------------------------------------------
local function DefByTexture(t)
  if not t then return nil end
  for _, d in ipairs(DEFS) do
    if string.find(t, d.tex, 1, true) then return d end
  end
  return nil
end

local function GetCP()
  return GetComboPoints("player", "target") or 0
end

local function TargetHas(def)
  for i = 1, 40 do
    local a, b, c = UnitDebuff("target", i)
    if not a then break end
    local tex = a
    if not string.find(a, "Interface", 1, true) then tex = c end
    if tex and string.find(tex, def.tex, 1, true) then return true end
  end
  return false
end

local function SnDLeft()
  for i = 0, 31 do
    local idx = GetPlayerBuff(i, "HELPFUL")
    if not idx or idx < 0 then break end
    local t = GetPlayerBuffTexture(idx)
    if t and string.find(t, "Ability_Rogue_SliceDice", 1, true) then
      return GetPlayerBuffTimeLeft(idx) or 0
    end
  end
  return 0
end

local function ScanSpells()
  FB.names = {}
  local i = 1
  while true do
    local name = GetSpellName(i, BOOKTYPE_SPELL)
    if not name then break end
    local def = DefByTexture(GetSpellTexture(i, BOOKTYPE_SPELL))
    if def then FB.names[string.lower(name)] = def end
    i = i + 1
  end
end

local function ScanTalents()
  FB.sndBonus = 0
  for tab = 1, 3 do
    for i = 1, GetNumTalents(tab) do
      local _, icon, _, _, rank = GetTalentInfo(tab, i)
      if icon and rank and string.find(icon, "Ability_Rogue_SliceDice", 1, true) then
        FB.sndBonus = rank * 0.15
      end
    end
  end
end

------------------------------------------------------------
-- Cast-Erkennung (Hooks) fuer Debuffs auf dem Ziel
------------------------------------------------------------
local function MarkPending(def)
  if def.key == "SND" then return end
  if not UnitExists("target") or not UnitCanAttack("player", "target") then return end
  local cp = GetCP()
  if def.finisher and cp < 1 then return end
  FB.pending[def.key] = { t = GetTime(), cp = cp, target = UnitName("target"), failed = false }
end

local origUseAction = UseAction
UseAction = function(slot, a, b)
  local def = DefByTexture(GetActionTexture(slot))
  if def then MarkPending(def) end
  return origUseAction(slot, a, b)
end

local origCastSpellByName = CastSpellByName
CastSpellByName = function(name, onSelf)
  if name then
    local n = string.lower(name)
    n = (string.gsub(n, "%s*%(.*%)%s*$", ""))
    local def = FB.names[n]
    if def then MarkPending(def) end
  end
  return origCastSpellByName(name, onSelf)
end

local origCastSpell = CastSpell
CastSpell = function(index, book)
  local def = DefByTexture(GetSpellTexture(index, book))
  if def then MarkPending(def) end
  return origCastSpell(index, book)
end

-- Fehlschlag-Muster aus den lokalisierten GlobalStrings
local failPatterns = {}
local function AddFail(g)
  if not g then return end
  g = string.gsub(g, "([%^%$%(%)%.%[%]%*%+%-%?])", "%%%1")
  g = string.gsub(g, "%%%d%$s", "(.+)")
  g = string.gsub(g, "%%s", "(.+)")
  table.insert(failPatterns, g)
end
local function BuildFailPatterns()
  AddFail(SPELLRESISTSELFOTHER); AddFail(SPELLMISSSELFOTHER)
  AddFail(SPELLDODGEDSELFOTHER); AddFail(SPELLPARRIEDSELFOTHER)
  AddFail(SPELLIMMUNESELFOTHER); AddFail(SPELLEVADEDSELFOTHER)
  AddFail(SPELLREFLECTSELFOTHER); AddFail(SPELLBLOCKEDSELFOTHER)
end

local function OnSpellMessage(msg)
  if not msg then return end
  local isFail = false
  for _, p in ipairs(failPatterns) do
    if string.find(msg, p) then isFail = true break end
  end
  if not isFail then return end
  local lmsg = string.lower(msg)
  for name, def in pairs(FB.names) do
    if FB.pending[def.key] and string.find(lmsg, name, 1, true) then
      FB.pending[def.key].failed = true
    end
  end
end

local function FailRecentPending()
  local now = GetTime()
  for _, p in pairs(FB.pending) do
    if now - p.t < 0.5 then p.failed = true end
  end
end

------------------------------------------------------------
-- Timer-Logik fuer Debuffs (gedrosselt, ca. 5x pro Sekunde)
------------------------------------------------------------
local function CheckTargetAuras()
  if not UnitExists("target") then return end
  local name = UnitName("target")
  local now = GetTime()

  for key, p in pairs(FB.pending) do
    local def = FB.defByKey[key]
    local age = now - p.t
    if age > 1.5 or p.failed then
      FB.pending[key] = nil
    elseif age > 0.3 and p.target == name then
      if TargetHas(def) and ((not def.finisher) or GetCP() < p.cp) then
        FB.timers[name] = FB.timers[name] or {}
        FB.timers[name][key] = { start = p.t, dur = Duration(def, p.cp) }
        FB.pending[key] = nil
      end
    end
  end

  local tt = FB.timers[name]
  if tt then
    for key, tm in pairs(tt) do
      if now > tm.start + tm.dur or (now - tm.start > 0.6 and not TargetHas(FB.defByKey[key])) then
        tt[key] = nil
      end
    end
    if UnitIsDead("target") then FB.timers[name] = nil end
  end
end

------------------------------------------------------------
-- UI
------------------------------------------------------------
local function Layout()
  local db = ForeverBarsDB
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
  if db.locked then FB.anchor.tint:Hide() else FB.anchor.tint:Show() end
end

local function BuildUI()
  local db = ForeverBarsDB
  local a = CreateFrame("Frame", "ForeverBarsAnchor", UIParent)
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
  a:SetScript("OnMouseDown", function()
    if not ForeverBarsDB.locked then a:StartMoving() end
  end)
  a:SetScript("OnMouseUp", function()
    a:StopMovingOrSizing()
    local x, y = a:GetLeft(), a:GetTop()
    if x and y then
      ForeverBarsDB.x, ForeverBarsDB.y = x, y
      a:ClearAllPoints()
      a:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", x, y)
    end
  end)

  for i, def in ipairs(DEFS) do
    local c = def.color
    local f = CreateFrame("Frame", nil, a)
    f.def = def
    f.bg = f:CreateTexture(nil, "BACKGROUND")
    f.bg:SetTexture(BAR_TEX); f.bg:SetVertexColor(0, 0, 0, 0.55); f.bg:SetAllPoints(f)
    f.ghost = f:CreateTexture(nil, "BORDER")
    f.ghost:SetTexture(BAR_TEX); f.ghost:SetVertexColor(c[1], c[2], c[3], 0.35)
    f.ghost:SetPoint("TOPLEFT", f, "TOPLEFT", 0, 0)
    f.fill = f:CreateTexture(nil, "ARTWORK")
    f.fill:SetTexture(BAR_TEX); f.fill:SetVertexColor(c[1], c[2], c[3], 1)
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

local function UpdateBars()
  local db = ForeverBarsDB
  local now = GetTime()
  local W = db.width
  local cp = GetCP()
  local hasTarget = UnitExists("target") and UnitCanAttack("player", "target") and not UnitIsDead("target")
  local tname = hasTarget and UnitName("target") or nil

  for _, f in ipairs(FB.bars) do
    local def = f.def
    local remaining, ghost = 0, 0

    if def.key == "SND" then
      remaining = SnDLeft()
    elseif tname and FB.timers[tname] and FB.timers[tname][def.key] then
      local tm = FB.timers[tname][def.key]
      remaining = tm.start + tm.dur - now
      if remaining < 0 then remaining = 0 end
    end
    if def.scaled and hasTarget and cp > 0 then ghost = Duration(def, cp) end

    if remaining > 0 or ghost > 0 or not db.locked then
      f:Show()
      local gw = math.min(ghost, MAXTIME) / MAXTIME * W
      local fw = math.min(remaining, MAXTIME) / MAXTIME * W
      if gw >= 1 then f.ghost:SetWidth(gw); f.ghost:Show() else f.ghost:Hide() end
      if fw >= 1 then f.fill:SetWidth(fw); f.fill:Show() else f.fill:Hide() end
      if remaining > 0 then f.text:SetText(string.format("%.2f", remaining)) else f.text:SetText("") end
    else
      f:Hide()
    end
  end
end

------------------------------------------------------------
-- Events / Update-Schleife
------------------------------------------------------------
local ev = CreateFrame("Frame", "ForeverBarsEvents", UIParent)
ev:RegisterEvent("ADDON_LOADED")
ev:RegisterEvent("PLAYER_ENTERING_WORLD")
ev:RegisterEvent("SPELLS_CHANGED")
ev:RegisterEvent("CHARACTER_POINTS_CHANGED")
ev:RegisterEvent("CHAT_MSG_SPELL_SELF_DAMAGE")
ev:RegisterEvent("UI_ERROR_MESSAGE")
ev:RegisterEvent("SPELLCAST_FAILED")
ev:RegisterEvent("PLAYER_TARGET_CHANGED")

local active = false
local acc = 0

ev:SetScript("OnEvent", function(self, e, a1)
  e = e or event
  a1 = a1 or arg1
  if e == "ADDON_LOADED" then
    if a1 ~= "ForeverBars" then return end
    ForeverBarsDB = ForeverBarsDB or {}
    for k, v in pairs(DEFAULTS) do
      if ForeverBarsDB[k] == nil then ForeverBarsDB[k] = v end
    end
    local _, class = UnitClass("player")
    if class ~= "ROGUE" then return end
    active = true
    BuildFailPatterns()
    BuildUI()
  elseif not active then
    return
  elseif e == "PLAYER_ENTERING_WORLD" or e == "SPELLS_CHANGED" or e == "CHARACTER_POINTS_CHANGED" then
    ScanSpells(); ScanTalents()
  elseif e == "CHAT_MSG_SPELL_SELF_DAMAGE" then
    OnSpellMessage(a1)
  elseif e == "UI_ERROR_MESSAGE" or e == "SPELLCAST_FAILED" then
    FailRecentPending()
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
-- Slash-Befehle
------------------------------------------------------------
SLASH_FOREVERBARS1 = "/fbars"
SlashCmdList["FOREVERBARS"] = function(msg)
  if not active then return end
  local db = ForeverBarsDB
  msg = string.lower(msg or "")
  local _, _, cmd, val = string.find(msg, "^(%S*)%s*(%S*)$")
  if cmd == "unlock" then db.locked = false; Layout()
  elseif cmd == "lock" then db.locked = true; Layout()
  elseif cmd == "width" and tonumber(val) then db.width = tonumber(val); Layout()
  elseif cmd == "height" and tonumber(val) then db.height = tonumber(val); Layout()
  elseif cmd == "reset" then
    db.x, db.y = nil, nil
    FB.anchor:ClearAllPoints()
    FB.anchor:SetPoint("CENTER", UIParent, "CENTER", 0, -150)
  else
    DEFAULT_CHAT_FRAME:AddMessage("ForeverBars: /fbars unlock | lock | width N | height N | reset")
  end
end
