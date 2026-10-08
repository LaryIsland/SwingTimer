local _, ns = ...

ns.DEFAULTS = {
	width = 180,
	height = 15,
	barPadding = 1,
	font = "Friz Quadrata TT",
	barTexture = "Solid",
	barBorder = "None",
	borderSize = 16,
	borderOffset = 4,
	borderColor = "ffffffff",
	barColor = "ff192dc3",
	castColor = "ff198ac3",
	enemyBarColor = "ffc31919",
	showLabels = true,
	showSpeedText = true,
	speedTextAnchor = "LEFT",
	speedTextSize = 14,
	speedTextColor = "ffffffff",
	speedTextOpacity = 100,
	labelColor = "ff000000",
	labelOpacity = 50,
	labelTextSize = 12,
	labelAnchor = "CENTER",
	recolorQueuedMainHand = false,
	queuedMainHandColor = "ffde4500",
	recolorQueuedOffHand = false,
	queuedOffHandColor = "ffde4500",
	recolorQueuedOnlyDualWielding = true,

	globalAlpha = 100,
	oocAlpha = 0,
	mountedAlpha = 0,
	ignoreOnEnemyTarget = true,
	ignoreOnFriendlyTarget = false,

	showEnemySwing = true,
}

-- Auto Shot and wand Shoot make you stand still for this long at the end of each ranged swing.
local CAST_WINDOW = 0.5
local CAST_WINDOW_CLASSES = {
	HUNTER = true,
	MAGE = true,
	PRIEST = true,
	WARLOCK = true,
}

local DEFAULT_POSITION = { point = "CENTER", relativePoint = "CENTER", x = 0, y = -318 }
local TEXT_INSETS = {
	LEFT = 2,
	CENTER = 0,
	RIGHT = -2,
}

local PLAYER_ROW_COUNT = 2
local ROW_COUNT = 4

local SIMULATED_SPEEDS = {
	mainHand = 2.5,
	offHand = 1.8,
	ranged = 3.0,
	enemyMainHand = 2.0,
	enemyOffHand = 1.5,
}

-- Always available, under the names LibSharedMedia uses where it has them, so a saved choice works with or without it.
local BUILT_IN_MEDIA = {
	font = {
		["Friz Quadrata TT"] = STANDARD_TEXT_FONT, -- The client's own, with the right glyphs for its locale.
		["Arial Narrow"] = "Fonts\\ARIALN.TTF",
		["Morpheus"] = "Fonts\\MORPHEUS_CYR.TTF",
		["Skurri"] = "Fonts\\SKURRI_CYR.TTF",
	},
	statusbar = {
		["Blizzard"] = "Interface\\TargetingFrame\\UI-StatusBar",
		["Blizzard Character Skills Bar"] = "Interface\\PaperDollInfoFrame\\UI-Character-Skills-Bar",
		["Blizzard Raid Bar"] = "Interface\\RaidFrame\\Raid-Bar-Hp-Fill",
		["Solid"] = "Interface\\Buttons\\WHITE8X8",
	},
	border = {
		["None"] = "",
		["Blizzard Dialog"] = "Interface\\DialogFrame\\UI-DialogBox-Border",
		["Blizzard Tooltip"] = "Interface\\Tooltips\\UI-Tooltip-Border",
		["Forever Bronze"] = { atlas = "ui-castingbar-frame" },
		["Solid"] = "Interface\\Buttons\\WHITE8X8",
	},
}

local BACKGROUND_COLOR = { 0, 0, 0, 0.5 }
local BAR_ALPHA = 0.8
local PHASE_COLOR_KEYS = {
	swing = "barColor",
	cast = "castColor",
}

local SwingType = Enum.PlayerSwingType
local INVSLOT_OFFHAND = INVSLOT_OFFHAND or 17
local INVSLOT_RANGED = INVSLOT_RANGED or 18
local ITEM_CLASS_WEAPON = Enum.ItemClass and Enum.ItemClass.Weapon or 2
local DRUID_TRAVEL_FORM, DRUID_AQUATIC_FORM = 3, 4

