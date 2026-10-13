--!strict
--@Splay

--[[
	Production1: persistence round trip against a real DataStore.

	Join -> change -> SaveNow -> change -> leave -> rejoin on a new service.
	It returns true when every check passed.
]]

local ServerScriptService = game:GetService("ServerScriptService")

local PlayerData = ServerScriptService.PlayerData

local DataSchema = require(PlayerData.Config.DataSchema)
local FakeEnvironment = require(PlayerData.Tests.FakeEnvironment)
local Harness = require(PlayerData.Tests.Harness)
local ProductionFixture = require(PlayerData.Tests.Production.ProductionFixture)

return function(adapter: ProductionFixture.Adapter): boolean
	local t = Harness.new("Production1")

	local userId = ProductionFixture.UserIdFor(ProductionFixture.NewRunId(), 1)
	local settle = ProductionFixture.SettleTimeoutSeconds

	-- Session 1: join, save mid-session, leave
	do
		local world = FakeEnvironment.new(1000)
		local handler, contexts = ProductionFixture.NewHandler()
		local service = ProductionFixture.StartService(world, adapter, handler)

		local player = world.Join("Alice", userId)
		t.Check("a new player loads from the real store", service:WaitForLoad(player))

		local record: any = ProductionFixture.ReadRecord(adapter, userId)
		t.Check("the session lock is written to the real store", record ~= nil and record.Lock ~= nil)

		contexts[player].LeaderstatsAdapter:Set("Points", 250)
		world.Advance(DataSchema.Timing.MinSaveGapSeconds + 1)
		t.Check("SaveNow succeeds against the real store", service:SaveNow(player))
		t.Equal("SaveNow stored the live value", ProductionFixture.StoredPoints(adapter, userId), 250)

		contexts[player].LeaderstatsAdapter:Set("Points", 300)
		world.Leave(player)

		t.Check(
			"leaving releases the lock in the real store",
			ProductionFixture.WaitUntil(function()
				return ProductionFixture.IsReleased(adapter, userId)
			end, settle)
		)
		t.Equal("leaving stored the latest value", ProductionFixture.StoredPoints(adapter, userId), 300)

		service:Destroy()
	end

	-- Session 2: a new service stands in for the next server the player joins
	do
		local world = FakeEnvironment.new(1000)
		local handler = ProductionFixture.NewHandler()
		local service = ProductionFixture.StartService(world, adapter, handler)

		local player = world.Join("Alice", userId)
		t.Check("a returning player loads", service:WaitForLoad(player))
		t.Equal("the returning player gets the saved data", service:Get(player, handler), { Points = 300 })

		world.Leave(player)
		ProductionFixture.WaitUntil(function()
			return ProductionFixture.IsReleased(adapter, userId)
		end, settle)

		service:Destroy()
	end

	return t.Summary()
end
