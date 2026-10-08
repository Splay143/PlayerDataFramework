--!strict
--@Splay

local ServerScriptService = game:GetService("ServerScriptService")

local MessagingAdapter = require(ServerScriptService.PlayerData.Adapters.MessagingAdapter)

export type ReleaseRequest = {
	UserId: number,
	SessionId: string,
}

export type ReleaseCoordinator = {
	Start: (self: ReleaseCoordinator) -> boolean,
	RequestRelease: (self: ReleaseCoordinator, blockerServerId: string, request: ReleaseRequest) -> boolean,
	Stop: (self: ReleaseCoordinator) -> (),
}

local TOPIC_PREFIX = "Release-"

local ReleaseCoordinator = {}
ReleaseCoordinator.__index = ReleaseCoordinator

local function topicFor(serverId: string): string
	return TOPIC_PREFIX .. serverId
end

local function isValidRequest(payload: any): boolean
	return type(payload) == "table"
		and type(payload.UserId) == "number"
		and type(payload.SessionId) == "string"
		and payload.SessionId ~= ""
end

function ReleaseCoordinator.new(
	messaging: MessagingAdapter.Adapter,
	serverId: string,
	onReleaseRequested: (request: ReleaseRequest) -> ()
): ReleaseCoordinator
	assert(type(messaging) == "table", "ReleaseCoordinator.new: messaging must be a messaging adapter")
	assert(type(serverId) == "string" and serverId ~= "", "ReleaseCoordinator.new: serverId must be a non-empty string")
	assert(type(onReleaseRequested) == "function", "ReleaseCoordinator.new: onReleaseRequested must be a function")

	local self = setmetatable({
		_messaging = messaging,
		_serverId = serverId,
		_onReleaseRequested = onReleaseRequested,
		_unsubscribe = nil :: (() -> ())?,
	}, ReleaseCoordinator)

	return (self :: any) :: ReleaseCoordinator
end

-- Returns false when the subscription could not be made; the server then simply
-- never receives requests, and the stale-lock timeout covers it.
function ReleaseCoordinator.Start(self: any): boolean
	assert(self._unsubscribe == nil, "ReleaseCoordinator:Start: already started")

	local unsubscribe = self._messaging:Subscribe(topicFor(self._serverId), function(payload: any)
		if not isValidRequest(payload) then
			warn("ReleaseCoordinator: ignored a malformed release request")
			return
		end

		-- Rebuilt so extra fields in the payload never reach the callback.
		self._onReleaseRequested({ UserId = payload.UserId, SessionId = payload.SessionId })
	end)

	if unsubscribe == nil then
		return false
	end

	self._unsubscribe = unsubscribe
	return true
end

function ReleaseCoordinator.RequestRelease(self: any, blockerServerId: string, request: ReleaseRequest): boolean
	assert(
		type(blockerServerId) == "string" and blockerServerId ~= "",
		"ReleaseCoordinator:RequestRelease: blockerServerId must be a non-empty string"
	)
	assert(blockerServerId ~= self._serverId, "ReleaseCoordinator:RequestRelease: a server cannot ask itself")
	assert(
		isValidRequest(request),
		"ReleaseCoordinator:RequestRelease: request needs a numeric UserId and a non-empty SessionId"
	)

	return self._messaging:Publish(topicFor(blockerServerId), {
		UserId = request.UserId,
		SessionId = request.SessionId,
	})
end

function ReleaseCoordinator.Stop(self: any)
	local unsubscribe = self._unsubscribe
	if unsubscribe ~= nil then
		self._unsubscribe = nil
		unsubscribe()
	end
end

return ReleaseCoordinator
