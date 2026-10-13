--!strict
--@Splay

--[[
	ProductionFixture

	Shared setup for the production tests, which run the real DataService lifecycle
	(fake players, fake clock) against a REAL DataStore.

	Each run uses fresh UserIds, so leftovers from earlier runs in the test store
	can never leak into a new run. Negative ids can never belong to a real player.
]]

local ServerScriptService = game:GetService("ServerScriptService")

local PlayerData = ServerScriptService.PlayerData

local BaseUtil = require(PlayerData.Utils.BaseUtil)
local DataSchema = require(PlayerData.Config.DataSchema)
local DataService = require(PlayerData.Data.DataService)
local DataStoreAdapter = require(PlayerData.Adapters.DataStoreAdapter)
local FakeEnvironment = require(PlayerData.Tests.FakeEnvironment)
local StoreHandler = require(PlayerData.Data.StoreHandler)

export type Adapter = DataStoreAdapter.Adapter

export type TestData = {
	Points: number,
}

export type FailingAdapter = Adapter & {
	FailNext: (self: FailingAdapter, count: number) -> (),
	FailuresRemaining: (self: FailingAdapter) -> number,
}

local MAX_POINTS = 1_000_000
local MAX_SLOTS_PER_RUN = 99

local ProductionFixture = {}

ProductionFixture.Namespace = "ProductionTest"

-- Real stores retry with backoff, so waits need far more room than the mock tests use.
ProductionFixture.SettleTimeoutSeconds = 30

function ProductionFixture.NewAdapter(storeName: string): Adapter
	assert(type(storeName) == "string" and storeName ~= "", "ProductionFixture.NewAdapter: storeName must be a string")
	-- Production tests write real data, so they must never be able to target the real store.
	assert(
		storeName ~= DataSchema.STORE_NAME,
		"ProductionFixture.NewAdapter: refusing to run production tests against the real player store"
	)
	return DataStoreAdapter.new(storeName)
end

function ProductionFixture.NewRunId(): number
	return os.time() * 1000 + math.random(0, 999)
end

function ProductionFixture.UserIdFor(runId: number, slot: number): number
	assert(type(runId) == "number", "ProductionFixture.UserIdFor: runId must be a number")
	assert(
		type(slot) == "number" and slot >= 1 and slot <= MAX_SLOTS_PER_RUN and slot == math.floor(slot),
		"ProductionFixture.UserIdFor: slot must be a whole number from 1 to 99"
	)
	return -(runId * 100 + slot)
end

function ProductionFixture.WaitUntil(condition: () -> boolean, timeoutSeconds: number): boolean
	local deadline = os.clock() + timeoutSeconds
	while not condition() do
		if os.clock() >= deadline then
			return false
		end
		task.wait(0.25)
	end
	return true
end

function ProductionFixture.ReadRecord(adapter: Adapter, userId: number): any
	return adapter:GetAsync(DataSchema.KeyFor(userId))
end

function ProductionFixture.StoredPoints(adapter: Adapter, userId: number): number?
	local record: any = ProductionFixture.ReadRecord(adapter, userId)
	if record == nil or record.Data == nil or record.Data[ProductionFixture.Namespace] == nil then
		return nil
	end
	return record.Data[ProductionFixture.Namespace].Points
end

function ProductionFixture.IsReleased(adapter: Adapter, userId: number): boolean
	local record: any = ProductionFixture.ReadRecord(adapter, userId)
	return record ~= nil and record.Lock == nil
end

-- Same contract as Phase7's handler: ExampleHandler asserts a real Player, which fake players are not.
function ProductionFixture.NewHandler(storage: BaseUtil.StorageKind?): (DataService.Handler<TestData>, { [Player]: BaseUtil.Context })
	local contexts: { [Player]: BaseUtil.Context } = {}

	local handler: DataService.Handler<TestData> = {
		Namespace = ProductionFixture.Namespace,
		Storage = storage,
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

function ProductionFixture.StartService(
	world: FakeEnvironment.FakeWorld,
	adapter: Adapter,
	handler: DataService.Handler<TestData>,
	storeOptions: StoreHandler.Options?
): DataService.DataService
	local service = DataService.new(world.Environment)
	service:RegisterHandler(handler)
	service:Start(adapter, storeOptions)
	return service
end

local FailingAdapterMethods = {}
FailingAdapterMethods.__index = FailingAdapterMethods

local function consumeFailure(self: any): boolean
	if self._failuresRemaining > 0 then
		self._failuresRemaining -= 1
		return true
	end
	return false
end

function ProductionFixture.ReadSecondary(adapter: Adapter, userId: number): any
	return adapter:GetAsync(DataSchema.SecondaryKeyFor(userId, ProductionFixture.Namespace))
end

function FailingAdapterMethods.FailNext(self: any, count: number)
	assert(
		type(count) == "number" and count >= 0 and count == math.floor(count),
		"FailingAdapter:FailNext: count must be a whole number of at least 0"
	)
	self._failuresRemaining = count
end

function FailingAdapterMethods.FailuresRemaining(self: any): number
	return self._failuresRemaining
end

function FailingAdapterMethods.GetAsync(self: any, key: string): any
	if consumeFailure(self) then
		error("FailingAdapter: simulated GetAsync failure")
	end
	return self._inner:GetAsync(key)
end

function FailingAdapterMethods.UpdateAsync(self: any, key: string, transform: (any?) -> any?): any?
	if consumeFailure(self) then
		error("FailingAdapter: simulated UpdateAsync failure")
	end
	return self._inner:UpdateAsync(key, transform)
end

function FailingAdapterMethods.GetBudget(self: any): number
	return self._inner:GetBudget()
end

-- Forwards to a real adapter, but can fail the next N calls to simulate DataStore errors.
function ProductionFixture.NewFailingAdapter(inner: Adapter): FailingAdapter
	assert(type(inner) == "table", "ProductionFixture.NewFailingAdapter: inner must be an adapter")

	local self = setmetatable({
		_inner = inner,
		_failuresRemaining = 0,
	}, FailingAdapterMethods)

	return (self :: any) :: FailingAdapter
end

return ProductionFixture