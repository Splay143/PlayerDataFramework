--!strict
--@Splay

local ServerScriptService = game:GetService("ServerScriptService")

local PlayerData = ServerScriptService.PlayerData
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local BaseUtil = require(PlayerData.Utils.BaseUtil)
local DataSchema = require(PlayerData.Config.DataSchema)
local DataService = require(PlayerData.Data.DataService)
local DeltaUtil = require(ReplicatedStorage.PlayerDataShared.Shared.DeltaUtil)
local FakeEnvironment = require(PlayerData.Tests.FakeEnvironment)
local Harness = require(PlayerData.Tests.Harness)
local MockAdapter = require(PlayerData.Adapters.MockAdapter)
local MockMessagingAdapter = require(PlayerData.Adapters.MockMessagingAdapter)
local StoreHandler = require(PlayerData.Data.StoreHandler)
local TableUtil = require(ReplicatedStorage.PlayerDataShared.Shared.TableUtil)
local ErrorCodes = require(PlayerData.Config.ErrorCodes)
local ErrorLogConfig = require(PlayerData.Config.ErrorLogConfig)
local Logger = require(PlayerData.Utils.Logger)

type TestData = {
	Points: number,
}

type Faults = {
	LoadThrows: boolean,
	SanitizeThrows: boolean,
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

-- What a real client would hold after receiving everything the server sent it.
local function clientView(world: FakeEnvironment.FakeWorld, player: Player): { [string]: any }
	local view: { [string]: any } = {}

	for _, message in world.Remotes:ReplicatedTo(player) do
		local raw: any = message
		if raw.Type == "Snapshot" then
			view = raw.Data
		else
			DeltaUtil.Apply(view, raw.Changes)
		end
	end

	return view
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
			if faults.SanitizeThrows then
				error("simulated Sanitize failure")
			end
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
	return { LoadThrows = false, SanitizeThrows = false, SaveThrows = false, SaveReturnsNil = false }
end

local function startService(
	world: FakeEnvironment.FakeWorld,
	adapter: MockAdapter.MockAdapter,
	handlers: { DataService.Handler<TestData> },
	storeOptions: StoreHandler.Options?,
	logger: Logger.Logger?,
	incidentAdapter: MockAdapter.MockAdapter?
)
	local service = DataService.new(world.Environment, logger)
	for _, handler in handlers do
		service:RegisterHandler(handler)
	end

	service:Start(adapter, storeOptions, incidentAdapter)
	return service
end

local function newAdapter(): MockAdapter.MockAdapter
	return MockAdapter.new(function(seconds: number)
		task.wait(seconds)
	end)
end

local function newRecordingLogger(world: FakeEnvironment.FakeWorld): (Logger.Logger, { Logger.Event })
	local logger = Logger.new({
		Now = world.Environment.Now,
		Context = { JobId = "test-job", PlaceId = 1, FrameworkVersion = "test" },
		Config = ErrorLogConfig.Resolve({ Preset = "Diagnostic" }),
	})
	local events: { Logger.Event } = {}
	logger:AddSink(function(event: Logger.Event)
		table.insert(events, event)
	end)
	return logger, events
end

local function eventWithCode(events: { Logger.Event }, code: number): Logger.Event?
	for _, event in events do
		if event.Code == code then
			return event
		end
	end
	return nil
end

local function countWithCode(events: { Logger.Event }, code: number): number
	local count = 0
	for _, event in events do
		if event.Code == code then
			count += 1
		end
	end
	return count
end

local function sendReleaseRequest(
	world: FakeEnvironment.FakeWorld,
	adapter: MockAdapter.MockAdapter,
	player: Player,
	sessionIdOverride: string?
)
	local lock: any = storedRecord(adapter, player).Lock
	world.Network:Publish("Release-" .. lock.ServerId, {
		UserId = player.UserId,
		SessionId = sessionIdOverride or lock.SessionId,
	})
	world.Network:Deliver()
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

	-- Failed releases are retried in the background

	do
		local base = DataSchema.Timing.UnreleasedRetryBaseSeconds
		local tick = DataSchema.Timing.UnreleasedRetryTickSeconds

		-- A failed release is retried later and saves the data from when the player left.
		do
			local world = FakeEnvironment.new(1000)
			local adapter = newAdapter()
			local handler, contexts = newTestHandler()
			-- One attempt per store call, so a failed release fails instantly instead of backing off.
			local service = startService(world, adapter, { handler }, { MaxAttempts = 1 })

			local player = world.Join("Alice", 1)
			service:WaitForLoad(player)
			contexts[player].LeaderstatsAdapter:Set("Points", 77)

			local callsBeforeLeave = adapter:CallCount()
			adapter:FailNext(1)
			world.Leave(player)

			t.Check(
				"The release is attempted when the player leaves",
				waitUntil(function()
					return adapter:CallCount() > callsBeforeLeave
				end, 2)
			)
			t.Check("A failed release leaves the lock in place", storedRecord(adapter, player).Lock ~= nil)

			local callsBeforeRetry = adapter:CallCount()
			-- The retry loop polls on real-time ticks; move past the fake-clock deadline
			-- so the next poll cannot miss the retry due to boundary scheduling.
			world.Advance(base + tick)

			local retried = waitUntil(function()
				return adapter:CallCount() > callsBeforeRetry
			end, base + tick + 10)
			t.Check("The background retry is attempted", retried)

			local released = waitUntil(function()
				return storedRecord(adapter, player).Lock == nil
			end, base + tick + 10)
			t.Check("The background retry releases the session", released)

			local record = storedRecord(adapter, player)
			local namespaceData = if type(record) == "table" and type(record.Data) == "table"
				then record.Data[TEST_NAMESPACE]
				else nil
			t.Check(
				"The retry saves the data from when the player left",
				type(namespaceData) == "table" and namespaceData.Points == 77
			)

			service:Destroy()
		end

		-- Rejoining before the retry runs must not lose the newest data.
		do
			local world = FakeEnvironment.new(1000)
			local adapter = newAdapter()
			local handler, contexts = newTestHandler()
			local service = startService(world, adapter, { handler }, { MaxAttempts = 1 })

			local player = world.Join("Alice", 1)
			service:WaitForLoad(player)
			contexts[player].LeaderstatsAdapter:Set("Points", 55)

			adapter:FailNext(1)
			world.Leave(player)
			t.Check("The failed release leaves the lock in place", storedRecord(adapter, player).Lock ~= nil)

			local rejoined = world.Join("Alice", 1)
			t.Check("A player rejoining with a pending release loads", service:WaitForLoad(rejoined))
			t.Equal("The rejoin saved the pending data first", service:Get(rejoined, handler), { Points = 55 })

			service:Destroy()
		end

		-- A failed flush must not block the rejoin.
		do
			local world = FakeEnvironment.new(1000)
			local adapter = newAdapter()
			local handler, contexts = newTestHandler()
			local service = startService(world, adapter, { handler }, { MaxAttempts = 1 })

			local player = world.Join("Alice", 1)
			service:WaitForLoad(player)
			contexts[player].LeaderstatsAdapter:Set("Points", 55)

			-- The first failure is the release, the second is the flush on rejoin.
			adapter:FailNext(2)
			world.Leave(player)

			local rejoined = world.Join("Alice", 1)
			t.Check("A failed flush does not block the join", service:WaitForLoad(rejoined))
			t.Equal("The player loads the last saved data", service:Get(rejoined, handler), { Points = 0 })

			service:Destroy()
		end

		-- A player who leaves while loading is released by abandonJoin, and that is retried too.
		do
			local world = FakeEnvironment.new(1000)
			local adapter = newAdapter()
			local handler = newTestHandler()
			local service = startService(world, adapter, { handler }, { MaxAttempts = 1 })

			-- The hook fires once, after the session is claimed but before the claim is committed.
			-- The player leaves there, and the abandon release (the next store call) fails.
			adapter:BeforeCommit(function()
				adapter:FailNext(1)
				for _, joining in world.Environment.GetPlayers() do
					world.Leave(joining)
				end
			end)

			local player = world.Join("Alice", 1)
			t.Check(
				"The abandoned join attempts a release",
				waitUntil(function()
					return adapter:CallCount() >= 2
				end, 2)
			)
			t.Check("A failed abandon release leaves the lock", storedRecord(adapter, player).Lock ~= nil)

			world.Advance(base)
			t.Check(
				"The background retry releases the abandoned session",
				waitUntil(function()
					return storedRecord(adapter, player).Lock == nil
				end, tick + 2)
			)

			service:Destroy()
		end

		-- Shutdown gives a pending failed release one last attempt, ignoring its delay.
		do
			local world = FakeEnvironment.new(1000)
			local adapter = newAdapter()
			local handler, contexts = newTestHandler()
			local service = startService(world, adapter, { handler }, { MaxAttempts = 1 })

			local player = world.Join("Alice", 1)
			service:WaitForLoad(player)
			contexts[player].LeaderstatsAdapter:Set("Points", 33)

			adapter:FailNext(1)
			world.Leave(player)
			t.Check("The failed release leaves the lock before shutdown", storedRecord(adapter, player).Lock ~= nil)

			-- Latency makes the retry yield, so shutdown has to genuinely wait for it.
			adapter:SetLatency(0.2)
			world.CloseServer()

			t.Check("Shutdown releases the pending session", storedRecord(adapter, player).Lock == nil)
			t.Equal("Shutdown saved the pending data", storedRecord(adapter, player).Data[TEST_NAMESPACE].Points, 33)

			service:Destroy()
		end

		-- A failed retry backs off before trying again.
		do
			local world = FakeEnvironment.new(1000)
			local adapter = newAdapter()
			local handler, contexts = newTestHandler()
			local service = startService(world, adapter, { handler }, { MaxAttempts = 1 })

			local player = world.Join("Alice", 1)
			service:WaitForLoad(player)
			contexts[player].LeaderstatsAdapter:Set("Points", 12)

			local callsBeforeLeave = adapter:CallCount()
			-- The first failure is the release, the second is the first retry.
			adapter:FailNext(2)
			world.Leave(player)

			world.Advance(base)
			t.Check(
				"The first retry is attempted after the base delay",
				waitUntil(function()
					return adapter:CallCount() > callsBeforeLeave + 1
				end, tick + 2)
			)
			t.Check("A failed retry keeps the lock", storedRecord(adapter, player).Lock ~= nil)

			local secondDelay = math.min(base * 2, DataSchema.Timing.UnreleasedRetryMaxSeconds)
			world.Advance(secondDelay - 1)
			task.wait(tick + 0.5)
			t.Equal("The next retry waits out the longer delay", adapter:CallCount(), callsBeforeLeave + 2)

			world.Advance(1)
			t.Check(
				"The retry succeeds once its delay has passed",
				waitUntil(function()
					return storedRecord(adapter, player).Lock == nil
				end, tick + 2)
			)
			t.Equal(
				"The late retry saved the right data",
				storedRecord(adapter, player).Data[TEST_NAMESPACE].Points,
				12
			)

			service:Destroy()
		end

		-- A late retry must never overwrite a newer owner of the session.
		do
			local worldA = FakeEnvironment.new(1000)
			local adapter = newAdapter()
			local handlerA, contextsA = newTestHandler()
			local serviceA = startService(worldA, adapter, { handlerA }, { MaxAttempts = 1 })

			local playerA = worldA.Join("Alice", 1)
			serviceA:WaitForLoad(playerA)
			contextsA[playerA].LeaderstatsAdapter:Set("Points", 99)

			local callsBeforeLeave = adapter:CallCount()
			adapter:FailNext(1)
			worldA.Leave(playerA)
			waitUntil(function()
				return adapter:CallCount() > callsBeforeLeave
			end, 2)

			-- Server B's clock is past the stale-lock timeout, so it may take the session over.
			local worldB = FakeEnvironment.new(1000 + DataSchema.Timing.StaleLockSeconds + 1)
			local handlerB = newTestHandler()
			local serviceB = startService(worldB, adapter, { handlerB }, { MaxAttempts = 1 })
			local playerB = worldB.Join("Alice", 1)
			t.Check("Another server can take over the abandoned session", serviceB:WaitForLoad(playerB))

			local lockBeforeRetry = TableUtil.DeepCopy(storedRecord(adapter, playerB).Lock)
			local callsBeforeRetry = adapter:CallCount()
			worldA.Advance(base)

			t.Check(
				"The old server still attempts its retry",
				waitUntil(function()
					return adapter:CallCount() > callsBeforeRetry
				end, tick + 2)
			)
			t.Equal(
				"The late retry does not touch the new owner's lock",
				storedRecord(adapter, playerB).Lock,
				lockBeforeRetry
			)
			t.Check("The new owner stays loaded", serviceB:IsLoaded(playerB))

			serviceA:Destroy()
			serviceB:Destroy()
		end
	end

	-- Release requests from other servers

	do
		-- Leaves with a failed release: the lock stays held and the service keeps an unreleased entry.
		local function leaveWithFailedRelease(
			world: FakeEnvironment.FakeWorld,
			adapter: MockAdapter.MockAdapter,
			service: any,
			contexts: { [Player]: BaseUtil.Context }
		): Player
			local player = world.Join("Alice", 1)
			service:WaitForLoad(player)
			contexts[player].LeaderstatsAdapter:Set("Points", 77)

			local callsBeforeLeave = adapter:CallCount()
			adapter:FailNext(1)
			world.Leave(player)
			waitUntil(function()
				return adapter:CallCount() > callsBeforeLeave
			end, 2)

			return player
		end

		-- A request retries the failed release now, without waiting for the backoff.
		do
			local world = FakeEnvironment.new(1000)
			local adapter = newAdapter()
			local handler, contexts = newTestHandler()
			local service = startService(world, adapter, { handler }, { MaxAttempts = 1 })
			local player = leaveWithFailedRelease(world, adapter, service, contexts)

			t.Check("The failed release leaves the lock in place", storedRecord(adapter, player).Lock ~= nil)

			-- The fake clock has not moved, so the background retry is not due yet.
			sendReleaseRequest(world, adapter, player, nil)

			t.Check(
				"A release request retries the failed release at once",
				waitUntil(function()
					return storedRecord(adapter, player).Lock == nil
				end, 2)
			)
			t.Equal(
				"The retry saves the data from when the player left",
				storedRecord(adapter, player).Data[TEST_NAMESPACE].Points,
				77
			)

			service:Destroy()
		end

		-- A request for a different session is ignored, and a correct one still works afterwards.
		do
			local world = FakeEnvironment.new(1000)
			local adapter = newAdapter()
			local handler, contexts = newTestHandler()
			local service = startService(world, adapter, { handler }, { MaxAttempts = 1 })
			local player = leaveWithFailedRelease(world, adapter, service, contexts)

			t.Check("The failed release leaves the lock in place", storedRecord(adapter, player).Lock ~= nil)

			sendReleaseRequest(world, adapter, player, "some-other-session")
			task.wait()
			t.Check("A request for another session is ignored", storedRecord(adapter, player).Lock ~= nil)

			sendReleaseRequest(world, adapter, player, nil)
			t.Check(
				"The matching request still releases afterwards",
				waitUntil(function()
					return storedRecord(adapter, player).Lock == nil
				end, 2)
			)

			service:Destroy()
		end

		-- A connected player is never released by a request.
		do
			local world = FakeEnvironment.new(1000)
			local adapter = newAdapter()
			local handler = newTestHandler()
			local service = startService(world, adapter, { handler }, { MaxAttempts = 1 })

			local player = world.Join("Alice", 1)
			service:WaitForLoad(player)

			sendReleaseRequest(world, adapter, player, nil)
			task.wait()

			t.Check("A request for a connected player keeps their lock", storedRecord(adapter, player).Lock ~= nil)
			t.Check("A request for a connected player leaves them loaded", service:IsLoaded(player))
			t.Check("A request for a connected player does not kick them", world.KickReasonOf(player) == nil)

			service:Destroy()
		end
	end

	-- A blocked join asks the blocking server to release

	do
		-- The request makes server A retry at once, so server B's player is not left waiting.
		do
			local worldA = FakeEnvironment.new(1000)
			local worldB = FakeEnvironment.new(1000, worldA.Network)
			local adapter = newAdapter()
			local handlerA, contextsA = newTestHandler()
			local handlerB = newTestHandler()
			local serviceA = startService(worldA, adapter, { handlerA }, { MaxAttempts = 1 })
			local loggerB, eventsB = newRecordingLogger(worldB)
			local serviceB = startService(worldB, adapter, { handlerB }, nil, loggerB)

			local playerOnA = worldA.Join("Alice", 1)
			serviceA:WaitForLoad(playerOnA)
			contextsA[playerOnA].LeaderstatsAdapter:Set("Points", 77)

			local callsBeforeLeave = adapter:CallCount()
			adapter:FailNext(1)
			worldA.Leave(playerOnA)
			waitUntil(function()
				return adapter:CallCount() > callsBeforeLeave
			end, 2)
			t.Check("Server A keeps the lock after its release failed", storedRecord(adapter, playerOnA).Lock ~= nil)

			local playerOnB = worldB.Join("Alice", 1)

			t.Check(
				"A blocked join sends a release request",
				waitUntil(function()
					return worldA.Network:PendingCount() > 0
				end, 2)
			)
			worldA.Network:Deliver()

			t.Check(
				"The join succeeds once server A has released",
				waitUntil(function()
					return serviceB:IsLoaded(playerOnB)
				end, 6)
			)
			t.Equal(
				"Server B loads the data server A saved on retry",
				serviceB:Get(playerOnB, handlerB),
				{ Points = 77 }
			)

			local blocked = eventWithCode(eventsB, ErrorCodes.Codes.JoinBlocked)
			t.Check("A blocked join is logged", blocked ~= nil)
			t.Check(
				"It is an Info at the Join stage",
				blocked ~= nil and blocked.Severity == "Info" and blocked.Stage == "Join"
			)
			t.Check(
				"It names the blocking server",
				blocked ~= nil and string.find(blocked.Detail or "", "blocked by server", 1, true) ~= nil
			)

			serviceA:Destroy()
			serviceB:Destroy()
		end

		-- A lost request is only a missed speed-up: the join still succeeds once A's own retry runs.
		do
			local base = DataSchema.Timing.UnreleasedRetryBaseSeconds

			local worldA = FakeEnvironment.new(1000)
			local worldB = FakeEnvironment.new(1000, worldA.Network)
			local adapter = newAdapter()
			local handlerA, contextsA = newTestHandler()
			local handlerB = newTestHandler()
			local serviceA = startService(worldA, adapter, { handlerA }, { MaxAttempts = 1 })
			local serviceB = startService(worldB, adapter, { handlerB }, nil)

			local playerOnA = worldA.Join("Alice", 1)
			serviceA:WaitForLoad(playerOnA)
			contextsA[playerOnA].LeaderstatsAdapter:Set("Points", 55)

			local callsBeforeLeave = adapter:CallCount()
			adapter:FailNext(1)
			worldA.Leave(playerOnA)
			waitUntil(function()
				return adapter:CallCount() > callsBeforeLeave
			end, 2)

			worldA.Network:DropNext(1)
			local playerOnB = worldB.Join("Alice", 1)

			t.Check(
				"The request was published",
				waitUntil(function()
					return worldA.Network:PublishedCount() >= 1
				end, 2)
			)
			worldA.Network:Deliver()
			t.Check("Without the request the join keeps waiting", not serviceB:IsLoaded(playerOnB))

			-- Making server A's own backoff due is the fallback that has to work without the message.
			worldA.Advance(base)
			t.Check(
				"The join still succeeds through server A's own retry",
				waitUntil(function()
					return serviceB:IsLoaded(playerOnB)
				end, 8)
			)

			serviceA:Destroy()
			serviceB:Destroy()
		end
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

	-- Gap 1: a failed Load or Sanitize must not overwrite saved data, and must kick the player
	local expectedCodes = { LoadThrows = 202, SanitizeThrows = 201 }
	for _, faultName in { "LoadThrows", "SanitizeThrows" } do
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

		-- Session 2: the handler is broken, so the player must not load.
		local brokenFaults = noFaults() :: any
		brokenFaults[faultName] = true
		local secondWorld = FakeEnvironment.new(1000)
		local secondLogger, secondEvents = newRecordingLogger(secondWorld)
		local secondService = startService(
			secondWorld,
			adapter,
			{ newFaultyHandler("Test", brokenFaults, contexts) },
			nil,
			secondLogger
		)
		local secondAlice = secondWorld.Join("Alice", 1)

		t.Check(faultName .. ": the player does not load", not secondService:WaitForLoad(secondAlice))
		t.Check(faultName .. ": the player is kicked", secondWorld.KickReasonOf(secondAlice) ~= nil)
		t.Check(
			faultName .. ": the kick shows the right error code",
			string.find(
				secondWorld.KickReasonOf(secondAlice) or "",
				"Error Code: " .. tostring(expectedCodes[faultName]),
				1,
				true
			) ~= nil
		)
		
		t.Check(
			faultName .. ": the session lock is released",
			waitUntil(function()
				return storedRecord(adapter, secondAlice).Lock == nil
			end, 2)
		)
		t.Equal(faultName .. ": the saved data is untouched", storedRecord(adapter, secondAlice).Data.Test.Points, 77)
		t.Equal(faultName .. ": exactly one incident is logged", #secondEvents, 1)
		local incident = secondEvents[1]
		t.Equal(faultName .. ": the incident has the kick's code", incident.Code, expectedCodes[faultName])
		t.Check(faultName .. ": the incident is marked as a kick", incident.Kicked)
		t.Equal(faultName .. ": the incident names the player", incident.UserId, 1)
		t.Equal(faultName .. ": the incident is a Load error", incident.Stage, "Load")
		t.Check(faultName .. ": the detail names the namespace", string.find(incident.Detail or "", "Test", 1, true) ~= nil)
		t.Check(
			faultName .. ": the detail carries the handler's error text",
			string.find(incident.Detail or "", "simulated", 1, true) ~= nil
		)
		t.Check(
			faultName .. ": the player never sees the log message",
			string.find(secondWorld.KickReasonOf(secondAlice) or "", incident.Message, 1, true) == nil
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
		local logger, events = newRecordingLogger(world)
		local service = startService(world, adapter, { newFaultyHandler("Test", faults, contexts) }, nil, logger)

		local failureCount = 0
		service.SaveFailed:Connect(function()
			failureCount += 1
		end)

		local player = world.Join("Alice", 1)
		service:WaitForLoad(player)
		contexts[player].LeaderstatsAdapter:Set("Test", 30)
		world.Advance(DataSchema.Timing.MinSaveGapSeconds + 1)
		t.Check("A healthy save succeeds", service:SaveNow(player))

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
		t.Equal("A nil Save is logged once", countWithCode(events, ErrorCodes.Codes.HandlerSaveFailure), 1)
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
		t.Equal("A throwing Save during release is logged too", countWithCode(events, ErrorCodes.Codes.HandlerSaveFailure), 2)
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

	-- An unreadable Secondary namespace stops the join, even when it is not Required

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

		t.Check("A player does not load when a Secondary namespace is unreadable", not service:WaitForLoad(player))
		t.Check("The player is kicked", world.KickReasonOf(player) ~= nil)
		t.Check(
			"The kick shows the NamespaceUnavailable code",
			string.find(world.KickReasonOf(player) or "", "Error Code: 403", 1, true) ~= nil
		)
		t.Check(
			"The kick shows the NamespaceUnavailable code",
			string.find(world.KickReasonOf(player) or "", "Error Code: 403", 1, true) ~= nil
		)
		t.Check(
			"The primary session lock is released",
			waitUntil(function()
				return storedRecord(adapter, player).Lock == nil
			end, 2)
		)
		t.Equal("An unreadable record is left untouched", adapter:Peek(secondaryKey), "not a record")

		service:Destroy()
	end

	-- An unreadable Required namespace stops the join

	do
		local adapter = newAdapter()
		local world = FakeEnvironment.new(1000)
		local logger, events = newRecordingLogger(world)

		local contexts: { [Player]: BaseUtil.Context } = {}
		local handler = newFaultyHandler("Vault", noFaults(), contexts, "Secondary", true)
		local secondaryKey = DataSchema.SecondaryKeyFor(1, "Vault")

		adapter:UpdateAsync(secondaryKey, function()
			return "not a record"
		end)

		local service = startService(world, adapter, { handler }, nil, logger)
		local player = world.Join("Alice", 1)

		t.Check("A player does not load when a Required namespace is unreadable", not service:WaitForLoad(player))
		t.Check("The player is kicked", world.KickReasonOf(player) ~= nil)
		t.Equal("One incident is logged for the kick", #events, 1)
		t.Equal("It uses the NamespaceUnavailable code", events[1].Code, ErrorCodes.Codes.NamespaceUnavailable)
		t.Equal("It is an Error", events[1].Severity, "Error")
		t.Check("It is marked as a kick", events[1].Kicked)
		t.Check(
			"Its detail names the namespace and the claim status",
			string.find(events[1].Detail or "", "Vault: claim returned", 1, true) ~= nil
		)
		t.Check(
			"The primary session lock is released",
			waitUntil(function()
				return storedRecord(adapter, player).Lock == nil
			end, 2)
		)

		service:Destroy()
	end

	-- A record that cannot be migrated kicks with its own code, not a generic load failure.
	do
		local world = FakeEnvironment.new(1000)
		local adapter = newAdapter()
		local logger, events = newRecordingLogger(world)
		local handler = newTestHandler()
		local service = startService(world, adapter, { handler }, nil, logger)
	
		adapter:UpdateAsync(DataSchema.KeyFor(1), function()
			return {
				SchemaVersion = 0,
				Lock = nil,
				Data = {},
				Meta = { CreatedAt = 1, LastSaved = 1 },
			}
		end)
	
		local player = world.Join("Alice", 1)
	
		t.Check("A player with an unmigratable record does not load", not service:WaitForLoad(player))
		t.Check("The player is kicked", world.KickReasonOf(player) ~= nil)
		t.Equal("One incident is logged", #events, 1)
		t.Equal("It uses the MigrationFailed code", events[1].Code, ErrorCodes.Codes.MigrationFailed)
		t.Check("It is a Developer fault and a kick", events[1].Fault == "Developer" and events[1].Kicked)
		t.Equal("The stored record is untouched", adapter:Peek(DataSchema.KeyFor(1)).SchemaVersion, 0)
	
		service:Destroy()
	end
	
	-- A logger that throws must not stop the kick
	do
		local adapter = newAdapter()
		local world = FakeEnvironment.new(1000)
		local contexts: { [Player]: BaseUtil.Context } = {}
		local handler = newFaultyHandler("Vault", noFaults(), contexts, "Secondary", true)
		local secondaryKey = DataSchema.SecondaryKeyFor(1, "Vault")

		adapter:UpdateAsync(secondaryKey, function()
			return "not a record"
		end)

		local brokenLogger = ({
			Log = function()
				error("simulated logger failure")
			end,
			AddSink = function() end,
		} :: any) :: Logger.Logger

		local service = startService(world, adapter, { handler }, nil, brokenLogger)
		local player = world.Join("Alice", 1)

		t.Check("The player does not load", not service:WaitForLoad(player))
		t.Check("The player is still kicked when logging throws", world.KickReasonOf(player) ~= nil)

		service:Destroy()
	end

	-- Release and shutdown incidents
	
	do
		local window = DataSchema.Timing.UnreleasedRetryWindowSeconds
		local tick = DataSchema.Timing.UnreleasedRetryTickSeconds
	
		-- A failed release is logged, and giving up on it is logged as data loss.
		do
			local world = FakeEnvironment.new(1000)
			local adapter = newAdapter()
			local logger, events = newRecordingLogger(world)
			local handler = newTestHandler()
			local service = startService(world, adapter, { handler }, { MaxAttempts = 1 }, logger)
	
			local player = world.Join("Alice", 1)
			service:WaitForLoad(player)
	
			adapter:FailNext(1)
			world.Leave(player)
	
			t.Check(
				"A failed release is logged",
				waitUntil(function()
					return eventWithCode(events, ErrorCodes.Codes.ReleaseFailed) ~= nil
				end, 2)
			)
			local failed = eventWithCode(events, ErrorCodes.Codes.ReleaseFailed)
			t.Check(
				"A failed release is an Error at the Release stage",
				failed ~= nil and failed.Severity == "Error" and failed.Stage == "Release"
			)
			t.Check(
				"A failed release that will be retried is not yet data loss",
				failed ~= nil and not failed.DataLossLikely
			)
	
			-- Every retry fails until the retry window runs out.
			adapter:FailNext(1000)
			world.Advance(window)
	
			t.Check(
				"Giving up on a release is logged as DataLoss",
				waitUntil(function()
					local abandoned = eventWithCode(events, ErrorCodes.Codes.ReleaseAbandoned)
					return abandoned ~= nil and abandoned.Severity == "DataLoss"
				end, tick + 3)
			)
	
			service:Destroy()
		end
	
		-- A shutdown that runs out of time says which players were not finished.
		do
			local world = FakeEnvironment.new(1000)
			local adapter = newAdapter()
			local logger, events = newRecordingLogger(world)
			local handler = newTestHandler()
			local service = startService(world, adapter, { handler }, nil, logger)
	
			local player = world.Join("Alice", 7)
			service:WaitForLoad(player)
	
			-- A slow store and a short deadline, so the release cannot finish in time.
			local originalTimeout = DataSchema.Timing.ShutdownTimeoutSeconds
			DataSchema.Timing.ShutdownTimeoutSeconds = 0.3
			adapter:SetLatency(1)
			world.CloseServer()
			DataSchema.Timing.ShutdownTimeoutSeconds = originalTimeout
	
			local incomplete = eventWithCode(events, ErrorCodes.Codes.ShutdownIncomplete)
			t.Check("An unfinished shutdown is logged", incomplete ~= nil)
			t.Check(
				"It counts the unfinished user IDs",
				incomplete ~= nil and string.find(incomplete.Detail or "", "Unfinished user IDs: 1", 1, true) ~= nil
			)
			t.Check(
				"It lists the affected user",
				incomplete ~= nil
					and string.find(incomplete.Detail or "", "Users affected: Alice (7)", 1, true) ~= nil
			)
			t.Check(
				"It lists section names once without repeating the user or exposing values",
				incomplete ~= nil
					and string.find(incomplete.Detail or "", "Sections: Test", 1, true) ~= nil
					and string.find(incomplete.Detail or "", "Points", 1, true) == nil
					and string.find(incomplete.Detail or "", "Alice (7):", 1, true) == nil
			)
	
			-- Let the slow release finish before the service is thrown away.
			waitUntil(function()
				return storedRecord(adapter, player).Lock == nil
			end, 5)
			service:Destroy()
		end
	end
	
	-- A failed save is a Warning with its own code, and the player keeps playing
	do
		local world = FakeEnvironment.new(1000)
		local adapter = newAdapter()
		local logger, events = newRecordingLogger(world)
		local handler = newTestHandler()
		local service = startService(world, adapter, { handler }, { MaxAttempts = 1 }, logger)
	
		local player = world.Join("Alice", 1)
		service:WaitForLoad(player)
		world.Advance(DataSchema.Timing.MinSaveGapSeconds + 1)
	
		adapter:FailNext(1)
		t.Check("SaveNow reports a failed save", not service:SaveNow(player))
	
		local failed = eventWithCode(events, ErrorCodes.Codes.SaveFailed)
		t.Check("A failed save is logged", failed ~= nil)
		t.Check(
			"It is a Warning at the Save stage",
			failed ~= nil and failed.Severity == "Warning" and failed.Stage == "Save"
		)
		t.Check("It is neither a kick nor data loss", failed ~= nil and not failed.Kicked and not failed.DataLossLikely)
		t.Check("The player is still loaded", service:IsLoaded(player))
	
		service:Destroy()
	end
	
	-- A rejoin that outlasts the release wait is logged, and the join still goes ahead
	do
		local world = FakeEnvironment.new(1000)
		local adapter = newAdapter()
		local logger, events = newRecordingLogger(world)
		local handler = newTestHandler()
		local service = startService(world, adapter, { handler }, nil, logger)
	
		local first = world.Join("Alice", 1)
		service:WaitForLoad(first)
	
		-- A short wait and a slow store, so the old release is still running when Alice comes back.
		local originalWait = DataSchema.Timing.ReleaseWaitSeconds
		DataSchema.Timing.ReleaseWaitSeconds = 0.2
		adapter:SetLatency(1)
		world.Leave(first)
		local second = world.Join("Alice", 1)
	
		t.Check(
			"A rejoin that waits too long is logged",
			waitUntil(function()
				return eventWithCode(events, ErrorCodes.Codes.ReleaseWaitTimeout) ~= nil
			end, 3)
		)
		DataSchema.Timing.ReleaseWaitSeconds = originalWait
	
		local timeout = eventWithCode(events, ErrorCodes.Codes.ReleaseWaitTimeout)
		t.Check(
			"It is a Warning at the Join stage for that player",
			timeout ~= nil and timeout.Severity == "Warning" and timeout.Stage == "Join" and timeout.UserId == 1
		)
	
		adapter:SetLatency(0)
		t.Check(
			"The rejoin still loads",
			waitUntil(function()
				return service:IsLoaded(second)
			end, 10)
		)
	
		service:Destroy()
	end
	
	-- Without messaging the release listener cannot start: that is logged, but joins still work
	do
		local world = FakeEnvironment.new(1000)
		world.Network:SetAvailable(false)
		local adapter = newAdapter()
		local logger, events = newRecordingLogger(world)
		local handler = newTestHandler()
		local service = startService(world, adapter, { handler }, nil, logger)
	
		t.Check(
			"A listener that cannot start is logged",
			waitUntil(function()
				return eventWithCode(events, ErrorCodes.Codes.ReleaseListenerFailed) ~= nil
			end, 2)
		)
		local failed = eventWithCode(events, ErrorCodes.Codes.ReleaseListenerFailed)
		t.Check("It is a Warning and names no player", failed ~= nil and failed.Severity == "Warning" and failed.UserId == nil)
	
		local player = world.Join("Alice", 1)
		t.Check("Players still load without the listener", service:WaitForLoad(player))
	
		service:Destroy()
	end

	-- Diagnostic signal and counts
	
	do
		local world = FakeEnvironment.new(1000)
		local adapter = newAdapter()
		local logger = newRecordingLogger(world)
		local handler = newTestHandler()
		local service = startService(world, adapter, { handler }, { MaxAttempts = 1 }, logger)
	
		local received: { Logger.Event } = {}
		service.Diagnostic:Connect(function(event: Logger.Event)
			table.insert(received, event)
		end)
	
		local player = world.Join("Alice", 1)
		service:WaitForLoad(player)
		adapter:FailNext(1)
		world.Leave(player)
	
		t.Check(
			"Diagnostic fires for a logged incident",
			waitUntil(function()
				return eventWithCode(received, ErrorCodes.Codes.ReleaseFailed) ~= nil
			end, 2)
		)
		t.Equal(
			"GetDiagnosticCounts counts the incident",
			service:GetDiagnosticCounts()[ErrorCodes.Codes.ReleaseFailed],
			1
		)
	
		local counts = service:GetDiagnosticCounts()
		counts[ErrorCodes.Codes.ReleaseFailed] = 99
		t.Equal(
			"The returned counts are a copy",
			service:GetDiagnosticCounts()[ErrorCodes.Codes.ReleaseFailed],
			1
		)
	
		service:Destroy()
	end

	-- Incident store wiring
	
	do
		local originalEnabled = DataSchema.IncidentStore.Enabled
		local originalTick = DataSchema.Timing.LogFlushTickSeconds
		local originalPreset: typeof(ErrorLogConfig.Settings.Preset) = ErrorLogConfig.Settings.Preset

		local function testIncident(severity: Logger.Severity): Logger.EventInput
			return {
				Code = ErrorCodes.Codes.SessionLost,
				Severity = severity,
				Fault = "Platform",
				Stage = "Release",
				Message = "test incident",
			}
		end
	
		local function keyOf(event: Logger.Event): string
			return DataSchema.IncidentStore.KeyPrefix .. event.Id
		end
	
		-- Off by default: nothing is written, even at shutdown.
		do
			local world = FakeEnvironment.new(1000)
			local incidentAdapter = newAdapter()
			local logger = newRecordingLogger(world)
			local handler = newTestHandler()
			local service = startService(world, newAdapter(), { handler }, nil, logger, incidentAdapter)
	
			logger:Log(testIncident("DataLoss"))
			world.CloseServer()
	
			t.Equal("A disabled incident store is never called", incidentAdapter:CallCount(), 0)
			service:Destroy()
		end
	
		-- On: the timer stores incidents that pass the floor, and leaves the rest out.
		do
			local world = FakeEnvironment.new(1000)
			local incidentAdapter = newAdapter()
			local logger = newRecordingLogger(world)
	
			DataSchema.IncidentStore.Enabled = true
			ErrorLogConfig.Settings.Preset = "Standard"
			DataSchema.Timing.LogFlushTickSeconds = 0.1

			local handler = newTestHandler()
			local service = startService(world, newAdapter(), { handler }, nil, logger, incidentAdapter)
			DataSchema.IncidentStore.Enabled = originalEnabled
			ErrorLogConfig.Settings.Preset = originalPreset

			local quiet = logger:Log(testIncident("Warning"))
			local loud = logger:Log(testIncident("Error"))
	
			t.Check(
				"The timer stores an incident that passes the floor",
				waitUntil(function()
					return incidentAdapter:Peek(keyOf(loud)) ~= nil
				end, 2)
			)
			t.Equal("An incident below the floor is not stored", incidentAdapter:Peek(keyOf(quiet)), nil)
			
			DataSchema.Timing.LogFlushTickSeconds = originalTick
			service:Destroy()
		end
	
		-- On: shutdown stores what is queued without waiting for the timer.
		do
			local world = FakeEnvironment.new(1000)
			local incidentAdapter = newAdapter()
			local logger = newRecordingLogger(world)
	
			DataSchema.IncidentStore.Enabled = true
			ErrorLogConfig.Settings.Preset = "Standard"
			local handler = newTestHandler()
			local service = startService(world, newAdapter(), { handler }, nil, logger, incidentAdapter)
			DataSchema.IncidentStore.Enabled = originalEnabled
			ErrorLogConfig.Settings.Preset = originalPreset
	
			local incident = logger:Log(testIncident("DataLoss"))
			world.CloseServer()
	
			t.Check("Shutdown stores queued incidents", incidentAdapter:Peek(keyOf(incident)) ~= nil)
			service:Destroy()
		end
	end

	-- Held log summaries are flushed on a timer and at shutdown
	
	do
		local flushCalls: { boolean } = {}
		local spyLogger = ({
			Log = function()
				return nil
			end,
			FlushSummaries = function(_self: unknown, force: boolean?)
				table.insert(flushCalls, force == true)
			end,
			AddSink = function() end,
		} :: any) :: Logger.Logger
	
		-- A short tick, so the timer is seen without waiting out the real interval.
		local originalTick = DataSchema.Timing.LogFlushTickSeconds
		DataSchema.Timing.LogFlushTickSeconds = 0.1
		local world = FakeEnvironment.new(1000)
		local handler = newTestHandler()
		local service = startService(world, newAdapter(), { handler }, nil, spyLogger)
		DataSchema.Timing.LogFlushTickSeconds = originalTick
	
		t.Check(
			"The timer flushes held summaries without forcing",
			waitUntil(function()
				return table.find(flushCalls, false) ~= nil
			end, 2)
		)
		t.Check("Nothing forces a flush before shutdown", table.find(flushCalls, true) == nil)
	
		world.CloseServer()
		t.Check("Shutdown forces a final flush", table.find(flushCalls, true) ~= nil)
	
		service:Destroy()
	end

	-- Structured replication

	do
		-- An early snapshot request is held until the load finishes, then answered completely.
		do
			local adapter = newAdapter()
			adapter:SetLatency(0.5)
			local world = FakeEnvironment.new(1000)
			local handler = newTestHandler()
			local service = startService(world, adapter, { handler })

			local player = world.Join("Alice", 1)
			world.Remotes:SimulateSnapshotRequest(player)

			-- Two flush ticks pass while the load is still waiting on the slow store.
			task.wait(0.25)
			t.Check("the player is still loading", not service:IsLoaded(player))
			t.Equal("nothing is sent while the player is loading", #world.Remotes:ReplicatedTo(player), 0)

			service:WaitForLoad(player)
			service:Replicate(player, "Inventory", { "Sword" })

			t.Check(
				"the held snapshot arrives after the load",
				waitUntil(function()
					return clientView(world, player).Inventory ~= nil
				end, 2)
			)
			t.Equal(
				"the client ends up with the replicated table",
				clientView(world, player),
				{ Inventory = { "Sword" } }
			)

			service:Destroy()
		end

		-- Changes arrive as deltas, and scalars never touch the remote
		do
			local adapter = newAdapter()
			local world = FakeEnvironment.new(1000)
			local handler = newTestHandler()
			local service = startService(world, adapter, { handler })

			local player = world.Join("Alice", 1)
			service:WaitForLoad(player)
			world.Remotes:SimulateSnapshotRequest(player)

			local inventory = { "Sword", "Potion" }
			service:Replicate(player, "Inventory", inventory)
			t.Check(
				"the first snapshot arrives",
				waitUntil(function()
					return clientView(world, player).Inventory ~= nil
				end, 2)
			)

			inventory[2] = "Bow"
			service:Replicate(player, "Inventory", inventory)
			t.Check(
				"a later change reaches the client",
				waitUntil(function()
					return clientView(world, player).Inventory[2] == "Bow"
				end, 2)
			)

			local sentBefore = #world.Remotes:ReplicatedTo(player)
			service:Replicate(player, "Coins", 5)
			task.wait(0.3)
			t.Equal("a scalar does not use the remote", #world.Remotes:ReplicatedTo(player), sentBefore)

			service:Destroy()
		end

		-- A player who left is forgotten
		do
			local adapter = newAdapter()
			local world = FakeEnvironment.new(1000)
			local handler = newTestHandler()
			local service = startService(world, adapter, { handler })

			local player = world.Join("Alice", 1)
			service:WaitForLoad(player)
			world.Remotes:SimulateSnapshotRequest(player)
			service:Replicate(player, "Inventory", { "Sword" })
			waitUntil(function()
				return #world.Remotes:ReplicatedTo(player) >= 1
			end, 2)

			world.Leave(player)
			local sentBefore = #world.Remotes:ReplicatedTo(player)

			world.Remotes:SimulateSnapshotRequest(player)
			service:Replicate(player, "Inventory", { "Sword", "Bow" })
			task.wait(0.3)
			t.Equal("nothing is sent to a player who left", #world.Remotes:ReplicatedTo(player), sentBefore)

			service:Destroy()
		end
	end

	-- The fake world's messaging

	do
		local sharedNetwork = MockMessagingAdapter.new()
		local worldA = FakeEnvironment.new(1000, sharedNetwork)
		local worldB = FakeEnvironment.new(1000, sharedNetwork)
		local worldAlone = FakeEnvironment.new(1000)

		t.Check("A world uses the network it was given", worldA.Network == sharedNetwork)
		t.Check("A world without a network gets its own", worldAlone.Network ~= sharedNetwork)

		local received: { any } = {}
		worldB.Environment.Messaging:Subscribe("test-topic", function(payload: any)
			table.insert(received, payload)
		end)

		worldA.Environment.Messaging:Publish("test-topic", { Value = 1 })
		worldA.Network:Deliver()
		t.Equal("A message reaches another world on the same network", received, { { Value = 1 } })

		worldAlone.Environment.Messaging:Publish("test-topic", { Value = 2 })
		worldAlone.Network:Deliver()
		t.Equal("A world on its own network is isolated", #received, 1)
	end

	-- EditUnlocked: editing a stored player who is not in any server

	do
		-- A saved player who has left: the lock is released and the record is editable.
		local function newOfflinePlayer(storeOptions: any)
			local world = FakeEnvironment.new(1000)
			local adapter = newAdapter()
			local handler, contexts = newTestHandler()
			local service = startService(world, adapter, { handler }, storeOptions)

			local player = world.Join("Alice", 1)
			service:WaitForLoad(player)
			contexts[player].LeaderstatsAdapter:Set("Points", 40)
			world.Leave(player)
			waitUntil(function()
				return storedRecord(adapter, player).Lock == nil
			end, 2)

			return service, world, adapter, handler, player
		end

		-- Edited: the change is written, and the player loads it on the next join.
		do
			local service, world, adapter, handler, player = newOfflinePlayer(nil)

			local status = service:EditUnlocked(1, function(data)
				data[TEST_NAMESPACE].Points += 5
				return true
			end)

			t.Equal("An unlocked player is edited", status, "Edited")
			t.Equal("The edit is stored", storedRecord(adapter, player).Data[TEST_NAMESPACE].Points, 45)
			t.Check("An edit leaves the record unlocked", storedRecord(adapter, player).Lock == nil)

			local rejoined = world.Join("Alice", 1)
			service:WaitForLoad(rejoined)
			t.Equal("The player loads the edited data", service:Get(rejoined, handler), { Points = 45 })

			service:Destroy()
		end

		-- Rejected: returning false or throwing writes nothing, even after the function changed data.
		do
			local service, _, adapter, _, player = newOfflinePlayer(nil)

			local falseStatus = service:EditUnlocked(1, function(data)
				data[TEST_NAMESPACE].Points = 999
				return false
			end)
			t.Equal("Returning false is Rejected", falseStatus, "Rejected")
			t.Equal("A rejected edit writes nothing", storedRecord(adapter, player).Data[TEST_NAMESPACE].Points, 40)

			local throwStatus = service:EditUnlocked(1, function(_data)
				error("simulated edit failure")
			end)
			t.Equal("A throwing edit is Rejected", throwStatus, "Rejected")
			t.Equal("A throwing edit writes nothing", storedRecord(adapter, player).Data[TEST_NAMESPACE].Points, 40)

			service:Destroy()
		end

		-- Locked: a connected player is never edited, and the function is never called.
		do
			local world = FakeEnvironment.new(1000)
			local adapter = newAdapter()
			local handler = newTestHandler()
			local service = startService(world, adapter, { handler }, nil)

			local player = world.Join("Alice", 1)
			service:WaitForLoad(player)

			local calls = 0
			local status = service:EditUnlocked(1, function(_data)
				calls += 1
				return true
			end)

			t.Equal("A player in a server is Locked", status, "Locked")
			t.Equal("The edit function is not called for a locked player", calls, 0)
			t.Check("A locked player stays loaded", service:IsLoaded(player))

			service:Destroy()
		end

		-- Missing: no record is ever created for a player who has not played.
		do
			local world = FakeEnvironment.new(1000)
			local adapter = newAdapter()
			local handler = newTestHandler()
			local service = startService(world, adapter, { handler }, nil)

			local calls = 0
			local status = service:EditUnlocked(999, function(_data)
				calls += 1
				return true
			end)

			t.Equal("An unknown player is Missing", status, "Missing")
			t.Equal("The edit function is not called for a missing player", calls, 0)
			t.Check("No record is created for an unknown player", adapter:Peek(DataSchema.KeyFor(999)) == nil)

			service:Destroy()
		end

		-- TooNew: a record from a newer version is left alone.
		do
			local world = FakeEnvironment.new(1000)
			local adapter = newAdapter()
			local handler = newTestHandler()
			local service = startService(world, adapter, { handler }, nil)

			adapter:UpdateAsync(DataSchema.KeyFor(5), function()
				return {
					SchemaVersion = DataSchema.CURRENT_VERSION + 1,
					Lock = nil,
					Data = {},
					Meta = { CreatedAt = 1, LastSaved = 1 },
				}
			end)

			t.Equal(
				"A record from a newer version is TooNew",
				service:EditUnlocked(5, function(_data)
					return true
				end),
				"TooNew"
			)
			t.Equal(
				"A TooNew record is untouched",
				adapter:Peek(DataSchema.KeyFor(5)).SchemaVersion,
				DataSchema.CURRENT_VERSION + 1
			)

			service:Destroy()
		end

		-- Failed: a DataStore error is reported, and nothing is written.
		do
			local service, _, adapter, _, player = newOfflinePlayer({ MaxAttempts = 1 })

			adapter:FailNext(1)
			local status = service:EditUnlocked(1, function(data)
				data[TEST_NAMESPACE].Points = 999
				return true
			end)

			t.Equal("A DataStore failure is Failed", status, "Failed")
			t.Equal("A failed edit writes nothing", storedRecord(adapter, player).Data[TEST_NAMESPACE].Points, 40)

			service:Destroy()
		end

		-- Argument checks
		do
			local service = newOfflinePlayer(nil)

			t.Check("EditUnlocked asserts on a non-number userId", not pcall(function()
				service:EditUnlocked("1" :: any, function(_data)
					return true
				end)
			end))
			t.Check("EditUnlocked asserts on a non-function edit", not pcall(function()
				service:EditUnlocked(1, "nope" :: any)
			end))
			t.Check("EditUnlocked asserts before Start", not pcall(function()
				local unstarted = DataService.new()
				unstarted:EditUnlocked(1, function(_data)
					return true
				end)
			end))

			service:Destroy()
		end
	end

	-- Handler.Unload

	do
		-- Unload runs after the release, so the lock is already gone when it is called.
		do
			local world = FakeEnvironment.new(1000)
			local adapter = newAdapter()
			local handler = newTestHandler()
			local unloaded: { Player } = {}
			local lockClearedAtUnload: boolean? = nil

			handler.Unload = function(player: Player)
				table.insert(unloaded, player)
				lockClearedAtUnload = storedRecord(adapter, player).Lock == nil
			end

			local service = startService(world, adapter, { handler }, nil)
			local player = world.Join("Alice", 1)
			service:WaitForLoad(player)

			t.Equal("Unload is not called while the player is in the game", #unloaded, 0)

			world.Leave(player)
			t.Check(
				"Unload is called when the player leaves",
				waitUntil(function()
					return #unloaded >= 1
				end, 2)
			)
			t.Check("Unload receives the player who left", unloaded[1] == player)
			t.Equal("Unload runs after the release", lockClearedAtUnload, true)
			t.Equal("Unload is called exactly once", #unloaded, 1)

			service:Destroy()
		end

		-- A player who leaves while joining is still unloaded exactly once, and the abandoned join releases the lock.
		do
			local world = FakeEnvironment.new(1000)
			local adapter = newAdapter()
			local handler = newTestHandler()
			local unloaded: { Player } = {}

			handler.Unload = function(player: Player)
				table.insert(unloaded, player)
			end

			local service = startService(world, adapter, { handler }, nil)

			-- The hook fires once, during the first store call (the session claim).
			adapter:BeforeCommit(function()
				for _, joining in world.Environment.GetPlayers() do
					world.Leave(joining)
				end
			end)

			local player = world.Join("Alice", 1)
			t.Check(
				"A player who leaves mid-join is unloaded",
				waitUntil(function()
					return #unloaded >= 1
				end, 2)
			)
			t.Check(
				"The abandoned join releases the lock",
				waitUntil(function()
					return storedRecord(adapter, player).Lock == nil
				end, 2)
			)
			task.wait(0.3)
			t.Equal("A player who leaves mid-join is unloaded exactly once", #unloaded, 1)

			service:Destroy()
		end

		-- A throwing Unload (a warning in the output is expected) must not stop the release or the save.
		do
			local world = FakeEnvironment.new(1000)
			local adapter = newAdapter()
			local handler, contexts = newTestHandler()
			local attempts = 0

			handler.Unload = function(_player: Player)
				attempts += 1
				error("simulated Unload failure")
			end

			local logger, events = newRecordingLogger(world)
			local service = startService(world, adapter, { handler }, nil, logger)
			local player = world.Join("Alice", 1)
			service:WaitForLoad(player)
			contexts[player].LeaderstatsAdapter:Set("Points", 21)

			world.Leave(player)
			t.Check(
				"The release completes when Unload throws",
				waitUntil(function()
					return storedRecord(adapter, player).Lock == nil
				end, 2)
			)
			t.Equal(
				"The data is saved when Unload throws",
				storedRecord(adapter, player).Data[TEST_NAMESPACE].Points,
				21
			)
			t.Equal("A throwing Unload was still called", attempts, 1)
			local unloadEvent = eventWithCode(events, ErrorCodes.Codes.HandlerUnloadFailure)
			t.Check("A throwing Unload is logged", unloadEvent ~= nil)
			t.Check(
				"It is a Warning for the right namespace",
				unloadEvent ~= nil and unloadEvent.Severity == "Warning" and unloadEvent.Namespace == TEST_NAMESPACE
			)
			service:Destroy()
		end

		-- Destroy unloads every loaded player.
		do
			local world = FakeEnvironment.new(1000)
			local adapter = newAdapter()
			local handler = newTestHandler()
			local unloaded: { Player } = {}

			handler.Unload = function(player: Player)
				table.insert(unloaded, player)
			end

			local service = startService(world, adapter, { handler }, nil)
			local player = world.Join("Alice", 1)
			service:WaitForLoad(player)

			service:Destroy()
			t.Equal("Destroy unloads a loaded player", #unloaded, 1)
			t.Check("Destroy unloads the right player", unloaded[1] == player)
		end
	end
	return t.Summary()
end