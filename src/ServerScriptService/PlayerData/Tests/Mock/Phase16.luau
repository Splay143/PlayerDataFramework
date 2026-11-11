--!strict
--@Splay

--[[
	Phase 16 tests: ViolationClassifier, StrikeTracker.
	A double cast through unknown on a bad-input check is deliberate: it passes a wrong type on purpose.
	Settings are passed in explicitly so the tests do not depend on the live config,
	except the one check that the shipped config is valid.
]]
local ServerScriptService = game:GetService("ServerScriptService")

local PlayerData = ServerScriptService.PlayerData

local DataSchema = require(PlayerData.Config.DataSchema)
local Harness = require(PlayerData.Tests.Harness)
local StrikeTracker = require(PlayerData.Security.StrikeTracker)
local ViolationClassifier = require(PlayerData.Security.ViolationClassifier)
local ErrorCodes = require(PlayerData.Config.ErrorCodes)
local Logger = require(PlayerData.Utils.Logger)
local MassTriggerGuard = require(PlayerData.Security.MassTriggerGuard)
local MockBanHandler = require(PlayerData.Adapters.MockBanHandler)
local SecurityService = require(PlayerData.Security.SecurityService)

-- The same shape as the real settings, but every value is unknown so a test can store a wrong type on purpose.
type LooseSettings = {
	InstantActions: unknown,
	InstantFallbackWeight: unknown,
	StrikeThreshold: unknown,
	StrikeDecayPerSecond: unknown,
	Weights: { [string]: unknown },
}

type KickRecord = { Player: Player, Incident: Logger.EventInput }

type Rig = {
	Service: SecurityService.SecurityService,
	Logs: { Logger.EventInput },
	Kicks: { KickRecord },
	Ban: MockBanHandler.MockBanHandler,
	Advance: (seconds: number) -> (),
}

type RigOptions = {
	Mode: SecurityService.Mode,
	IsStudio: boolean?,
	NoBanHandler: boolean?,
	Tweak: ((settings: SecurityService.Settings) -> ())?,
}

local function newSecuritySettings(mode: SecurityService.Mode): SecurityService.Settings
	return {
		Mode = mode,
		InstantActions = true,
		InstantFallbackWeight = 25,
		Weights = { RateLimited = 2, SnapshotRateLimited = 2, InvalidPayload = 25 },
		StrikeThreshold = 100,
		StrikeDecayPerSecond = 0.5,
		BanAfterFlags = 3,
		BanDurationSeconds = -1,
		ExemptUserIds = {},
		MassTriggerPlayers = 3,
		MassTriggerWindowSeconds = 60,
	}
end

-- Scripts cannot create real Players, and SecurityService only reads UserId.
local function fakePlayer(userId: number): Player
	return ({ UserId = userId } :: unknown) :: Player
end

local CREATOR_ID = 7

local function newRig(options: RigOptions): Rig
	local clock = 1000
	local logs: { Logger.EventInput } = {}
	local kicks: { KickRecord } = {}
	local ban = MockBanHandler.new()

	local settings = newSecuritySettings(options.Mode)
	if options.Tweak ~= nil then
		options.Tweak(settings)
	end

	local banHandler: SecurityService.BanHandler? = nil
	if options.NoBanHandler ~= true then
		banHandler = function(userId: number, reason: string, durationSeconds: number)
			ban:Handle(userId, reason, durationSeconds)
		end
	end

	local service = SecurityService.new({
		Settings = settings,
		Now = function(): number
			return clock
		end,
		Log = function(input: Logger.EventInput)
			table.insert(logs, input)
		end,
		Kick = function(player: Player, incident: Logger.EventInput)
			table.insert(kicks, { Player = player, Incident = incident })
		end,
		BanHandler = banHandler,
		IsStudio = options.IsStudio == true,
		CreatorId = CREATOR_ID,
	})

	return {
		Service = service,
		Logs = logs,
		Kicks = kicks,
		Ban = ban,
		Advance = function(seconds: number)
			clock += seconds
		end,
	}
end

-- True when the action throws. Wrapped so pcall's extra return values never reach t.Check.
local function throws(action: () -> ()): boolean
	return not (pcall(action))
