--!strict
--@Splay

--[[
	UnreleasedSessions

	Remembers sessions whose release failed, so they can be retried instead of leaving
	the lock to go stale (which locks the player out for minutes).

	This file only stores entries and decides WHEN a retry is due. It never talks to the
	DataStore: DataService performs the actual release, which keeps this testable with a
	fake clock.
]]

local ServerScriptService = game:GetService("ServerScriptService")

local DataSchema = require(ServerScriptService.PlayerData.Config.DataSchema)
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TableUtil = require(ReplicatedStorage.PlayerDataShared.Shared.TableUtil)

export type Entry = {
	UserId: number,
	SessionId: string,
	Data: DataSchema.PlayerData,
	FirstFailedAt: number,
	Attempts: number,
	NextAttemptAt: number,
}

export type Options = {
	Now: (() -> number)?,
}

export type UnreleasedSessions = {
	Add: (self: UnreleasedSessions, userId: number, sessionId: string, data: DataSchema.PlayerData) -> (),
	Get: (self: UnreleasedSessions, userId: number) -> Entry?,
	All: (self: UnreleasedSessions) -> { Entry },
	Remove: (self: UnreleasedSessions, userId: number, sessionId: string) -> (),
	Due: (self: UnreleasedSessions) -> { Entry },
	RecordFailure: (self: UnreleasedSessions, userId: number, sessionId: string) -> (),
	DropExpired: (self: UnreleasedSessions) -> { Entry },
	Count: (self: UnreleasedSessions) -> number,
}

local UnreleasedSessions = {}
UnreleasedSessions.__index = UnreleasedSessions

local function backoffSeconds(retriesSoFar: number): number
	local delay = DataSchema.Timing.UnreleasedRetryBaseSeconds * 2 ^ retriesSoFar
	return math.min(delay, DataSchema.Timing.UnreleasedRetryMaxSeconds)
end

function UnreleasedSessions.new(options: Options?): UnreleasedSessions
	local timing = DataSchema.Timing
	assert(
		timing.UnreleasedRetryBaseSeconds > 0,
		"UnreleasedSessions.new: UnreleasedRetryBaseSeconds must be greater than 0"
	)
	assert(
		timing.UnreleasedRetryMaxSeconds >= timing.UnreleasedRetryBaseSeconds,
		"UnreleasedSessions.new: UnreleasedRetryMaxSeconds must be at least the base delay"
	)
	assert(
		timing.UnreleasedRetryWindowSeconds > 0,
		"UnreleasedSessions.new: UnreleasedRetryWindowSeconds must be greater than 0"
	)

	local self = setmetatable({
		_now = (options and options.Now) or os.time,
		_entries = {} :: { [number]: Entry },
	}, UnreleasedSessions)

	return (self :: any) :: UnreleasedSessions
end

function UnreleasedSessions.Add(self: any, userId: number, sessionId: string, data: DataSchema.PlayerData)
	assert(type(userId) == "number", "UnreleasedSessions:Add: userId must be a number")
	assert(
		type(sessionId) == "string" and sessionId ~= "",
		"UnreleasedSessions:Add: sessionId must be a non-empty string"
	)
	assert(type(data) == "table", "UnreleasedSessions:Add: data must be a table")

	local nowSeconds = self._now()

	self._entries[userId] = {
		UserId = userId,
		SessionId = sessionId,
		Data = TableUtil.DeepCopy(data),
		FirstFailedAt = nowSeconds,
		Attempts = 0,
		NextAttemptAt = nowSeconds + backoffSeconds(0),
	}
end

function UnreleasedSessions.Get(self: any, userId: number): Entry?
	return self._entries[userId]
end

function UnreleasedSessions.Remove(self: any, userId: number, sessionId: string)
	local entry = self._entries[userId]
	if entry ~= nil and entry.SessionId == sessionId then
		self._entries[userId] = nil
	end
end

function UnreleasedSessions.Due(self: any): { Entry }
	local nowSeconds = self._now()
	local due: { Entry } = {}

	for _, entry in self._entries do
		if entry.NextAttemptAt <= nowSeconds then
			table.insert(due, entry)
		end
	end

	return due
end

function UnreleasedSessions.All(self: any): { Entry }
	local all: { Entry } = {}

	for _, entry in self._entries do
		table.insert(all, entry)
	end

	return all
end

function UnreleasedSessions.RecordFailure(self: any, userId: number, sessionId: string)
	local entry = self._entries[userId]

	if entry == nil or entry.SessionId ~= sessionId then
		return
	end

	entry.Attempts += 1
	entry.NextAttemptAt = self._now() + backoffSeconds(entry.Attempts)
end

function UnreleasedSessions.DropExpired(self: any): { Entry }
	local nowSeconds = self._now()
	local dropped: { Entry } = {}

	for userId, entry in self._entries do
		if nowSeconds - entry.FirstFailedAt >= DataSchema.Timing.UnreleasedRetryWindowSeconds then
			table.insert(dropped, entry)
			self._entries[userId] = nil
		end
	end

	return dropped
end

function UnreleasedSessions.Count(self: any): number
	return TableUtil.Count(self._entries)
end

return UnreleasedSessions
