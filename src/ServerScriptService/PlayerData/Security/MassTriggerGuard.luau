--!strict
--@Splay

local ServerScriptService = game:GetService("ServerScriptService")

local DataSchema = require(ServerScriptService.PlayerData.Config.DataSchema)

type Entry = {
    Players: { [ number]: number },
    LastSeen: number,
}

export type Options = {
    Now: (() -> number)?,
    MinPlayers: number?,
    WindowSeconds: number?,
    MaxKeys: number?,
}

type Fields = {
    _now: () -> number,
    _minPlayers: number,
    _windowSeconds: number,
    _maxKeys: number,
    _entries: { [string]: Entry },
    _keyCount: number,
}

local DEFAULT_MAX_KEYS = 200

local MassTriggerGuard = {}
MassTriggerGuard.__index = MassTriggerGuard

export type MassTriggerGuard = typeof(setmetatable({} :: Fields, MassTriggerGuard))

local function isWholeNumber(value: number): boolean
    return value == value and value > -math.huge and value < math.huge and value == math.floor(value)
end

local function currentTime(): number
    return os.time()
end

local function sweep(self: MassTriggerGuard, now: number)
    for key, entry in self._entries do 
        if now - entry.LastSeen > self._windowSeconds then 
            self._entries[key] = nil
            self._keyCount -= 1
        end
    end
end

function MassTriggerGuard.new(options: Options?): MassTriggerGuard
	assert(options == nil or type(options) == "table", "MassTriggerGuard.new: options must be a table when provided")

	local now = options and options.Now
	assert(now == nil or type(now) == "function", "MassTriggerGuard.new: Now must be a function")

	local minPlayers = (options and options.MinPlayers) or DataSchema.Security.MassTriggerPlayers
	assert(
		type(minPlayers) == "number" and isWholeNumber(minPlayers) and minPlayers >= 2,
		"MassTriggerGuard.new: MinPlayers must be a whole number of at least 2"
	)

	local windowSeconds = (options and options.WindowSeconds) or DataSchema.Security.MassTriggerWindowSeconds
	assert(
		type(windowSeconds) == "number" and windowSeconds > 0 and windowSeconds < math.huge,
		"MassTriggerGuard.new: WindowSeconds must be a finite number above 0"
	)

	local maxKeys = (options and options.MaxKeys) or DEFAULT_MAX_KEYS
	assert(
		type(maxKeys) == "number" and isWholeNumber(maxKeys) and maxKeys >= 1,
		"MassTriggerGuard.new: MaxKeys must be a whole number of at least 1"
	)

	return setmetatable({
		_now = now or currentTime,
		_minPlayers = minPlayers,
		_windowSeconds = windowSeconds,
		_maxKeys = maxKeys,
		_entries = {} :: { [string]: Entry },
		_keyCount = 0,
	}, MassTriggerGuard)
end

function MassTriggerGuard.Record(self: MassTriggerGuard, key: string, userId: number): boolean
    assert(type(key) == "string" and key ~= "", "MassTriggerGuard.Record: key must be a non-empty string")
    assert(type(userId) == "number" and isWholeNumber(userId) and userId >= 0, "MassTriggerGuard.Record: userId must be a whole numbe")

    local now = self._now()
    local entry = self._entries[key]

    if entry == nil then 
        if self._keyCount >= self._maxKeys then 
            sweep(self, now)
            if self._keyCount >= self._maxKeys then 
                return false
            end
        end
        entry = { Players = {}, LastSeen = now }
        self._entries[key] = entry
        self._keyCount += 1
    end

    entry.LastSeen = now
    entry.Players[userId] = now

	local distinctPlayers = 0
	for otherId, seenAt in entry.Players do
		if now - seenAt > self._windowSeconds then
			entry.Players[otherId] = nil
		else
			distinctPlayers += 1
		end
	end

	return distinctPlayers >= self._minPlayers
end

return MassTriggerGuard