local QUEUED_COLOR_KEYS = {
	[SwingType.MainHand] = { isEnabled = "recolorQueuedMainHand", color = "queuedMainHandColor" },
	[SwingType.OffHand] = { isEnabled = "recolorQueuedOffHand", color = "queuedOffHandColor" },
}

-- Every rank, as any of them can be queued from the action bars.
local QUEUED_ATTACK_SPELLS = CopyValuesAsKeys({
	78, 284, 285, 1608, 11564, 11565, 11566, 11567, 25286, -- Heroic Strike
	845, 7369, 11608, 11609, 20569, -- Cleave
	2973, 14260, 14261, 14262, 14263, 14264, 14265, 14266, -- Raptor Strike
	6807, 6808, 6809, 8972, 9745, 9880, 9881, -- Maul
})

ns.CHAT_PREFIX = "|cff3399ffSwing Timer|r"

local container = CreateFrame("Frame", "LaryIslandSwingTimerFrame", UIParent)
local bars = {}
local lastSwings = {}
local db = ns.DEFAULTS -- Replaced by the active profile on login.
ns.db = db
local playerClass
local classHasCastWindow = false
local isUnlocked = false
local isPreviewing = false
local simulation
local inBarberShop = false
local isRangedActive = false
local queuedSpellID

function ns.IsSecret(value)
	return issecretvalue ~= nil and issecretvalue(value)
end

local function HasWeaponInSlot(slot)
	local itemID = GetInventoryItemID("player", slot)
	if not itemID then
		return false
	end

	local classID = select(6, C_Item.GetItemInfoInstant(itemID))
	return classID == ITEM_CLASS_WEAPON
end

local function GetEquippedSwingDuration(swingType)
	-- Player stats can be secret while unit stats are restricted, so only trust plain numbers.
	local speed = select(swingType + 1, UnitAttackSpeed("player"))
	if speed == nil or ns.IsSecret(speed) or speed <= 0 then
		return nil
	end
	return speed
end

local function IsInTravelForm()
	if playerClass ~= "DRUID" or not GetShapeshiftFormID then
		return false
	end

	local formID = GetShapeshiftFormID()
	return formID == DRUID_TRAVEL_FORM or formID == DRUID_AQUATIC_FORM
end

local function GetSharedMedia()
	return LibStub and LibStub("LibSharedMedia-3.0", true)
end

function ns.GetMediaNames(mediaType)
	local isListed = {}
	for name in pairs(BUILT_IN_MEDIA[mediaType]) do
		isListed[name] = true
	end

	local sharedMedia = GetSharedMedia()
	if sharedMedia then
		for _, name in ipairs(sharedMedia:List(mediaType)) do
			isListed[name] = true
		end
	end

	local names = {}
	for name in pairs(isListed) do
		table.insert(names, name)
	end
	table.sort(names)
	return names
end

local function FetchMedia(mediaType, name, defaultName)
	local sharedMedia = GetSharedMedia()
	return (sharedMedia and sharedMedia:Fetch(mediaType, name, true)) or BUILT_IN_MEDIA[mediaType][name]
		or BUILT_IN_MEDIA[mediaType][defaultName]
end

local function GetFontPath()
	return FetchMedia("font", db.font, ns.DEFAULTS.font)
end

local function GetBarTexturePath()
	return FetchMedia("statusbar", db.barTexture, ns.DEFAULTS.barTexture)
end

local SUGGESTED_BORDER_LAYOUTS = {
	["Blizzard Dialog"] = { size = 32, offset = 11 },
	["Blizzard Tooltip"] = { size = 16, offset = 4 },
	["Forever Bronze"] = { offset = 2 },
	["Solid"] = { size = 1, offset = 1 },
}
local DEFAULT_SUGGESTED_BORDER_LAYOUT = { size = 16, offset = 4 }

function ns.IsAtlasBorder(name)
	return type(BUILT_IN_MEDIA.border[name]) == "table"
end

