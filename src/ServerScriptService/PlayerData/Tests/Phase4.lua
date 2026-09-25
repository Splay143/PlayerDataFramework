--!strict

--[[
	Phase 4 tests: LeaderstatsAdapter and DataService.

	It returns true when every check passed.
]]

local ServerScriptService = game:GetService("ServerScriptService")

local PlayerData = ServerScriptService.PlayerData

local LeaderstatsAdapter = require(PlayerData.Adapters.LeaderstatsAdapter)
local DataService = require(PlayerData.Data.DataService)

local Harness = require(PlayerData.Tests.Harness)

return function(): boolean
	local t = Harness.new("Phase4")

	-- LeaderstatsAdapter

	do
		local folder = Instance.new("Folder")
		folder.Name = "leaderstats"

		local adapter = LeaderstatsAdapter.new(folder)

		t.Check("new accepts a Folder", adapter ~= nil)

		local coins = adapter:ShowInLeaderStats("Coins", 500)

		t.Check("ShowInLeaderStats creates a stat", coins.Parent == folder)
		t.Check("Created stat has the correct name", coins.Name == "Coins")
		t.Check("Integer numbers infer IntValue", coins:IsA("IntValue"))
		t.Equal("Get returns the initial value", adapter:Get("Coins"), 500)

		adapter:Set("Coins", 750)

		t.Equal("Set updates the stat", adapter:Get("Coins"), 750)

		local multiplier = adapter:ShowInLeaderStats("Multiplier", 1.5)

		t.Check("Decimal numbers infer NumberValue", multiplier:IsA("NumberValue"))
		t.Equal("NumberValue receives the initial value", adapter:Get("Multiplier"), 1.5)

		local username = adapter:ShowInLeaderStats("Username", "Splay")

		t.Check("Strings infer StringValue", username:IsA("StringValue"))
		t.Equal("StringValue receives the initial value", adapter:Get("Username"), "Splay")

		local vip = adapter:ShowInLeaderStats("VIP", true)

		t.Check("Booleans infer BoolValue", vip:IsA("BoolValue"))
		t.Equal("BoolValue receives the initial value", adapter:Get("VIP"), true)

		local explicit = adapter:ShowInLeaderStats("Explicit", 10, "NumberValue")

		t.Check("Explicit type overrides inferred type", explicit:IsA("NumberValue"))
		t.Equal("Explicit type preserves the value", adapter:Get("Explicit"), 10)

		local existing = adapter:ShowInLeaderStats("Coins", 1000)

		t.Check("Existing stat is reused", existing == coins)
		t.Equal("Existing stat receives the new initial value", adapter:Get("Coins"), 1000)

		local oldCoins = existing
		local replaced = adapter:ShowInLeaderStats("Coins", 2.5, "NumberValue")

		t.Check("Mismatched type replaces the existing stat", replaced ~= oldCoins)
		t.Check("Replacement has the requested type", replaced:IsA("NumberValue"))
		t.Equal("Replacement receives the initial value", adapter:Get("Coins"), 2.5)

		t.Equal("Get returns nil for a missing stat", adapter:Get("Missing"), nil)

		t.Check(
			"Set rejects an unregistered stat",
			not pcall(function()
				adapter:Set("Missing", 10)
			end)
		)

		t.Check(
			"ShowInLeaderStats rejects an empty name",
			not pcall(function()
				adapter:ShowInLeaderStats("", 10)
			end)
		)

		t.Check(
			"Get rejects an empty name",
			not pcall(function()
				adapter:Get("")
			end)
		)

		t.Check(
			"Set rejects an empty name",
			not pcall(function()
				adapter:Set("", 10)
			end)
		)

		folder:Destroy()
	end

	-- DataService

	do
		local invalidPlayer = Instance.new("Folder")

		t.Check(
			"SaveNow rejects a non-Player",
			not pcall(function()
				DataService.SaveNow(invalidPlayer :: any)
			end)
		)

		t.Check(
			"WaitForLoad rejects a non-Player",
			not pcall(function()
				DataService.WaitForLoad(invalidPlayer :: any)
			end)
		)

		t.Check(
			"Get rejects a non-Player",
			not pcall(function()
				DataService.Get(invalidPlayer :: any, "DefinitelyNotAHandler")
			end)
		)

		invalidPlayer:Destroy()
	end

	t.Check(
		"DataService cannot start without a registered handler",
		not pcall(DataService.Start)
	)

	return t.Summary()
end