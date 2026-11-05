--!strict
--@Splay

--[[
	WebhookSink

	Posts Error and DataLoss incidents to a webhook (for example a Discord channel). Best effort: an
	incident that cannot be posted is dropped, and it is still in the Output log.

	Attach it with the floor from ErrorLogConfig:
		logger:AddSink(function(event) sink:Write(event) end, config.Sinks.Webhook)
]]

local HttpService = game:GetService("HttpService")
local ServerScriptService = game:GetService("ServerScriptService")

local DataSchema = require(ServerScriptService.PlayerData.Config.DataSchema)
local EmbedFormatter = require(ServerScriptService.PlayerData.Integration.Discord.EmbedFormatter)
local Logger = require(ServerScriptService.PlayerData.Utils.Logger)

local SECONDS_PER_MINUTE = 60
-- How long a shutdown flush waits for a step that is already in flight before giving up.
local FINAL_WAIT_SECONDS = 5

type QueueEntry = {
	Event: Logger.Event,
	Attempts: number,
}

export type Poster = (url: string, body: string) -> boolean
export type Formatter = (event: Logger.Event) -> { [string]: unknown }

export type Options = {
	Now: (() -> number)?,
	Poster: Poster?,
	Format: Formatter?,
	QueueCapacity: number?,
	MaxPostsPerMinute: number?,
	MaxAttempts: number?,
	FinalFlushMaxPosts: number?,
}

export type WebhookSink = {
	Write: (self: WebhookSink, event: Logger.Event) -> (),
	Step: (self: WebhookSink, isFinal: boolean?) -> number,
	PendingCount: (self: WebhookSink) -> number,
	DroppedCount: (self: WebhookSink) -> number,
}

type Private = WebhookSink & {
	_url: string,
	_poster: Poster,
	_format: Formatter,
	_now: () -> number,
	_queueCapacity: number,
	_maxPostsPerMinute: number,
	_maxAttempts: number,
	_finalFlushMaxPosts: number,
	_queue: { QueueEntry },
	_postTimes: { number },
	_dropped: number,
	_stepping: boolean,
}

local WebhookSink = {}
WebhookSink.__index = WebhookSink

local function defaultPoster(url: string, body: string): boolean
	local ok, response = pcall(function(): any
		return HttpService:RequestAsync({
			Url = url,
			Method = "POST",
			Headers = { ["Content-Type"] = "application/json" },
			Body = body,
		})
	end)
	return ok and response.Success == true
end

local function isPositiveWholeNumber(value: unknown): boolean
	return type(value) == "number" and value >= 1 and value == math.floor(value) and value < math.huge
end

local function pickSetting(override: number?, fallback: number, name: string): number
	local value = override or fallback
	assert(isPositiveWholeNumber(value), ("WebhookSink.new: %s must be a whole number of at least 1"):format(name))
	return value
end

function WebhookSink.new(url: string, options: Options?): WebhookSink
	assert(
		type(url) == "string" and string.sub(url, 1, 8) == "https://",
		"WebhookSink.new: url must be an https:// URL"
	)
	assert(options == nil or type(options) == "table", "WebhookSink.new: options must be a table when provided")
	assert(
		options == nil or options.Now == nil or type(options.Now) == "function",
		"WebhookSink.new: Now must be a function"
	)
	assert(
		options == nil or options.Poster == nil or type(options.Poster) == "function",
		"WebhookSink.new: Poster must be a function"
	)
	assert(
		options == nil or options.Format == nil or type(options.Format) == "function",
		"WebhookSink.new: Format must be a function"
	)

	local settings = DataSchema.IncidentWebhook

	local self = setmetatable({
		_url = url,
		_poster = (options and options.Poster) or defaultPoster,
		_format = (options and options.Format) or EmbedFormatter.Format,
		_now = (options and options.Now) or os.time,
		_queueCapacity = pickSetting(options and options.QueueCapacity, settings.QueueCapacity, "QueueCapacity"),
		_maxPostsPerMinute = pickSetting(
			options and options.MaxPostsPerMinute,
			settings.MaxPostsPerMinute,
			"MaxPostsPerMinute"
		),
		_maxAttempts = pickSetting(options and options.MaxAttempts, settings.MaxAttempts, "MaxAttempts"),
		_finalFlushMaxPosts = pickSetting(
			options and options.FinalFlushMaxPosts,
			settings.FinalFlushMaxPosts,
			"FinalFlushMaxPosts"
		),
		_queue = {},
		_postTimes = {},
		_dropped = 0,
		_stepping = false,
	}, WebhookSink)

	return (self :: any) :: WebhookSink
end

-- DataLoss is the last thing to be thrown away, because it is the reason the sink exists.
local function makeRoom(self: Private, incoming: Logger.Event): boolean
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

function WebhookSink.Write(self: Private, event: Logger.Event)
	assert(type(event) == "table", "WebhookSink:Write: event must be a table")

	if makeRoom(self, event) then
		table.insert(self._queue, { Event = event, Attempts = 0 })
	end
end

local function canPostNow(self: Private): boolean
	local now = self._now()
	while #self._postTimes > 0 and now - self._postTimes[1] >= SECONDS_PER_MINUTE do
		table.remove(self._postTimes, 1)
	end
	return #self._postTimes < self._maxPostsPerMinute
end

-- Nil means the event cannot be turned into JSON, which no retry will fix.
local function encode(self: Private, event: Logger.Event): string?
	local ok, body = pcall(function(): string
		return HttpService:JSONEncode(self._format(event))
	end)
	if not ok then
		return nil
	end
	return body
end

local function sendQueued(self: Private, isFinal: boolean): number
	local sent = 0
	local limit = if isFinal then self._finalFlushMaxPosts else math.huge

	while #self._queue > 0 and sent < limit and (isFinal or canPostNow(self)) do
		local entry = self._queue[1]
		local body = encode(self, entry.Event)

		if body == nil then
			table.remove(self._queue, 1)
			self._dropped += 1
			continue
		end

		-- Failed attempts count too, so a broken relay is not hammered.
		table.insert(self._postTimes, self._now())

		-- A Poster must not throw, but a bad one must not wedge the queue either.
		local posted = select(2, pcall(self._poster, self._url, body)) == true
		if posted then
			table.remove(self._queue, 1)
			sent += 1
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

	return sent
end

-- Posts as many queued events as the rate cap allows. Yields. Returns how many were posted.
function WebhookSink.Step(self: Private, isFinal: boolean?): number
	local final = isFinal == true

	if self._stepping then
		if not final then
			return 0
		end

		local deadline = os.clock() + FINAL_WAIT_SECONDS
		while self._stepping and os.clock() < deadline do
			task.wait(0.1)
		end
		if self._stepping then
			return 0
		end
	end

	self._stepping = true
	local ok, sentOrError = pcall(sendQueued, self, final)
	self._stepping = false

	if not ok then
		error(sentOrError, 0)
	end
	return sentOrError
end

function WebhookSink.PendingCount(self: Private): number
	return #self._queue
end

function WebhookSink.DroppedCount(self: Private): number
	return self._dropped
end

return WebhookSink