-- Returns the size and offset that suit the passed border (no size for an atlas), or nothing for None.
function ns.GetSuggestedBorderLayout(name)
	if name ~= ns.DEFAULTS.barBorder then
		local layout = SUGGESTED_BORDER_LAYOUTS[name] or DEFAULT_SUGGESTED_BORDER_LAYOUT
		return layout.size, layout.offset
	end
end

local function GetBorder()
	if db.barBorder == ns.DEFAULTS.barBorder then
		return nil
	end
	local border = FetchMedia("border", db.barBorder, ns.DEFAULTS.barBorder)
	if type(border) == "table" then
		return C_Texture.GetAtlasInfo(border.atlas) and border or nil
	end
	return border ~= "" and border or nil
end

-- FontStrings given a font file directly can stop drawing text that isn't set again, so they inherit these instead.
local speedTextFont = CreateFont("LaryIslandSwingTimerSpeedTextFont")
speedTextFont:SetShadowColor(0, 0, 0, 1)
speedTextFont:SetShadowOffset(1, -1)
local labelFont = CreateFont("LaryIslandSwingTimerLabelFont")

local function SetFontOrDefault(font, path, size)
	if not font:SetFont(path, size, "") then
		font:SetFont(STANDARD_TEXT_FONT, size, "")
	end
end

SetFontOrDefault(speedTextFont, GetFontPath(), db.speedTextSize)
SetFontOrDefault(labelFont, GetFontPath(), db.labelTextSize)

-- Text set before a font change can stop drawing until it's set again.
local function RedrawText(fontString)
	local text = fontString:GetText()
	fontString:SetText("")
	fontString:SetText(text)
end

local function GetBarGradient(hexColor)
	local color = CreateColorFromHexString(hexColor)
	local function Darken(value)
		return math.max(value * 0.8 - 0.05, 0)
	end
	return CreateColor(Darken(color.r), Darken(color.g), Darken(color.b), BAR_ALPHA), CreateColor(color.r, color.g, color.b, BAR_ALPHA)
end

function ns.SetBarColors(bar, colorKey)
	bar.colorKey = colorKey
	local hexColor = db[colorKey] --[[@as string]]
	bar:GetStatusBarTexture():SetGradient("HORIZONTAL", GetBarGradient(hexColor))
end

function ns.CreateBarFrame(labelText)
	local bar = CreateFrame("StatusBar", nil, container)
	bar:SetPoint("TOP", container, "TOP")
	bar:SetStatusBarTexture(GetBarTexturePath())
	bar:SetMinMaxValues(0, 1)
	bar:Hide()

	local background = bar:CreateTexture(nil, "BACKGROUND")
	background:SetAllPoints()
	background:SetColorTexture(unpack(BACKGROUND_COLOR))

	local speedText = bar:CreateFontString(nil, "OVERLAY", "LaryIslandSwingTimerSpeedTextFont")
	speedText:SetPoint("LEFT", bar, "LEFT", 2, 0)
	bar.SpeedText = speedText

	local label = bar:CreateFontString(nil, "OVERLAY", "LaryIslandSwingTimerLabelFont")
	label:SetPoint("CENTER")
	label:SetText(labelText)
	bar.Label = label

	local border = CreateFrame("Frame", nil, bar, "BackdropTemplate")
	border.Atlas = border:CreateTexture()
	border.Atlas:SetAllPoints()
	bar.Border = border

	return bar
end

local SwingBarMixin = {}

function SwingBarMixin:UpdateColor()
	local colorKey = PHASE_COLOR_KEYS[self.phase]
	local queuedKeys = QUEUED_COLOR_KEYS[self.swingType]
	if queuedKeys and db[queuedKeys.isEnabled] and queuedSpellID
		and (not db.recolorQueuedOnlyDualWielding or HasWeaponInSlot(INVSLOT_OFFHAND)) then
		colorKey = queuedKeys.color
	end

	if colorKey ~= self.colorKey then
		ns.SetBarColors(self, colorKey)
	end
end

function SwingBarMixin:SetPhase(phase)
	if self.phase == phase then
		return
	end

	self.phase = phase
	self:UpdateColor()
