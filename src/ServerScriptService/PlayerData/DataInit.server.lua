--!strict
--@Splay

local RunService = game:GetService("RunService")
local ServerScriptService = game:GetService("ServerScriptService")

local PlayerData = ServerScriptService.PlayerData

local DataService = require(PlayerData.Data.DataService)
local MockAdapter = require(PlayerData.Adapters.MockAdapter)
local StoreHandler = require(PlayerData.Data.StoreHandler)

-- Handler requires
--local ExampleHandler = require(PlayerData.Handlers.ExampleHandler)

--[[Tests
require(PlayerData.Tests.Phase1)() -- BaseUtil, TableUtil, Schema, Versioning
require(PlayerData.Tests.Phase2)() -- Adapter, StoreHandler
require(PlayerData.Tests.Phase3)() -- SessionManager
require(PlayerData.Tests.Phase4)() -- DataService and LeaderstatsAdapter
require(PlayerData.Tests.Phase5)() -- SaveUtil, ValueReplication, PrivateAdapter, and DataService.Replicate
]]

-- Register handlers here
--DataService.RegisterHandler(ExampleHandler)

-- Use an in-memory adapter in Studio so tests do not require DataStore API access.
local adapter: StoreHandler.Adapter? = nil

if RunService:IsStudio() then
	adapter = MockAdapter.new()
end

-- Start the player data system
DataService.Start(adapter)