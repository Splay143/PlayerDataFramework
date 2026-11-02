--!strict
--@Splay

--[[
	Logger

	Turns a described incident into one structured event, decides whether to record it,
	keeps the newest recorded events in a ring buffer, and hands each one to its sinks.

	Every event is counted first. Then it is dropped, held for a summary, or delivered,
	following the ErrorLogConfig. DataLoss events are always delivered.

	Spam caps: a player, and the serve as a whole. can only have so many events delivered
	per minute. An event over the cap is not lost. It is merged into the summary for its code.
	DataLoss events are never capped, and never use up capacity.

	Pure: the clock, the id generator, the random source and the server context are
	injected, so tests need no real time and no Roblox services.

	Sinks must not yield. A sink that needs slow work (DataStore, HTTP) queues it and
	returns at once. A throwing sink is caught, so logging can never break the data system.

	Held summaries are delivered by FlushSummaries (also called at the start of every Log).
	Something must call it on a timer, and with force = true at shutdown.
]]

local ServerScriptService = game:GetService("ServerScriptService")

local ErrorCodes = require(ServerScriptService.PlayerData.Config.ErrorCodes)
local ErrorLogConfig = require(ServerScriptService.PlayerData.Config.ErrorLogConfig)

export type Severity = ErrorLogConfig.Severity
export type Fault = "Developer" | "Framework" | "Platform" | "Unknown"
export type Stage = "Join" | "Load" | "Save" | "Release" | "Shutdown" | "Request" | "Replication"

export type Context = {
	JobId: string,
	PlaceId: number,
	FrameworkVersion: string,
}

export type EventInput = {
	Code: number,
	Severity: Severity,
	Fault: Fault,
	Stage: Stage,
	Message: string,
	UserId: number?,
	SessionId: string?,
	Namespace: string?,
	Kicked: boolean?,
	DataLossLikely: boolean?,
	Detail: string?,
}

-- Count, FirstTimestamp and LastTimestamp are only set on a summary event.
export type Event = {
	Id: string,
	Code: number,
	Name: string,
	Severity: Severity,
	Fault: Fault,
	UserId: number?,
	SessionId: string?,
	JobId: string,
	PlaceId: number,
	FrameworkVersion: string,
	Timestamp: number,
	Stage: Stage,
	Namespace: string?,
	Kicked: boolean,
	DataLossLikely: boolean,
	Message: string,
	Detail: string?,
	Count: number?,
	FirstTimestamp: number?,
	LastTimestamp: number?,
}

export type Sink = (event: Event) -> ()

export type Options = {
	Now: (() -> number)?,
	GenerateId: (() -> string)?,
	Random: (() -> number)?,
	BufferSize: number?,
	Context: Context?,
	Config: ErrorLogConfig.Resolved?,
}

export type Logger = {
	Log: (self: Logger, input: EventInput) -> Event,
	AddSink: (self: Logger, sink: Sink, minSeverity: Severity?) -> (),
	Recent: (self: Logger) -> { Event },
	Counts: (self: Logger) -> { [number]: number },
	FlushSummaries: (self: Logger, force: boolean?) -> (),
}

type SinkEntry = {
	Callback: Sink,
	MinRank: number,
}

type Summary = {
	First: Event,
	Count: number,
	FirstAt: number,
	LastAt: number,
	DueAt: number,
}

type Window = {
	StartedAt: number,
	Count: number,
}

type Decision = "Drop" | "Summarise" | "Deliver"

type Private = Logger & {
	_now: () -> number,
	_generateId: () -> string,
	_random: () -> number,
	_config: ErrorLogConfig.Resolved,
	_context: Context,
	_capacity: number,
	_buffer: { Event },
	_nextIndex: number,
	_count: number,
	_sinks: { SinkEntry },
	_warnedSinks: { [number]: boolean },
	_counts: { [number]: number },
	_summaries: { [number]: Summary },
	_serverWindow: Window,
	_playerWindows: { [number]: Window },
	_lastPruneAt: number,
}

