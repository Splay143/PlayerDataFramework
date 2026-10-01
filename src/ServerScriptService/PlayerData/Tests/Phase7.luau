--!strict
--@Splay

local ServerScriptService = game:GetService("ServerScriptService")

local PlayerData = ServerScriptService.PlayerData

local BaseUtil = require(PlayerData.Utils.BaseUtil)
local DataSchema = require(PlayerData.Config.DataSchema)
local DataService = require(PlayerData.Data.DataService)
local FakeEnvironment = require(PlayerData.Tests.FakeEnvironment)
local Harness = require(PlayerData.Tests.Harness)
local MockAdapter = require(PlayerData.Adapters.MockAdapter)

type TestData = {
	Points: number,
}

type Faults = {
	LoadThrows: boolean,
	SaveThrows: boolean,
	SaveReturnsNil: boolean,
}

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

local function settledCount(getCount: () -> number, expected: number): number
	waitUntil(function()
		return getCount() >= expected
	end, 2)
	task.wait(0.3)
	return getCount()
end

-- ExampleHandler asserts a real Player instance, which fake players are not,
-- so lifecycle tests use this minimal handler with the same contract.
local function newTestHandler(): (DataService.Handler<TestData>, { [Player]: BaseUtil.Context })
	local contexts: { [Player]: BaseUtil.Context } = {}

	local handler: DataService.Handler<TestData> = {
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

	return service, world, adapter, contexts, handler
end

local function storedRecord(adapter: MockAdapter.MockAdapter, player: Player): any
	return adapter:Peek(DataSchema.KeyFor(player.UserId))
end

local function newFaultyHandler(
	namespace: string,
	faults: Faults,
	contexts: { [Player]: BaseUtil.Context },
	storage: BaseUtil.StorageKind?,
	required: boolean?
): DataService.Handler<TestData>
	return {
		Namespace = namespace,
		Storage = storage,
		Required = required,
		Default = function()
			return { Points = 0 }
		end,
		Sanitize = function(raw: any?)
			local rawTable = BaseUtil.AsTable(raw)
			return { Points = BaseUtil.SanitizeInt(rawTable.Points, 0, 0, MAX_POINTS) }
		end,
		Load = function(player: Player, ctx: BaseUtil.Context, value: TestData)
			if faults.LoadThrows then
				error("simulated Load failure")
			end
			contexts[player] = ctx
			ctx.LeaderstatsAdapter:ShowInLeaderStats(namespace, value.Points)
		end,
		Save = function(_player: Player, ctx: BaseUtil.Context): TestData
			if faults.SaveThrows then
				error("simulated Save failure")
			end
			if faults.SaveReturnsNil then
				-- A handler that forgot to return. The type says T, so cast to get past the compiler.
				return nil :: any
			end
			return { Points = ctx.LeaderstatsAdapter:Get(namespace) or 0 }
		end,
	}
end

local function noFaults(): Faults
	return { LoadThrows = false, SaveThrows = false, SaveReturnsNil = false }
end

local function startService(
	world: FakeEnvironment.FakeWorld,
	adapter: MockAdapter.MockAdapter,
	handlers: { DataService.Handler<TestData> }
)
	local service = DataService.new(world.Environment)
	for _, handler in handlers do
		service:RegisterHandler(handler)
	end
	service:Start(adapter)
	return service
end

local function newAdapter(): MockAdapter.MockAdapter
	return MockAdapter.new(function(seconds: number)
		task.wait(seconds)
	end)
end

return function(): boolean
	local t = Harness.new("Phase7")

	-- Join

	do
		local service, world, adapter, _, handler = newRunningService()
		local player = world.Join("Alice", 1)

		t.Check("A joining player loads", service:WaitForLoad(player))
		t.Check("IsLoaded is true after load", service:IsLoaded(player))
		t.Equal("A new player receives the handler default", service:Get(player, handler), { Points = 0 })
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
		t.Equal(
			"GetLastSaved reports the save time",
			service:GetLastSaved(player),
			1000 + DataSchema.Timing.MinSaveGapSeconds + 1
		)

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
		t.Check("WaitForLoad returns false promptly for a player who left", waitUntil(function()
			return returned
		end, 2) and result == false)

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
		t.Equal(
			"Shutdown saved the second player's value",
			storedRecord(adapter, second).Data[TEST_NAMESPACE].Points,
			22
		)

		service:Destroy()
	end

	-- Gap 1: a failed Load must not overwrite saved data

	do
		local adapter = newAdapter()
		local contexts: { [Player]: BaseUtil.Context } = {}

		-- Session 1 saves 77 points for Alice.
		local firstWorld = FakeEnvironment.new(1000)
		local firstService = startService(firstWorld, adapter, { newFaultyHandler("Test", noFaults(), contexts) })
		local firstAlice = firstWorld.Join("Alice", 1)
		firstService:WaitForLoad(firstAlice)
		contexts[firstAlice].LeaderstatsAdapter:Set("Test", 77)
		firstWorld.Leave(firstAlice)
		waitUntil(function()
			return storedRecord(adapter, firstAlice).Lock == nil
		end, 2)
		firstService:Destroy()

		-- Session 2: Load throws, but Save is healthy and would write 0 from empty state.
		local brokenFaults = noFaults()
		brokenFaults.LoadThrows = true
		local secondWorld = FakeEnvironment.new(1000)
		local secondService = startService(secondWorld, adapter, { newFaultyHandler("Test", brokenFaults, contexts) })
		local secondAlice = secondWorld.Join("Alice", 1)

		t.Check("A player still loads when a handler's Load throws", secondService:WaitForLoad(secondAlice))
		secondWorld.Leave(secondAlice)
		waitUntil(function()
			return storedRecord(adapter, secondAlice).Lock == nil
		end, 2)

		t.Equal(
			"A failed Load does not overwrite the saved data",
			storedRecord(adapter, secondAlice).Data.Test.Points,
			77
		)

		secondService:Destroy()
	end

	-- Gap 2: a namespace with no registered handler must survive a save

	do
		local adapter = newAdapter()
		local contexts: { [Player]: BaseUtil.Context } = {}

		-- Session 1 has two handlers and saves 9 points under "Legacy".
		local firstWorld = FakeEnvironment.new(1000)
		local firstService = startService(firstWorld, adapter, {
			newFaultyHandler("Test", noFaults(), contexts),
			newFaultyHandler("Legacy", noFaults(), contexts),
		})
		local firstAlice = firstWorld.Join("Alice", 1)
		firstService:WaitForLoad(firstAlice)
		contexts[firstAlice].LeaderstatsAdapter:Set("Legacy", 9)
		firstWorld.Leave(firstAlice)
		waitUntil(function()
			return storedRecord(adapter, firstAlice).Lock == nil
		end, 2)
		firstService:Destroy()

		-- Session 2 only registers "Test", as if "Legacy" had been renamed or removed.
		local secondWorld = FakeEnvironment.new(1000)
		local secondService = startService(secondWorld, adapter, { newFaultyHandler("Test", noFaults(), contexts) })
		local secondAlice = secondWorld.Join("Alice", 1)
		secondService:WaitForLoad(secondAlice)
		secondWorld.Leave(secondAlice)
		waitUntil(function()
			return storedRecord(adapter, secondAlice).Lock == nil
		end, 2)

		t.Equal(
			"A namespace with no handler survives a save",
			storedRecord(adapter, secondAlice).Data.Legacy,
			{ Points = 9 }
		)

		secondService:Destroy()
	end

	-- Gap 3: a Save that returns nil or throws must keep the previous value and report it

	do
		local adapter = newAdapter()
		local world = FakeEnvironment.new(1000)
		local contexts: { [Player]: BaseUtil.Context } = {}
		local faults = noFaults()
		local service = startService(world, adapter, { newFaultyHandler("Test", faults, contexts) })

		local failureCount = 0
		service.SaveFailed:Connect(function()
			failureCount += 1
		end)

		local player = world.Join("Alice", 1)
		service:WaitForLoad(player)
		contexts[player].LeaderstatsAdapter:Set("Test", 30)
		world.Advance(DataSchema.Timing.MinSaveGapSeconds + 1)
		t.Check("A healthy save succeeds", service:SaveNow(player))

		-- Save returns nil: Sanitize(nil) would turn that into Default() and reset progress.
		t.Equal("A healthy save fires nothing", failureCount, 0)

		-- Save returns nil: Sanitize(nil) would turn that into Default() and reset progress.
		faults.SaveReturnsNil = true
		world.Advance(DataSchema.Timing.MinSaveGapSeconds + 1)
		service:SaveNow(player)

		t.Equal("A nil Save keeps the previous stored value", storedRecord(adapter, player).Data.Test.Points, 30)
		local countAfterNilSave = settledCount(function()
			return failureCount
		end, 1)
		t.Equal("A nil Save fires SaveFailed exactly once", countAfterNilSave, 1)

		-- Save throws during release: the old behaviour reported Released and stayed silent.
		faults.SaveReturnsNil = false
		faults.SaveThrows = true
		world.Leave(player)
		waitUntil(function()
			return storedRecord(adapter, player).Lock == nil
		end, 2)

		t.Equal(
			"A throwing Save keeps the previous value on release",
			storedRecord(adapter, player).Data.Test.Points,
			30
		)
		local countAfterRelease = settledCount(function()
			return failureCount
		end, countAfterNilSave + 1)
		t.Equal(
			"A throwing Save during release fires SaveFailed exactly once more",
			countAfterRelease,
			countAfterNilSave + 1
		)

		service:Destroy()
	end

	-- Secondary namespaces: claimed on join

	do
		local adapter = newAdapter()
		local world = FakeEnvironment.new(1000)
		local contexts: { [Player]: BaseUtil.Context } = {}
		local handler = newFaultyHandler("Vault", noFaults(), contexts, "Secondary")
		local secondaryKey = DataSchema.SecondaryKeyFor(1, "Vault")

		-- A record left behind by an earlier session, as another server would have written it.
		adapter:UpdateAsync(secondaryKey, function()
			return { SessionId = "old-session", Data = { Points = 12 }, SavedAt = 1 }
		end)

		local service = startService(world, adapter, { handler })
		local player = world.Join("Alice", 1)

		t.Check("A player with a Secondary namespace loads", service:WaitForLoad(player))
		t.Equal("A Secondary namespace loads from its own key", service:Get(player, handler), { Points = 12 })
		t.Check(
			"Joining stamps the Secondary record with a new session",
			adapter:Peek(secondaryKey).SessionId ~= "old-session"
		)
		t.Equal("Joining keeps the Secondary data", adapter:Peek(secondaryKey).Data, { Points = 12 })

		service:Destroy()
	end

	-- An unreadable optional namespace is unavailable, but the player still joins

	do
		local adapter = newAdapter()
		local world = FakeEnvironment.new(1000)
		local contexts: { [Player]: BaseUtil.Context } = {}
		local handler = newFaultyHandler("Vault", noFaults(), contexts, "Secondary")
		local secondaryKey = DataSchema.SecondaryKeyFor(1, "Vault")

		adapter:UpdateAsync(secondaryKey, function()
			return "not a record"
		end)

		local service = startService(world, adapter, { handler })
		local player = world.Join("Alice", 1)

		t.Check("A player still joins when an optional Secondary namespace is unreadable", service:WaitForLoad(player))
		t.Check("An unreadable Secondary namespace has no value", service:Get(player, handler) == nil)
		t.Check("An unreadable Secondary namespace is never loaded", contexts[player] == nil)
		t.Equal("An unreadable record is left untouched", adapter:Peek(secondaryKey), "not a record")

		service:Destroy()
	end

	-- An unreadable Required namespace stops the join

	do
		local adapter = newAdapter()
		local world = FakeEnvironment.new(1000)
		local contexts: { [Player]: BaseUtil.Context } = {}
		local handler = newFaultyHandler("Vault", noFaults(), contexts, "Secondary", true)
		local secondaryKey = DataSchema.SecondaryKeyFor(1, "Vault")

		adapter:UpdateAsync(secondaryKey, function()
			return "not a record"
		end)

		local service = startService(world, adapter, { handler })
		local player = world.Join("Alice", 1)

		t.Check("A player does not load when a Required namespace is unreadable", not service:WaitForLoad(player))
		t.Check("The player is kicked", world.KickReasonOf(player) ~= nil)
		t.Check(
			"The primary session lock is released",
			waitUntil(function()
				return storedRecord(adapter, player).Lock == nil
			end, 2)
		)

		service:Destroy()
	end
	return t.Summary()
end
