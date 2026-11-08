--!strict
--@Splay

local ServerScriptService = game:GetService("ServerScriptService")

local DataSchema = require(ServerScriptService.PlayerData.Config.DataSchema)

type Entry = {
	Score: number,
	UpdatedAt: number,
}

export type Options = {
	Now: (() -> number)?,
	Threshold: number?,
	DecayPerSecond: number?,
}

type Fields = {
	_now: () -> number,
	_threshold: number,
	_decayPerSecond: number,
	_entries: { [number]: Entry },
}

local StrikeTracker = {}
StrikeTracker.__index = StrikeTracker

export type StrikeTracker = typeof(setmetatable({} :: Fields, StrikeTracker))

local function isFiniteNumber(value: unknown): boolean
	return type(value) == "number" and value == value and value > -math.huge and value < math.huge
end

--Studio test players have negative UserIds.
local function isWholeNumber(value: unknown): boolean
	return type(value) == "number"
		and value == value
		and value > -math.huge
		and value < math.huge
		and value == math.floor(value)
end

local function currentTime(): number
	return os.time()
end

local function decayedScore(self: StrikeTracker, entry: Entry, now: number): number
	-- A clock that steps backwards must not make time run in reverse and raise a score.
	local elapsedSeconds = math.max(0, now - entry.UpdatedAt)
	return math.max(0, entry.Score - elapsedSeconds * self._decayPerSecond)
end

function StrikeTracker.new(options: Options?): StrikeTracker
	assert(options == nil or type(options) == "table", "StrikeTracker.new: options must be a table when provided")

	local now = options and options.Now
	assert(now == nil or type(now) == "function", "StrikeTracker.new: Now must be a function")

	local threshold = (options and options.Threshold) or DataSchema.Security.StrikeThreshold
	assert(isFiniteNumber(threshold) and threshold > 0, "StrikeTracker.new: Threshold must be a finite number above 0")

	local decayPerSecond = (options and options.DecayPerSecond) or DataSchema.Security.StrikeDecayPerSecond
	assert(
		isFiniteNumber(decayPerSecond) and decayPerSecond >= 0,
		"StrikeTracker.new: DecayPerSecond must be a finite number of at least 0"
	)

	return setmetatable({
		_now = now or currentTime,
		_threshold = threshold,
		_decayPerSecond = decayPerSecond,
		_entries = {} :: { [number]: Entry },
	}, StrikeTracker)
end

-- Returns the score after adding. A weight of 0 just reads the current score.
function StrikeTracker.Add(self: StrikeTracker, userId: number, weight: number): number
	assert(isWholeNumber(userId), "StrikeTracker:Add: userId must be a whole number")
	assert(isFiniteNumber(weight) and weight >= 0, "StrikeTracker:Add: weight must be a finite number of at least 0")

	local now = self._now()
	local entry = self._entries[userId]
	local score = (if entry ~= nil then decayedScore(self, entry, now) else 0) + weight

	if score <= 0 then
		self._entries[userId] = nil
		return 0
	end

	self._entries[userId] = { Score = score, UpdatedAt = now }
	return score
end

function StrikeTracker.Score(self: StrikeTracker, userId: number): number
	assert(isWholeNumber(userId), "StrikeTracker:Score: userId must be a whole number")

	local entry = self._entries[userId]
	if entry == nil then
		return 0
	end

	local score = decayedScore(self, entry, self._now())
	if score <= 0 then
		self._entries[userId] = nil
	end
	return score
end

function StrikeTracker.IsOverThreshold(self: StrikeTracker, userId: number): boolean
	return self:Score(userId) >= self._threshold
end

function StrikeTracker.Clear(self: StrikeTracker, userId: number)
	assert(isWholeNumber(userId), "StrikeTracker:Clear: userId must be a whole number")
	self._entries[userId] = nil
end

return StrikeTracker