--!strict
--@Splay

--[[
	Production3: two servers contending for one player on a real DataStore.

	Each "server" is its own DataService with its own fake clock and fake players,
	sharing the real adapter (like two live servers) and a mock messaging network.
	Needs distinct server ids, which only exist in Studio (see the skip below).
	It returns true when every check passed.
]]

local ServerScriptService = game:GetService("ServerScriptService")

local PlayerData = ServerScriptService.PlayerData

local DataSchema = require(PlayerData.Config.DataSchema)
local FakeEnvironment = require(PlayerData.Tests.FakeEnvironment)
local Harness = require(PlayerData.Tests.Harness)
local ProductionFixture = require(PlayerData.Tests.Production.ProductionFixture)

return function(adapter: ProductionFixture.Adapter): boolean
	local t = Harness.new("Production3")

	-- On a live server both services would share game.JobId as their server id.
	if game.JobId ~= "" then
		print("[Production3] SKIPPED: two services need distinct server ids, which only exist in Studio")
		return t.Summary()
	end

	local runId = ProductionFixture.NewRunId()
	local settle = ProductionFixture.SettleTimeoutSeconds

	-- A held lock blocks the second server
	do
		local userId = ProductionFixture.UserIdFor(runId, 1)

		local worldA = FakeEnvironment.new(1000)
		local worldB = FakeEnvironment.new(1000, worldA.Network)
		local handlerA = ProductionFixture.NewHandler()
		local handlerB = ProductionFixture.NewHandler()
		local serviceA = ProductionFixture.StartService(worldA, adapter, handlerA)
		local serviceB = ProductionFixture.StartService(worldB, adapter, handlerB)

		local playerOnA = worldA.Join("Alice", userId)
		t.Check("server A loads the player", serviceA:WaitForLoad(playerOnA))

		local recordBefore: any = ProductionFixture.ReadRecord(adapter, userId)
		local lockBefore = recordBefore and recordBefore.Lock
		t.Check("server A holds a lock in the real store", lockBefore ~= nil)

		-- B's join waits out AcquireRetryWindowSeconds in real time before giving up.
		local playerOnB = worldB.Join("Alice", userId)
		t.Check("server B cannot load while A holds the lock", not serviceB:WaitForLoad(playerOnB))
		t.Check(
			"server B kicks the player it could not load",
			ProductionFixture.WaitUntil(function()
				return worldB.KickReasonOf(playerOnB) ~= nil
			end, 5)
		)

		local recordAfter: any = ProductionFixture.ReadRecord(adapter, userId)
		t.Equal("a refused join leaves A's lock untouched", recordAfter and recordAfter.Lock, lockBefore)

		t.Check("the blocked join sent a release request", worldA.Network:PublishedCount() >= 1)
		worldA.Network:Deliver()
		task.wait(0.5)
		t.Check("a release request does not evict a connected player", serviceA:IsLoaded(playerOnA))

		worldA.Leave(playerOnA)
		ProductionFixture.WaitUntil(function()
			return ProductionFixture.IsReleased(adapter, userId)
		end, settle)

		serviceA:Destroy()
		serviceB:Destroy()
	end

	-- A stale lock is taken over, and the old server's late save is fenced out
	do
		local userId = ProductionFixture.UserIdFor(runId, 2)

		-- B's clock is past the stale-lock timeout, so B may take the session over.
		local worldA = FakeEnvironment.new(1000)
		local worldB = FakeEnvironment.new(1000 + DataSchema.Timing.StaleLockSeconds + 1, worldA.Network)
		local handlerA, contextsA = ProductionFixture.NewHandler()
		local handlerB, contextsB = ProductionFixture.NewHandler()
		local serviceA = ProductionFixture.StartService(worldA, adapter, handlerA)
		local serviceB = ProductionFixture.StartService(worldB, adapter, handlerB)

		local playerOnA = worldA.Join("Bob", userId)
		serviceA:WaitForLoad(playerOnA)
		contextsA[playerOnA].LeaderstatsAdapter:Set("Points", 50)

		local playerOnB = worldB.Join("Bob", userId)
		t.Check("server B takes over a stale lock", serviceB:WaitForLoad(playerOnB))
		contextsB[playerOnB].LeaderstatsAdapter:Set("Points", 7)

		worldA.Advance(DataSchema.Timing.MinSaveGapSeconds + 1)
		t.Check("the old server's late save is refused", not serviceA:SaveNow(playerOnA))
		t.Check("the old server kicks its player", worldA.KickReasonOf(playerOnA) ~= nil)
		t.Check("the old server's data never reached the store", ProductionFixture.StoredPoints(adapter, userId) ~= 50)

		worldB.Leave(playerOnB)
		t.Check(
			"the new owner releases normally",
			ProductionFixture.WaitUntil(function()
				return ProductionFixture.IsReleased(adapter, userId)
			end, settle)
		)
		t.Equal("the new owner's data is what is stored", ProductionFixture.StoredPoints(adapter, userId), 7)

		serviceA:Destroy()
		serviceB:Destroy()
	end

	return t.Summary()
end
