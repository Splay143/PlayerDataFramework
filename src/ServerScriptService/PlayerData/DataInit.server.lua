--!strict
--@Splay

local ServerScriptService = game:GetService("ServerScriptService")
local PlayerData = ServerScriptService.PlayerData

--[[Tests
require(PlayerData.Tests.Phase1)() -- BaseUtil,TableUtil,Schema,Versioning
require(PlayerData.Tests.Phase2)() -- Adapter, StoreHandler
require(PlayerData.Tests.Phase3)() -- SessionManager]]

