--!strict
--@Splay

local RunService = game:GetService("RunService")
local ServerScriptService = game:GetService("ServerScriptService")

local PlayerData = ServerScriptService.PlayerData

local DataService = require(PlayerData.Data.DataService)
local MockAdapter = require(PlayerData.Adapters.MockAdapter)
local StoreHandler = require(PlayerData.Data.StoreHandler)

-- Handler requires
local ExampleHandler = require(PlayerData.Handlers.ExampleHandler)

local isStudio = RunService:IsStudio()

-- Tests only run in Studio: live servers gain nothing from them except slower startup.
if isStudio then
	local testPhases: { { Name: string, Run: () -> boolean } } = {
		{ Name = "Phase1 (BaseUtil, TableUtil, Schema, Versioning)", Run = require(PlayerData.Tests.Phase1) },
		{ Name = "Phase2 (Adapter, StoreHandler)", Run = require(PlayerData.Tests.Phase2) },
		{ Name = "Phase3 (SessionManager)", Run = require(PlayerData.Tests.Phase3) },
		{ Name = "Phase4 (DataService, LeaderstatsAdapter)", Run = require(PlayerData.Tests.Phase4) },
		{ Name = "Phase5 (SaveUtil, ValueReplication, PrivateAdapter)", Run = require(PlayerData.Tests.Phase5) },
		{ Name = "Phase6 (ReleaseTracker)", Run = require(PlayerData.Tests.Phase6) },
		{ Name = "Phase7 (DataService lifecycle)", Run = require(PlayerData.Tests.Phase7) },
		{ Name = "Phase8 (NamespaceStore)", Run = require(PlayerData.Tests.Phase8) },
		{ Name = "Phase9 (UnreleasedSessions)", Run = require(PlayerData.Tests.Phase9) },
		{
			Name = "Phase10 (MessagingAdapter, MockMessagingAdapter, UnreleasedSessions)",
			Run = require(PlayerData.Tests.Phase10),
		},
		{ Name = "Phase11 (DeltaUtil.Diff)", Run = require(PlayerData.Tests.Phase11) },
		{ Name = "Phase12 (RateLimiter)", Run = require(PlayerData.Tests.Phase12) },
	}

	local failedPhases: { string } = {}
	for _, phase in testPhases do
		print(("Running %s..."):format(phase.Name))
		if not phase.Run() then
			table.insert(failedPhases, phase.Name)
		end
	end

	-- Fail closed, like the rest of the framework: a red test should stop startup
	assert(#failedPhases == 0, "PlayerData tests failed: " .. table.concat(failedPhases, ", "))
end

-- Register handlers here
local dataService = DataService.new()
dataService:RegisterHandler(ExampleHandler)

-- Use an in-memory adapter in Studio so tests do not require DataStore API access.
local adapter: StoreHandler.Adapter? = nil
if isStudio then
	adapter = MockAdapter.new()
end

-- Start the player data system
dataService:Start(adapter)
