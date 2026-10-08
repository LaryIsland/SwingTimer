local addonName, ns = ...

local isProbing = false

local MAX_CAPTURES = 10
local MAX_CAPTURE_RECORDS = 5000

local capture
local captureStart

function ns.Describe(value)
	if ns.IsSecret(value) then
		return "<secret>"
	elseif type(value) == "number" then
		return ("%.2f"):format(value)
	end
	return tostring(value)
end

function ns.ProbeLog(message, ...)
	if isProbing then
		print(("|cff3399ff[%.2f]|r " .. message):format(GetTime(), ...))
	end
end

function ns.CaptureValue(value)
	if ns.IsSecret(value) then
		return "secret"
	end
	return value
end

function ns.IsCapturing()
	return capture ~= nil
end

function ns.CaptureRecord(kind, record)
	if not capture then
		return
	end

	record.kind = kind
	record.time = math.floor((GetTime() - captureStart) * 1000 + 0.5) / 1000
	table.insert(capture.records, record)
	if #capture.records >= MAX_CAPTURE_RECORDS then
		capture = nil
		print(ns.CHAT_PREFIX, "capture stopped as it's full. It's saved when you log out or /reload.")
	end
end

local function Line(message, ...)
	print(("  " .. message):format(...))
end

ns.RegisterSlashCommand("debug", function()
	print(ns.CHAT_PREFIX, "debug:")
	ns.DescribePlayerState(Line)
	ns.EnemySwing.DescribeState(Line)
	Line("capture=%s", capture and ("%d records"):format(#capture.records) or "off")
end)

ns.RegisterSlashCommand("probe", function()
	isProbing = not isProbing
	print(ns.CHAT_PREFIX, "probe", isProbing and "on: hits on you and changes to your queued attack will be logged." or "off.")
end)

ns.RegisterSlashCommand("capture", function()
	if capture then
		print(ns.CHAT_PREFIX, ("capture stopped with %d records. It's saved when you log out or /reload."):format(#capture.records))
		capture = nil
		return
	end

	LaryIslandSwingTimerCapture = LaryIslandSwingTimerCapture or {}
	local captures = LaryIslandSwingTimerCapture
	capture = {
		date = date("%Y-%m-%d %H:%M"),
		version = C_AddOns.GetAddOnMetadata(addonName, "Version"),
		records = {},
	}
	captureStart = GetTime()
	table.insert(captures, capture)
	while #captures > MAX_CAPTURES do
		table.remove(captures, 1)
	end

	ns.CaptureRecord("combat", { inCombat = UnitAffectingCombat("player") })
	ns.EnemySwing.CaptureTarget()
	print(ns.CHAT_PREFIX, ("capturing the swings enemies take at you. |cffffd100/lst capture|r again to stop; the last %d captures are kept."):format(MAX_CAPTURES))
end)

local combatFrame = CreateFrame("Frame")
combatFrame:RegisterEvent("PLAYER_REGEN_DISABLED")
combatFrame:RegisterEvent("PLAYER_REGEN_ENABLED")
combatFrame:SetScript("OnEvent", function(_, event)
	ns.CaptureRecord("combat", { inCombat = event == "PLAYER_REGEN_DISABLED" })
end)