end

function SwingBarMixin:IsSwinging()
	return self.endTime ~= nil and self.endTime > GetTime()
end

function SwingBarMixin:Start(duration)
	if not duration or duration <= 0 then
		return
	end

	self.duration = duration
	self.endTime = GetTime() + duration
	self.SpeedText:SetFormattedText("%.1f", duration)
	self:SetScript("OnUpdate", self.OnUpdate)
	self:Refresh()
end

function SwingBarMixin:Stop()
	self.endTime = nil
	self:SetScript("OnUpdate", nil)
	self:Refresh()
end

function SwingBarMixin:OnUpdate()
	if self:IsSwinging() then
		self:Refresh()
	else
		self:Stop()
	end
end

function SwingBarMixin:Refresh()
	local remaining = self.endTime and max(self.endTime - GetTime(), 0) or 0
	local duration = self.duration

	if self.hasCastWindow then
		-- Fill up over the reload, then drain over the cast.
		if remaining <= CAST_WINDOW then
			self:SetPhase("cast")
			self:SetValue(remaining / CAST_WINDOW)
		else
			self:SetPhase("swing")
			self:SetValue((duration - remaining) / (duration - CAST_WINDOW))
		end
	else
		self:SetPhase("swing")
		self:SetValue(duration and (1 - remaining / duration) or 1)
	end
end

local function CreateSwingBar(swingType, labelText)
	local bar = Mixin(ns.CreateBarFrame(labelText), SwingBarMixin)
	bar.swingType = swingType
	bar:SetScript("OnShow", bar.Refresh)
	bar:Refresh()

	bars[swingType] = bar
	return bar
end

container:SetClampedToScreen(true)
container:SetMovable(true)

local mover = CreateFrame("Frame", nil, container)
mover:SetPoint("TOP", container, "TOP")
mover:SetFrameLevel(container:GetFrameLevel() + 20)
mover:EnableMouse(true)
mover:RegisterForDrag("LeftButton")
mover:SetIgnoreParentAlpha(true)
mover:Hide()

local moverBackground = mover:CreateTexture(nil, "BACKGROUND")
moverBackground:SetAllPoints()
moverBackground:SetColorTexture(0.2, 0.6, 1, 0.3)

local moverText = mover:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
moverText:SetPoint("CENTER")
moverText:SetText("Drag to move")

-- Ranged shares the main hand's slot; whichever kind of attack was used last is shown.
CreateSwingBar(SwingType.MainHand, "Main Hand")
CreateSwingBar(SwingType.OffHand, "Off-Hand")
CreateSwingBar(SwingType.Ranged, "Ranged")

local function AnchorText(bar, fontString, anchorKey)
	local anchor = TEXT_INSETS[db[anchorKey]] and db[anchorKey] or ns.DEFAULTS[anchorKey]
	fontString:ClearAllPoints()
	fontString:SetPoint(anchor, bar, anchor, TEXT_INSETS[anchor], 0)
end

local function StyleBar(bar, style)
	bar:SetSize(db.width, db.height)
	bar:SetStatusBarTexture(style.texture)
	if bar.colorKey then
		-- Setting the texture drops its gradient.
		ns.SetBarColors(bar, bar.colorKey)
	end

	AnchorText(bar, bar.SpeedText, "speedTextAnchor")
	RedrawText(bar.SpeedText)
	local speedTextColor = style.speedTextColor
	bar.SpeedText:SetTextColor(speedTextColor.r, speedTextColor.g, speedTextColor.b, db.speedTextOpacity / 100)
	bar.SpeedText:SetShown(db.showSpeedText)
	AnchorText(bar, bar.Label, "labelAnchor")
	RedrawText(bar.Label)
	bar.Label:SetShown(db.showLabels)
	bar.Label:SetTextColor(style.labelColor.r, style.labelColor.g, style.labelColor.b, db.labelOpacity / 100)

	local border = bar.Border
	border:SetShown(style.border ~= nil)
	border.Atlas:SetShown(type(style.border) == "table")
	if not style.border then
		return
	end

	local offset = db.borderOffset
	border:SetPoint("TOPLEFT", -offset, offset)
	border:SetPoint("BOTTOMRIGHT", offset, -offset)
	local color = style.borderColor
	if type(style.border) == "table" then
		border:SetBackdrop(nil)
		border.Atlas:SetAtlas(style.border.atlas)
		border.Atlas:SetVertexColor(color.r, color.g, color.b, color.a)
	else
		border:SetBackdrop({ edgeFile = style.border, edgeSize = db.borderSize })
		border:SetBackdropBorderColor(color.r, color.g, color.b, color.a)
	end
