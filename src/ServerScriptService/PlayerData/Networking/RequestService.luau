--!strict
--@Splay

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local DataSchema = require(ServerScriptService.PlayerData.Config.DataSchema)
local PayloadValidator = require(ServerScriptService.PlayerData.Utils.PayloadValidator)
local Protocol = require(ReplicatedStorage.PlayerDataShared.Shared.Protocol)
local RateLimiter = require(ServerScriptService.PlayerData.Utils.RateLimiter)
local RemoteAdapter = require(ServerScriptService.PlayerData.Adapters.RemoteAdapter)

export type FailureReason =
	"Unavailable"
	| "NotLoaded"
	| "NoHandler"
	| "RateLimited"
	| "InvalidPayload"
	| "HandlerError"
	| "InvalidPayload"
	| "HandlerError"
	| "MalformedRoute"
	| "MalformedPayload"
	| "ExtraArguments"
	| "Honeypot"

export type Result = {
	Success: boolean,
	Reason: string?,
	Data: { [any]: any }?,
}

export type RequestHandler = (player: Player, payload: { [any]: any }) -> Result
export type SendHandler = (player: Player, payload: { [any]: any }) -> ()

export type Options = {
	IsLoaded: (player: Player) -> boolean,
	OnRejected: ((player: Player, route: any, reason: FailureReason) -> ())?,
	Now: (() -> number)?,
}

export type RequestService = {
	Start: (self: RequestService) -> (),
	Stop: (self: RequestService) -> (),
	RegisterRequest: (self: RequestService, route: string, handler: RequestHandler) -> (),
	RegisterHoneypot: (self: RequestService, route: string) -> (),
	RegisterSend: (self: RequestService, route: string, handler: SendHandler) -> (),
	RemovePlayer: (self: RequestService, player: Player) -> (),
}

type TransportKind = "Request" | "Send"

local Reasons = {
	Unavailable = "Unavailable" :: FailureReason,
	NotLoaded = "NotLoaded" :: FailureReason,
	NoHandler = "NoHandler" :: FailureReason,
	RateLimited = "RateLimited" :: FailureReason,
	InvalidPayload = "InvalidPayload" :: FailureReason,
	HandlerError = "HandlerError" :: FailureReason,
	MalformedRoute = "MalformedRoute" :: FailureReason,
	MalformedPayload = "MalformedPayload" :: FailureReason,
	ExtraArguments = "ExtraArguments" :: FailureReason,
	Honeypot = "Honeypot" :: FailureReason,
}

-- What the client is told. The probe reasons look like ordinary refusals, so a prober cannot learn what is detected.
local PUBLIC_REASONS: { [string]: FailureReason } = {
	MalformedRoute = "NoHandler",
	MalformedPayload = "InvalidPayload",
	ExtraArguments = "InvalidPayload",
	Honeypot = "NoHandler",
}

local RequestService = {}
RequestService.__index = RequestService

function RequestService.new(adapter: RemoteAdapter.Adapter, options: Options): RequestService
	assert(type(adapter) == "table", "RequestService.new: adapter must be a RemoteAdapter")
	assert(type(options) == "table", "RequestService.new: options must be a table")
	assert(type(options.IsLoaded) == "function", "RequestService.new: options.IsLoaded must be a function")
	assert(
		options.OnRejected == nil or type(options.OnRejected) == "function",
		"RequestService.new: OnRejected must be a function when provided"
	)

	local limiterOptions: RateLimiter.Options = { Now = options.Now }
	local policies = DataSchema.Requests

	local self = setmetatable({
		_adapter = adapter,
		_isLoaded = options.IsLoaded,
		_onRejected = options.OnRejected,
		_requestLimiter = RateLimiter.new({
			Capacity = policies.RequestCapacity,
			RefillPerSecond = policies.RequestRefillPerSecond,
		}, limiterOptions),
		_sendLimiter = RateLimiter.new({
			Capacity = policies.SendCapacity,
			RefillPerSecond = policies.SendRefillPerSecond,
		}, limiterOptions),
		_requestHandlers = {} :: { [string]: RequestHandler },
		_sendHandlers = {} :: { [string]: SendHandler },
		_honeypots = {} :: { [string]: boolean },
		_started = false,
		_running = false,
		_unsubscribeSend = nil :: (() -> ())?,
	}, RequestService)

	return (self :: any) :: RequestService
end

local function report(self: any, player: Player, route: any, reason: FailureReason)
	local hook = self._onRejected
	if hook == nil then
		return
	end

	xpcall(hook, function(hookError: any)
		warn(("RequestService: OnRejected errored: %s"):format(tostring(hookError)))
	end, player, route, reason)
end

local function publicReasonFor(reason: FailureReason): FailureReason
	return PUBLIC_REASONS[reason] or reason
end

