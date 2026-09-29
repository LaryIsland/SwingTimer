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

local MIN_SWING_FRACTION = 0.75
local MIN_SWING_GAP = 0.2
local MIN_NPC_SWING_SPEED = 1.0
local SPEED_SNAP_TOLERANCE = 0.02
local MAX_LEARNED_INTERVAL = 6
local LEARNED_INTERVAL_COUNT = 5
local UNKNOWN_SPEED = 10
local BAR_OVERRUN = 1

local OFF_HAND_DETECTION_HITS = 2
local OFF_HAND_SPACING_TOLERANCE = 0.15
local OFF_HAND_EVIDENCE_EXPIRY_SWINGS = 2
local MIN_ALTERNATING_GAP_DIFFERENCE = 0.1
local ALTERNATION_HISTORY = 4
local OFF_HAND_DROP_SWINGS = 3

local OFF_HAND_DAMAGE_RATIO = 0.7
local HIT_DAMAGE_MULTIPLIERS = {
	[""] = 1,
	CRITICAL = 2,
	CRUSHING = 1.5,
}
-- Melee crits on players only deal 150% on the Forever beta, which Blizzard has confirmed is a bug, so
-- they're skipped rather than guessed at. Players can't land crushing blows.
local PLAYER_HIT_DAMAGE_MULTIPLIERS = {
	[""] = 1,
}
local HAND_DAMAGE_SAMPLES = 5
local MIN_HAND_DAMAGE_SAMPLES = 2
local MIN_SAMPLES_TO_RULE_OUT_OFF_HAND = 3
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
	offHandCandidate = { count = 0, isDamageConfirmed = false },
	recentMainHits = {},
	lastSwingHand = nil,
	sameHandSwings = 0,
	main = CreateHand("Main Hand", false),
	off = CreateHand("Off-Hand", true),
}

EnemySwing.bars = { enemy.main.bar, enemy.off.bar }

local function GetHandName(hand)
	return hand.isOffHand and "off-hand" or "main hand"
end

local function GetLiveHandSpeed(hand)
	-- Secret in combat, but secret values can still be handed to the bar and text to display.
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

