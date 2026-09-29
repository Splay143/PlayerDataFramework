--!strict
--@Splay

local ServerScriptService = game:GetService("ServerScriptService")

local PlayerData = ServerScriptService.PlayerData

local DataSchema = require(PlayerData.Config.DataSchema)
local DataService = require(PlayerData.Data.DataService)
local MockAdapter = require(PlayerData.Adapters.MockAdapter)
local BaseUtil = require(PlayerData.Utils.BaseUtil)
local FakeEnvironment = require(PlayerData.Tests.FakeEnvironment)
local Harness = require(PlayerData.Tests.Harness)

local TEST_NAMESPACE = "Test"
local MAX_POINTS = 1_000_000

local function waitUntil(condition: () -> boolean, timeoutSeconds: number): boolean
	local deadline = os.clock() + timeoutSeconds
	while not condition() do
		if os.clock() >= deadline then
			return false
		end
		task.wait(0.05)
	end
	return true
end

-- ExampleHandler asserts a real Player instance, which fake players are not,
-- so lifecycle tests use this minimal handler with the same contract.
local function newTestHandler(): (DataService.Handler, { [Player]: BaseUtil.Context })
	local contexts: { [Player]: BaseUtil.Context } = {}

	local handler: DataService.Handler = {
		Namespace = TEST_NAMESPACE,
		Key = TEST_NAMESPACE,
		Default = function()
			return { Points = 0 }
		end,
		Sanitize = function(raw: any?)
			local rawTable = BaseUtil.AsTable(raw)
			return { Points = BaseUtil.SanitizeInt(rawTable.Points, 0, 0, MAX_POINTS) }
		end,
		Load = function(player: Player, ctx: BaseUtil.Context, value: any)
			contexts[player] = ctx
			ctx.LeaderstatsAdapter:ShowInLeaderStats("Points", value.Points)
		end,
		Save = function(_player: Player, ctx: BaseUtil.Context): any
			return { Points = ctx.LeaderstatsAdapter:Get("Points") or 0 }
		end,
	}

	return handler, contexts
end

local function newRunningService()
	local world = FakeEnvironment.new(1000)
	local adapter = MockAdapter.new(function(seconds: number)
		task.wait(seconds)
	end)
	local handler, contexts = newTestHandler()

	local service = DataService.new(world.Environment)
	service:RegisterHandler(handler)
	service:Start(adapter)

	return service, world, adapter, contexts
end

local function storedRecord(adapter: MockAdapter.MockAdapter, player: Player): any
	return adapter:Peek(DataSchema.KeyFor(player.UserId))
end

return function(): boolean
	local t = Harness.new("Phase7")

	-- Join

	do
		local service, world, adapter = newRunningService()
		local player = world.Join("Alice", 1)

		t.Check("A joining player loads", service:WaitForLoad(player))
		t.Check("IsLoaded is true after load", service:IsLoaded(player))
		t.Equal("A new player receives the handler default", service:Get(player, TEST_NAMESPACE), { Points = 0 })
		t.Check("Folders are attached to the player", world.WasAttached(player))
		t.Check("The session is locked in the store", storedRecord(adapter, player).Lock ~= nil)

		service:Destroy()
	end

	-- Save

	do
		local service, world, adapter, contexts = newRunningService()
		local player = world.Join("Alice", 1)
		service:WaitForLoad(player)

		contexts[player].LeaderstatsAdapter:Set("Points", 250)

		t.Check("SaveNow inside the minimum gap is skipped", not service:SaveNow(player))
		t.Check("A skipped save writes nothing", storedRecord(adapter, player).Data[TEST_NAMESPACE] == nil)

		world.Advance(DataSchema.Timing.MinSaveGapSeconds + 1)

		t.Check("SaveNow succeeds once the gap has passed", service:SaveNow(player))
		t.Equal("The saved record holds the live value", storedRecord(adapter, player).Data[TEST_NAMESPACE].Points, 250)
		t.Equal("GetLastSaved reports the save time", service:GetLastSaved(player), 1000 + DataSchema.Timing.MinSaveGapSeconds + 1)

		service:Destroy()
	end

	-- Leave

	do
		local service, world, adapter, contexts = newRunningService()
		local player = world.Join("Alice", 1)
		service:WaitForLoad(player)
		contexts[player].LeaderstatsAdapter:Set("Points", 40)

		world.Leave(player)

		t.Check(
			"Leaving releases the session lock",
			waitUntil(function()
				return storedRecord(adapter, player).Lock == nil
			end, 2)
		)
		t.Equal("Leaving saves the live value", storedRecord(adapter, player).Data[TEST_NAMESPACE].Points, 40)
		t.Check("A player who left is no longer loaded", not service:IsLoaded(player))

		-- WaitForLoad on a player who already left must return, not hang.
		local returned = false
		local result: boolean? = nil
		task.spawn(function()
			result = service:WaitForLoad(player)
			returned = true
		end)
		t.Check(
			"WaitForLoad returns false promptly for a player who left",
			waitUntil(function()
				return returned
			end, 2) and result == false
		)

		service:Destroy()
	end

	-- Shutdown

	do
		local service, world, adapter, contexts = newRunningService()
		local first = world.Join("Alice", 1)
		local second = world.Join("Bob", 2)
		service:WaitForLoad(first)
		service:WaitForLoad(second)

		contexts[first].LeaderstatsAdapter:Set("Points", 11)
		contexts[second].LeaderstatsAdapter:Set("Points", 22)

		-- Latency makes each release yield, so shutdown has to genuinely wait for it.
		adapter:SetLatency(0.2)
		world.CloseServer()

		t.Check("Shutdown released the first player's lock", storedRecord(adapter, first).Lock == nil)
		t.Check("Shutdown released the second player's lock", storedRecord(adapter, second).Lock == nil)
		t.Equal("Shutdown saved the first player's value", storedRecord(adapter, first).Data[TEST_NAMESPACE].Points, 11)
		t.Equal("Shutdown saved the second player's value", storedRecord(adapter, second).Data[TEST_NAMESPACE].Points, 22)

		service:Destroy()
	end

	return t.Summary()
end