end

local function ApplyLayout()
	container:SetSize(db.width, db.height)
	SetFontOrDefault(speedTextFont, GetFontPath(), db.speedTextSize)
	SetFontOrDefault(labelFont, GetFontPath(), db.labelTextSize)

	local style = {
		texture = GetBarTexturePath(),
		speedTextColor = CreateColorFromHexString(db.speedTextColor),
		labelColor = CreateColorFromHexString(db.labelColor),
		border = GetBorder(),
		borderColor = CreateColorFromHexString(db.borderColor),
	}
	for _, bar in pairs(bars) do
		StyleBar(bar, style)
	end

	local rowOffset = db.height + db.barPadding
	local rowCount = db.showEnemySwing and ROW_COUNT or PLAYER_ROW_COUNT
	mover:SetSize(db.width, rowCount * rowOffset - db.barPadding)
	bars[SwingType.OffHand]:SetPoint("TOP", container, "TOP", 0, -rowOffset)

	for index, bar in ipairs(ns.EnemySwing.bars) do
		StyleBar(bar, style)
		bar:SetPoint("TOP", container, "TOP", 0, -(index + 1) * rowOffset)
	end
end

local function OnSharedMediaRegistered(_, mediaType, name)
	if (mediaType == "font" and name == db.font) or (mediaType == "statusbar" and name == db.barTexture)
		or (mediaType == "border" and name == db.barBorder) then
		ApplyLayout()
	end
end

local function UpdateVisibility()
	if isPreviewing or simulation then
		local showRanged = simulation == "ranged" or simulation == "autoshot"
		bars[SwingType.MainHand]:SetShown(not showRanged)
		bars[SwingType.OffHand]:SetShown(not showRanged)
		bars[SwingType.Ranged]:SetShown(showRanged)
		for _, bar in ipairs(ns.EnemySwing.bars) do
			bar:SetShown(db.showEnemySwing)
		end
		return
	end

	bars[SwingType.MainHand]:SetShown(not isRangedActive)
	bars[SwingType.OffHand]:SetShown(not isRangedActive and HasWeaponInSlot(INVSLOT_OFFHAND))
	bars[SwingType.Ranged]:SetShown(isRangedActive)
	ns.EnemySwing.UpdateVisibility()
end
ns.UpdateVisibility = UpdateVisibility

local function UpdateAlpha()
	local alpha = db.globalAlpha

	if isPreviewing or simulation then
		alpha = db.globalAlpha
	elseif inBarberShop then
		alpha = 0
	elseif IsMounted() or IsInTravelForm() then
		alpha = min(alpha, db.mountedAlpha)
	else
		if not UnitAffectingCombat("player") then
			alpha = min(alpha, db.oocAlpha)
		end

		if UnitExists("target") then
			local isEnemy = UnitCanAttack("player", "target") or UnitIsEnemy("player", "target")
			if (isEnemy and db.ignoreOnEnemyTarget) or (not isEnemy and db.ignoreOnFriendlyTarget) then
				alpha = db.globalAlpha
			end
		end
	end

	container:SetAlpha(alpha / 100)
end

local function UpdateAll()
	UpdateVisibility()
	UpdateAlpha()
end

ns.DEFAULT_POSITION = DEFAULT_POSITION

local function ApplyPosition()
	local position = db.position or DEFAULT_POSITION
	container:ClearAllPoints()
	container:SetPoint(position.point, UIParent, position.relativePoint, position.x, position.y)
