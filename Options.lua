local _, ns = ...

local SETTING_PREFIX = "LARYISLAND_SWINGTIMER_"

local function FormatPercent(value)
	return ("%d%%"):format(value)
end

local function FormatPixels(value)
	return ("%d px"):format(value)
end

local RESET_DIALOG = "LARYISLAND_SWINGTIMER_RESET_SETTINGS"

local TEXT_POSITIONS = {
	{ "LEFT", "Left" },
	{ "CENTER", "Middle" },
	{ "RIGHT", "Right" },
}

-- A section header with a reset button beside its title. Header frames are pooled and reused for
-- every section, so the button is hidden again whenever its frame is set up for another header.
local function CreateHeaderWithResetButton(name, resetTitle, resetTooltip, onReset)
	local header = CreateSettingsListSectionHeaderInitializer(name)
	header.reset = { title = resetTitle, tooltip = resetTooltip, onReset = onReset }
	local baseInitFrame = header.InitFrame

	function header:InitFrame(frame)
		baseInitFrame(self, frame)

		if not frame.LaryIslandSwingTimerReset then
			local button = CreateFrame("Button", nil, frame)
			button:SetSize(18, 18)
			button:SetPoint("LEFT", frame.Title, "RIGHT", 6, 0)
			button:SetNormalAtlas("common-icon-undo")
			button:SetHighlightAtlas("common-icon-undo", "ADD")
			button:GetHighlightTexture():SetAlpha(0.4)
			button:SetScript("OnClick", function(owner)
				owner.reset.onReset()
			end)
			button:SetScript("OnEnter", function(owner)
				GameTooltip:SetOwner(owner, "ANCHOR_RIGHT")
				GameTooltip_SetTitle(GameTooltip, owner.reset.title)
				GameTooltip_AddNormalLine(GameTooltip, owner.reset.tooltip)
				GameTooltip:Show()
			end)
			button:SetScript("OnLeave", GameTooltip_Hide)
			frame.LaryIslandSwingTimerReset = button

			hooksecurefunc(frame, "Init", function(_, initializer)
				button:SetShown(initializer.reset ~= nil)
			end)
		end

		local button = frame.LaryIslandSwingTimerReset
		button.reset = self.reset
		button:Show()
	end

	return header
end

