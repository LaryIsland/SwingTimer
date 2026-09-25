local _, ns = ...

-- Forever hides the combat log from addons, so the target's swings are inferred from the hits and
-- misses it lands on the player (UNIT_COMBAT). Swings at anyone else can't be seen.

local IsSecret, Describe, ProbeLog = ns.IsSecret, ns.Describe, ns.ProbeLog

local SWING_ACTIONS = {
	WOUND = true,
	BLOCK = true,
	ABSORB = true,
	MISS = true,
	DODGE = true,
	PARRY = true,
	DEFLECT = true,
}
local AVOIDANCE_ACTIONS = {
	MISS = true,
	DODGE = true,
	PARRY = true,
	DEFLECT = true,
}
local SCHOOL_MASK_PHYSICAL = 1

-- Hits landing sooner than this far into the expected swing are the other hand, another mob or an ability.
-- With both hands at the same speed, one of each pair of hands' hits always lands before this.
local MIN_SWING_FRACTION = 0.75
local MIN_SWING_GAP = 0.2
-- NPCs swing no faster than this without haste buffs, so closer hits can't be the same hand.
local MIN_NPC_SWING_SPEED = 1.0
-- NPC speeds are set to one decimal place, so learned speeds this close to one are snapped to it.
local SPEED_SNAP_TOLERANCE = 0.02
-- Gaps longer than this (stuns, fleeing, casting) aren't used to learn the speed, and leave a hand's
-- schedule too old to go on.
local MAX_LEARNED_INTERVAL = 6
local LEARNED_INTERVAL_COUNT = 5
-- Bar length while the target's speed is unknown, and longer than any real swing.
local UNKNOWN_SPEED = 10
-- Keep filling this long past the expected swing, in case the real (secret) speed is slower.
local BAR_OVERRUN = 1

-- This many too-soon hits spaced a swing apart from each other reveal an off-hand.
local OFF_HAND_DETECTION_HITS = 2
local OFF_HAND_SPACING_TOLERANCE = 0.15 -- As a fraction of the swing speed.
-- A dual wielder's alternating short and long gaps must differ by more than this fraction of its speed
-- to be told apart from a single hand's even ones. Closer than that, alternating damage decides.
local MIN_ALTERNATING_GAP_DIFFERENCE = 0.1
local ALTERNATION_HISTORY = 4
-- A detected off-hand that stays silent while the main hand lands this many swings was a false detection.
-- Counted in swings rather than time, so crowd control or kiting doesn't drop it.
local OFF_HAND_DROP_SWINGS = 3

-- NPC off-hands hit for half damage, so a hit this much weaker than the other hand's is an off-hand.
local OFF_HAND_DAMAGE_RATIO = 0.7
-- Hits are only compared with hits of the same kind; blocked, absorbed and resisted ones are skipped.
local COMPARABLE_DAMAGE_FLAGS = {
	[""] = true,
	CRUSHING = true,
	CRITICAL = true,
}
local HAND_DAMAGE_SAMPLES = 5
local MIN_HAND_DAMAGE_SAMPLES = 2
-- What makes up a hand's swing history, as opposed to its bar, so two hands can trade them.
local HAND_HISTORY_FIELDS = { "swingStart", "intervals", "damage" }

local EnemySwing = {}
ns.EnemySwing = EnemySwing

local function CreateHand(labelText, isOffHand)
	local hand = { isOffHand = isOffHand, intervals = {}, damage = {}, bar = ns.CreateBarFrame(labelText) }
	hand.bar.hand = hand
	ns.SetBarColors(hand.bar, "enemyBarColor")
	hand.bar:SetValue(0)
	return hand
end

local enemy = {
	isPlayer = false,
	isDualWielding = false,
	-- Hits too soon to be the main hand; enough of them spaced a swing apart reveal an off-hand.
	offHandCandidate = { count = 0 },
	-- Recent hits taken for main hand swings without a trusted speed, to spot two hands alternating.
	recentMainHits = {},
	mainSwingsSinceOffHand = 0,
	main = CreateHand("Main Hand", false),
	off = CreateHand("Off-Hand", true),
}