end

local function RoundToPixel(value)
	return math.floor(value + 0.5)
end

function ns.GetPositionOffset()
	local position = db.position or DEFAULT_POSITION
	if position.point == "CENTER" and position.relativePoint == "CENTER" then
		return position.x, position.y
	end

	-- Saved against another anchor point by an earlier version.
	local x, y = container:GetCenter()
	local screenX, screenY = UIParent:GetCenter()
	return RoundToPixel(x - screenX), RoundToPixel(y - screenY)
end

function ns.SetPositionOffset(x, y)
	db.position = { point = "CENTER", relativePoint = "CENTER", x = x, y = y }
	ApplyPosition()
end

mover:SetScript("OnDragStart", function()
	container:StartMoving()
end)
mover:SetScript("OnDragStop", function()
	container:StopMovingOrSizing()

	local x, y = container:GetCenter()
	local screenX, screenY = UIParent:GetCenter()
	ns.SetPositionOffset(RoundToPixel(x - screenX), RoundToPixel(y - screenY))
	if ns.OnPositionChanged then
		ns.OnPositionChanged()
	end
end)

function ns.IsUnlocked()
	return isUnlocked
end

function ns.SetUnlocked(unlocked)
	isUnlocked = unlocked
	mover:SetShown(unlocked)
	UpdateAll()
end

function ns.IsPreviewing()
	return isPreviewing
end

function ns.SetPreviewing(previewing)
	isPreviewing = previewing
	UpdateAll()
end

local simulationFrame = CreateFrame("Frame")
local simulatedSwings = {}

local function OnSimulationUpdate()
	local now = GetTime()
	for _, swing in ipairs(simulatedSwings) do
		if now >= swing.nextSwing then
			swing.play(swing.speed)
			swing.nextSwing = now + swing.speed
		end
	end
end

local function AddSimulatedSwing(speed, play)
	table.insert(simulatedSwings, { speed = speed, nextSwing = GetTime(), play = play })
end

local function StartPlayerSwing(swingType)
	return function(speed)
		bars[swingType]:Start(speed)
	end
end

local function StartEnemySwing(handKey)
	return function(speed)
		ns.EnemySwing.SimulateSwing(handKey, speed)
	end
end

function ns.GetSimulation()
	return simulation or "none"
end

function ns.SetSimulation(mode)
	local newSimulation = mode ~= "none" and mode or nil
	if newSimulation == simulation then
		return
	end

	simulation = newSimulation
	wipe(simulatedSwings)
	local rangedBar = bars[SwingType.Ranged]
	if simulation == "autoshot" then
		rangedBar.hasCastWindow = true
	elseif simulation == "ranged" then
		rangedBar.hasCastWindow = false
	else
		rangedBar.hasCastWindow = classHasCastWindow
	end
	for _, bar in pairs(bars) do
		bar:Stop()
	end

	if simulation == "ranged" or simulation == "autoshot" then
		AddSimulatedSwing(SIMULATED_SPEEDS.ranged, StartPlayerSwing(SwingType.Ranged))
	elseif simulation == "melee" then
		AddSimulatedSwing(SIMULATED_SPEEDS.mainHand, StartPlayerSwing(SwingType.MainHand))
		AddSimulatedSwing(SIMULATED_SPEEDS.offHand, StartPlayerSwing(SwingType.OffHand))
	end

	if simulation then
		AddSimulatedSwing(SIMULATED_SPEEDS.enemyMainHand, StartEnemySwing("main"))
		AddSimulatedSwing(SIMULATED_SPEEDS.enemyOffHand, StartEnemySwing("off"))
		simulationFrame:SetScript("OnUpdate", OnSimulationUpdate)
	else
		simulationFrame:SetScript("OnUpdate", nil)
		ns.EnemySwing.EndSimulation()
	end
	UpdateAll()
end

local function NotifyPreviewChanged()
	if ns.OnPreviewChanged then
		ns.OnPreviewChanged()
	end
end