function ns.RegisterOptions(db)
	local category, layout = Settings.RegisterVerticalLayoutCategory("LaryIsland's Swing Timer")
	local allSettings = {}
	local sectionSettings -- The settings in the section being added, which its reset button resets.

	local function TrackSetting(setting)
		table.insert(allSettings, setting)
		table.insert(sectionSettings, setting)
		return setting
	end

	local function AddSetting(key, name, variableType)
		local setting = Settings.RegisterAddOnSetting(category, SETTING_PREFIX .. key:upper(), key, db, variableType, name, ns.DEFAULTS[key])
		setting:SetValueChangedCallback(ns.ApplySettings)
		return TrackSetting(setting)
	end

	local function AddProxySetting(key, name, variableType, defaultValue, getValue, setValue)
		return TrackSetting(Settings.RegisterProxySetting(category, SETTING_PREFIX .. key, variableType, name, defaultValue, getValue, setValue))
	end

	local function AddCheckbox(key, name, tooltip)
		Settings.CreateCheckbox(category, AddSetting(key, name, Settings.VarType.Boolean), tooltip)
	end

	local function AddSlider(key, name, minValue, maxValue, formatter, tooltip)
		local setting = AddSetting(key, name, Settings.VarType.Number)
		local options = Settings.CreateSliderOptions(minValue, maxValue, 1)
		options:SetLabelFormatter(MinimalSliderWithSteppersMixin.Label.Right, formatter)
		Settings.CreateSlider(category, setting, options, tooltip)
		return setting
	end

	-- Lists the media each time the dropdown opens, so ones registered after login are included.
	local function AddMediaDropdown(key, name, mediaType, tooltip)
		local function GetOptions()
			local container = Settings.CreateControlTextContainer()
			for _, mediaName in ipairs(ns.GetMediaNames(mediaType)) do
				container:Add(mediaName, mediaName)
			end
			return container:GetData()
		end
		Settings.CreateDropdown(category, AddSetting(key, name, Settings.VarType.String), GetOptions, tooltip)
	end

	-- choices is a list of { value, label } pairs.
	local function AddChoiceDropdown(key, name, choices, tooltip)
		local function GetOptions()
			local container = Settings.CreateControlTextContainer()
			for _, choice in ipairs(choices) do
				container:Add(choice[1], choice[2])
			end
			return container:GetData()
		end
		Settings.CreateDropdown(category, AddSetting(key, name, Settings.VarType.String), GetOptions, tooltip)
	end

	-- Starts a section whose header has a button resetting the settings added to it.
	local function AddSection(name, resetTooltip)
		local settings = {}
		sectionSettings = settings
		layout:AddInitializer(CreateHeaderWithResetButton(name, "Reset " .. name, resetTooltip, function()
			for _, setting in ipairs(settings) do
				setting:SetValueToDefault()
			end
		end))
	end

	-- Offsets of the bars from the centre of the screen. The slider's arrows move a pixel at a time.
	local function AddPositionSlider(axis, name, halfRange, tooltip)
		local function GetValue()
			local x, y = ns.GetPositionOffset()
			return axis == "x" and x or y
		end

		local function SetValue(value)
			local x, y = ns.GetPositionOffset()
			value = math.floor(value + 0.5)
			if axis == "x" then
				ns.SetPositionOffset(value, y)
			else
				ns.SetPositionOffset(x, value)
			end
		end

		local setting = AddProxySetting("POSITION_" .. axis:upper(), name, Settings.VarType.Number, ns.DEFAULT_POSITION[axis], GetValue, SetValue)
		local options = Settings.CreateSliderOptions(-halfRange, halfRange, 1)
		options:SetLabelFormatter(MinimalSliderWithSteppersMixin.Label.Right, FormatPixels)
		Settings.CreateSlider(category, setting, options, tooltip)
		return setting
	end

	-- None of these are saved: the bars always start locked, hidden out of combat and not simulating.
	AddSection("Preview", "Lock the bars and turn off the preview and simulation.")
	local unlockSetting = AddProxySetting("UNLOCKED", "Unlock", Settings.VarType.Boolean, false, ns.IsUnlocked, ns.SetUnlocked)
	Settings.CreateCheckbox(category, unlockSetting, "Show a handle over the bars that can be dragged to move them.")
	local previewSetting = AddProxySetting("PREVIEW", "Preview", Settings.VarType.Boolean, false, ns.IsPreviewing, ns.SetPreviewing)
	Settings.CreateCheckbox(category, previewSetting, "Show all the bars outside of combat, to see how they look.")
	local simulationSetting = AddProxySetting("SIMULATION", "Simulate", Settings.VarType.String, "none", ns.GetSimulation, ns.SetSimulation)
	local function GetSimulationOptions()
		local container = Settings.CreateControlTextContainer()
		container:Add("none", "Off")
		container:Add("melee", "Melee")
		container:Add("ranged", "Ranged")
		container:Add("autoshot", "Ranged (Auto Shot)")
		return container:GetData()
	end
	Settings.CreateDropdown(category, simulationSetting, GetSimulationOptions,
		"Plays fake swings on the bars.\nWith Auto Shot, the ranged bar fills up 0.5 seconds before each shot, then drains over those 0.5 seconds while you have to stand still for the shot to fire. You're free to move again once it's empty.")
	-- Keep the controls in step when these change from a slash command or entering combat.
	ns.OnPreviewChanged = function()
		unlockSetting:NotifyUpdate()
		previewSetting:NotifyUpdate()
		simulationSetting:NotifyUpdate()
	end

	AddSection("Position", "Move the bars back to their default position below the centre of the screen.")
	local xSetting = AddPositionSlider("x", "X Offset", math.floor(UIParent:GetWidth() / 2),
		"How far the bars are right of the centre of the screen, or left if negative.")
	local ySetting = AddPositionSlider("y", "Y Offset", math.floor(UIParent:GetHeight() / 2),
		"How far the bars are above the centre of the screen, or below if negative.")
	-- Keep the sliders in step when the bars are dragged or reset with /lst reset.
	ns.OnPositionChanged = function()
		xSetting:NotifyUpdate()
		ySetting:NotifyUpdate()
	end

	AddSection("Size", "Set the bars' width and height back to their defaults.")
	AddSlider("width", "Width", 50, 600, FormatPixels)
	AddSlider("height", "Height", 5, 60, FormatPixels)

	AddSection("Appearance", "Set the font, bar texture, spacing and bar colours back to their defaults.")
	local sharedMediaNote = "Includes any added by other addons through LibSharedMedia, such as SharedMedia or WeakAuras."
	AddMediaDropdown("font", "Font", "font", sharedMediaNote)
	AddMediaDropdown("barTexture", "Bar Texture", "statusbar", sharedMediaNote)
	AddSlider("barPadding", "Bar Spacing", 0, 30, FormatPixels, "The gap between the rows of bars.")
	local gradientNote = " The bar fades to a darker shade of it towards the start."
	Settings.CreateColorSwatch(category, AddSetting("barColor", "Bar Colour", Settings.VarType.String),
		"The colour of your main hand, off-hand and ranged bars." .. gradientNote)
	Settings.CreateColorSwatch(category, AddSetting("castColor", "Ranged Cast Colour", Settings.VarType.String),
		"The last 0.5 seconds of Auto Shot or a wand's Shoot, when you have to stand still to fire. Hunters, Mages, Priests and Warlocks only." .. gradientNote)
	Settings.CreateColorSwatch(category, AddSetting("enemyBarColor", "Enemy Bar Colour", Settings.VarType.String),
		"The colour of your target's swing bars." .. gradientNote)

	AddSection("Swing Speed", "Set how the swing speeds are shown back to the defaults.")
	AddCheckbox("showSpeedText", "Show Swing Speeds", "Show each bar's swing speed, in seconds, on the bar.")
	AddChoiceDropdown("speedTextAnchor", "Swing Speed Position", TEXT_POSITIONS,
		"Where on the bar the swing speed goes. Watch out for overlapping the label if they're in the same place.")
	AddSlider("speedTextSize", "Swing Speed Size", 6, 32, FormatPixels)
	Settings.CreateColorSwatch(category, AddSetting("speedTextColor", "Swing Speed Colour", Settings.VarType.String))
	AddSlider("speedTextOpacity", "Swing Speed Opacity", 0, 100, FormatPercent)

	AddSection("Labels", "Set how the bar labels are shown back to the defaults.")
	AddCheckbox("showLabels", "Show Bar Labels", "Show \"Main Hand\", \"Off-Hand\" and \"Ranged\" on the bars.")
	AddChoiceDropdown("labelAnchor", "Label Position", TEXT_POSITIONS,
		"Where on the bar the label goes. Watch out for overlapping the swing speed if they're in the same place.")
	AddSlider("labelTextSize", "Label Size", 6, 32, FormatPixels)
	Settings.CreateColorSwatch(category, AddSetting("labelColor", "Label Colour", Settings.VarType.String))
	AddSlider("labelOpacity", "Label Opacity", 0, 100, FormatPercent)

	AddSection("Visibility", "Set the opacity and fading options back to their defaults.")
	AddSlider("globalAlpha", "Opacity", 0, 100, FormatPercent)
	AddSlider("oocAlpha", "Out of Combat Opacity", 0, 100, FormatPercent)
	AddSlider("mountedAlpha", "Mounted Opacity", 0, 100, FormatPercent, "Also applies in druid Travel and Aquatic Form.")
	AddCheckbox("ignoreOnEnemyTarget", "Don't Fade With Enemy Target", "Keep full opacity out of combat while targeting an enemy.")
	AddCheckbox("ignoreOnFriendlyTarget", "Don't Fade With Friendly Target", "Keep full opacity out of combat while targeting a friendly unit.")

	AddSection("Enemy", "Set the enemy swing timer option back to its default.")
	AddCheckbox("showEnemySwing", "Show Enemy Swing Timer",
		"Show your target's melee swing timers below your own, with an off-hand bar once it's seen dual wielding. Forever hides the combat log from addons, so this is worked out from the hits and misses you take: it only tracks swings aimed at you, and can be thrown off when several enemies are attacking you.")

	Settings.RegisterAddOnCategory(category)

	StaticPopupDialogs[RESET_DIALOG] = {
		text = "Reset all of LaryIsland's Swing Timer settings to their defaults?",
		button1 = RESET or "Reset",
		button2 = CANCEL,
		OnAccept = function()
			for _, setting in ipairs(allSettings) do
				setting:SetValueToDefault()
			end
		end,
		hideOnEscape = 1,
		whileDead = 1,
		fullScreenCover = true,
	}

	-- The panel's Defaults button offers to reset the game's and every addon's settings as well. On this
	-- addon's page, ask about just this addon's instead. It's hooked rather than replaced, so Blizzard's
	-- own handling stays intact and other pages are unaffected.
	SettingsPanel:GetSettingsList().Header.DefaultsButton:HookScript("OnClick", function()
		if SettingsPanel:GetCurrentCategory() == category then
			StaticPopup_Hide("GAME_SETTINGS_APPLY_DEFAULTS")
			StaticPopup_Show(RESET_DIALOG)
		end
	end)

	return category
end
