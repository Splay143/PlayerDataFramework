--!strict
--@Splay

local RunService = game:GetService("RunService")
local ServerScriptService = game:GetService("ServerScriptService")

local PlayerData = ServerScriptService.PlayerData

local DataSchema = require(PlayerData.Config.DataSchema)
local DataService = require(PlayerData.Data.DataService)
local DataStoreAdapter = require(ServerScriptService.PlayerData.Adapters.DataStoreAdapter)
local MockAdapter = require(PlayerData.Adapters.MockAdapter)
local StoreHandler = require(PlayerData.Data.StoreHandler)

-- Handler requires
local ExampleHandler = require(PlayerData.Handlers.ExampleHandler)

--Test switches.
local USE_LIVE_TEST_STORE = false -- Uses a REAL datastore for testing
local USE_MOCK_TESTING = false -- Uses mock tests. No real datastore is used.
local LIVE_TEST_STORE_NAME = "PlayerData_LiveTest" --Test data store name

if USE_LIVE_TEST_STORE == true then
	warn(('PlayerData: LIVE TEST MODE, using the real DataStore "%s"'):format(LIVE_TEST_STORE_NAME))
end

local isStudio = RunService:IsStudio()

--Mock Tests only run in Studio: live servers gain nothing from them except slower startup. These tests do not interative with real datastores.
if isStudio and USE_MOCK_TESTING == true then
	local testPhases: { { Name: string, Run: () -> boolean } } = {
		{ Name = "Phase1 (BaseUtil, TableUtil, Schema, Versioning)", Run = require(PlayerData.Tests.Mock.Phase1) },
		{ Name = "Phase2 (Adapter, StoreHandler)", Run = require(PlayerData.Tests.Mock.Phase2) },
		{ Name = "Phase3 (SessionManager)", Run = require(PlayerData.Tests.Mock.Phase3) },
		{ Name = "Phase4 (DataService, LeaderstatsAdapter)", Run = require(PlayerData.Tests.Mock.Phase4) },
		{ Name = "Phase5 (SaveUtil, ValueReplication, PrivateAdapter)", Run = require(PlayerData.Tests.Mock.Phase5) },
		{ Name = "Phase6 (ReleaseTracker)", Run = require(PlayerData.Tests.Mock.Phase6) },
		{ Name = "Phase7 (DataService lifecycle)", Run = require(PlayerData.Tests.Mock.Phase7) },
		{ Name = "Phase8 (NamespaceStore)", Run = require(PlayerData.Tests.Mock.Phase8) },
		{ Name = "Phase9 (UnreleasedSessions)", Run = require(PlayerData.Tests.Mock.Phase9) },
		{
			Name = "Phase10 (MessagingAdapter, MockMessagingAdapter, UnreleasedSessions)",
			Run = require(PlayerData.Tests.Mock.Phase10),
		},
		{ Name = "Phase11 (DeltaUtil.Diff)", Run = require(PlayerData.Tests.Mock.Phase11) },
		{ Name = "Phase12 (RateLimiter)", Run = require(PlayerData.Tests.Mock.Phase12) },
		{ Name = "Phase13 (RequestService)", Run = require(PlayerData.Tests.Mock.Phase13) },
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

-- Production tests write to a REAL DataStore, so they only run in live test mode.
-- The modules are required inside the block so normal servers never load them.
if USE_LIVE_TEST_STORE then
	assert(
		LIVE_TEST_STORE_NAME ~= DataSchema.STORE_NAME,
		"DataInit: LIVE_TEST_STORE_NAME must differ from DataSchema.STORE_NAME"
	)

	local productionAdapter = DataStoreAdapter.new(LIVE_TEST_STORE_NAME)
	local productionPhases: { { Name: string, Run: (adapter: DataStoreAdapter.Adapter) -> boolean } } = {
		{ Name = "Production1 (persistence round trip)", Run = require(PlayerData.Tests.Production.Production1) },
		{ Name = "Production2 (multi-player shutdown)", Run = require(PlayerData.Tests.Production.Production2) },
		{ Name = "Production3 (two servers, one store)", Run = require(PlayerData.Tests.Production.Production3) },
		{ Name = "Production4 (release failure and recovery)", Run = require(PlayerData.Tests.Production.Production4) },
		{ Name = "Production5 (secondary namespace)", Run = require(PlayerData.Tests.Production.Production5) },
	}

	local failedProduction: { string } = {}
	for _, phase in productionPhases do
		print(("Running %s..."):format(phase.Name))
		-- pcall so a thrown error (for example a DataStore failure) is reported as a red
		-- test instead of aborting before the other tests have run.
		local ran, passed = pcall(phase.Run, productionAdapter)
		if not ran then
			warn(("%s errored: %s"):format(phase.Name, tostring(passed)))
		end
		if not ran or passed ~= true then
			table.insert(failedProduction, phase.Name)
		end
	end

	assert(#failedProduction == 0, "Production tests failed: " .. table.concat(failedProduction, ", "))
end

-- Register handlers here
local dataService = DataService.new()
dataService:RegisterHandler(ExampleHandler)

-- Use an in-memory adapter in Studio so tests do not require DataStore API access.
local adapter: StoreHandler.Adapter? = nil

if USE_LIVE_TEST_STORE then
	adapter = DataStoreAdapter.new(LIVE_TEST_STORE_NAME)
elseif isStudio then
	adapter = MockAdapter.new()
end

-- Start the player data system
dataService:Start(adapter)
