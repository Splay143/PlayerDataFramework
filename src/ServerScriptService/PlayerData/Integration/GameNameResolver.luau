--!strict
--@Splay

local MarketplaceService = game:GetService("MarketplaceService")

export type Fetcher = (placeId: number) -> string?

export type Options = {
	Fetch: Fetcher?,
	Wait: ((seconds: number) -> ())?,
	MaxAttempts: number?,
	RetrySeconds: number?,
}

type Fields = {
	_placeId: number,
	_fetch: Fetcher,
	_wait: (seconds: number) -> (),
	_maxAttempts: number,
	_retrySeconds: number,
	_name: string?,
	_started: boolean,
}

local DEFAULT_MAX_ATTEMPTS = 3
local DEFAULT_RETRY_SECONDS = 5
-- Roblox caps names at 50 characters
local MAX_NAME_BYTES = 200

local GameNameResolver = {}
GameNameResolver.__index = GameNameResolver

export type GameNameResolver = typeof(setmetatable({} :: Fields, GameNameResolver))

local function defaultFetch(placeId: number): string?
	local info = MarketplaceService:GetProductInfo(placeId)
	local name: unknown = info.Name
	if type(name) == "string" then
		return name
	end
	return nil
end

local function waitSeconds(seconds: number)
	task.wait(seconds)
end

local function cleanName(value: unknown): string?
	if type(value) ~= "string" or value == "" or #value > MAX_NAME_BYTES then
		return nil
	end
	return value
end

local function isWholeNumber(value: unknown, minimum: number): boolean
	return type(value) == "number" and value == math.floor(value) and value >= minimum and value < math.huge
end

function GameNameResolver.new(placeId: number, options: Options?): GameNameResolver
	assert(isWholeNumber(placeId, 0), "GameNameResolver.new: placeId must be a whole number of at least 0")
	assert(options == nil or type(options) == "table", "GameNameResolver.new: options must be a table when provided")

	local maxAttempts = (options and options.MaxAttempts) or DEFAULT_MAX_ATTEMPTS
	assert(isWholeNumber(maxAttempts, 1), "GameNameResolver.new: MaxAttempts must be a whole number of at least 1")

	local retrySeconds = (options and options.RetrySeconds) or DEFAULT_RETRY_SECONDS
	assert(
		type(retrySeconds) == "number" and retrySeconds >= 0,
		"GameNameResolver.new: RetrySeconds must be at least 0"
	)

	return setmetatable({
		_placeId = placeId,
		_fetch = (options and options.Fetch) or defaultFetch,
		_wait = (options and options.Wait) or waitSeconds,
		_maxAttempts = maxAttempts,
		_retrySeconds = retrySeconds,
		_name = nil :: string?,
		_started = false,
	}, GameNameResolver)
end

function GameNameResolver.Start(self: GameNameResolver)
	assert(not self._started, "GameNameResolver:Start: already started")
	self._started = true

	-- An unpublished place (id 0, as in Studio) has no name to look up.
	if self._placeId == 0 then
		return
	end

	task.spawn(function()
		for attempt = 1, self._maxAttempts do
			local fetched, result = pcall(self._fetch, self._placeId)
			local name = if fetched then cleanName(result) else nil

			if name ~= nil then
				self._name = name
				return
			end

			if attempt < self._maxAttempts then
				self._wait(self._retrySeconds)
			end
		end
	end)
end

function GameNameResolver.Get(self: GameNameResolver): string?
	return self._name
end

return GameNameResolver