local function GetLearnedHandSpeed(hand)
	if #hand.intervals == 0 then
		return nil
	end

	local sorted = CopyTable(hand.intervals)
	table.sort(sorted)
	return SnapSpeed(sorted[math.ceil(#sorted / 2)])
end

local function HasTrustedHandSpeed(hand)
	local speed = GetLiveHandSpeed(hand)
	return (speed and not IsSecret(speed)) or hand.knownSpeed ~= nil
end

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

	if enemy.isPlayer and enemy.off.knownSpeed then
		enemy.isDualWielding = true
	end
end

local function GetNormalHitDamage(action, flagText, amount)
	if action ~= "WOUND" or IsSecret(flagText) or IsSecret(amount) or not amount or amount <= 0 then
		return nil
	end

	local multipliers = enemy.isPlayer and PLAYER_HIT_DAMAGE_MULTIPLIERS or HIT_DAMAGE_MULTIPLIERS
	local multiplier = multipliers[flagText or ""]
	return multiplier and amount / multiplier
end

local function RecordHandDamage(hand, damage)
	if not damage then
		return
	end

	table.insert(hand.damage, damage)
	if #hand.damage > HAND_DAMAGE_SAMPLES then
		table.remove(hand.damage, 1)
	end
end

-- The highest recent hit rather than an average, since the other hand's hits taken for this one's
-- would drag an average down.
local function GetHandDamage(hand)
	if #hand.damage < MIN_HAND_DAMAGE_SAMPLES then
		return nil
	end
	return math.max(unpack(hand.damage))
end

local function IsOffHandStrength(damage, mainHandDamage)
	return damage <= mainHandDamage * OFF_HAND_DAMAGE_RATIO
end

-- Threat rather than target-of-target, which is secret in dungeons.
local function IsTankingUnit(unit)
	local threatStatus = UnitThreatSituation("player", unit)
	return threatStatus ~= nil and not IsSecret(threatStatus) and threatStatus >= 2
end

local nameplateUnits = {}

local function CountEnemiesAttackingMe()
	local count = 0
	for unit in pairs(nameplateUnits) do
		if IsTankingUnit(unit) then
			count = count + 1
		end
	end
	return count
end

local function CanTrustOffHandTiming()
	return CountEnemiesAttackingMe() <= 1
end

local function IsTargetAttackingMe()
	if not UnitExists("target") or not UnitCanAttack("player", "target") or UnitIsDeadOrGhost("target") then
		return false
	end

	if IsTankingUnit("target") then
		return true
	end

	-- Enemy players have no threat table.
	local isTargetingMe = UnitIsUnit("targettarget", "player")
	return not IsSecret(isTargetingMe) and isTargetingMe == true
end

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

local function OnEnemyBarUpdate(bar)
	local elapsed = GetTime() - bar.hand.swingStart
	local expected = GetExpectedHandSpeed(bar.hand) or UNKNOWN_SPEED
	if elapsed < expected + BAR_OVERRUN then
		bar:SetValue(elapsed)
	else
		-- Overdue (crowd control, kiting), so the bar stays full until the next swing.
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

local function ClearOffHandEvidence()
	enemy.offHandCandidate.count = 0
	enemy.offHandCandidate.last = nil
	enemy.offHandCandidate.isDamageConfirmed = false
end

local function ResetEnemySwing()
	local isPlayer = UnitIsPlayer("target")
	enemy.isPlayer = not IsSecret(isPlayer) and isPlayer == true
	enemy.isDualWielding = false
	ClearOffHandEvidence()
	wipe(enemy.recentMainHits)
	enemy.lastSwingHand = nil
	enemy.sameHandSwings = 0
	ResetHand(enemy.main)
	ResetHand(enemy.off)
	CacheTargetSpeeds()

	ProbeLog("target changed: player=%s speed=%s offSpeed=%s dualWield=%s statsSecret=%s", tostring(enemy.isPlayer),
		Describe(GetLiveHandSpeed(enemy.main)), Describe(GetLiveHandSpeed(enemy.off)), tostring(enemy.isDualWielding),
		Describe(C_Secrets and C_Secrets.ShouldUnitStatsBeSecret and C_Secrets.ShouldUnitStatsBeSecret()))
	ns.UpdateVisibility()
end

-- How far a hit is from when the hand's swing was due (lower fits better), or nil if it's too soon to
-- be that hand's swing.
local function GetHandFit(hand, now)
	if not hand.swingStart or now - hand.swingStart > MAX_LEARNED_INTERVAL then
		-- Any hit fits a hand with no schedule, but one with a live schedule fits better.
		return MAX_LEARNED_INTERVAL
	end

	local elapsed = now - hand.swingStart
	local expected = GetExpectedHandSpeed(hand)
	local slowestPlausible = math.max(expected or 0, enemy.isPlayer and 0 or MIN_NPC_SWING_SPEED)
	local minGap = math.max(slowestPlausible * MIN_SWING_FRACTION, MIN_SWING_GAP)
	if elapsed < minGap then
		return nil
	end
	return expected and math.abs(elapsed - expected) or 0
end

local function StartDualWielding(evidence, ...)
	enemy.isDualWielding = true
	enemy.lastSwingHand = enemy.off
	enemy.sameHandSwings = 1
	-- The main hand's damage so far may have mixed both hands' hits.
	wipe(enemy.main.damage)
	wipe(enemy.off.damage)
	ProbeLog("off-hand detected from " .. evidence, ...)
end

local function TrackOffHandCandidate(now, damage)
	local candidate = enemy.offHandCandidate
	local expected = GetExpectedHandSpeed(enemy.main)
	if candidate.last and expected and now - candidate.last > expected * OFF_HAND_EVIDENCE_EXPIRY_SWINGS then
		ClearOffHandEvidence()
	end

	local mainHandDamage = damage and GetHandDamage(enemy.main)
	local isWeak = mainHandDamage ~= nil and IsOffHandStrength(damage, mainHandDamage)
	if mainHandDamage and not isWeak then
		ClearOffHandEvidence()
		return false, ("too soon, and damage %.0f matches main hand %.0f"):format(damage, mainHandDamage)
	end

	local isSpacedLikeASwing = expected and candidate.last
		and math.abs(now - candidate.last - expected) <= expected * OFF_HAND_SPACING_TOLERANCE
	if isSpacedLikeASwing then
		candidate.count = candidate.count + 1
		candidate.isDamageConfirmed = candidate.isDamageConfirmed and isWeak
	else
		candidate.count = 1
		candidate.isDamageConfirmed = isWeak
	end
	candidate.last = now

	if candidate.count < OFF_HAND_DETECTION_HITS then
		return false, ("too soon (off-hand evidence %d/%d)"):format(candidate.count, OFF_HAND_DETECTION_HITS)
	elseif candidate.isDamageConfirmed then
		return true, ("%d weak hits a swing apart, damage %.0f vs main hand %.0f"):format(candidate.count, damage, mainHandDamage)
	elseif not CanTrustOffHandTiming() then
		return false, ("too soon (off-hand timing, but %d enemies attacking)"):format(CountEnemiesAttackingMe())
	end
	return true, ("%d hits a swing apart"):format(candidate.count)
end

local function SwapHands()
	for _, field in ipairs(HAND_HISTORY_FIELDS) do
		enemy.main[field], enemy.off[field] = enemy.off[field], enemy.main[field]
	end
	enemy.lastSwingHand = nil
	enemy.sameHandSwings = 0

	for _, hand in ipairs({ enemy.main, enemy.off }) do
		if hand.swingStart then
			ShowHandSwing(hand)
		end
	end
end

-- wasMainHand: the off-hand's hits were really the main hand's, so the later of the two hands' last
-- hits carries on the main hand's schedule. If that's the off-hand's, the gaps the main hand learned
-- were between every other hit, so they're thrown away.
local function DropOffHand(wasMainHand, reason, ...)
	ProbeLog("off-hand dropped: " .. reason, ...)
	enemy.isDualWielding = false
	enemy.lastSwingHand = nil
	enemy.sameHandSwings = 0
	ClearOffHandEvidence()
	wipe(enemy.recentMainHits)

	local main, off = enemy.main, enemy.off
	if wasMainHand and off.swingStart and (not main.swingStart or off.swingStart > main.swingStart) then
		main.swingStart = off.swingStart
		wipe(main.intervals)
		ShowHandSwing(main)
	end

	off.swingStart = nil
	wipe(off.intervals)
	wipe(off.damage)
	off.bar:SetScript("OnUpdate", nil)
end

-- Returns the hand the swing belongs to, which is the main hand if this drops the off-hand.
local function CountHandSwing(hand)
	if hand == enemy.lastSwingHand then
		enemy.sameHandSwings = enemy.sameHandSwings + 1
	else
		enemy.lastSwingHand = hand
		enemy.sameHandSwings = 1
	end

	if enemy.sameHandSwings < OFF_HAND_DROP_SWINGS then
		return hand
	end

	local swings = enemy.sameHandSwings
	if hand == enemy.off then
		-- The off-hand has taken over the swings, so its schedule carries on as the main hand's.
		SwapHands()
	end
	DropOffHand(false, "%d %s swings in a row without the other hand", swings, GetHandName(hand))
	return enemy.main
end

local function IsSameHandStrength(damage1, damage2)
	return not IsOffHandStrength(damage1, damage2) and not IsOffHandStrength(damage2, damage1)
end

-- Without a trusted speed to spot a dual wielder's early hits against (a target picked up mid-fight),
-- both hands' hits get taken for main hand swings, so the hands have to be spotted alternating.
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
	end

	local damage1, damage2, damage3, damage4 = hit1.damage, hit2.damage, hit3.damage, hit4.damage
	for _, pair in ipairs({ { damage1, damage2 }, { damage2, damage3 }, { damage3, damage4 } }) do
		if pair[1] and pair[2] and IsSameHandStrength(pair[1], pair[2]) then
			return nil
		end
	end

	-- Damage overrides the gaps: evenly spaced hits could be one hand at twice the speed, and
	-- alternating ones could be two enemies.
	if damage1 and damage2 and damage3 and damage4 then
		local oddMax, oddMin = math.max(damage1, damage3), math.min(damage1, damage3)
		local evenMax, evenMin = math.max(damage2, damage4), math.min(damage2, damage4)
		if IsOffHandStrength(oddMax, evenMin) or IsOffHandStrength(evenMax, oddMin) then
			return SnapSpeed(speed), "alternating damage"
		end
		return nil
	end

	if math.abs(gap1 - gap2) > speed * MIN_ALTERNATING_GAP_DIFFERENCE and CanTrustOffHandTiming() then
		return SnapSpeed(speed), "alternating gaps"
	end
	return nil
end

local function RecordUntrustedMainHit(now, damage)
	local hits = enemy.recentMainHits
	table.insert(hits, {
		interval = enemy.main.swingStart and now - enemy.main.swingStart,
		damage = damage,
	})
	if #hits > ALTERNATION_HISTORY then
		table.remove(hits, 1)
	end
end

local function AssignEnemySwing(now, damage)
	local mainFit = GetHandFit(enemy.main, now)

	if not enemy.isDualWielding then
		if mainFit and not HasTrustedHandSpeed(enemy.main) then
			RecordUntrustedMainHit(now, damage)
			local speed, evidence = DetectAlternatingHands(enemy.recentMainHits)
			if speed then
				-- The gaps learned so far were between both hands' hits.
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

		local isOffHand, evidence = TrackOffHandCandidate(now, damage)
		if isOffHand then
			StartDualWielding(evidence)
			return enemy.off
		end
		return nil, evidence
	end

	local offFit = GetHandFit(enemy.off, now)
	local hand
	local mainDamage, offDamage = GetHandDamage(enemy.main), GetHandDamage(enemy.off)
	if damage and mainDamage and offDamage and IsOffHandStrength(offDamage, mainDamage) then
		hand = IsOffHandStrength(damage, mainDamage) and enemy.off or enemy.main
		if not (hand == enemy.main and mainFit or hand == enemy.off and offFit) then
			return nil, ("too soon for the %s it hits like"):format(GetHandName(hand))
		end
	elseif mainFit and (not offFit or mainFit <= offFit) then
		hand = enemy.main
	elseif offFit then
		hand = enemy.off
	else
		return nil, "too soon"
	end

	return CountHandSwing(hand)
end

-- Timing decides which hand is which, so the stronger hand can end up labelled as the off-hand, and
-- a single hand's swings can end up split across both.
local function CheckHandStrengths()
	if not enemy.isDualWielding then
		return
	end

	local mainDamage, offDamage = GetHandDamage(enemy.main), GetHandDamage(enemy.off)
	if not (mainDamage and offDamage) then
		return
	elseif IsOffHandStrength(mainDamage, offDamage) then
		SwapHands()
		ProbeLog("hands swapped: main hand hit for %.0f vs off-hand %.0f", mainDamage, offDamage)
	elseif not enemy.isPlayer and IsSameHandStrength(mainDamage, offDamage)
		and #enemy.main.damage >= MIN_SAMPLES_TO_RULE_OUT_OFF_HAND
		and #enemy.off.damage >= MIN_SAMPLES_TO_RULE_OUT_OFF_HAND then
		-- Enemy players can carry a stronger off-hand weapon.
		DropOffHand(true, "off-hand hit for %.0f, as hard as main hand %.0f", offDamage, mainDamage)
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

function EnemySwing.UpdateVisibility()
	local showEnemy = ns.db.showEnemySwing and UnitAffectingCombat("player")
	enemy.main.bar:SetShown(showEnemy and enemy.main.swingStart ~= nil)
	enemy.off.bar:SetShown(showEnemy and enemy.isDualWielding and enemy.off.swingStart ~= nil)
end

local function OnSimulatedBarUpdate(bar)
	bar:SetValue(GetTime() - bar.simulatedSwingStart)
end

function EnemySwing.SimulateSwing(handKey, speed)
	local bar = enemy[handKey].bar
	bar.simulatedSwingStart = GetTime()
	bar:SetMinMaxValues(0, speed)
	bar:SetValue(0)
	bar.SpeedText:SetFormattedText("%.1f", speed)
	bar:SetScript("OnUpdate", OnSimulatedBarUpdate)
end

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
	Line("Enemy: attackingMe=%s player=%s dualWield=%s offHandEvidence=%d/%d enemiesAttackingMe=%d", tostring(IsTargetAttackingMe()),
		tostring(enemy.isPlayer), tostring(enemy.isDualWielding), enemy.offHandCandidate.count, OFF_HAND_DETECTION_HITS,
		CountEnemiesAttackingMe())
	for _, hand in ipairs({ enemy.main, enemy.off }) do
		Line("Enemy %s: shown=%s speed=%s learned=%s known=%s damage=%s", GetHandName(hand), tostring(hand.bar:IsShown()),
			Describe(GetLiveHandSpeed(hand)), Describe(GetLearnedHandSpeed(hand)), Describe(hand.knownSpeed),
			Describe(GetHandDamage(hand)))
	end
end

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
	local damage = isSwing and GetNormalHitDamage(action, flagText, amount) or nil
	local hand
	if isSwing then
		hand, reason = AssignEnemySwing(now, damage)
	end

	ProbeLog("hit on me: %s %s amount=%s normal=%s school=%s -> %s", Describe(action), Describe(flagText), Describe(amount),
		Describe(damage), Describe(schoolMask),
		hand and ("%s swing, expected %s"):format(GetHandName(hand), Describe(GetExpectedHandSpeed(hand))) or reason)

	if hand then
		RecordHandDamage(hand, damage)
		StartHandSwing(hand, now)
		CheckHandStrengths()
	end
end

function EVENT_HANDLERS.NAME_PLATE_UNIT_ADDED(unit)
	nameplateUnits[unit] = true
end

function EVENT_HANDLERS.NAME_PLATE_UNIT_REMOVED(unit)
	nameplateUnits[unit] = nil
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
