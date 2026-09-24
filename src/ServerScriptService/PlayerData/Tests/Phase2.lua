--!strict
--@Splay

local ServerScriptService = game:GetService("ServerScriptService")
local PlayerData = ServerScriptService.PlayerData
local MockAdapter = require(PlayerData.Adapters.MockAdapter)
local StoreHandler = require(PlayerData.Data.StoreHandler)
local Harness = require(PlayerData.Tests.Harness)

-- Returns a Wait function for StoreHandler.new plus a way to read how many
-- times it was called and with what values.
local function waitCounter()
	local calls: { number } = {}
	local function wait(seconds: number)
		table.insert(calls, seconds)
	end
	return wait, calls
end

return function(): boolean
	local t = Harness.new("Phase2")

	-- StoreHandler.ExponentialBackoff
	do
		t.Check("Backoff attempt 1 is the base", StoreHandler.ExponentialBackoff(1, 1, 8) == 1)
		t.Check("Backoff attempt 2 doubles", StoreHandler.ExponentialBackoff(2, 1, 8) == 2)
		t.Check("Backoff attempt 4 doubles again", StoreHandler.ExponentialBackoff(4, 1, 8) == 8)
		t.Check("Backoff is capped at maxSeconds", StoreHandler.ExponentialBackoff(10, 1, 8) == 8)
		t.Check("Backoff asserts on attempt below 1", not pcall(StoreHandler.ExponentialBackoff, 0, 1, 8))
		t.Check("Backoff asserts on a negative base", not pcall(StoreHandler.ExponentialBackoff, 1, -1, 8))
		t.Check("Backoff asserts when max is below base", not pcall(StoreHandler.ExponentialBackoff, 1, 8, 1))
	end

	-- StoreHandler.new argument checks
	do
		local adapter = MockAdapter.new()
		t.Check("new asserts on an empty storeName", not pcall(function()
			StoreHandler.new("", adapter)
		end))
		t.Check("new asserts on MaxAttempts below 1", not pcall(function()
			StoreHandler.new("S", adapter, { MaxAttempts = 0 })
		end))
		t.Check("new asserts on a negative BaseBackoffSeconds", not pcall(function()
			StoreHandler.new("S", adapter, { BaseBackoffSeconds = -1 })
		end))
		t.Check(
			"new asserts when MaxBackoffSeconds is below BaseBackoffSeconds",
			not pcall(function()
				StoreHandler.new("S", adapter, { BaseBackoffSeconds = 8, MaxBackoffSeconds = 1 })
			end)
		)
	end

	-- Get
	do
		local adapter = MockAdapter.new()
		local wait, waits = waitCounter()
		local store = StoreHandler.new("S", adapter, { Wait = wait })

		local status, value = store:Get("Player_1")
		t.Check("Get on an empty key succeeds with nil", status == "Ok" and value == nil)
		t.Equal("Get does not wait on the first try", waits, {})

		local ok = store:Update("Player_1", function()
			return { Gold = 10 }
		end)
		t.Check("seed Update for the read-back test succeeded", ok == "Ok")

		local readStatus, readValue: any = store:Get("Player_1")
		t.Check("Get reads back what was stored", readStatus == "Ok" and readValue.Gold == 10)

		readValue.Gold = 999
		local rereadStatus, rereadValue: any = store:Get("Player_1")
		t.Check("Get returns an independent copy each time", rereadStatus == "Ok" and rereadValue.Gold == 10)
	end

	do
		local adapter = MockAdapter.new()
		adapter:FailNext(2)
		local wait, waits = waitCounter()
		local store = StoreHandler.new("S", adapter, { MaxAttempts = 5, Wait = wait })

		local status = store:Get("Player_1")
		t.Check("Get retries past transient failures and succeeds", status == "Ok")
		t.Check("Get made exactly 3 adapter calls (2 failures + 1 success)", adapter:CallCount() == 3)
		t.Equal("Get waited once per failed attempt", waits, { 1, 2 })
	end

	do
		local adapter = MockAdapter.new()
		adapter:FailNext(10)
		local wait, waits = waitCounter()
		local store = StoreHandler.new("S", adapter, { MaxAttempts = 3, Wait = wait })

		local status = store:Get("Player_1")
		t.Check("Get gives up after MaxAttempts and reports Failed", status == "Failed")
		t.Check("Get stopped at exactly MaxAttempts calls", adapter:CallCount() == 3)
		t.Check("Get never waits after the last attempt", #waits == 2)
	end

	-- Update: success and cancel
	do
		local adapter = MockAdapter.new()
		local wait, waits = waitCounter()
		local store = StoreHandler.new("S", adapter, { Wait = wait })

		local status, value: any = store:Update("Player_1", function(current)
			t.Check("transform sees nil for a key with no data yet", current == nil)
			return { Gold = 5 }
		end)
		t.Check("Update reports Ok and returns the new value", status == "Ok" and value.Gold == 5)
		t.Equal("Update did not need to wait", waits, {})

		local status2, value2: any = store:Update("Player_1", function(current)
			return { Gold = current.Gold + 1 }
		end)
		t.Check("A second Update sees the previously stored value", status2 == "Ok" and value2.Gold == 6)
		t.Check("The adapter actually persisted the value", adapter:Peek("Player_1").Gold == 6)
	end

	do
		local adapter = MockAdapter.new()
		local wait, waits = waitCounter()
		local store = StoreHandler.new("S", adapter, { Wait = wait })

		local status, value = store:Update("Player_1", function()
			return nil -- caller decided not to write anything
		end)
		t.Check("Update reports Cancelled when the transform returns nil", status == "Cancelled" and value == nil)
		t.Check("A cancelled Update makes exactly one adapter call", adapter:CallCount() == 1)
		t.Equal("A cancelled Update never retries or waits", waits, {})
		t.Check("Nothing was written to the store", adapter:Peek("Player_1") == nil)
	end

	--retry then succeed, retry then fail
	do
		local adapter = MockAdapter.new()
		adapter:FailNext(2)
		local wait, waits = waitCounter()
		local store = StoreHandler.new("S", adapter, { MaxAttempts = 5, Wait = wait })

		local status, value: any = store:Update("Player_1", function()
			return { Gold = 42 }
		end)
		t.Check("Update retries past transient failures and succeeds", status == "Ok" and value.Gold == 42)
		t.Check("Update made exactly 3 adapter calls (2 failures + 1 success)", adapter:CallCount() == 3)
		t.Equal("Update waited once per failed attempt", waits, { 1, 2 })
		t.Check("The value from the eventually-successful attempt was stored", adapter:Peek("Player_1").Gold == 42)
	end

	do
		local adapter = MockAdapter.new()
		adapter:FailNext(10)
		local wait, waits = waitCounter()
		local store = StoreHandler.new("S", adapter, { MaxAttempts = 4, Wait = wait })

		local status, value = store:Update("Player_1", function()
			return { Gold = 42 }
		end)
		t.Check("Update gives up after MaxAttempts and reports Failed", status == "Failed" and value == nil)
		t.Check("Update stopped at exactly MaxAttempts calls", adapter:CallCount() == 4)
		t.Check("Update never waits after the last attempt", #waits == 3)
		t.Check("A failed Update never wrote anything", adapter:Peek("Player_1") == nil)
	end

	-- Argument checks on Get and Update
	do
		local adapter = MockAdapter.new()
		local store = StoreHandler.new("S", adapter, { Wait = function() end })
		t.Check("Get asserts on an empty key", not pcall(function()
			store:Get("")
		end))
		t.Check("Update asserts on an empty key", not pcall(function()
			store:Update("", function(): any?
				return nil
			end)
		end))
		t.Check("Update asserts when transform is not a function", not pcall(function()
			store:Update("Player_1", "not a function" :: any)
		end))
	end

	-- MockAdapter
	do
		local adapter = MockAdapter.new()
		t.Check("FailNext asserts on a negative count", not pcall(function()
			adapter:FailNext(-1)
		end))
		t.Check("SetLatency asserts on a negative value", not pcall(function()
			adapter:SetLatency(-1)
		end))
		t.Check("GetAsync asserts on an empty key", not pcall(function()
			adapter:GetAsync("")
		end))
	end

	return t.Summary()
end