const DEFAULT_BUFFER_SIZE = 100
const WINDOW_SECONDS = 60

local SEVERITY_RANK = ErrorLogConfig.SeverityRank
local FAULTS: { [string]: boolean } = { Developer = true, Framework = true, Platform = true, Unknown = true }
local STAGES: { [string]: boolean } = {
	Join = true,
	Load = true,
	Save = true,
	Release = true,
	Shutdown = true,
	Request = true,
	Replication = true,
}

local Logger = {}
Logger.__index = Logger

Logger.MaxDetailLength = 500

local function defaultGenerateId(): string
	local HttpService = game:GetService("HttpService")
	return HttpService:GenerateGUID(false)
end

function Logger.new(options: Options?): Logger
	local now: () -> number = (options and options.Now) or os.time
	local generateId: () -> string = (options and options.GenerateId) or defaultGenerateId
	local random: () -> number = (options and options.Random) or function(): number
		return math.random()
	end
	local capacity: number = (options and options.BufferSize) or DEFAULT_BUFFER_SIZE
	local context: Context = (options and options.Context)
		or { JobId = game.JobId, PlaceId = game.PlaceId, FrameworkVersion = "unknown" }
	local config: ErrorLogConfig.Resolved = (options and options.Config) or ErrorLogConfig.Resolve(nil)

	assert(type(now) == "function", "Logger.new: Now must be a function")
	assert(type(generateId) == "function", "Logger.new: GenerateId must be a function")
	assert(type(random) == "function", "Logger.new: Random must be a function")
	assert(type(config) == "table", "Logger.new: Config must be a resolved ErrorLogConfig")
	assert(
		type(capacity) == "number" and capacity >= 1 and capacity == math.floor(capacity),
		"Logger.new: BufferSize must be a whole number of at least 1"
	)
	assert(type(context.JobId) == "string", "Logger.new: Context.JobId must be a string")
	assert(type(context.PlaceId) == "number", "Logger.new: Context.PlaceId must be a number")
	assert(type(context.FrameworkVersion) == "string", "Logger.new: Context.FrameworkVersion must be a string")

	local self = setmetatable({
		_now = now,
		_generateId = generateId,
		_random = random,
		_config = config,
		_context = table.freeze(table.clone(context)),
		_capacity = capacity,
		_buffer = {},
		_nextIndex = 1,
		_count = 0,
		_sinks = {},
		_warnedSinks = {},
		_counts = {},
		_summaries = {},
		_serverWindow = { StartedAt = now(), Count = 0 },
		_playerWindows = {},
		_lastPruneAt = now(),
	}, Logger)

	return (self :: unknown) :: Logger
end

function Logger.AddSink(self: Private, sink: Sink, minSeverity: Severity?)
	assert(type(sink) == "function", "Logger:AddSink: sink must be a function")
	assert(
		minSeverity == nil or SEVERITY_RANK[minSeverity] ~= nil,
		"Logger:AddSink: unknown severity " .. tostring(minSeverity)
	)

	table.insert(self._sinks, {
		Callback = sink,
		MinRank = if minSeverity ~= nil then SEVERITY_RANK[minSeverity] else 1,
	})
end

-- The buffer is written before the sinks, so a bad sink can never cost us the event.
local function deliver(self: Private, event: Event)
	self._buffer[self._nextIndex] = event
	self._nextIndex = self._nextIndex % self._capacity + 1
	self._count = math.min(self._count + 1, self._capacity)

	local rank = SEVERITY_RANK[event.Severity]
	for index, entry in self._sinks do
		if rank < entry.MinRank then
			continue
		end

		local ok, sinkError = pcall(function(): string?
			entry.Callback(event)
			return nil
		end)
		if not ok and not self._warnedSinks[index] then
			self._warnedSinks[index] = true
			warn(
				("Logger: sink %d errored, further failures from it are not reported: %s"):format(
					index,
					tostring(sinkError)
				)
			)
		end
	end
