--!strict
--@Splay

--[[
	DataStoreSink

	Keeps Error and DataLoss incidents after the server closes, one key per incident, so an incident id from a
	kick message or ban reason can be looked up later.

	Write() only queues. Step() does the DataStore calls, and the owner decides when to call it. The sink is
	low priority on purpose: it is capped per minute and waits while the request budget is low, so it can never
	starve player saves.

	Attach it with the floor from ErrorLogConfig:
		logger:AddSink(function(event) sink:Write(event) end, config.Sinks.DataStore)
]]

local ServerScriptService = game:GetService("ServerScriptService")

local DataSchema = require(ServerScriptService.PlayerData.Config.DataSchema)
local Logger = require(ServerScriptService.PlayerData.Utils.Logger)
local DataStoreAdapter = require(ServerScriptService.PlayerData.Adapters.DataStoreAdapter)

local SECONDS_PER_MINUTE = 60


type QueueEntry = {
	Event: Logger.Event,
	Attempts: number,
}

export type Adapter = DataStoreAdapter.Adapter

export type Options = {
	Now: (() -> number)?,
	QueueCapacity: number?,
	MaxWritesPerMinute: number?,
	BudgetReserve: number?,
	MaxAttempts: number?,
	FinalFlushMaxWrites: number?,
}

export type DataStoreSink = {
	Write: (self: DataStoreSink, event: Logger.Event) -> (),
	Step: (self: DataStoreSink, isFinal: boolean?) -> number,
	PendingCount: (self: DataStoreSink) -> number,
	DroppedCount: (self: DataStoreSink) -> number,
	

	_adapter: Adapter,
	_now: () -> number,
	_queueCapacity: number,
	_maxWritesPerMinute: number,
	_budgetReserve: number,
	_maxAttempts: number,
	_queue: { QueueEntry },
	_writeTimes: { number },
	_dropped: number,
	_finalFlushMaxWrites: number,
}

local DataStoreSink = {}
DataStoreSink.__index = DataStoreSink

local function isPositiveWholeNumber(value: unknown): boolean
	return type(value) == "number" and value >= 1 and value == math.floor(value) and value < math.huge
end

local function pickSetting(override: number?, fallback: number, name: string): number
	local value = override or fallback
	assert(isPositiveWholeNumber(value), ("DataStoreSink.new: %s must be a whole number of at least 1"):format(name))
	return value
end

function DataStoreSink.new(adapter: Adapter, options: Options?): DataStoreSink
	assert(
		type(adapter) == "table" and type(adapter.UpdateAsync) == "function",
		"DataStoreSink.new: adapter must have an UpdateAsync method"
	)
	assert(options == nil or type(options) == "table", "DataStoreSink.new: options must be a table when provided")
	assert(
		options == nil or options.Now == nil or type(options.Now) == "function",
		"DataStoreSink.new: Now must be a function"
	)

	local settings = DataSchema.IncidentStore
	assert(
		#settings.KeyPrefix > 0 and #settings.KeyPrefix <= 14,
		"DataStoreSink.new: KeyPrefix must be 1 to 14 characters, so prefix and a 36 character id fit in 50"
	)

	local self = setmetatable({
		_adapter = adapter,
		_now = (options and options.Now) or os.time,
		_queueCapacity = pickSetting(options and options.QueueCapacity, settings.QueueCapacity, "QueueCapacity"),
		_maxWritesPerMinute = pickSetting(
			options and options.MaxWritesPerMinute,
			settings.MaxWritesPerMinute,
			"MaxWritesPerMinute"
		),
		_budgetReserve = pickSetting(options and options.BudgetReserve, settings.BudgetReserve, "BudgetReserve"),
		_maxAttempts = pickSetting(options and options.MaxAttempts, settings.MaxAttempts, "MaxAttempts"),
		_finalFlushMaxWrites = pickSetting(
			options and options.FinalFlushMaxWrites,
			settings.FinalFlushMaxWrites,
			"FinalFlushMaxWrites"
		),
		_queue = {},
		_writeTimes = {},
		_dropped = 0,
	}, DataStoreSink)

	return (self :: any) :: DataStoreSink
end

-- DataLoss is the last thing to be thrown away, because it is the reason the sink exists.
local function makeRoom(self: DataStoreSink, incoming: Logger.Event): boolean
	if #self._queue < self._queueCapacity then
		return true
	end

	for index, entry in self._queue do
		if entry.Event.Severity ~= "DataLoss" then
			table.remove(self._queue, index)
			self._dropped += 1
			return true
		end
	end

	-- The queue is all DataLoss: a new DataLoss replaces the oldest, anything lower is not kept.
	self._dropped += 1
	if incoming.Severity == "DataLoss" then
		table.remove(self._queue, 1)
		return true
	end
	return false
end

function DataStoreSink.Write(self: DataStoreSink, event: Logger.Event)
	assert(type(event) == "table", "DataStoreSink:Write: event must be a table")

	if makeRoom(self, event) then
		table.insert(self._queue, { Event = event, Attempts = 0 })
	end
end

local function canWriteNow(self: DataStoreSink): boolean
	local now = self._now()
	while #self._writeTimes > 0 and now - self._writeTimes[1] >= SECONDS_PER_MINUTE do
		table.remove(self._writeTimes, 1)
	end
	if #self._writeTimes >= self._maxWritesPerMinute then
		return false
	end

	-- Saves share this budget, so incident writes only use what is left above the reserve.
	local adapter = self._adapter
	local getBudget = adapter.GetBudget
	if getBudget ~= nil then
		return getBudget(adapter) >= self._budgetReserve
	end
	return true
end

local function storeEvent(self: DataStoreSink, event: Logger.Event): boolean
	local key = DataSchema.IncidentStore.KeyPrefix .. event.Id

	return (pcall(function(): any?
		return self._adapter:UpdateAsync(key, function(current: any?): any?
			-- Already stored, for example when an earlier attempt succeeded but its reply was lost.
			if current ~= nil then
				return nil
			end
			return event
		end)
	end))
end

-- Writes as many queued events as the rate cap and budget allow. Returns how many were stored.
function DataStoreSink.Step(self: DataStoreSink, isFinal: boolean?): number
	local written = 0
	local limit = if isFinal == true then self._finalFlushMaxWrites else math.huge

	while #self._queue > 0 and written < limit and (isFinal == true or canWriteNow(self)) do
		local entry = self._queue[1]

		-- Failed attempts count too, so a broken store is not hammered.
		table.insert(self._writeTimes, self._now())

		if storeEvent(self, entry.Event) then
			table.remove(self._queue, 1)
			written += 1
		else
			entry.Attempts += 1
			if entry.Attempts >= self._maxAttempts then
				table.remove(self._queue, 1)
				self._dropped += 1
			else
				-- Try again on the next step instead of retrying in a tight loop.
				break
			end
		end
	end

	return written
end

function DataStoreSink.PendingCount(self: DataStoreSink): number
	return #self._queue
end

function DataStoreSink.DroppedCount(self: DataStoreSink): number
	return self._dropped
end

return DataStoreSink