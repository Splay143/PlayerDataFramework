--!strict
--@Splay

local ServerScriptService = game:GetService("ServerScriptService")

local PlayerData = ServerScriptService.PlayerData

local DataSchema = require(PlayerData.Config.DataSchema)
local Harness = require(PlayerData.Tests.Harness)
local MockAdapter = require(PlayerData.Adapters.MockAdapter)
local NamespaceStore = require(PlayerData.Data.NamespaceStore)
local StoreHandler = require(PlayerData.Data.StoreHandler)

local USER_ID = 1
local NAMESPACE = "Inventory"
local KEY = DataSchema.SecondaryKeyFor(USER_ID, NAMESPACE)

-- Each scenario gets its own adapter and clock, so leftover FailNext counts
-- or stored records can't leak into the next one.
local function newFixture()
	local adapter = MockAdapter.new()
	local noWait = function() end
	local store = StoreHandler.new("S", adapter, { Wait = noWait })

	local currentTime = 1000
	local namespaceStore = NamespaceStore.new(store, {
		Now = function()
			return currentTime
		end,
	})

	local function advance(seconds: number)
		currentTime += seconds
	end

	return namespaceStore, adapter, store, advance
end

return function(): boolean
	local t = Harness.new("Phase8")

	-- One session's lifecycle, then a takeover

	do
		local namespaceStore, adapter, _, advance = newFixture()

		local claimStatus, claimedData = namespaceStore:Claim(USER_ID, NAMESPACE, "session-A")
		t.Equal("Claiming a new namespace succeeds", claimStatus, "Claimed")
		t.Check("A new namespace has no data yet", claimedData == nil)
		t.Equal("The claim stamps the session on the record", adapter:Peek(KEY).SessionId, "session-A")

		advance(5)
		t.Equal(
			"The owning session can save",
			namespaceStore:Save(USER_ID, NAMESPACE, "session-A", { Items = 3 }),
			"Saved"
		)
		t.Equal("The saved record holds the data", adapter:Peek(KEY).Data, { Items = 3 })
		t.Equal("The saved record holds the save time", adapter:Peek(KEY).SavedAt, 1005)

		-- Session B takes over: it reads A's last save and re-stamps the record.
		local takeoverStatus, takeoverData = namespaceStore:Claim(USER_ID, NAMESPACE, "session-B")
		t.Equal("A newer claim reads the last saved data", takeoverData, { Items = 3 })
		t.Equal("A newer claim re-stamps the record", adapter:Peek(KEY).SessionId, "session-B")
		t.Equal("A newer claim reports Claimed", takeoverStatus, "Claimed")

		t.Equal(
			"The old session's save is refused after a takeover",
			namespaceStore:Save(USER_ID, NAMESPACE, "session-A", { Items = 99 }),
			"Lost"
		)
		t.Equal("A refused save changes nothing", adapter:Peek(KEY).Data, { Items = 3 })
	end

	-- A save with no claim

	do
		local namespaceStore, adapter = newFixture()

		t.Equal(
			"Saving a namespace that was never claimed is refused",
			namespaceStore:Save(USER_ID, NAMESPACE, "session-A", { Items = 1 }),
			"Lost"
		)
		t.Check("An unclaimed save writes nothing", adapter:Peek(KEY) == nil)
	end

	-- A save in flight while another session claims

	do
		local namespaceStore, adapter = newFixture()
		namespaceStore:Claim(USER_ID, NAMESPACE, "session-A")

		-- Session B claims between session A's read and its commit.
		adapter:BeforeCommit(function()
			namespaceStore:Claim(USER_ID, NAMESPACE, "session-B")
		end)

		t.Equal(
			"A save that races a newer claim is refused",
			namespaceStore:Save(USER_ID, NAMESPACE, "session-A", { Items = 5 }),
			"Lost"
		)
		t.Check("The racing save wrote no data", adapter:Peek(KEY).Data == nil)
		t.Equal("The newer claim still owns the record", adapter:Peek(KEY).SessionId, "session-B")
	end

	-- Unreadable record

	do
		local namespaceStore, adapter, store = newFixture()
		store:Update(KEY, function()
			return "not a record"
		end)

		local status = namespaceStore:Claim(USER_ID, NAMESPACE, "session-A")
		t.Equal("Claiming an unreadable record reports Invalid", status, "Invalid")
		t.Equal("An unreadable record is left untouched", adapter:Peek(KEY), "not a record")
	end

	-- Store failures

	do
		local namespaceStore, adapter = newFixture()

		adapter:FailNext(10)
		local status = namespaceStore:Claim(USER_ID, NAMESPACE, "session-A")
		t.Equal("A claim reports Failed when the store keeps failing", status, "Failed")
		t.Check("A failed claim wrote nothing", adapter:Peek(KEY) == nil)
	end

	do
		local namespaceStore, adapter = newFixture()
		namespaceStore:Claim(USER_ID, NAMESPACE, "session-A")
		namespaceStore:Save(USER_ID, NAMESPACE, "session-A", { Items = 1 })

		adapter:FailNext(10)
		local status = namespaceStore:Save(USER_ID, NAMESPACE, "session-A", { Items = 2 })
		t.Equal("A save reports Failed when the store keeps failing", status, "Failed")
		t.Equal("A failed save keeps the previous data", adapter:Peek(KEY).Data, { Items = 1 })
	end

	-- Argument validation

	do
		local namespaceStore = newFixture()

		t.Check("Claim rejects an empty sessionId", not pcall(function()
			namespaceStore:Claim(USER_ID, NAMESPACE, "")
		end))
		t.Check("Save rejects nil data", not pcall(function()
			namespaceStore:Save(USER_ID, NAMESPACE, "session-A", nil :: any)
		end))
	end

	return t.Summary()
end
