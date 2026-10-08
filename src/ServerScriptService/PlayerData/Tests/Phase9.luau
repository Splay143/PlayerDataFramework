--!strict
--@Splay

--[[
	Phase 9 tests: UnreleasedSessions.

	Nothing here uses real time: a fake clock moves only when the test advances it.
	Expected delays are read from DataSchema.Timing, so changing the config does not
	break the tests.

	It returns true when every check passed.
]]

local ServerScriptService = game:GetService("ServerScriptService")

local PlayerData = ServerScriptService.PlayerData

local DataSchema = require(PlayerData.Config.DataSchema)
local Harness = require(PlayerData.Tests.Harness)
local UnreleasedSessions = require(PlayerData.Utils.UnreleasedSessions)

local START_TIME = 1000
local USER_ID = 1
local SESSION_ID = "session-a"

local function newTracker(): (UnreleasedSessions.UnreleasedSessions, (seconds: number) -> ())
	local currentTime = START_TIME

	local tracker = UnreleasedSessions.new({
		Now = function()
			return currentTime
		end,
	})

	local function advance(seconds: number)
		currentTime += seconds
	end

	return tracker, advance
end

return function(): boolean
	local t = Harness.new("Phase9")

	local base = DataSchema.Timing.UnreleasedRetryBaseSeconds
	local maxDelay = DataSchema.Timing.UnreleasedRetryMaxSeconds
	local window = DataSchema.Timing.UnreleasedRetryWindowSeconds

	-- Storing and reading

	do
		local tracker = newTracker()
		t.Equal("A new tracker holds nothing", tracker:Count(), 0)
		t.Check("Get returns nil for an unknown player", tracker:Get(USER_ID) == nil)

		tracker:Add(USER_ID, SESSION_ID, { Test = { Points = 5 } })
		local entry = tracker:Get(USER_ID)

		t.Check("Add stores an entry", entry ~= nil)
		t.Equal("The entry keeps the session id", entry and entry.SessionId, SESSION_ID)
		t.Equal("The entry keeps the data", entry and entry.Data, { Test = { Points = 5 } })
		t.Equal("A new entry has had no retries", entry and entry.Attempts, 0)
		t.Equal("Count reports one entry", tracker:Count(), 1)
	end

	-- The stored data must not change when the live table does

	do
		local tracker = newTracker()
		local live = { Test = { Points = 5 } }
		tracker:Add(USER_ID, SESSION_ID, live)
		live.Test.Points = 999

		local entry = tracker:Get(USER_ID)
		t.Equal("The stored data is a snapshot, not the live table", entry and entry.Data, { Test = { Points = 5 } })
	end

	-- Retry timing

	do
		local tracker, advance = newTracker()
		tracker:Add(USER_ID, SESSION_ID, {})

		t.Equal("Nothing is due straight after a failure", #tracker:Due(), 0)

		advance(base - 1)
		t.Equal("Nothing is due before the base delay", #tracker:Due(), 0)

		advance(1)
		t.Equal("The entry is due once the base delay has passed", #tracker:Due(), 1)
	end

	-- Backoff

	do
		local tracker, advance = newTracker()
		tracker:Add(USER_ID, SESSION_ID, {})
		advance(base)

		tracker:RecordFailure(USER_ID, SESSION_ID)
		local entry = tracker:Get(USER_ID)
		t.Equal("RecordFailure counts the attempt", entry and entry.Attempts, 1)
		t.Equal("An entry is not due right after a failed retry", #tracker:Due(), 0)

		local secondDelay = math.min(base * 2, maxDelay)
		advance(secondDelay - 1)
		t.Equal("The second delay is longer than the first", #tracker:Due(), 0)
		advance(1)
		t.Equal("The entry is due after the second delay", #tracker:Due(), 1)

		-- Enough failures to hit the cap, however the config is tuned.
		for _ = 1, 20 do
			tracker:RecordFailure(USER_ID, SESSION_ID)
		end
		advance(maxDelay - 1)
		t.Equal("Backoff does not shrink once capped", #tracker:Due(), 0)
		advance(1)
		t.Equal("Backoff never exceeds the maximum delay", #tracker:Due(), 1)
	end

	-- Session id guards

	do
		local tracker = newTracker()
		tracker:Add(USER_ID, "session-b", {})

		tracker:RecordFailure(USER_ID, SESSION_ID)
		local entry = tracker:Get(USER_ID)
		t.Equal("RecordFailure for an old session is ignored", entry and entry.Attempts, 0)

		tracker:Remove(USER_ID, SESSION_ID)
		t.Equal("Remove for an old session is ignored", tracker:Count(), 1)

		tracker:Remove(USER_ID, "session-b")
		t.Equal("Remove with the matching session deletes the entry", tracker:Count(), 0)
	end

	-- One entry per player

	do
		local tracker = newTracker()
		tracker:Add(USER_ID, "session-a", { Test = { Points = 1 } })
		tracker:Add(USER_ID, "session-b", { Test = { Points = 2 } })

		local entry = tracker:Get(USER_ID)
		t.Equal("Add replaces an older entry for the same player", tracker:Count(), 1)
		t.Equal("The newest session wins", entry and entry.SessionId, "session-b")

		tracker:Add(2, "session-c", {})
		tracker:Remove(USER_ID, "session-b")
		t.Check("Removing one player leaves the others", tracker:Get(2) ~= nil)
	end

	-- Expiry

	do
		local tracker, advance = newTracker()
		tracker:Add(1, "old", {})
		advance(window - 1)
		tracker:Add(2, "newer", {})

		t.Equal("Nothing expires inside the window", #tracker:DropExpired(), 0)

		advance(1)
		local dropped = tracker:DropExpired()
		t.Equal("DropExpired returns the expired entry", #dropped, 1)
		t.Equal("The expired entry is the right player", dropped[1] and dropped[1].UserId, 1)
		t.Check("The expired entry is gone", tracker:Get(1) == nil)
		t.Check("A newer entry survives", tracker:Get(2) ~= nil)
	end

		-- All

	do
		local tracker = newTracker()
		t.Equal("All is empty for a new tracker", #tracker:All(), 0)

		tracker:Add(1, "a", {})
		tracker:Add(2, "b", {})
		t.Equal("All returns every entry even when none is due", #tracker:All(), 2)
	end
	
	-- Argument validation

	do
		local tracker = newTracker()

		t.Check(
			"Add rejects a non-numeric user id",
			not pcall(function()
				tracker:Add("1" :: any, SESSION_ID, {})
			end)
		)
		t.Check(
			"Add rejects an empty session id",
			not pcall(function()
				tracker:Add(USER_ID, "", {})
			end)
		)
		t.Check(
			"Add rejects data that is not a table",
			not pcall(function()
				tracker:Add(USER_ID, SESSION_ID, nil :: any)
			end)
		)
	end

	return t.Summary()
end