function ns.ResetPosition()
	db.position = nil
	ApplyPosition()
	if ns.OnPositionChanged then
		ns.OnPositionChanged()
	end
end

local function UpdateBarColors()
	for _, bar in pairs(bars) do
		bar:UpdateColor()
	end
end

local function UpdateQueuedSpell()
	local currentSpellID
	for spellID in pairs(QUEUED_ATTACK_SPELLS) do
		if C_Spell.IsCurrentSpell(spellID) then
			currentSpellID = spellID
			break
		end
	end

	if currentSpellID ~= queuedSpellID then
		ns.ProbeLog("queued attack: %s", tostring(currentSpellID))
		queuedSpellID = currentSpellID
		UpdateBarColors()
	end
end

function ns.ApplySettings()
	ApplyLayout()
	UpdateBarColors()
	UpdateAll()
end

function ns.UseProfile(profile)
	db = profile
	ns.db = profile
	ApplyPosition()
	ns.ApplySettings()
end

function ns.DescribePlayerState(Line)
	local swingTypeNames = { [SwingType.MainHand] = "Main Hand", [SwingType.OffHand] = "Off-Hand", [SwingType.Ranged] = "Ranged" }
	local point, _, relativePoint, x, y = container:GetPoint(1)

	Line("class=%s inCombat=%s target=%s alpha=%.2f", tostring(playerClass), tostring(UnitAffectingCombat("player")),
		tostring(UnitExists("target")), container:GetAlpha())
	Line("unlocked=%s preview=%s simulation=%s", tostring(isUnlocked), tostring(isPreviewing), ns.GetSimulation())
	Line("position=%s/%s %.0f, %.0f shown=%s", tostring(point), tostring(relativePoint), x or 0, y or 0, tostring(container:IsVisible()))
	Line("offHandWeapon=%s rangedWeapon=%s rangedActive=%s", tostring(HasWeaponInSlot(INVSLOT_OFFHAND)),
		tostring(HasWeaponInSlot(INVSLOT_RANGED)), tostring(isRangedActive))
	Line("queuedSpell=%s recolor mainHand=%s offHand=%s onlyDualWielding=%s", tostring(queuedSpellID),
		tostring(db.recolorQueuedMainHand), tostring(db.recolorQueuedOffHand), tostring(db.recolorQueuedOnlyDualWielding))
	for swingType, name in pairs(swingTypeNames) do
		local lastSwing = lastSwings[swingType]
		local lastSwingText = lastSwing and ("%.1fs, %.0fs ago"):format(lastSwing.duration, GetTime() - lastSwing.time) or "never"
		local label = bars[swingType].Label
		Line("%s: shown=%s lastSwing=%s", name, tostring(bars[swingType]:IsShown()), lastSwingText)
		Line("  label: text=%s shown=%s width=%.0f font=%s", tostring(label:GetText()), tostring(label:IsShown()),
			label:GetStringWidth(), tostring(label:GetFont()))
	end
end

local slashCommands = {}
local slashCommandNames = {}

function ns.RegisterSlashCommand(name, handler)
	slashCommands[name] = handler
	table.insert(slashCommandNames, name)
end

ns.RegisterSlashCommand("unlock", function()
	ns.SetUnlocked(true)
	NotifyPreviewChanged()
	print(ns.CHAT_PREFIX, "unlocked: drag the handle over the bars to move them. |cffffd100/lst lock|r when done.")
end)

ns.RegisterSlashCommand("lock", function()
	ns.SetUnlocked(false)
	NotifyPreviewChanged()
	print(ns.CHAT_PREFIX, "locked.")
end)

ns.RegisterSlashCommand("reset", function()
	ns.ResetPosition()
	print(ns.CHAT_PREFIX, "position reset.")
end)

