--!strict
--@Splay

local ServerScriptService = game:GetService("ServerScriptService")
local PlayerData = ServerScriptService.PlayerData

local DataService = require(PlayerData.Data.DataService)

--Handler requires

--[[Tests
require(PlayerData.Tests.Phase1)() --BaseUtil,TableUtil,Schema,Versioning
require(PlayerData.Tests.Phase2)() --Adapter, StoreHandler
require(PlayerData.Tests.Phase3)()--SessionManager
require(PlayerData.Tests.Phase4)() --DataService and leaderstats adapater
]]

--Register Handlers here

--Data Init
DataService.Start()
