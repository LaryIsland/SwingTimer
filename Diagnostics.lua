local _, ns = ...

-- /lst debug prints each part's current state; /lst probe logs the enemy swing tracker's decisions.

local isProbing = false

-- Formats a value for diagnostics, including secret values that can't be read.
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

local function Line(message, ...)
	print(("  " .. message):format(...))
end

ns.RegisterSlashCommand("debug", function()
	print(ns.CHAT_PREFIX, "debug:")
	ns.DescribePlayerState(Line)
	ns.EnemySwing.DescribeState(Line)
end)

ns.RegisterSlashCommand("probe", function()
	isProbing = not isProbing
	print(ns.CHAT_PREFIX, "enemy swing probe", isProbing and "on: hits on you will be logged." or "off.")
end)
