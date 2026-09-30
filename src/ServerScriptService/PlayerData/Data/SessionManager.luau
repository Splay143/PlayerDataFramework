--!strict
--@Splay

local ServerScriptService = game:GetService("ServerScriptService")
local DataSchema = require(ServerScriptService.PlayerData.Config.DataSchema)
local StoreHandler = require(ServerScriptService.PlayerData.Data.StoreHandler)
local TableUtil = require(ServerScriptService.PlayerData.Utils.TableUtil)
local Versioning = require(ServerScriptService.PlayerData.Config.Versioning)

export type AcquireStatus = "Acquired" | "Locked" | "TooNew" | "Failed"
export type SaveStatus = "Saved" | "Lost" | "Failed"
export type ReleaseStatus = "Released" | "Lost" | "Failed"

export type StoreHandlerLike = {
	Get: (self: StoreHandlerLike, key: string) -> (StoreHandler.Status, any?),
	Update: (self: StoreHandlerLike, key: string, transform: (any?) -> any?) -> (StoreHandler.Status, any?),
}

export type Options = {
	Now: (() -> number)?,
	GenerateSessionId: (() -> string)?,
	Wait: ((seconds: number) -> ())?,
}

export type SessionManager = {
	Acquire: (self: SessionManager, userId: number) -> (AcquireStatus, DataSchema.PlayerRecord?),
	AcquireWithRetry: (
		self: SessionManager,
		userId: number,
		shouldContinue: (() -> boolean)?
	) -> (AcquireStatus, DataSchema.PlayerRecord?),
	Save: (self: SessionManager, userId: number, sessionId: string, data: DataSchema.PlayerData) -> SaveStatus,
	Release: (self: SessionManager, userId: number, sessionId: string, data: DataSchema.PlayerData) -> ReleaseStatus,
}

local SessionManager = {}
SessionManager.__index = SessionManager

local function defaultGenerateSessionId(): string
	local HttpService = game:GetService("HttpService")
	return HttpService:GenerateGUID(false)
end

local function defaultWait(seconds: number)
	task.wait(seconds)
end

function SessionManager.new(store: StoreHandlerLike, serverId: string, options: Options?): SessionManager
	assert(
		type(store) == "table" and type(store.Update) == "function",
		"SessionManager.new: store must be a StoreHandler"
	)
	assert(type(serverId) == "string" and serverId ~= "", "SessionManager.new: serverId must be a non-empty string")
	assert(
		DataSchema.Timing.AcquireRetryIntervalSeconds > 0,
		"SessionManager.new: AcquireRetryIntervalSeconds must be greater than 0"
	)
	assert(
		DataSchema.Timing.AcquireRetryWindowSeconds >= 0,
		"SessionManager.new: AcquireRetryWindowSeconds must be at least 0"
	)

	local self = setmetatable({
		_store = store,
		_serverId = serverId,
		_now = (options and options.Now) or os.time,
		_generateSessionId = (options and options.GenerateSessionId) or defaultGenerateSessionId,
		_wait = (options and options.Wait) or defaultWait,
	}, SessionManager)

	return (self :: any) :: SessionManager
end