end

-- A code rule wins over its category.
local function isEnabled(config: ErrorLogConfig.Resolved, code: number, rule: ErrorLogConfig.CodeRule?): boolean
	if rule ~= nil and rule.Enabled ~= nil then
		return rule.Enabled
	end
	return config.Categories[code // 100] ~= false
end

-- A code rule wins over the preset.
local function shouldSummarise(config: ErrorLogConfig.Resolved, rule: ErrorLogConfig.CodeRule?, event: Event): boolean
	if rule ~= nil and rule.Summarise ~= nil then
		return rule.Summarise
	end
	if event.Kicked and config.SummariseKicks then
		return true
	end
	return event.Severity == "Warning" and config.SummariseWarnings
end

local function decide(self: Private, event: Event, rule: ErrorLogConfig.CodeRule?): Decision
	local config = self._config

	if event.Severity == "DataLoss" then
		return "Deliver"
	end
	if SEVERITY_RANK[event.Severity] < SEVERITY_RANK[config.MinSeverity] then
		return "Drop"
	end
	if not isEnabled(config, event.Code, rule) then
		return "Drop"
	end
	if rule ~= nil and rule.Sample ~= nil and self._random() >= rule.Sample then
		return "Drop"
	end
	if shouldSummarise(config, rule, event) then
		return "Summarise"
	end
	return "Deliver"
end

local function refreshWindow(window: Window, nowSeconds: number)
	if nowSeconds - window.StartedAt >= WINDOW_SECONDS then
		window.StartedAt = nowSeconds
		window.Count = 0
	end
end

local function playerWindowFor(self: Private, userId: number, nowSeconds: number): Window
	local existingWindow = self._playerWindows[userId]
	if existingWindow ~= nil then
		refreshWindow(existingWindow, nowSeconds)
		return existingWindow
	end

	local newWindow: Window = { StartedAt = nowSeconds, Count = 0 }
	self._playerWindows[userId] = newWindow
	return newWindow
end

-- Takes one slot from the server window and the player's window, or none at all.
-- Both are checked before either is used, so a player over their own cap cannot
-- use up the capacity the rest of the server needs.
local function takeCapacity(self: Private, event: Event): boolean
	local config = self._config
	local nowSeconds = event.Timestamp

	local serverWindow = self._serverWindow
	refreshWindow(serverWindow, nowSeconds)
	if serverWindow.Count >= config.MaxEventsPerServerPerMinute then
		return false
	end

	-- An event with no player (a server-wide problem) only counts against the server cap.
	local playerWindow: Window? = nil
	if event.UserId ~= nil then
		local window = playerWindowFor(self, event.UserId, nowSeconds)
		if window.Count >= config.MaxEventsPerPlayerPerMinute then
			return false
		end
		playerWindow = window
	end

	serverWindow.Count += 1
	if playerWindow ~= nil then
		playerWindow.Count += 1
	end
	return true
end

-- Players who have left would otherwise stay in the table forever. Runs at most once a window.
local function prunePlayerWindows(self: Private, nowSeconds: number)
	if nowSeconds - self._lastPruneAt < WINDOW_SECONDS then
		return
	end
	self._lastPruneAt = nowSeconds

	for userId, window in self._playerWindows do
		if nowSeconds - window.StartedAt >= WINDOW_SECONDS then
			self._playerWindows[userId] = nil
		end
	end
end

local function addToSummary(self: Private, event: Event, rule: ErrorLogConfig.CodeRule?)
	local summary: Summary? = self._summaries[event.Code]
	if summary ~= nil then
		summary.Count += 1
		summary.LastAt = event.Timestamp
		return
	end

	local interval = (rule and rule.SummaryIntervalSeconds) or self._config.SummaryIntervalSeconds
	self._summaries[event.Code] = {
		First = event,
		Count = 1,
		FirstAt = event.Timestamp,
		LastAt = event.Timestamp,
		DueAt = event.Timestamp + interval,
	}
end

-- Built from the first event of the window. Per-event details (user, session, detail) are dropped.
local function summaryEvent(self: Private, summary: Summary, nowSeconds: number): Event
	local first = summary.First
	return table.freeze({
		Id = self._generateId(),
		Code = first.Code,
		Name = first.Name,
		Severity = first.Severity,
		Fault = first.Fault,
		JobId = first.JobId,
		PlaceId = first.PlaceId,
		FrameworkVersion = first.FrameworkVersion,
		Timestamp = nowSeconds,
		Stage = first.Stage,
		Kicked = first.Kicked,
		DataLossLikely = false,
		Message = ("%d occurrences, first: %s"):format(summary.Count, first.Message),
		Count = summary.Count,
		FirstTimestamp = summary.FirstAt,
		LastTimestamp = summary.LastAt,
	})
end

function Logger.FlushSummaries(self: Private, force: boolean?)
	local nowSeconds = self._now()
	prunePlayerWindows(self, nowSeconds)

	for code, summary in self._summaries do
		if force == true or nowSeconds >= summary.DueAt then
			self._summaries[code] = nil
			deliver(self, summaryEvent(self, summary, nowSeconds))
		end
	end
end

function Logger.Log(self: Private, input: EventInput): Event
	assert(type(input) == "table", "Logger:Log: input must be a table")
	assert(ErrorCodes.IsKnown(input.Code), "Logger:Log: unknown error code " .. tostring(input.Code))
	assert(SEVERITY_RANK[input.Severity] ~= nil, "Logger:Log: unknown severity " .. tostring(input.Severity))
	assert(FAULTS[input.Fault], "Logger:Log: unknown fault " .. tostring(input.Fault))
	assert(STAGES[input.Stage], "Logger:Log: unknown stage " .. tostring(input.Stage))
	assert(type(input.Message) == "string" and input.Message ~= "", "Logger:Log: Message must be a non-empty string")

	self._counts[input.Code] = (self._counts[input.Code] or 0) + 1
	self:FlushSummaries(false)

	local rule: ErrorLogConfig.CodeRule? = self._config.Codes[input.Code]

	local severity: Severity = input.Severity
	if rule ~= nil and rule.Severity ~= nil and severity ~= "DataLoss" then
		severity = rule.Severity
	end

	local detail = input.Detail
	if detail ~= nil and #detail > Logger.MaxDetailLength then
		detail = string.sub(detail, 1, Logger.MaxDetailLength)
	end

	local event: Event = {
		Id = self._generateId(),
		Code = input.Code,
		Name = ErrorCodes.NameOf(input.Code),
		Severity = severity,
		Fault = input.Fault,
		UserId = input.UserId,
		SessionId = input.SessionId,
		JobId = self._context.JobId,
		PlaceId = self._context.PlaceId,
		FrameworkVersion = self._context.FrameworkVersion,
		Timestamp = self._now(),
		Stage = input.Stage,
		Namespace = input.Namespace,
		Kicked = input.Kicked == true,
		DataLossLikely = input.DataLossLikely == true,
		Message = input.Message,
		Detail = detail,
	}
	table.freeze(event)

	local decision = decide(self, event, rule)
	if decision == "Deliver" and event.Severity ~= "DataLoss" and not takeCapacity(self, event) then
		decision = "Summarise"
	end
	
	if decision == "Deliver" then
		deliver(self, event)
	elseif decision == "Summarise" then
		addToSummary(self, event, rule)
	end

	return event
end

-- Oldest first. Once the buffer is full, _nextIndex points at the oldest event.
function Logger.Recent(self: Private): { Event }
	local events: { Event } = {}
	local start = if self._count < self._capacity then 1 else self._nextIndex

	for offset = 0, self._count - 1 do
		local index = (start - 1 + offset) % self._capacity + 1
		table.insert(events, self._buffer[index])
	end

	return events
end

function Logger.Counts(self: Private): { [number]: number }
	return table.clone(self._counts)
end

return Logger
