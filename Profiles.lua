local _, ns = ...

local DEFAULT_PROFILE = "Default"
local EXPORT_PREFIX = "!LST1!"
local OPTIONS_APP_NAME = "LaryIsland_SwingTimer_Profiles"

local Profiles = {}
ns.Profiles = Profiles

local db

local function OnProfileChanged()
	ns.UseProfile(db.profile)
	LibStub("AceConfigRegistry-3.0"):NotifyChange(OPTIONS_APP_NAME)
	if ns.OnProfileChanged then
		ns.OnProfileChanged()
	end
end

function Profiles.Load()
	local savedVariables = LaryIslandSwingTimerDB
	if savedVariables and not savedVariables.profiles then
		-- Saved before profiles, with the settings at the top level.
		local settings = {}
		for key, value in pairs(savedVariables) do
			settings[key] = value
			savedVariables[key] = nil
		end
		savedVariables.profiles = { [DEFAULT_PROFILE] = settings }
	end

	db = LibStub("AceDB-3.0"):New("LaryIslandSwingTimerDB", { profile = ns.DEFAULTS }, true)
	db.RegisterCallback(Profiles, "OnProfileChanged", OnProfileChanged)
	db.RegisterCallback(Profiles, "OnProfileCopied", OnProfileChanged)
	db.RegisterCallback(Profiles, "OnProfileReset", OnProfileChanged)
	return db.profile
end

function Profiles.GetActiveName()
	return db:GetCurrentProfile()
end

function Profiles.Export()
	local settings = {}
	for key, value in pairs(db.profile) do
		if value ~= ns.DEFAULTS[key] then
			settings[key] = value
		end
	end

	local payload = C_EncodingUtil.SerializeCBOR({ name = db:GetCurrentProfile(), settings = settings })
	return EXPORT_PREFIX .. C_EncodingUtil.EncodeBase64(C_EncodingUtil.CompressString(payload))
end

local function Decode(text)
	text = strtrim(text)
	if text:sub(1, #EXPORT_PREFIX) ~= EXPORT_PREFIX then
		return nil
	end

	local isDecoded, payload = pcall(function()
		local compressed = C_EncodingUtil.DecodeBase64(text:sub(#EXPORT_PREFIX + 1))
		return C_EncodingUtil.DeserializeCBOR(C_EncodingUtil.DecompressString(compressed))
	end)
	if isDecoded and type(payload) == "table" and type(payload.settings) == "table" then
		return payload
	end
end

local function IsHexColor(value)
	return value:match("^%x%x%x%x%x%x%x%x$") ~= nil
end

local function ReadSettings(imported)
	local settings = {}
	for key, default in pairs(ns.DEFAULTS) do
		local value = imported[key]
		if type(value) == type(default) then
			local isValid = true
			if type(value) == "number" then
				isValid = value == value and math.abs(value) ~= math.huge
			elseif type(value) == "string" and IsHexColor(default) then
				isValid = IsHexColor(value)
			end
			if isValid then
				settings[key] = value
			end
		end
	end

	local position = imported.position
	if type(position) == "table" and position.point == "CENTER" and position.relativePoint == "CENTER"
		and type(position.x) == "number" and type(position.y) == "number" then
		settings.position = { point = "CENTER", relativePoint = "CENTER", x = position.x, y = position.y }
	end
	return settings
end

local function Import(text)
	local payload = Decode(text)
	if not payload then
		return nil
	end

	local baseName = type(payload.name) == "string" and strtrim(payload.name) ~= "" and strtrim(payload.name) or "Imported"
	local name = baseName
	local suffix = 1
	while db.sv.profiles[name] do
		suffix = suffix + 1
		name = ("%s (%d)"):format(baseName, suffix)
	end

	db.sv.profiles[name] = ReadSettings(payload.settings)
	db:SetProfile(name)
	return name
end

local function CreateOptionsTable()
	local profileOptions = LibStub("AceDBOptions-3.0"):GetOptionsTable(db)
	-- AceDBOptions gives every addon the same args table, so ours are added to a copy of it.
	local args = CopyTable(profileOptions.args, true)

	args.sharedesc = {
		order = 90,
		type = "description",
		name = "\nShare a profile as text, to use on another account or to give to someone else.",
	}
	args.export = {
		order = 91,
		type = "input",
		name = "Export Current Profile",
		desc = "Copy this text to share the current profile.",
		multiline = 3,
		width = "full",
		get = Profiles.Export,
		set = function() end,
	}
	args.import = {
		order = 92,
		type = "input",
		name = "Import Profile",
		desc = "Paste text from Export Current Profile. It's added as a new profile and switched to.",
		multiline = 3,
		width = "full",
		get = function()
			return ""
		end,
		validate = function(_, text)
			return Decode(text) ~= nil or "That isn't an exported LaryIsland's Swing Timer profile."
		end,
		set = function(_, text)
			print(ns.CHAT_PREFIX, ("imported the %s profile."):format(Import(text)))
		end,
	}

	return {
		type = "group",
		name = profileOptions.name,
		desc = profileOptions.desc,
		handler = profileOptions.handler,
		args = args,
	}
end

function Profiles.RegisterOptions(parentCategory)
	local options = CreateOptionsTable()
	LibStub("AceConfigRegistry-3.0"):RegisterOptionsTable(OPTIONS_APP_NAME, options)
	LibStub("AceConfigDialog-3.0"):AddToBlizOptions(OPTIONS_APP_NAME, options.name --[[@as string]], parentCategory:GetID())
end