function SessionManager:Acquire(userId: number): (AcquireStatus, DataSchema.PlayerRecord?)
	local key = DataSchema.KeyFor(userId)

	local outcome: AcquireStatus = "Failed"

	local transform = function(current: any?): any?
		local now = self._now()

		if current == nil then
			local fresh = DataSchema.NewRecord(now)
			fresh.Lock = { ServerId = self._serverId, SessionId = self._generateSessionId(), Time = now }
			outcome = "Acquired"
			return fresh
		end

		local migrateStatus, migrated = Versioning.Migrate(current)
		if migrateStatus == "TooNew" then
			outcome = "TooNew"
			return nil
		elseif migrateStatus ~= "Ok" then
			outcome = "Failed"
			return nil
		end

		local record = migrated :: DataSchema.PlayerRecord
		record.Meta.LastLogin = now

		local lock = record.Lock
		local free = lock == nil
		local ours = lock ~= nil and lock.ServerId == self._serverId
		local stale = lock ~= nil and (now - lock.Time) >= DataSchema.Timing.StaleLockSeconds

		if not (free or ours or stale) then
			outcome = "Locked"
			return nil
		end

		record.Lock = { ServerId = self._serverId, SessionId = self._generateSessionId(), Time = now }
		outcome = "Acquired"
		return record
	end

	local storeStatus, result = self._store:Update(key, transform)

	if storeStatus == "Failed" then
		return "Failed", nil
	elseif storeStatus == "Cancelled" then
		return outcome, nil
	end

	assert(outcome == "Acquired", "SessionManager:Acquire: successful update did not acquire the session")

	return "Acquired", (result :: any) :: DataSchema.PlayerRecord
end

function SessionManager:AcquireWithRetry(
	userId: number,
	shouldContinue: (() -> boolean)?
): (AcquireStatus, DataSchema.PlayerRecord?)
	assert(type(userId) == "number", "SessionManager: AcquireWithRetry: userId must be a number")
	assert(
		shouldContinue == nil or type(shouldContinue) == "function",
		"sessionManager:AcquireWithRetry: shouldContinue must be a function"
	)

	local windowSeconds = DataSchema.Timing.AcquireRetryWindowSeconds
	local intervalSeconds = DataSchema.Timing.AcquireRetryIntervalSeconds
	local keepGoing: () -> boolean = shouldContinue or function()
		return true
	end

	local status, record = self:Acquire(userId)
	local secondsWaited = 0

	while status == "Locked" and secondsWaited < windowSeconds and keepGoing() do
		local sleepSeconds = math.min(intervalSeconds, windowSeconds - secondsWaited)
		self._wait(sleepSeconds)
		secondsWaited += sleepSeconds

		if not keepGoing() then
			break
		end

		status, record = self:Acquire(userId)
	end

	return status, record
end

local function ownershipTransform(
	self: any,
	sessionId: string,
	data: DataSchema.PlayerData,
	releasing: boolean
): (any?) -> any?
	return function(current: any?): any?
		if type(current) ~= "table" or type(current.Lock) ~= "table" then
			return nil
		end

		local lock = current.Lock
		if lock.SessionId ~= sessionId then
			return nil
		end

		local now = self._now()
		local updated = TableUtil.DeepCopy(current)
		updated.Data = data
		updated.Meta.LastSaved = now
		if releasing then
			updated.Lock = nil
		else
			updated.Lock = { ServerId = self._serverId, SessionId = sessionId, Time = now }
		end
		return updated
	end
end

function SessionManager:Save(userId: number, sessionId: string, data: DataSchema.PlayerData): SaveStatus
	local key = DataSchema.KeyFor(userId)
	assert(type(sessionId) == "string" and sessionId ~= "", "SessionManager:Save: sessionId must be a non-empty string")
	assert(type(data) == "table", "SessionManager:Save: data must be a table")

	local storeStatus = self._store:Update(key, ownershipTransform(self, sessionId, data, false))

	if storeStatus == "Ok" then
		return "Saved"
	elseif storeStatus == "Cancelled" then
		return "Lost"
	end
	return "Failed"
end

function SessionManager:Release(userId: number, sessionId: string, data: DataSchema.PlayerData): ReleaseStatus
	local key = DataSchema.KeyFor(userId)
	assert(
		type(sessionId) == "string" and sessionId ~= "",
		"SessionManager:Release: sessionId must be a non-empty string"
	)
	assert(type(data) == "table", "SessionManager:Release: data must be a table")

	local storeStatus = self._store:Update(key, ownershipTransform(self, sessionId, data, true))

	if storeStatus == "Ok" then
		return "Released"
	elseif storeStatus == "Cancelled" then
		return "Lost"
	end
	return "Failed"
end

return SessionManager