local function admit(
	self: any,
	kind: TransportKind,
	player: Player,
	route: any,
	payload: any,
	extraArgumentCount: number
): (FailureReason?, any?, { [any]: any }?)

	if not self._running then
		return Reasons.Unavailable, nil, nil
	end

	-- PlayerData.Request and PlayerData.Send can never produce these four.
	if extraArgumentCount > 0 then
		return Reasons.ExtraArguments, nil, nil
	end

	if not Protocol.IsValidRouteName(route) then
		return Reasons.MalformedRoute, nil, nil
	end

	if payload ~= nil and type(payload) ~= "table" then
		return Reasons.MalformedPayload, nil, nil
	end

	if self._honeypots[route] then
		return Reasons.Honeypot, nil, nil
	end

	if not self._isLoaded(player) then
		return Reasons.NotLoaded, nil, nil
	end

	local handlers = if kind == "Request" then self._requestHandlers else self._sendHandlers
	local limiter = if kind == "Request" then self._requestLimiter else self._sendLimiter

	if handlers[route] == nil then
		return Reasons.NoHandler, nil, nil
	end

	if not limiter:TryConsume(player, route) then
		return Reasons.RateLimited, nil, nil
	end

	local resolvedPayload: any = payload
	if resolvedPayload == nil then
		resolvedPayload = {}
	end

	if not PayloadValidator.Validate(resolvedPayload) then
		return Reasons.InvalidPayload, nil, nil
	end

	return nil, handlers[route], resolvedPayload
end

-- Rebuilt field by field so extra fields from a handler never reach the client.
local function normalizeResult(result: any): Result?
	if type(result) ~= "table" or type(result.Success) ~= "boolean" then
		return nil
	end

	local reason = result.Reason
	if reason ~= nil and (type(reason) ~= "string" or #reason > Protocol.Limits.MaxStringLength) then
		return nil
	end

	local data = result.Data
	if data ~= nil and not PayloadValidator.Validate(data) then
		return nil
	end

	return { Success = result.Success, Reason = reason, Data = data }
end

local function failure(reason: FailureReason): Result
	return { Success = false, Reason = reason }
end

local function handleRequest(self: any, player: Player, route: any, payload: any, extraArgumentCount: number): Result
	local reason, handler, cleanPayload = admit(self, "Request", player, route, payload, extraArgumentCount)
	if reason ~= nil then
		local refusal: FailureReason = reason :: FailureReason
		report(self, player, route, refusal)
		return failure(publicReasonFor(refusal))
	end

	local ok, result = pcall(handler :: RequestHandler, player, cleanPayload :: { [any]: any })
	if not ok then
		warn(("RequestService: request handler for %s errored: %s"):format(tostring(route), tostring(result)))
		report(self, player, route, "HandlerError")
		return failure("HandlerError")
	end

	local normalized = normalizeResult(result)
	if normalized == nil then
		warn(("RequestService: request handler for %s returned a malformed result"):format(tostring(route)))
		report(self, player, route, "HandlerError")
		return failure("HandlerError")
	end

	return normalized
end

local function handleSend(self: any, player: Player, route: any, payload: any, extraArgumentCount: number)
	local reason, handler, cleanPayload = admit(self, "Send", player, route, payload, extraArgumentCount)
	if reason ~= nil then
		report(self, player, route, reason :: FailureReason)
		return
	end

	local sendHandler = handler :: SendHandler
	local sendPayload = cleanPayload :: { [any]: any }

	-- The wrapper returns a value so pcall always yields an error slot to read.
	local ok, handlerError = pcall(function(): any
		sendHandler(player, sendPayload)
		return nil
	end)
	if not ok then
		warn(("RequestService: send handler for %s errored: %s"):format(tostring(route), tostring(handlerError)))
		report(self, player, route, "HandlerError")
	end
end

function RequestService.Start(self: any)
	assert(not self._started, "RequestService:Start: already started")
	self._started = true
	self._running = true

	self._adapter:SetRequestHandler(
		function(player: Player, route: unknown, payload: unknown, extraArgumentCount: number): unknown
			return handleRequest(self, player, route, payload, extraArgumentCount)
		end
	)
	
	self._unsubscribeSend = self._adapter:OnSend(
		function(player: Player, route: unknown, payload: unknown, extraArgumentCount: number)
			handleSend(self, player, route, payload, extraArgumentCount)
		end
	)
end

-- A RemoteFunction callback cannot be unset, so after Stop requests are answered "Unavailable".
function RequestService.Stop(self: any)
	self._running = false

	local unsubscribe = self._unsubscribeSend
	if unsubscribe ~= nil then
		self._unsubscribeSend = nil
		unsubscribe()
	end
end

function RequestService.RegisterRequest(self: any, route: string, handler: RequestHandler)
	Protocol.AssertRouteName(route)
	assert(type(handler) == "function", "RequestService:RegisterRequest: handler must be a function")
	assert(
		self._requestHandlers[route] == nil,
		"RequestService:RegisterRequest: this route already has a request handler"
	)
	assert(not self._honeypots[route], "RequestService:RegisterRequest: this route is a honeypot")

	self._requestHandlers[route] = handler
end

function RequestService.RegisterSend(self: any, route: string, handler: SendHandler)
	Protocol.AssertRouteName(route)
	assert(type(handler) == "function", "RequestService:RegisterSend: handler must be a function")
	assert(self._sendHandlers[route] == nil, "RequestService:RegisterSend: this route already has a send handler")
	assert(not self._honeypots[route], "RequestService:RegisterSend: this route is a honeypot")
	self._sendHandlers[route] = handler
end

function RequestService.RegisterHoneypot(self: any, route: string)
	Protocol.AssertRouteName(route)
	assert(
		self._requestHandlers[route] == nil and self._sendHandlers[route] == nil,
		"RequestService:RegisterHoneypot: this route already has a handler"
	)

	self._honeypots[route] = true
end

function RequestService.RemovePlayer(self: any, player: Player)
	assert((player :: any) ~= nil, "RequestService:RemovePlayer: player must not be nil")

	self._requestLimiter:Remove(player)
	self._sendLimiter:Remove(player)
end

return RequestService
