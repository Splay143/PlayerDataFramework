--!strict
--@Splay

--[[
	Production5: a Secondary namespace against a real DataStore.
]]

local ServerScriptService = game:GetService("ServerScriptService")

local PlayerData = ServerScriptService.PlayerData

local DataSchema = require(PlayerData.Config.DataSchema)
local FakeEnvironment = require(PlayerData.Tests.FakeEnvironment)
local Harness = require(PlayerData.Tests.Harness)
local ProductionFixture = require(PlayerData.Tests.Production.ProductionFixture)

local function secondaryPoints(adapter: ProductionFixture.Adapter, userId: number): number?
	local record: any = ProductionFixture.ReadSecondary(adapter, userId)
	if record == nil or record.Data == nil then
		return nil
	end
	return record.Data.Points
end

return function(adapter: ProductionFixture.Adapter): boolean
	local t = Harness.new("Production5")

	local runId = ProductionFixture.NewRunId()
	local settle = ProductionFixture.SettleTimeoutSeconds

	-- A. Round trip
	do
		local userId = ProductionFixture.UserIdFor(runId, 1)

		do
			local world = FakeEnvironment.new(1000)
			local handler, contexts = ProductionFixture.NewHandler("Secondary")
			local service = ProductionFixture.StartService(world, adapter, handler)

			local player = world.Join("Alice", userId)
			t.Check("a player with a Secondary namespace loads", service:WaitForLoad(player))

			local claimed: any = ProductionFixture.ReadSecondary(adapter, userId)
			t.Check("joining stamps the secondary key", claimed ~= nil and type(claimed.SessionId) == "string")

			contexts[player].LeaderstatsAdapter:Set("Points", 120)
			world.Advance(DataSchema.Timing.MinSaveGapSeconds + 1)
			t.Check("SaveNow succeeds", service:SaveNow(player))
			t.Equal("SaveNow writes the secondary key", secondaryPoints(adapter, userId), 120)
			-- Design check: secondary data stays out of the primary record once saved.
			t.Equal("the primary record does not hold the secondary data", ProductionFixture.StoredPoints(adapter, userId), nil)

			contexts[player].LeaderstatsAdapter:Set("Points", 130)
			world.Leave(player)
			t.Check(
				"leaving releases the primary lock",
				ProductionFixture.WaitUntil(function()
					return ProductionFixture.IsReleased(adapter, userId)
				end, settle)
			)
			t.Equal("leaving saves the latest secondary value", secondaryPoints(adapter, userId), 130)

			service:Destroy()
		end

		do
			local world = FakeEnvironment.new(1000)
			local handler = ProductionFixture.NewHandler("Secondary")
			local service = ProductionFixture.StartService(world, adapter, handler)

			local player = world.Join("Alice", userId)
			t.Check("a returning player loads", service:WaitForLoad(player))
			t.Equal("the secondary value comes back", service:Get(player, handler), { Points = 130 })

			world.Leave(player)
			ProductionFixture.WaitUntil(function()
				return ProductionFixture.IsReleased(adapter, userId)
			end, settle)
			service:Destroy()
		end
	end

	-- B. Fence (needs distinct server ids, which only exist in Studio)
	if game.JobId ~= "" then
		print("[Production5] fence scenario SKIPPED: needs distinct server ids")
		return t.Summary()
	end

	do
		local userId = ProductionFixture.UserIdFor(runId, 2)

		local worldA = FakeEnvironment.new(1000)
		local worldB = FakeEnvironment.new(1000 + DataSchema.Timing.StaleLockSeconds + 1, worldA.Network)
		local handlerA, contextsA = ProductionFixture.NewHandler("Secondary")
		local handlerB, contextsB = ProductionFixture.NewHandler("Secondary")
		local serviceA = ProductionFixture.StartService(worldA, adapter, handlerA)
		local serviceB = ProductionFixture.StartService(worldB, adapter, handlerB)

		local playerOnA = worldA.Join("Bob", userId)
		serviceA:WaitForLoad(playerOnA)
		contextsA[playerOnA].LeaderstatsAdapter:Set("Points", 50)

		local playerOnB = worldB.Join("Bob", userId)
		t.Check("server B takes over", serviceB:WaitForLoad(playerOnB))
		contextsB[playerOnB].LeaderstatsAdapter:Set("Points", 7)

		worldA.Advance(DataSchema.Timing.MinSaveGapSeconds + 1)
		t.Check("the old server's save is refused", not serviceA:SaveNow(playerOnA))
		t.Check("the old server never wrote the secondary key", secondaryPoints(adapter, userId) ~= 50)

		worldB.Leave(playerOnB)
		ProductionFixture.WaitUntil(function()
			return ProductionFixture.IsReleased(adapter, userId)
		end, settle)
		t.Equal("the new owner's secondary value is stored", secondaryPoints(adapter, userId), 7)

		serviceA:Destroy()
		serviceB:Destroy()
	end

	return t.Summary()
end