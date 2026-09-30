--!strict

--@Splay

--[[
	Phase 5 tests: SaveUtil, ValueReplication, PrivateAdapter, and
	DataService.Replicate.

	It returns true when every check passed.
]]

local ServerScriptService = game:GetService("ServerScriptService")

local PlayerData = ServerScriptService.PlayerData

local DataSchema = require(PlayerData.Config.DataSchema)
local DataService = require(PlayerData.Data.DataService)
local Harness = require(PlayerData.Tests.Harness)
local PrivateAdapter = require(PlayerData.Adapters.PrivateAdapter)
local SaveUtil = require(PlayerData.Utils.SaveUtil)
local ValueReplication = require(PlayerData.Utils.ValueReplication)

return function(): boolean
	local t = Harness.new("Phase5")

	-- SaveUtil.new argument checks
	do
		t.Check("new asserts when getBudget is not a function", not pcall(function()
			SaveUtil.new("not a function" :: any, function(_key: string): SaveUtil.SaveResult
				return "Saved"
			end)
		end))

		t.Check("new asserts when performSave is not a function", not pcall(function()
			SaveUtil.new(function()
				return 0
			end, "not a function" :: any)
		end))
	end

	-- Dedup
	do
		local calls: { string } = {}

		local saveUtil = SaveUtil.new(function()
			return math.huge
		end, function(key: string): SaveUtil.SaveResult
			table.insert(calls, key)
			return "Saved"
		end)

		saveUtil:RequestSave("Alice")
		saveUtil:RequestSave("Alice")
		saveUtil:Update()

		t.Equal("A duplicate RequestSave for the same key only saves once", calls, { "Alice" })
	end

	-- Cancel
	do
		local calls: { string } = {}

		local saveUtil = SaveUtil.new(function()
			return math.huge
		end, function(key: string): SaveUtil.SaveResult
			table.insert(calls, key)
			return "Saved"
		end)

		saveUtil:RequestSave("Bob")
		saveUtil:Cancel("Bob")
		saveUtil:Update()

		t.Equal("A cancelled key is never saved", calls, {})
	end

	t.Check("RequestSave asserts on a nil key", not pcall(function()
		local saveUtil = SaveUtil.new(function()
			return math.huge
		end, function(_key: string): SaveUtil.SaveResult
			return "Saved"
		end)

		saveUtil:RequestSave(nil :: any)
	end))

	-- Budget gating: zero budget sends nothing
	do
		local calls = 0

		local saveUtil = SaveUtil.new(function()
			return 0
		end, function(_key: string): SaveUtil.SaveResult
			calls += 1
			return "Saved"
		end)

		saveUtil:RequestSave("Alice")
		saveUtil:RequestSave("Bob")
		saveUtil:Update()

		t.Check("Update sends nothing when the available budget is zero", calls == 0)
	end

	-- Budget gating: a partial budget sends exactly the allowed count, in order
	do
		-- SaveQueueBudgetFraction is 0.5, so a budget of 6 allows exactly 3 sends per tick.
		local calls: { string } = {}

		local saveUtil = SaveUtil.new(function()
			return 6
		end, function(key: string): SaveUtil.SaveResult
			table.insert(calls, key)
			return "Saved"
		end)

		for _, key in { "A", "B", "C", "D", "E" } do
			saveUtil:RequestSave(key)
		end

		saveUtil:Update()

		t.Equal("A tick sends exactly the budget-allowed count in FIFO order", calls, { "A", "B", "C" })

		saveUtil:Update()

		t.Equal("A later tick with the same budget drains what's left", calls, { "A", "B", "C", "D", "E" })
	end

	-- Cooldown after a failure
	do
		local callTimes: { number } = {}
		local time = 0

		local saveUtil = SaveUtil.new(function()
			return math.huge
		end, function(_key: string): SaveUtil.SaveResult
			table.insert(callTimes, time)
			return "Failed"
		end, {
			Now = function()
				return time
			end,
		})

		saveUtil:RequestSave("Alice")
		saveUtil:RequestSave("Bob")
		saveUtil:Update()

		t.Equal("A failure stops the rest of that tick's batch", callTimes, { 0 })

		saveUtil:Update()

		t.Equal("A retry within the cooldown makes no further calls", callTimes, { 0 })

		time += DataSchema.Store.SaveQueueCooldownSeconds

		saveUtil:Update()

		t.Equal(
			"A retry after the cooldown elapses resumes",
			callTimes,
			{ 0, DataSchema.Store.SaveQueueCooldownSeconds }
		)
	end

	-- ValueReplication
	do
		local folder = Instance.new("Folder")
		local values = ValueReplication.new(folder)

		t.Check("new asserts on a non-Folder", not pcall(function()
			local model = Instance.new("Model")
			ValueReplication.new(model :: any)
			model:Destroy()
		end))

		local coins = values:Show("Coins", 100)

		t.Check("Show creates a value in the folder", coins.Parent == folder)

		t.Check("Integer numbers infer IntValue", coins:IsA("IntValue"))

		t.Equal("Get returns the initial value", values:Get("Coins"), 100)

		values:Set("Coins", 150)

		t.Equal("Set updates an existing value", values:Get("Coins"), 150)

		local ratio = values:Show("Ratio", 1.5)

		t.Check("Decimal numbers infer NumberValue", ratio:IsA("NumberValue"))

		local flag = values:Show("Flag", true)

		t.Check("Booleans infer BoolValue", flag:IsA("BoolValue"))

		local name = values:Show("Name", "Splay")

		t.Check("Strings infer StringValue", name:IsA("StringValue"))

		local explicit = values:Show("Explicit", 10, "NumberValue")

		t.Check("An explicit valueType overrides inference", explicit:IsA("NumberValue"))

		local reused = values:Show("Coins", 200)

		t.Check("Showing an existing name reuses the Instance", reused == coins)

		t.Equal("Reuse still applies the new value", values:Get("Coins"), 200)

		local replaced = values:Show("Coins", 5.5, "NumberValue")

		t.Check("A type change replaces the Instance", replaced ~= coins)

		t.Check("The replacement has the requested type", replaced:IsA("NumberValue"))

		t.Equal("The replacement receives the new value", values:Get("Coins"), 5.5)

		t.Equal("Get returns nil for an unknown name", values:Get("Missing"), nil)

		t.Check("Set rejects an unregistered name", not pcall(function()
			values:Set("Missing", 1)
		end))

		t.Check("Show rejects an empty name", not pcall(function()
			values:Show("", 1)
		end))

		t.Check("Get rejects an empty name", not pcall(function()
			values:Get("")
		end))

		t.Check("Set rejects an empty name", not pcall(function()
			values:Set("", 1)
		end))

		folder:Destroy()
	end

	-- PrivateAdapter
	do
		local folder = Instance.new("Folder")
		local adapter = PrivateAdapter.new(folder)

		local xp = adapter:Show("XP", 0)

		t.Check("Show creates a value in the folder", xp.Parent == folder)

		t.Check("Integer numbers infer IntValue", xp:IsA("IntValue"))

		t.Equal("Get returns the initial value", adapter:Get("XP"), 0)

		adapter:Set("XP", 50)

		t.Equal("Set updates the value", adapter:Get("XP"), 50)

		t.Check("Set rejects an unregistered name", not pcall(function()
			adapter:Set("Missing", 1)
		end))

		folder:Destroy()
	end

	-- DataService.Replicate
	do
		local dataService = DataService.new()
		local invalidPlayer = Instance.new("Folder")

		t.Check("Replicate rejects a non-Player", not pcall(function()
			dataService:Replicate(invalidPlayer :: any, "Points", 10)
		end))

		invalidPlayer:Destroy()
		dataService:Destroy()
	end

	return t.Summary()
end
