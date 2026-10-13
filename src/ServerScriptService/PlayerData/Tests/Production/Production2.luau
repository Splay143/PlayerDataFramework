--!strict
--@Splay

--[[
	Production2: shutdown with several players against a real DataStore.

	FakeWorld.CloseServer runs the BindToClose callbacks, so this exercises the same
	shutdownSave path as a real shutdown. The elapsed time is printed because it is
	the number that decides whether ShutdownTimeoutSeconds is safe.
	It returns true when every check passed.
]]

local ServerScriptService = game:GetService("ServerScriptService")

local PlayerData = ServerScriptService.PlayerData

local DataSchema = require(PlayerData.Config.DataSchema)
local FakeEnvironment = require(PlayerData.Tests.FakeEnvironment)
local Harness = require(PlayerData.Tests.Harness)
local ProductionFixture = require(PlayerData.Tests.Production.ProductionFixture)

local PLAYER_COUNT = 20
local POINTS_PER_SLOT = 11

return function(adapter: ProductionFixture.Adapter): boolean
	local t = Harness.new("Production2")

	local runId = ProductionFixture.NewRunId()
	local world = FakeEnvironment.new(1000)
	local handler, contexts = ProductionFixture.NewHandler()
	local service = ProductionFixture.StartService(world, adapter, handler)

	local players: { Player } = {}
	local userIds: { number } = {}
	for slot = 1, PLAYER_COUNT do
		userIds[slot] = ProductionFixture.UserIdFor(runId, slot)
		players[slot] = world.Join("Player" .. slot, userIds[slot])
	end

	local allLoaded = true
	for _, player in players do
		if not service:WaitForLoad(player) then
			allLoaded = false
		end
	end
	t.Check("every player loads", allLoaded)

	for slot, player in players do
		contexts[player].LeaderstatsAdapter:Set("Points", slot * POINTS_PER_SLOT)
	end

	local startedAt = os.clock()
	world.CloseServer()
	local shutdownSeconds = os.clock() - startedAt

	print(
		("[Production2] shutdown with %d players took %.1fs (limit %ds)"):format(
			PLAYER_COUNT,
			shutdownSeconds,
			DataSchema.Timing.ShutdownTimeoutSeconds
		)
	)
	t.Check("shutdown finishes inside the timeout", shutdownSeconds < DataSchema.Timing.ShutdownTimeoutSeconds)

	for slot, userId in userIds do
		t.Check("player " .. slot .. " was released", ProductionFixture.IsReleased(adapter, userId))
		t.Equal(
			"player " .. slot .. " was saved",
			ProductionFixture.StoredPoints(adapter, userId),
			slot * POINTS_PER_SLOT
		)
	end

	service:Destroy()
	return t.Summary()
end