SLASH_LARYISLANDSWINGTIMER1 = "/lst"
SLASH_LARYISLANDSWINGTIMER2 = "/laryswing"
SlashCmdList.LARYISLANDSWINGTIMER = function(msg)
	local command = strtrim(msg or ""):lower()

	if slashCommands[command] then
		slashCommands[command]()
	elseif command == "" then
		Settings.OpenToCategory(ns.optionsCategory:GetID())
	else
		local commandList = { "|cffffd100/lst|r (options)" }
		for _, name in ipairs(slashCommandNames) do
			table.insert(commandList, ("|cffffd100/lst %s|r"):format(name))
		end
		print(ns.CHAT_PREFIX, "commands: " .. table.concat(commandList, ", "))
	end
end

local EVENT_HANDLERS = {}

function EVENT_HANDLERS.PLAYER_LOGIN()
	playerClass = UnitClassBase("player")
	classHasCastWindow = CAST_WINDOW_CLASSES[playerClass] or false
	local rangedBar = bars[SwingType.Ranged]
	rangedBar.hasCastWindow = classHasCastWindow
	rangedBar:Refresh()

	local sharedMedia = GetSharedMedia()
	if sharedMedia then
		-- Added to the library at runtime by CallbackHandler.
		---@diagnostic disable-next-line: undefined-field
		sharedMedia.RegisterCallback(ns, "LibSharedMedia_Registered", OnSharedMediaRegistered)
	end

	ns.UseProfile(ns.Profiles.Load())
	ns.optionsCategory = ns.RegisterOptions()
end

function EVENT_HANDLERS.PLAYER_SWING(swingDuration, swingType)
	lastSwings[swingType] = { duration = swingDuration, time = GetTime() }

	local bar = bars[swingType]
	if bar then
		bar:Start(swingDuration)
	end

	local isRanged = swingType == SwingType.Ranged
	if isRanged ~= isRangedActive then
		isRangedActive = isRanged
		UpdateVisibility()
	end
end

function EVENT_HANDLERS.WEAPON_SLOT_CHANGED()
	-- Swapping weapons restarts the swing.
	for swingType, bar in pairs(bars) do
		if bar:IsSwinging() then
			local duration = GetEquippedSwingDuration(swingType)
			if duration then
				bar:Start(duration)
			else
				bar:Stop()
			end
		end
	end
	UpdateVisibility()
end

function EVENT_HANDLERS.PLAYER_EQUIPMENT_CHANGED()
	UpdateVisibility()
	UpdateBarColors()
end

function EVENT_HANDLERS.PLAYER_REGEN_DISABLED()
	if simulation then
		ns.SetSimulation("none")
		NotifyPreviewChanged()
	end
	UpdateAll()
end

function EVENT_HANDLERS.BARBER_SHOP_OPEN()
	inBarberShop = true
	UpdateAlpha()
end

function EVENT_HANDLERS.BARBER_SHOP_CLOSE()
	inBarberShop = false
	UpdateAlpha()
end

-- The action bars highlight queued attacks from this, so it fires whenever one is queued, goes off or is unqueued.
EVENT_HANDLERS.ACTIONBAR_UPDATE_STATE = UpdateQueuedSpell
EVENT_HANDLERS.PLAYER_TARGET_CHANGED = UpdateAlpha
EVENT_HANDLERS.PLAYER_ENTERING_WORLD = UpdateAll
EVENT_HANDLERS.PLAYER_REGEN_ENABLED = UpdateAll
EVENT_HANDLERS.PLAYER_IN_COMBAT_CHANGED = UpdateAll
EVENT_HANDLERS.PLAYER_ALIVE = UpdateAlpha
EVENT_HANDLERS.PLAYER_DEAD = UpdateAlpha
EVENT_HANDLERS.PLAYER_UNGHOST = UpdateAlpha
EVENT_HANDLERS.PLAYER_MOUNT_DISPLAY_CHANGED = UpdateAlpha
EVENT_HANDLERS.UPDATE_SHAPESHIFT_FORM = UpdateAlpha
EVENT_HANDLERS.UPDATE_BONUS_ACTIONBAR = UpdateAlpha

for event in pairs(EVENT_HANDLERS) do
	container:RegisterEvent(event)
end

container:SetScript("OnEvent", function(_, event, ...)
	EVENT_HANDLERS[event](...)
end)
