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

-- The same shape as the real settings, but every value is unknown so a test can store a wrong type on purpose.
type LooseSettings = {
	InstantActions: unknown,
	InstantFallbackWeight: unknown,
	StrikeThreshold: unknown,
	StrikeDecayPerSecond: unknown,
	Weights: { [string]: unknown },
}

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

	return t.Summary()
end