--!strict
--@Splay

--[[
	Production4: release failure and recovery against a real DataStore.

	A wrapper adapter fails the next calls on purpose, so each scenario starts
	from a real, repeatable DataStore error:
	  A. a failed release is kept and retried in the background
	  B. rejoining while a release is pending does not lose the newest data
	  C. a failed flush on rejoin never locks the player out
	It returns true when every check passed.
]]

local ServerScriptService = game:GetService("ServerScriptService")

local PlayerData = ServerScriptService.PlayerData

local DataSchema = require(PlayerData.Config.DataSchema)
local FakeEnvironment = require(PlayerData.Tests.FakeEnvironment)
local Harness = require(PlayerData.Tests.Harness)
local ProductionFixture = require(PlayerData.Tests.Production.ProductionFixture)

-- Builds one fake server whose store calls go through the failing wrapper.
local function newServer(adapter: ProductionFixture.Adapter)
	local world = FakeEnvironment.new(1000)
	local failing = ProductionFixture.NewFailingAdapter(adapter)
	local handler, contexts = ProductionFixture.NewHandler()
	-- One attempt per call, so an injected failure fails the call instead of being retried away.
	local service = ProductionFixture.StartService(world, failing, handler, { MaxAttempts = 1 })
	return world, failing, handler, contexts, service
end

return function(adapter: ProductionFixture.Adapter): boolean
	local t = Harness.new("Production4")

	local runId = ProductionFixture.NewRunId()
	local settle = ProductionFixture.SettleTimeoutSeconds

	local function isReleased(userId: number): boolean
		return ProductionFixture.IsReleased(adapter, userId)
	end

	local function waitUntilReleased(userId: number): boolean
		return ProductionFixture.WaitUntil(function()
			return isReleased(userId)
		end, settle)
	end

	local function waitUntilFailuresUsed(failing: ProductionFixture.FailingAdapter): boolean
		return ProductionFixture.WaitUntil(function()
			return failing:FailuresRemaining() == 0
		end, settle)
	end

	-- A. A failed release is retried in the background and saves the data from when the player left
	do
		local userId = ProductionFixture.UserIdFor(runId, 1)
		local world, failing, _, contexts, service = newServer(adapter)

		local player = world.Join("Alice", userId)
		service:WaitForLoad(player)
		contexts[player].LeaderstatsAdapter:Set("Points", 77)

		failing:FailNext(1)
		world.Leave(player)

		t.Check("the release is attempted when the player leaves", waitUntilFailuresUsed(failing))
		t.Check("a failed release leaves the lock in the real store", not isReleased(userId))

		-- The retry schedule runs on the service's fake clock.
		world.Advance(DataSchema.Timing.UnreleasedRetryBaseSeconds)
		t.Check("the background retry releases the session", waitUntilReleased(userId))
		t.Equal(
			"the retry saves the data from when the player left",
			ProductionFixture.StoredPoints(adapter, userId),
			77
		)

		service:Destroy()
	end

	-- B. Rejoining before the retry runs must not lose the newest data
	do
		local userId = ProductionFixture.UserIdFor(runId, 2)
		local world, failing, handler, contexts, service = newServer(adapter)

		local player = world.Join("Bob", userId)
		service:WaitForLoad(player)
		contexts[player].LeaderstatsAdapter:Set("Points", 55)

		failing:FailNext(1)
		world.Leave(player)
		waitUntilFailuresUsed(failing)
		t.Check("the failed release leaves the lock in place", not isReleased(userId))

		local rejoined = world.Join("Bob", userId)
		t.Check("a player rejoining with a pending release loads", service:WaitForLoad(rejoined))
		t.Equal("the rejoin saved the pending data first", service:Get(rejoined, handler), { Points = 55 })

		world.Leave(rejoined)
		waitUntilReleased(userId)
		service:Destroy()
	end

	-- C. A failed flush must not block the rejoin
	do
		local userId = ProductionFixture.UserIdFor(runId, 3)
		local world, failing, handler, contexts, service = newServer(adapter)

		local player = world.Join("Carol", userId)
		service:WaitForLoad(player)
		contexts[player].LeaderstatsAdapter:Set("Points", 9)

		-- The first failure is the release, the second is the flush on rejoin.
		failing:FailNext(2)
		world.Leave(player)

		local rejoined = world.Join("Carol", userId)
		t.Check("a failed flush does not block the join", service:WaitForLoad(rejoined))
		t.Equal("the player loads the last saved data", service:Get(rejoined, handler), { Points = 0 })
		t.Check("both injected failures were used", failing:FailuresRemaining() == 0)

		world.Leave(rejoined)
		waitUntilReleased(userId)
		service:Destroy()
	end

	return t.Summary()
end