end

local function newSettings(): ViolationClassifier.Settings
	return {
		InstantActions = true,
		InstantFallbackWeight = 25,
		StrikeThreshold = 100,
		StrikeDecayPerSecond = 0.5,
		Weights = { RateLimited = 2, SnapshotRateLimited = 2, InvalidPayload = 25 },
	}
end

local function newLooseSettings(): LooseSettings
	return (newSettings() :: unknown) :: LooseSettings
end

return function(): boolean
	local t = Harness.new("Phase16")

	-- ViolationClassifier
	do
		local settings = newSettings()

		t.Check("the shipped security config is valid", not throws(function()
			ViolationClassifier.ValidateSettings(DataSchema.Security)
		end))

		-- Every reason the networking layer can produce, and the new probe reasons, handled on purpose.
		local expectedKinds: { [string]: string } = {
			Unavailable = "Ignore",
			NotLoaded = "Ignore",
			HandlerError = "Ignore",
			UnknownPlayer = "Ignore",
			RateLimited = "Strike",
			SnapshotRateLimited = "Strike",
			InvalidPayload = "Strike",
			NoHandler = "Instant",
			MalformedRoute = "Instant",
			MalformedPayload = "Instant",
			ExtraArguments = "Instant",
			Honeypot = "Instant",
		}
		for reason, kind in expectedKinds do
			t.Equal(reason .. " is classified as intended", ViolationClassifier.Classify(reason, settings).Kind, kind)
		end

		-- Normal behaviour and our own bugs are never punished, even if config tries to give them weight.
		local tempting = newSettings()
		for _, reason in { "NotLoaded", "UnknownPlayer", "Unavailable", "HandlerError" } do
			tempting.Weights[reason] = 50
			t.Equal(
				reason .. " stays ignored even if config gives it a weight",
				ViolationClassifier.Classify(reason, tempting),
				{ Kind = "Ignore", Weight = 0 }
			)
		end

		-- With InstantActions off, probe reasons only add the fallback weight.
		local cautious = newSettings()
		cautious.InstantActions = false
		cautious.InstantFallbackWeight = 7
		for _, reason in { "MalformedRoute", "MalformedPayload", "ExtraArguments", "NoHandler", "Honeypot" } do
			t.Equal(
				reason .. " is a plain strike when InstantActions is off",
				ViolationClassifier.Classify(reason, cautious),
				{ Kind = "Strike", Weight = 7 }
			)
		end

		-- Strike weights come from the settings.
		t.Equal(
			"RateLimited uses its configured weight",
			ViolationClassifier.Classify("RateLimited", settings),
			{ Kind = "Strike", Weight = 2 }
		)
		t.Equal(
			"InvalidPayload uses its configured weight",
			ViolationClassifier.Classify("InvalidPayload", settings),
			{ Kind = "Strike", Weight = 25 }
		)
		t.Check(
			"InvalidPayload weighs more than rate limiting",
			ViolationClassifier.Classify("InvalidPayload", settings).Weight
				> ViolationClassifier.Classify("RateLimited", settings).Weight
		)

		local custom = newSettings()
		custom.Weights.InvalidPayload = 77
		t.Equal(
			"a passed-in table overrides the config",
			ViolationClassifier.Classify("InvalidPayload", custom).Weight,
			77
		)

		local sparse = newSettings()
		sparse.Weights = {}
		t.Equal(
			"a missing weight gives no punishment",
			ViolationClassifier.Classify("InvalidPayload", sparse),
			{ Kind = "Strike", Weight = 0 }
		)

		t.Equal(
			"an unknown reason is ignored",
			ViolationClassifier.Classify("SomethingNew", settings),
			{ Kind = "Ignore", Weight = 0 }
		)
		t.Check("Classify asserts on a non-string reason", throws(function()
			ViolationClassifier.Classify((5 :: unknown) :: string)
		end))

		-- Validation
		local function rejects(mutate: (candidate: LooseSettings) -> ()): boolean
			local candidate = newLooseSettings()
			mutate(candidate)
			return throws(function()
				ViolationClassifier.ValidateSettings(candidate)
			end)
		end

		t.Check("ValidateSettings accepts a good table", not throws(function()
			ViolationClassifier.ValidateSettings(newSettings())
		end))
		t.Check("a non-table is rejected", throws(function()
			ViolationClassifier.ValidateSettings("nope")
		end))
		t.Check("a missing weight is rejected", rejects(function(candidate)
			candidate.Weights.InvalidPayload = nil
		end))
		t.Check("a negative weight is rejected", rejects(function(candidate)
			candidate.Weights.InvalidPayload = -1
		end))
		t.Check("a NaN weight is rejected", rejects(function(candidate)
			candidate.Weights.InvalidPayload = 0 / 0
		end))
		t.Check("an infinite weight is rejected", rejects(function(candidate)
			candidate.Weights.InvalidPayload = math.huge
		end))
		t.Check("a weight for an ignored reason is rejected", rejects(function(candidate)
			candidate.Weights.NotLoaded = 5
		end))
		t.Check("a leftover weight for an instant reason is rejected", rejects(function(candidate)
			candidate.Weights.NoHandler = 10
		end))
		t.Check("a typo'd reason is rejected", rejects(function(candidate)
			candidate.Weights.InvalidPayloads = 5
		end))
		t.Check("InstantActions must be a boolean", rejects(function(candidate)
			candidate.InstantActions = "yes"
		end))
		t.Check("a negative fallback weight is rejected", rejects(function(candidate)
			candidate.InstantFallbackWeight = -1
		end))
		t.Check("a threshold of 0 is rejected", rejects(function(candidate)
			candidate.StrikeThreshold = 0
		end))
		t.Check("a negative decay is rejected", rejects(function(candidate)
			candidate.StrikeDecayPerSecond = -1
		end))
	end

	-- StrikeTracker
	do
		local now = 1000
		local function newTracker(): StrikeTracker.StrikeTracker
			return StrikeTracker.new({
				Now = function(): number
					return now
				end,
				Threshold = 100,
				DecayPerSecond = 0.5,
			})
		end

		-- Adding and draining
		local tracker = newTracker()
		t.Equal("an unknown player has no strikes", tracker:Score(1), 0)
		t.Equal("Add returns the new score", tracker:Add(1, 10), 10)
		t.Equal("strikes add up", tracker:Add(1, 15), 25)

		now += 20 -- 20 seconds at 0.5 per second drains 10
		t.Equal("strikes drain over time", tracker:Score(1), 15)

		now += 1000
		t.Equal("a score never goes below zero", tracker:Score(1), 0)

		-- Threshold
		local limit = newTracker()
		limit:Add(2, 99)
		t.Check("just under the threshold is not over", not limit:IsOverThreshold(2))
		limit:Add(2, 1)
		t.Check("reaching the threshold counts as over", limit:IsOverThreshold(2))
		now += 10 -- drains 5
		t.Check("draining back under the threshold clears it", not limit:IsOverThreshold(2))

		-- Separate players
		local shared = newTracker()
		shared:Add(3, 40)
		shared:Add(4, 5)
		t.Equal("players are scored separately", { shared:Score(3), shared:Score(4) }, { 40, 5 })
		t.Equal("a zero weight only reads the score", shared:Add(4, 0), 5)
		t.Equal("a negative UserId works", shared:Add(-1, 5), 5)
		shared:Clear(3)
		t.Equal("Clear forgets a player", shared:Score(3), 0)
		t.Equal("Clear leaves other players alone", shared:Score(4), 5)

		-- A clock that steps backwards
		local skewed = newTracker()
		skewed:Add(5, 10)
		now -= 100
		t.Equal("a clock that steps backwards does not change a score", skewed:Score(5), 10)
		now += 100

		-- Bad input
		t.Check("Add asserts on a negative weight", throws(function()
			tracker:Add(1, -1)
		end))
		t.Check("Add asserts on a NaN weight", throws(function()
			tracker:Add(1, 0 / 0)
		end))
		t.Check("Add asserts on an infinite weight", throws(function()
			tracker:Add(1, math.huge)
		end))
		t.Check("Add asserts on a fractional userId", throws(function()
			tracker:Add(1.5, 1)
		end))
		t.Check("Score asserts on a non-number userId", throws(function()
			tracker:Score(("nope" :: unknown) :: number)
		end))
		t.Check("new asserts on a Threshold of 0", throws(function()
			StrikeTracker.new({ Threshold = 0 })
		end))
		t.Check("new asserts on a negative DecayPerSecond", throws(function()
			StrikeTracker.new({ DecayPerSecond = -1 })
		end))
		t.Check("new asserts when Now is not a function", throws(function()
			StrikeTracker.new({ Now = ("nope" :: unknown) :: () -> number })
		end))
	end

	-- MassTriggerGuard
	do
		local now = 1000
		local function newGuard(maxKeys: number?): MassTriggerGuard.MassTriggerGuard
			return MassTriggerGuard.new({
				Now = function(): number
					return now
				end,
				MinPlayers = 3,
				WindowSeconds = 60,
				MaxKeys = maxKeys,
			})
		end
	
		local guard = newGuard()
		t.Equal("one player is not a mass trigger", guard:Record("Typo", 1), false)
		t.Equal("two players are not a mass trigger", guard:Record("Typo", 2), false)
		t.Equal("a third different player is", guard:Record("Typo", 3), true)
		t.Equal("another route is counted separately", guard:Record("Other", 1), false)
	
		local repeater = newGuard()
		local everTrue = false
		for _ = 1, 5 do
			everTrue = everTrue or repeater:Record("Typo", 1)
		end
		t.Check("one player repeating never triggers it", not everTrue)
	
		local expiring = newGuard()
		expiring:Record("Typo", 1)
		expiring:Record("Typo", 2)
		now += 61
		t.Equal("players outside the window no longer count", expiring:Record("Typo", 3), false)
	
		-- A full table of live keys refuses new keys instead of growing
		now = 1000
		local capped = newGuard(2)
		capped:Record("A", 1)
		capped:Record("B", 1)
		local cappedTriggered = false
		for userId = 1, 3 do
			cappedTriggered = cappedTriggered or capped:Record("C", userId)
		end
		t.Check("a new key is not tracked while the table is full of live keys", not cappedTriggered)
		now += 61
		capped:Record("C", 1)
		capped:Record("C", 2)
		t.Equal("expired keys are swept so a new key can be tracked", capped:Record("C", 3), true)
	
		t.Check("Record asserts on an empty key", throws(function()
			guard:Record("", 1)
		end))
		t.Check("new asserts on MinPlayers below 2", throws(function()
			MassTriggerGuard.new({ MinPlayers = 1 })
		end))
		t.Check("new asserts on a WindowSeconds of 0", throws(function()
			MassTriggerGuard.new({ WindowSeconds = 0 })
		end))
	end
	
	-- SecurityService
	do
		t.Check("the shipped security config passes the full validation", not throws(function()
			SecurityService.ValidateSettings(DataSchema.Security)
		end))
		t.Equal("the framework ships in LogOnly", DataSchema.Security.Mode, "LogOnly")
	
		-- Off
		local off = newRig({ Mode = "Off" })
		t.Equal("Off does nothing", off.Service:Report(fakePlayer(100), "Honeypot", "Trap", "Request"), "Off")
		t.Equal("Off logs and kicks nothing", { #off.Logs, #off.Kicks }, { 0, 0 })
	
		-- LogOnly
		local logOnly = newRig({ Mode = "LogOnly" })
		t.Equal(
			"LogOnly reports a would-be ban for an instant reason",
			logOnly.Service:Report(fakePlayer(100), "Honeypot", "Trap", "Request"),
			"WouldBan"
		)
		t.Equal(
			"LogOnly logs it as code 701 at Warning",
			{ Code = logOnly.Logs[1].Code, Severity = logOnly.Logs[1].Severity },
			{ Code = ErrorCodes.Codes.SecurityWouldAct, Severity = "Warning" }
		)
		t.Equal("LogOnly never kicks or bans", { #logOnly.Kicks, #logOnly.Ban.Calls }, { 0, 0 })
		t.Equal(
			"LogOnly reports a would-be kick for NoHandler",
			logOnly.Service:Report(fakePlayer(101), "NoHandler", "Missing", "Request"),
			"WouldKick"
		)
		t.Equal("LogOnly does not count flags", logOnly.Service:GetFlags(101), 0)
	
		-- Ignored reasons and exemptions
		local enforce = newRig({
			Mode = "Enforce",
			Tweak = function(settings: SecurityService.Settings)
				settings.ExemptUserIds = { 55 }
			end,
		})
		t.Equal(
			"a normal rejection is ignored",
			enforce.Service:Report(fakePlayer(200), "NotLoaded", "Route", "Request"),
			"Ignored"
		)
		t.Equal(
			"the creator is exempt",
			enforce.Service:Report(fakePlayer(CREATOR_ID), "Honeypot", "Trap", "Request"),
			"Exempt"
		)
		t.Equal(
			"a listed user is exempt",
			enforce.Service:Report(fakePlayer(55), "Honeypot", "Trap", "Request"),
			"Exempt"
		)
		t.Equal("exempt and ignored players cause no action", { #enforce.Kicks, #enforce.Ban.Calls }, { 0, 0 })
	
		-- Enforce: instant ban, once only
		local cheater = fakePlayer(300)
		t.Equal(
			"a honeypot hit is banned in Enforce",
			enforce.Service:Report(cheater, "Honeypot", "Trap", "Request"),
			"Banned"
		)
		t.Equal("the ban handler was called once", #enforce.Ban.Calls, 1)
		t.Equal(
			"the ban incident is code 703 at Error",
			{ Code = enforce.Kicks[1].Incident.Code, Severity = enforce.Kicks[1].Incident.Severity },
			{ Code = ErrorCodes.Codes.SecurityBan, Severity = "Error" }
		)
		t.Equal(
			"a second report from a banned player does nothing",
			enforce.Service:Report(cheater, "MalformedRoute", 5, "Request"),
			"AlreadyActed"
		)
		enforce.Service:Clear(300)
		t.Equal(
			"a banned player is not banned twice, even after leaving and rejoining",
			enforce.Service:Report(cheater, "Honeypot", "Trap", "Request"),
			"AlreadyActed"
		)
		t.Equal("still only one ban call", #enforce.Ban.Calls, 1)
	
		-- Ban handler failures fall back to a kick
		local failing = newRig({ Mode = "Enforce" })
		failing.Ban.ShouldFail = true
		t.Equal(
			"a throwing ban handler falls back to a kick",
			failing.Service:Report(fakePlayer(310), "MalformedRoute", 5, "Request"),
			"Kicked"
		)
		t.Equal("the fallback is code 704", failing.Kicks[1].Incident.Code, ErrorCodes.Codes.SecurityBanFailed)
		failing.Service:Clear(310)
		failing.Ban.ShouldFail = false
		t.Equal(
			"a failed ban is retried when the player comes back",
			failing.Service:Report(fakePlayer(310), "MalformedRoute", 5, "Request"),
			"Banned"
		)
	
		local noHandler = newRig({ Mode = "Enforce", NoBanHandler = true })
		t.Equal(
			"a missing ban handler falls back to a kick",
			noHandler.Service:Report(fakePlayer(311), "Honeypot", "Trap", "Request"),
			"Kicked"
		)
	
		-- Studio never bans
		local studio = newRig({ Mode = "Enforce", IsStudio = true })
		t.Equal(
			"Studio kicks instead of banning",
			studio.Service:Report(fakePlayer(320), "Honeypot", "Trap", "Request"),
			"Kicked"
		)
		t.Equal(
			"Studio makes no ban call and logs code 702",
			{ #studio.Ban.Calls, studio.Kicks[1].Incident.Code },
			{ 0, ErrorCodes.Codes.SecurityKick }
		)
	
		-- NoHandler: kick and flag, repeat offenders are banned
		local flagging = newRig({ Mode = "Enforce" })
		local repeatOffender = fakePlayer(330)
		local outcomes: { string } = {}
		for _, route in { "RouteA", "RouteB", "RouteC" } do
			table.insert(outcomes, flagging.Service:Report(repeatOffender, "NoHandler", route, "Request"))
			flagging.Service:Clear(330) -- leaves and rejoins
		end
		t.Equal("the third flag becomes a ban", outcomes, { "Kicked", "Kicked", "Banned" })
		t.Equal("flags survive a rejoin", flagging.Service:GetFlags(330), 3)
	
		-- Mass trigger
		local typo = newRig({ Mode = "Enforce" })
		typo.Service:Report(fakePlayer(401), "NoHandler", "Typo", "Request")
		typo.Service:Report(fakePlayer(402), "NoHandler", "Typo", "Request")
		t.Equal(
			"a third player on the same unknown route is treated as a typo",
			typo.Service:Report(fakePlayer(403), "NoHandler", "Typo", "Request"),
			"MassTrigger"
		)
		t.Equal("the typo victim is not kicked", #typo.Kicks, 2)
		t.Equal("the typo is logged as code 705", typo.Logs[1].Code, ErrorCodes.Codes.SecurityMassTrigger)
		t.Equal(
			"a different route is still acted on",
			typo.Service:Report(fakePlayer(404), "NoHandler", "Other", "Request"),
			"Kicked"
		)
	
		-- Strikes
		local strikes = newRig({ Mode = "Enforce" })
		local striker = fakePlayer(500)
		local strikeOutcomes: { string } = {}
		for _ = 1, 4 do
			table.insert(strikeOutcomes, strikes.Service:Report(striker, "InvalidPayload", "Route", "Request"))
		end
		t.Equal("strikes only act at the threshold", strikeOutcomes, { "Counted", "Counted", "Counted", "Kicked" })
		t.Equal("a kicked player is not reported again", strikes.Service:Report(striker, "InvalidPayload", "R", "Request"), "AlreadyActed")
		strikes.Service:Clear(500)
		t.Equal("Clear forgets the strikes", strikes.Service:Report(striker, "InvalidPayload", "R", "Request"), "Counted")
	
		local logStrikes = newRig({ Mode = "LogOnly" })
		local lastOutcome = ""
		for _ = 1, 4 do
			lastOutcome = logStrikes.Service:Report(fakePlayer(501), "InvalidPayload", "Route", "Request")
		end
		t.Equal("LogOnly reports a would-be kick at the threshold", lastOutcome, "WouldKick")
	
		-- Replication has no route
		local replication = newRig({ Mode = "Enforce" })
		t.Equal(
			"a replication rejection without a route is handled",
			replication.Service:Report(fakePlayer(600), "ExtraArguments", nil, "Replication"),
			"Banned"
		)
	
		-- Validation
		local function rejectsSecurity(mutate: (candidate: { [string]: unknown }) -> ()): boolean
			local candidate = table.clone((newSecuritySettings("LogOnly") :: unknown) :: { [string]: unknown })
			mutate(candidate)
			return throws(function()
				SecurityService.ValidateSettings(candidate)
			end)
		end
	
		t.Check("an unknown Mode is rejected", rejectsSecurity(function(candidate)
			candidate.Mode = "Enforcee"
		end))
		t.Check("BanAfterFlags of 0 is rejected", rejectsSecurity(function(candidate)
			candidate.BanAfterFlags = 0
		end))
		t.Check("a ban duration of 0 is rejected", rejectsSecurity(function(candidate)
			candidate.BanDurationSeconds = 0
		end))
		t.Check("a non-number in ExemptUserIds is rejected", rejectsSecurity(function(candidate)
			candidate.ExemptUserIds = { "bob" }
		end))
		t.Check("MassTriggerPlayers of 1 is rejected", rejectsSecurity(function(candidate)
			candidate.MassTriggerPlayers = 1
		end))
		t.Check("a MassTriggerWindowSeconds of 0 is rejected", rejectsSecurity(function(candidate)
			candidate.MassTriggerWindowSeconds = 0
		end))
		t.Check("new asserts without a Log function", throws(function()
			SecurityService.new(({ Kick = function() end } :: unknown) :: SecurityService.Options)
		end))
	end

	return t.Summary()
end