-- In the order they're laid out below the player's bars.
EnemySwing.bars = { enemy.main.bar, enemy.off.bar }

-- Speeds

local function GetHandName(hand)
	return hand.isOffHand and "off-hand" or "main hand"
end

local function GetLiveHandSpeed(hand)
	-- May be secret in combat; secret values can still be handed to the bar and text to display.
	local mainSpeed, offSpeed = UnitAttackSpeed("target")
	-- NPCs don't report an off-hand speed; they swing both hands at the main hand's speed.
	local speed = (hand.isOffHand and enemy.isPlayer) and offSpeed or mainSpeed
	if speed == nil or IsSecret(speed) then
		return speed
	end
	return speed > 0 and speed or nil
end

local function SnapSpeed(speed)
	local rounded = math.floor(speed * 10 + 0.5) / 10
	return math.abs(speed - rounded) <= SPEED_SNAP_TOLERANCE and rounded or speed
end

-- The median of the recent gaps between swings, so a single odd gap doesn't move it but a lasting
-- speed change does within a few swings.
local function GetLearnedHandSpeed(hand)
	if #hand.intervals == 0 then
		return nil
	end

	local sorted = CopyTable(hand.intervals)
	table.sort(sorted)
	return SnapSpeed(sorted[math.ceil(#sorted / 2)])
end

-- Whether the hand's speed comes from the game rather than only being learned from its hits.
local function HasTrustedHandSpeed(hand)
	local speed = GetLiveHandSpeed(hand)
	return (speed and not IsSecret(speed)) or hand.knownSpeed ~= nil
end

-- The hand's speed as a plain number, for timing decisions. The speed seen before combat is preferred
-- over the learned one, which a dual wielder's interleaved hits can drag down before it's detected.
local function GetExpectedHandSpeed(hand)
	local speed = GetLiveHandSpeed(hand)
	if speed and not IsSecret(speed) then
		return speed
	end

	speed = hand.knownSpeed or GetLearnedHandSpeed(hand)
	if not speed and hand.isOffHand then
		return GetExpectedHandSpeed(enemy.main)
	end
	return speed
end

-- The hand's speed for the bar and text, which may be secret.
local function GetDisplayHandSpeed(hand)
	local speed = GetLiveHandSpeed(hand) or hand.knownSpeed or GetLearnedHandSpeed(hand)
	if not speed and hand.isOffHand then
		return GetDisplayHandSpeed(enemy.main)
	end
	return speed
end

local function CacheTargetSpeeds()
	for _, hand in ipairs({ enemy.main, enemy.off }) do
		local speed = GetLiveHandSpeed(hand)
		if speed and not IsSecret(speed) then
			hand.knownSpeed = speed
		end
	end

	-- Enemy players report their off-hand speed, so their dual wielding doesn't need detecting.
	if enemy.isPlayer and enemy.off.knownSpeed then
		enemy.isDualWielding = true
	end
end

-- Damage

-- The hit type a damaging hit can be compared under, or nil if its damage isn't comparable.
local function GetDamageKind(action, flagText, amount)
	if action ~= "WOUND" or IsSecret(flagText) or IsSecret(amount) or not amount or amount <= 0 then
		return nil
	end

	local kind = flagText or ""
	return COMPARABLE_DAMAGE_FLAGS[kind] and kind or nil
end

local function RecordHandDamage(hand, action, flagText, amount)
	local kind = GetDamageKind(action, flagText, amount)
	if not kind then
		return
	end

	local samples = hand.damage[kind] or {}
	hand.damage[kind] = samples
	table.insert(samples, amount)
	if #samples > HAND_DAMAGE_SAMPLES then
		table.remove(samples, 1)
	end
end

-- Returns how hard the hand hits for this kind of hit, once enough have been seen. Uses the highest
-- recent hit, since the other hand's hits taken for this one's would drag an average down.
local function GetHandDamage(hand, kind)
	local samples = hand.damage[kind]
	if not samples or #samples < MIN_HAND_DAMAGE_SAMPLES then
		return nil
	end
	return math.max(unpack(samples))
end

-- Target

local function IsTargetAttackingMe()
	if not UnitExists("target") or not UnitCanAttack("player", "target") or UnitIsDeadOrGhost("target") then
		return false
	end

	-- Tanking status covers NPCs, including in dungeons where target-of-target is secret.
	local threatStatus = UnitThreatSituation("player", "target")
	if threatStatus ~= nil and not IsSecret(threatStatus) and threatStatus >= 2 then
		return true
	end

	-- Enemy players have no threat table.
	local isTargetingMe = UnitIsUnit("targettarget", "player")
	return not IsSecret(isTargetingMe) and isTargetingMe == true
end

-- Returns whether a hit on the player looks like one of the target's swings, and why not if it doesn't.
local function IsEnemySwingHit(action, schoolMask)
	if IsSecret(action) or IsSecret(schoolMask) then
		return false, "secret payload"
	elseif not SWING_ACTIONS[action] then
		return false, "not a swing"
	elseif schoolMask ~= SCHOOL_MASK_PHYSICAL and not (AVOIDANCE_ACTIONS[action] and schoolMask == 0) then
		return false, "not physical"
	elseif not IsTargetAttackingMe() then
		return false, "target not attacking me"
	end
	return true
end

-- Bars

local function OnEnemyBarUpdate(bar)
	local elapsed = GetTime() - bar.hand.swingStart
	local expected = GetExpectedHandSpeed(bar.hand) or UNKNOWN_SPEED
	if elapsed < expected + BAR_OVERRUN then
		bar:SetValue(elapsed)
	else
		-- The swing is overdue (crowd control, kiting), so leave the bar full until the next one.
		bar:SetValue(UNKNOWN_SPEED)
		bar:SetScript("OnUpdate", nil)
	end
end

local function ShowHandSwing(hand)
	local speed = GetDisplayHandSpeed(hand)
	local bar = hand.bar
	bar:SetMinMaxValues(0, speed or UNKNOWN_SPEED)
	bar:SetValue(GetTime() - hand.swingStart)
	if speed then
		bar.SpeedText:SetFormattedText("%.1f", speed)
	else
		bar.SpeedText:SetText("")
	end
	bar:SetScript("OnUpdate", OnEnemyBarUpdate)
end

local function StartHandSwing(hand, now)
	if hand.swingStart then
		local interval = now - hand.swingStart
		if interval <= MAX_LEARNED_INTERVAL then
			table.insert(hand.intervals, interval)
			if #hand.intervals > LEARNED_INTERVAL_COUNT then
				table.remove(hand.intervals, 1)
			end
		end
	end
	hand.swingStart = now

	ShowHandSwing(hand)
	ns.UpdateVisibility()
end

local function ResetHand(hand)
	hand.swingStart = nil
	hand.knownSpeed = nil
	wipe(hand.intervals)
	wipe(hand.damage)

	hand.bar:SetScript("OnUpdate", nil)
	hand.bar:SetValue(0)
	hand.bar.SpeedText:SetText("")
end

local function ResetEnemySwing()
	local isPlayer = UnitIsPlayer("target")
	enemy.isPlayer = not IsSecret(isPlayer) and isPlayer == true
	enemy.isDualWielding = false
	enemy.offHandCandidate.count = 0
	enemy.offHandCandidate.last = nil
	wipe(enemy.recentMainHits)
	enemy.mainSwingsSinceOffHand = 0
	ResetHand(enemy.main)
	ResetHand(enemy.off)
	CacheTargetSpeeds()

	ProbeLog("target changed: player=%s speed=%s offSpeed=%s dualWield=%s statsSecret=%s", tostring(enemy.isPlayer),
		Describe(GetLiveHandSpeed(enemy.main)), Describe(GetLiveHandSpeed(enemy.off)), tostring(enemy.isDualWielding),
		Describe(C_Secrets and C_Secrets.ShouldUnitStatsBeSecret and C_Secrets.ShouldUnitStatsBeSecret()))
	ns.UpdateVisibility()
end

-- Telling the hands apart

-- How far a hit is from when the hand's swing was due, or nil if it's too soon to be that hand's swing.
local function GetHandFit(hand, now)
	if not hand.swingStart or now - hand.swingStart > MAX_LEARNED_INTERVAL then
		-- No schedule to go on: any hit fits, but a hand with a live schedule fits better.
		return MAX_LEARNED_INTERVAL
	end

	local elapsed = now - hand.swingStart
	local expected = GetExpectedHandSpeed(hand)
	-- Enemy players can be hasted below the NPC minimum.
	local slowestPlausible = math.max(expected or 0, enemy.isPlayer and 0 or MIN_NPC_SWING_SPEED)
	local minGap = math.max(slowestPlausible * MIN_SWING_FRACTION, MIN_SWING_GAP)
	if elapsed < minGap then
		return nil
	end
	return expected and math.abs(elapsed - expected) or 0
end

local function StartDualWielding(evidence, ...)
	enemy.isDualWielding = true
	enemy.mainSwingsSinceOffHand = 0
	-- The main hand's damage so far mixed both hands' hits; compare the hands from here on.
	wipe(enemy.main.damage)
	wipe(enemy.off.damage)
	ProbeLog("off-hand detected from " .. evidence, ...)
end

-- Returns whether a too-soon hit completes the evidence of an off-hand, and what gave it away.
local function TrackOffHandCandidate(now, action, flagText, amount)
	local candidate = enemy.offHandCandidate
	local expected = GetExpectedHandSpeed(enemy.main)
	local isSpacedLikeASwing = expected and candidate.last
		and math.abs(now - candidate.last - expected) <= expected * OFF_HAND_SPACING_TOLERANCE

	candidate.count = isSpacedLikeASwing and candidate.count + 1 or 1
	candidate.last = now

	local kind = GetDamageKind(action, flagText, amount)
	local mainHandDamage = kind and GetHandDamage(enemy.main, kind)
	if mainHandDamage and amount <= mainHandDamage * OFF_HAND_DAMAGE_RATIO then
		return true, ("damage %d vs main hand %d"):format(amount, mainHandDamage)
	elseif candidate.count >= OFF_HAND_DETECTION_HITS then
		return true, "timing"
	end
	return false
end

local function DropOffHandIfSilent()
	if enemy.mainSwingsSinceOffHand < OFF_HAND_DROP_SWINGS then
		return
	end

	ProbeLog("off-hand dropped: %d main hand swings without an off-hand swing", enemy.mainSwingsSinceOffHand)
	enemy.isDualWielding = false
	enemy.mainSwingsSinceOffHand = 0
	enemy.offHandCandidate.count = 0
	enemy.offHandCandidate.last = nil
	wipe(enemy.recentMainHits)
	enemy.off.swingStart = nil
	wipe(enemy.off.intervals)
	wipe(enemy.off.damage)
	enemy.off.bar:SetScript("OnUpdate", nil)
end

-- Without a trusted speed to spot a dual wielder's early hits against (a target picked up mid-fight),
-- both hands' hits get taken for main hand swings. They still give it away by alternating short and
-- long gaps, or weak and strong hits. Returns the real swing speed and what gave it away, or nil.
local function DetectAlternatingHands(hits)
	if #hits < ALTERNATION_HISTORY then
		return nil
	end

	local hit1, hit2, hit3, hit4 = unpack(hits, #hits - ALTERNATION_HISTORY + 1)
	local gap1, gap2, gap3 = hit2.interval, hit3.interval, hit4.interval
	if not (gap1 and gap2 and gap3) then
		return nil
	end

	-- Each short and long pair adds up to one swing of either hand.
	local speed = gap1 + gap2
	if math.abs(gap1 - gap3) > speed * OFF_HAND_SPACING_TOLERANCE then
		return nil
	elseif math.abs(gap1 - gap2) > speed * MIN_ALTERNATING_GAP_DIFFERENCE then
		return SnapSpeed(speed), "alternating gaps"
	end

	-- Evenly spaced hits could be one hand at twice the speed; only alternating damage tells them apart.
	local kind = hit1.kind
	if not kind or hit2.kind ~= kind or hit3.kind ~= kind or hit4.kind ~= kind then
		return nil
	end

	local oddMax, oddMin = math.max(hit1.amount, hit3.amount), math.min(hit1.amount, hit3.amount)
	local evenMax, evenMin = math.max(hit2.amount, hit4.amount), math.min(hit2.amount, hit4.amount)
	if oddMax <= evenMin * OFF_HAND_DAMAGE_RATIO or evenMax <= oddMin * OFF_HAND_DAMAGE_RATIO then
		return SnapSpeed(speed), "alternating damage"
	end
	return nil
end

local function RecordUntrustedMainHit(now, action, flagText, amount)
	local kind = GetDamageKind(action, flagText, amount)
	local hits = enemy.recentMainHits
	table.insert(hits, {
		interval = enemy.main.swingStart and now - enemy.main.swingStart,
		kind = kind,
		amount = kind and amount,
	})
	if #hits > ALTERNATION_HISTORY then
		table.remove(hits, 1)
	end
end

-- Returns which of the target's hands a swing on the player came from, or nil and why it was ignored.
local function AssignEnemySwing(now, action, flagText, amount)
	local mainFit = GetHandFit(enemy.main, now)

	if not enemy.isDualWielding then
		if mainFit and not HasTrustedHandSpeed(enemy.main) then
			RecordUntrustedMainHit(now, action, flagText, amount)
			local speed, evidence = DetectAlternatingHands(enemy.recentMainHits)
			if speed then
				-- The gaps learned so far were between both hands' hits; replace them with the real speed.
				wipe(enemy.recentMainHits)
				wipe(enemy.main.intervals)
				wipe(enemy.off.intervals)
				table.insert(enemy.main.intervals, speed)
				table.insert(enemy.off.intervals, speed)
				StartDualWielding("%s, speed %.2f", evidence, speed)
				return enemy.off
			end
		end

		if mainFit then
			return enemy.main
		end

		local isOffHand, evidence = TrackOffHandCandidate(now, action, flagText, amount)
		if isOffHand then
			StartDualWielding(evidence)
			return enemy.off
		end
		return nil, ("too soon (off-hand evidence %d/%d)"):format(enemy.offHandCandidate.count, OFF_HAND_DETECTION_HITS)
	end

	local offFit = GetHandFit(enemy.off, now)
	if mainFit and (not offFit or mainFit <= offFit) then
		enemy.mainSwingsSinceOffHand = enemy.mainSwingsSinceOffHand + 1
		DropOffHandIfSilent()
		return enemy.main
	elseif offFit then
		enemy.mainSwingsSinceOffHand = 0
		return enemy.off
	end
	return nil, "too soon"
end

-- Which hand is which is decided by hit timing, so the stronger hand can end up labelled as the
-- off-hand. Off-hands hit for half damage, so trade the hands' histories once that's clear.
local function CorrectSwappedHands()
	if not enemy.isDualWielding then
		return
	end

	for kind in pairs(COMPARABLE_DAMAGE_FLAGS) do
		local mainDamage, offDamage = GetHandDamage(enemy.main, kind), GetHandDamage(enemy.off, kind)
		if mainDamage and offDamage and mainDamage <= offDamage * OFF_HAND_DAMAGE_RATIO then
			for _, field in ipairs(HAND_HISTORY_FIELDS) do
				enemy.main[field], enemy.off[field] = enemy.off[field], enemy.main[field]
			end
			enemy.mainSwingsSinceOffHand = 0

			for _, hand in ipairs({ enemy.main, enemy.off }) do
				if hand.swingStart then
					ShowHandSwing(hand)
				end
			end
			ProbeLog("hands swapped: main hand hit for %d vs off-hand %d (%s)", mainDamage, offDamage, kind == "" and "normal" or kind:lower())
			return
		end
	end
end

local function ApplyParryHaste(hand)
	-- A parry takes 40% of a swing off the parrying unit's time to its next one, but never leaves less
	-- than 20% of a swing to go.
	local expected = GetExpectedHandSpeed(hand)
	if not hand.swingStart or not expected then
		return
	end

	local now = GetTime()
	local remaining = expected - (now - hand.swingStart)
	if remaining > 0.6 * expected then
		hand.swingStart = hand.swingStart - 0.4 * expected
	elseif remaining > 0.2 * expected then
		hand.swingStart = now - 0.8 * expected
	end
end

-- Module interface

function EnemySwing.UpdateVisibility()
	-- Enemy bars stay up for the rest of the fight once their hand has swung at you.
	local showEnemy = ns.db.showEnemySwing and UnitAffectingCombat("player")
	enemy.main.bar:SetShown(showEnemy and enemy.main.swingStart ~= nil)
	enemy.off.bar:SetShown(showEnemy and enemy.isDualWielding and enemy.off.swingStart ~= nil)
end

local function OnSimulatedBarUpdate(bar)
	bar:SetValue(GetTime() - bar.simulatedSwingStart)
end

-- Plays a pretend swing on a hand's bar ("main" or "off") for the options' simulation, leaving the
-- tracked swings alone.
function EnemySwing.SimulateSwing(handKey, speed)
	local bar = enemy[handKey].bar
	bar.simulatedSwingStart = GetTime()
	bar:SetMinMaxValues(0, speed)
	bar:SetValue(0)
	bar.SpeedText:SetFormattedText("%.1f", speed)
	bar:SetScript("OnUpdate", OnSimulatedBarUpdate)
end

-- Puts the bars back to showing the tracked swings.
function EnemySwing.EndSimulation()
	for _, hand in ipairs({ enemy.main, enemy.off }) do
		if hand.swingStart then
			ShowHandSwing(hand)
		else
			hand.bar:SetScript("OnUpdate", nil)
			hand.bar:SetValue(0)
			hand.bar.SpeedText:SetText("")
		end
	end
end

function EnemySwing.DescribeState(Line)
	Line("Enemy: attackingMe=%s player=%s dualWield=%s offHandEvidence=%d/%d", tostring(IsTargetAttackingMe()),
		tostring(enemy.isPlayer), tostring(enemy.isDualWielding), enemy.offHandCandidate.count, OFF_HAND_DETECTION_HITS)
	for _, hand in ipairs({ enemy.main, enemy.off }) do
		Line("Enemy %s: shown=%s speed=%s learned=%s known=%s", GetHandName(hand), tostring(hand.bar:IsShown()),
			Describe(GetLiveHandSpeed(hand)), Describe(GetLearnedHandSpeed(hand)), Describe(hand.knownSpeed))
	end
end

-- Events

local EVENT_HANDLERS = {}
local UNIT_EVENTS = {
	UNIT_COMBAT = { "player", "target" },
	UNIT_ATTACK_SPEED = { "target" },
}

function EVENT_HANDLERS.UNIT_COMBAT(unit, action, flagText, amount, schoolMask)
	if unit == "target" then
		if not IsSecret(action) and action == "PARRY" then
			ApplyParryHaste(enemy.main)
			ProbeLog("target parried: main hand swing sped up")
		end
		return
	end

	local now = GetTime()
	local isSwing, reason = IsEnemySwingHit(action, schoolMask)
	local hand
	if isSwing then
		hand, reason = AssignEnemySwing(now, action, flagText, amount)
	end

	ProbeLog("hit on me: %s %s amount=%s school=%s -> %s", Describe(action), Describe(flagText), Describe(amount), Describe(schoolMask),
		hand and ("%s swing, expected %s"):format(GetHandName(hand), Describe(GetExpectedHandSpeed(hand))) or reason)

	if hand then
		RecordHandDamage(hand, action, flagText, amount)
		StartHandSwing(hand, now)
		CorrectSwappedHands()
	end
end

EVENT_HANDLERS.UNIT_ATTACK_SPEED = CacheTargetSpeeds
EVENT_HANDLERS.PLAYER_TARGET_CHANGED = ResetEnemySwing
EVENT_HANDLERS.PLAYER_TARGET_DIED = ResetEnemySwing

local eventFrame = CreateFrame("Frame")
for event in pairs(EVENT_HANDLERS) do
	if UNIT_EVENTS[event] then
		eventFrame:RegisterUnitEvent(event, unpack(UNIT_EVENTS[event]))
	else
		eventFrame:RegisterEvent(event)
	end
end

eventFrame:SetScript("OnEvent", function(_, event, ...)
	EVENT_HANDLERS[event](...)
end)
