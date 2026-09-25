--!strict

--@Splay

local ServerScriptService = game:GetService("ServerScriptService")

local PlayerData = ServerScriptService.PlayerData

local DataSchema = require(PlayerData.Config.DataSchema)
local MockAdapter = require(PlayerData.Adapters.MockAdapter)
local StoreHandler = require(PlayerData.Data.StoreHandler)
local SessionManager = require(PlayerData.Data.SessionManager)
local TableUtil = require(PlayerData.Utils.TableUtil)
local Harness = require(PlayerData.Tests.Harness)

-- A clock the test controls directly, plus a Now function to hand to
-- SessionManager.new. time() reads it back for assertions.
local function fakeClock(startTime: number)
	local current = startTime

	local function now(): number
		return current
	end

	local function advance(seconds: number)
		current += seconds
	end

	return now, advance
end

-- Deterministic, readable session ids: "server-1-session-1", "server-1-session-2", ...
local function sessionIdGenerator(serverId: string)
	local count = 0

	return function(): string
		count += 1
		return serverId .. "-session-" .. tostring(count)
	end
end

return function(): boolean
	local t = Harness.new("Phase3")

	-- SessionManager.new argument checks
	do
		local adapter = MockAdapter.new()
		local store = StoreHandler.new("S", adapter, { Wait = function() end })

		t.Check("new asserts on a missing store", not pcall(function()
			SessionManager.new(nil :: any, "server-1")
		end))

		t.Check("new asserts on an empty serverId", not pcall(function()
			SessionManager.new(store, "")
		end))
	end

	-- Two servers racing over the same player
	do
		local adapter = MockAdapter.new()
		local wait = function() end

		local store1 = StoreHandler.new("S", adapter, { Wait = wait })
		local store2 = StoreHandler.new("S", adapter, { Wait = wait })

		local now, advance = fakeClock(1000)

		local sm1 = SessionManager.new(store1, "server-1", {
			Now = now,
			GenerateSessionId = sessionIdGenerator("server-1"),
		})

		local sm2 = SessionManager.new(store2, "server-2", {
			Now = now,
			GenerateSessionId = sessionIdGenerator("server-2"),
		})

		-- New player: server 1 acquires and gets a freshly defaulted record.
		local status1, record1 = sm1:Acquire(1)

		t.Check(
			"Acquire on a brand-new player succeeds",
			status1 == "Acquired" and record1 ~= nil
		)

		t.Check(
			"The new record contains default data",
			record1 ~= nil
				and TableUtil.DeepEqual(
					(record1 :: any).Data,
					DataSchema.NewData()
				)
		)

		t.Check(
			"The lock belongs to server 1",
			(record1 :: any).Lock.ServerId == "server-1"
		)

		local sessionId1 = (record1 :: any).Lock.SessionId :: string

		-- Second server, same instant: refused.
		local status2, record2 = sm2:Acquire(1)

		t.Check(
			"A second server is refused while the lock is fresh",
			status2 == "Locked" and record2 == nil
		)

		t.Check(
			"A refused Acquire does not touch the stored record",
			adapter:Peek(DataSchema.KeyFor(1)).Lock.ServerId == "server-1"
		)

		-- Server 1 re-acquiring its own fresh lock ("already ours") succeeds
		-- and issues a new session id.
		local reacquireStatus, reacquireRecord = sm1:Acquire(1)

		t.Check(
			"A server can re-acquire its own still-fresh lock",
			reacquireStatus == "Acquired"
		)

		local sessionId1b = (reacquireRecord :: any).Lock.SessionId :: string

		t.Check(
			"Re-acquiring issues a new session id",
			sessionId1b ~= sessionId1
		)

		-- The old session id is now stale from the server's point of view.
		local staleSaveStatus = sm1:Save(
			1,
			sessionId1,
			DataSchema.NewData()
		)

		t.Check(
			"Saving with a superseded session id is Lost",
			staleSaveStatus == "Lost"
		)

		-- Save with the current session id succeeds and changes are visible.
		local data = DataSchema.NewData()

		local saveStatus = sm1:Save(
			1,
			sessionId1b,
			data
		)

		t.Check(
			"Saving with the current session id succeeds",
			saveStatus == "Saved"
		)

		t.Check(
			"The saved data was actually persisted",
			TableUtil.DeepEqual(
				adapter:Peek(DataSchema.KeyFor(1)).Data,
				data
			)
		)

		t.Check(
			"Save refreshed the lock's time",
			adapter:Peek(DataSchema.KeyFor(1)).Lock.Time == now()
		)

		-- Still locked, still too fresh: server 2 is refused again.
		local status2b = sm2:Acquire(1)

		t.Check(
			"Server 2 is still refused after server 1's save",
			status2b == "Locked"
		)

		-- Time passes well beyond the stale timeout with no further saves.
		advance(DataSchema.Timing.StaleLockSeconds + 1)

		local takeoverStatus, takeoverRecord = sm2:Acquire(1)

		t.Check(
			"A stale lock is taken over by another server",
			takeoverStatus == "Acquired"
		)

		t.Check(
			"The taken-over record kept the previously saved data",
			takeoverRecord ~= nil
				and TableUtil.DeepEqual(
					(takeoverRecord :: any).Data,
					data
				)
		)

		t.Check(
			"The lock now belongs to server 2",
			(takeoverRecord :: any).Lock.ServerId == "server-2"
		)

		local sessionId2 = (takeoverRecord :: any).Lock.SessionId :: string

		-- Server 1 no longer owns the lock: its save is refused and writes nothing.
		local lostSaveStatus = sm1:Save(
			1,
			sessionId1b,
			DataSchema.NewData()
		)

		t.Check(
			"A save from the server that lost its lock is Lost",
			lostSaveStatus == "Lost"
		)

		t.Check(
			"A lost save writes nothing",
			adapter:Peek(DataSchema.KeyFor(1)).Lock.ServerId == "server-2"
		)

		-- Server 1 also can't release a lock it doesn't hold.
		local wrongReleaseStatus = sm1:Release(
			1,
			sessionId1b,
			DataSchema.NewData()
		)

		t.Check(
			"Releasing with a superseded session id is Lost",
			wrongReleaseStatus == "Lost"
		)

		t.Check(
			"A refused release leaves the lock in place",
			adapter:Peek(DataSchema.KeyFor(1)).Lock ~= nil
		)

		-- Server 2 releases properly: the lock clears immediately.
		local releaseStatus = sm2:Release(
			1,
			sessionId2,
			DataSchema.NewData()
		)

		t.Check(
			"A correct release succeeds",
			releaseStatus == "Released"
		)

		t.Check(
			"Releasing clears the lock",
			adapter:Peek(DataSchema.KeyFor(1)).Lock == nil
		)

		-- With the lock free, server 1 can acquire immediately.
		local reacquireAfterReleaseStatus = sm1:Acquire(1)

		t.Check(
			"A freed lock can be acquired immediately",
			reacquireAfterReleaseStatus == "Acquired"
		)
	end

	-- A record with a newer SchemaVersion is refused outright.
	do
		local adapter = MockAdapter.new()
		local store = StoreHandler.new("S", adapter, { Wait = function() end })
		local now = fakeClock(1000)

		local sm = SessionManager.new(store, "server-1", {
			Now = now,
			GenerateSessionId = sessionIdGenerator("server-1"),
		})

		-- Seed a record from "future" code directly, bypassing SessionManager.
		store:Update(DataSchema.KeyFor(2), function()
			return {
				SchemaVersion = DataSchema.CURRENT_VERSION + 1,
				Lock = nil,
				Data = {},
				Meta = {
					CreatedAt = 1,
					LastSaved = 1,
				},
			}
		end)

		local status, record = sm:Acquire(2)

		t.Check(
			"Acquire refuses a record with a newer SchemaVersion",
			status == "TooNew" and record == nil
		)

		t.Check(
			"A refused TooNew record is left completely untouched",
			adapter:Peek(DataSchema.KeyFor(2)).SchemaVersion
				== DataSchema.CURRENT_VERSION + 1
		)
	end

	-- A corrupt record is refused as Failed, not silently reset.
	do
		local adapter = MockAdapter.new()
		local store = StoreHandler.new("S", adapter, { Wait = function() end })
		local now = fakeClock(1000)

		local sm = SessionManager.new(store, "server-1", {
			Now = now,
			GenerateSessionId = sessionIdGenerator("server-1"),
		})

		store:Update(DataSchema.KeyFor(3), function()
			return {
				SchemaVersion = "not a number",
			}
		end)

		local status, record = sm:Acquire(3)

		t.Check(
			"Acquire refuses a record it cannot parse",
			status == "Failed" and record == nil
		)

		t.Check(
			"A refused corrupt record is left untouched",
			adapter:Peek(DataSchema.KeyFor(3)).SchemaVersion
				== "not a number"
		)
	end

	-- Saving to a key with no record at all is Lost, not a crash.
	do
		local adapter = MockAdapter.new()
		local store = StoreHandler.new("S", adapter, { Wait = function() end })
		local now = fakeClock(1000)

		local sm = SessionManager.new(store, "server-1", {
			Now = now,
			GenerateSessionId = sessionIdGenerator("server-1"),
		})

		local saveStatus = sm:Save(
			4,
			"some-session-id",
			DataSchema.NewData()
		)

		t.Check(
			"Saving with no existing record is Lost",
			saveStatus == "Lost"
		)

		local releaseStatus = sm:Release(
			4,
			"some-session-id",
			DataSchema.NewData()
		)

		t.Check(
			"Releasing with no existing record is Lost",
			releaseStatus == "Lost"
		)
	end

	-- A genuine DataStore failure bubbles up as Failed from every method.
	do
		local adapter = MockAdapter.new()
		adapter:FailNext(10)

		local store = StoreHandler.new("S", adapter, {
			MaxAttempts = 2,
			Wait = function() end,
		})

		local now = fakeClock(1000)

		local sm = SessionManager.new(store, "server-1", {
			Now = now,
			GenerateSessionId = sessionIdGenerator("server-1"),
		})

		local status, record = sm:Acquire(5)

		t.Check(
			"Acquire reports Failed when the DataStore keeps erroring",
			status == "Failed" and record == nil
		)

		local saveStatus = sm:Save(
			5,
			"irrelevant",
			DataSchema.NewData()
		)

		t.Check(
			"Save reports Failed when the DataStore keeps erroring",
			saveStatus == "Failed"
		)

		local releaseStatus = sm:Release(
			5,
			"irrelevant",
			DataSchema.NewData()
		)

		t.Check(
			"Release reports Failed when the DataStore keeps erroring",
			releaseStatus == "Failed"
		)
	end

	-- Save and Release argument checks.
	do
		local adapter = MockAdapter.new()
		local store = StoreHandler.new("S", adapter, { Wait = function() end })
		local now = fakeClock(1000)

		local sm = SessionManager.new(store, "server-1", {
			Now = now,
			GenerateSessionId = sessionIdGenerator("server-1"),
		})

		t.Check("Acquire asserts on a fractional userId", not pcall(function()
			sm:Acquire(1.5)
		end))

		t.Check("Save asserts on an empty sessionId", not pcall(function()
			sm:Save(6, "", DataSchema.NewData())
		end))

		t.Check("Save asserts when data is not a table", not pcall(function()
			sm:Save(6, "session", "not a table" :: any)
		end))

		t.Check("Release asserts on an empty sessionId", not pcall(function()
			sm:Release(6, "", DataSchema.NewData())
		end))

		t.Check("Release asserts when data is not a table", not pcall(function()
			sm:Release(6, "session", "not a table" :: any)
		end))
	end

	return t.Summary()
end