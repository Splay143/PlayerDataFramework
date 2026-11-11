--!strict
--@Splay

local HttpService = game:GetService("HttpService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")
local RunService = game:GetService("RunService")
local PlayerData = ServerScriptService.PlayerData
local FRAMEWORK_VERSION = "2.1.0"

local DataSchema = require(PlayerData.Config.DataSchema)
local ErrorCodes = require(PlayerData.Config.ErrorCodes)
local ErrorLogConfig = require(PlayerData.Config.ErrorLogConfig)
local Signal = require(PlayerData.Utils.Signal)
local SecurityService = require(PlayerData.Security.SecurityService)

local Logger = require(PlayerData.Utils.Logger)
local OutputSink = require(PlayerData.Adapters.LogSinks.OutputSink)
local WebhookSink = require(PlayerData.Adapters.LogSinks.WebhookSink)
local EmbedFormatter = require(PlayerData.Integration.Discord.EmbedFormatter)
local GameNameResolver = require(PlayerData.Integration.GameNameResolver)

local NamespaceStore = require(PlayerData.Data.NamespaceStore)
local PlayerEnvironment = require(PlayerData.Data.PlayerEnvironment)
local SessionManager = require(PlayerData.Data.SessionManager)
local StoreHandler = require(PlayerData.Data.StoreHandler)

local ReplicationService = require(PlayerData.Networking.ReplicationService)
local RequestService = require(PlayerData.Networking.RequestService)

local BaseUtil = require(PlayerData.Utils.BaseUtil)
local ReleaseCoordinator = require(PlayerData.Utils.ReleaseCoordinator)
local ReleaseTracker = require(PlayerData.Utils.ReleaseTracker)
local SaveUtil = require(PlayerData.Utils.SaveUtil)
local TableUtil = require(ReplicatedStorage.PlayerDataShared.Shared.TableUtil)
local UnreleasedSessions = require(PlayerData.Utils.UnreleasedSessions)

local LeaderStatsAdapter = require(PlayerData.Adapters.LeaderstatsAdapter)
local PrivateAdapter = require(PlayerData.Adapters.PrivateAdapter)
local RemoteAdapter = require(PlayerData.Adapters.RemoteAdapter)
local DataStoreAdapter = require(PlayerData.Adapters.DataStoreAdapter)
local DataStoreSink = require(PlayerData.Adapters.LogSinks.DataStoreSink)

type AnyHandler = BaseUtil.Handler<any>
export type Handler<T> = BaseUtil.Handler<T>
export type Context = BaseUtil.Context
export type Environment = PlayerEnvironment.Environment

type LoadState = "Loading" | "Loaded" | "Releasing" | "Released" | "Failed" | "Lost"

export type SaveFailureReason = "Failed" | "Lost"

export type PlayerMeta = {
	CreatedAt: number,
	LastLogin: number,
	SchemaVersion: number,
}

type PlayerState = {
	State: LoadState,
	SessionId: string,
	Data: DataSchema.PlayerData,
	Ctx: Context,
	LastSaved: number,
	LoadFailedNamespaces: { [string]: boolean },
	Meta: PlayerMeta,
}

type SecondaryClaims = {
	Values: { [string]: unknown },
	Unavailable: { [string]: boolean },
	RequiredUnavailable: boolean,
	Notes: { string },
}

export type DataService = {
	SaveFailed: Signal.Event<Player, SaveFailureReason>,
	PlayerLoaded: Signal.Event<Player>,

	RegisterHandler: <T>(self: DataService, handler: Handler<T>) -> (),
	Start: (
		self: DataService,
		adapter: StoreHandler.Adapter?,
		storeOptions: StoreHandler.Options?,
		incidentAdapter: DataStoreSink.Adapter?
	) -> (),
	Destroy: (self: DataService) -> (),
	Get: <T>(self: DataService, player: Player, handler: Handler<T>) -> T?,
	SaveNow: (self: DataService, player: Player) -> boolean,
	RequestSave: (self: DataService, player: Player) -> (),
	Replicate: (self: DataService, player: Player, key: string, value: any, private: boolean?) -> (),
	IsLoaded: (self: DataService, player: Player) -> boolean,
	WaitForLoad: (self: DataService, player: Player) -> boolean,
	GetLastSaved: (self: DataService, player: Player) -> number?,
	OnPlayerLoaded: (self: DataService, callback: (player: Player) -> ()) -> Signal.Connection,
	Diagnostic: Signal.Event<Logger.Event>,
	GetDiagnosticCounts: (self: DataService) -> { [number]: number },

	RegisterRequest: (self: DataService, route: string, handler: RequestService.RequestHandler) -> (),
	RegisterSend: (self: DataService, route: string, handler: RequestService.SendHandler) -> (),
	RegisterHoneypot: (self: DataService, route: string) -> (),

	GetMeta: (self: DataService, player: Player) -> PlayerMeta?,
	EditUnlocked: (
		self: DataService,
		userId: number,
		edit: (data: DataSchema.PlayerData) -> boolean
	) -> SessionManager.EditStatus,

	-- Private by convention: only this file touches these.
	_handlers: { AnyHandler },
	_handlersByNamespace: { [string]: AnyHandler },
	_started: boolean,
	_destroyed: boolean,
	_session: SessionManager.SessionManager?,
	_storeHandler: StoreHandler.StoreHandler?,
	_saveUtil: SaveUtil.SaveUtil<Player>?,
	_namespaceStore: NamespaceStore.NamespaceStore?,
	_playerStates: { [Player]: PlayerState },
	_loadWaiters: { [Player]: { thread } },
	_releaseCoordinator: ReleaseCoordinator.ReleaseCoordinator?,
	_remotes: RemoteAdapter.Adapter?,
	_replicationService: ReplicationService.ReplicationService?,
	_requestService: RequestService.RequestService?,
	_releaseTracker: ReleaseTracker.ReleaseTracker,
	_pendingReleaseSections: { [number]: { [string]: boolean } },
	_pendingReleaseNames: { [number]: string },
	_unreleased: UnreleasedSessions.UnreleasedSessions,
	_saveFailedSignal: Signal.Signal<Player, SaveFailureReason>,
	_playerLoadedSignal: Signal.Signal<Player>,
	_diagnosticsSignal: Signal.Signal<Logger.Event>,

	_connections: { PlayerEnvironment.PlayerConnection },
	_threads: { thread },
	_environment: PlayerEnvironment.Environment,
	_logger: Logger.Logger,
	_incidentSink: DataStoreSink.DataStoreSink?,
	_webhookSink: WebhookSink.WebhookSink?,
	_security: SecurityService.SecurityService?,
}

local DataService = {}
DataService.__index = DataService

local function now(self: DataService): number
	return self._environment.Now()
end

local function assertIsService(self: any, methodName: string)
	assert(
		type(self) == "table" and getmetatable(self) == DataService,
		("DataService.%s: call it on an instance with a colon, e.g. dataService:%s(...)"):format(methodName, methodName)
	)
end

local function assertIsPlayer(self: DataService, player: any, methodName: string)
	assert(self._environment.IsPlayer(player), ("DataService.%s: player must be a Player"):format(methodName))
end

local function isSecondary(handler: AnyHandler): boolean
	local storage = handler.Storage
	return storage == "Secondary"
end

local function logIncident(self: DataService, input: Logger.EventInput)
	local logged, logError = pcall(function(): Logger.Event
		return self._logger:Log(input)
	end)
	if not logged then 
		warn(("DataService: could not log incident %d: %s"):format(input.Code, tostring(logError)))
	end
end

local function logHandlerFailure(
	self: DataService,
	code: number,
	severity: Logger.Severity,
	stage: Logger.Stage,
	player: Player,
	namespace: string,
	message: string,
	detail: unknown
)
	logIncident(self, {
		Code = code,
		Severity = severity,
		Fault = "Developer",
		Stage = stage,
		Message = message,
		Detail = tostring(detail),
		UserId = player.UserId,
		Namespace = namespace,
	})
end

local function resolveLogConfig(): ErrorLogConfig.Resolved
	return ErrorLogConfig.Resolve(ErrorLogConfig.Settings)
end

local function newDefaultLogger(environment: PlayerEnvironment.Environment): Logger.Logger
	local config = resolveLogConfig()
	local logger = Logger.new({
		Now = environment.Now,
		Config = config,
		Context = { JobId = game.JobId, PlaceId = game.PlaceId, FrameworkVersion = FRAMEWORK_VERSION },
	})
	logger:AddSink(OutputSink.Write, config.Sinks.Output)
	return logger
end

-- A failing incident store must never stop saving or shutdown, so errors are swallowed here.
local function stepIncidentSink(self: DataService, isFinal: boolean)
	local sink = self._incidentSink
	if sink == nil then
		return
	end

	pcall(function(): number
		return sink:Step(isFinal)
	end)
end

-- Opt-in, because it spends DataStore requests. Games turn it on with DataSchema.IncidentStore.Enabled.
local function attachIncidentSink(self: DataService, incidentAdapter: DataStoreSink.Adapter?)
	if not DataSchema.IncidentStore.Enabled then
		return
	end

	local sink = DataStoreSink.new(
		incidentAdapter or DataStoreAdapter.new(DataSchema.IncidentStore.StoreName),
		{ Now = self._environment.Now }
	)
	self._incidentSink = sink

	-- The floor comes from the game's log config, so a Warning never reaches the store under Standard.
	self._logger:AddSink(function(event: Logger.Event)
		sink:Write(event)
	end, resolveLogConfig().Sinks.DataStore)
end

local function stepWebhookSink(self: DataService, isFinal: boolean)
	local sink = self._webhookSink
	if sink == nil then 
		return
	end

	pcall(function(): number
		return sink:Step(isFinal)
	end)
end

local function attachWebhookSink(self: DataService)
	local settings = DataSchema.IncidentWebhook
	if not settings.Enabled then
		return
	end

	local gameName = GameNameResolver.new(game.PlaceId)
	gameName:Start()

	local sink = WebhookSink.new(settings.Url, {
		Now = self._environment.Now,
		Format = function(event: Logger.Event)
			return EmbedFormatter.Format(event, { GameName = gameName:Get() })
		end,
	})
	self._webhookSink = sink
	self._logger:AddSink(function(event: Logger.Event)
		sink:Write(event)
	end, resolveLogConfig().Sinks.Webhook)
end

function DataService.new(environment: PlayerEnvironment.Environment?, logger: Logger.Logger?): DataService
	assert(
		environment == nil or type(environment) == "table",
		"DataService.new: environment must be a table when provided"
	)
	assert(logger == nil or type(logger) == "table", "DataService.new: logger must be a table when provided")

	-- One signal pair per instance, so two services never fire each other's events.
	local saveFailedSignal: Signal.Signal<Player, SaveFailureReason> = Signal.new()
	local playerLoadedSignal: Signal.Signal<Player> = Signal.new()
	local resolvedEnvironment = environment or PlayerEnvironment.Default()
	local dianogsticSignal: Signal.Signal<Logger.Event> = Signal.new()
	
	local self = setmetatable({
		SaveFailed = saveFailedSignal.Event,
		PlayerLoaded = playerLoadedSignal.Event,
		Diagnostic = dianogsticSignal.Event,
		_environment = resolvedEnvironment,
		_logger = logger or newDefaultLogger(resolvedEnvironment),
		_security = nil,

		_handlers = {},
		_handlersByNamespace = {},
		_started = false,
		_destroyed = false,

		-- _session, _storeHandler, _saveUtil,_releaseCoordinator, _remotes and _replicationService, _incidentSink, _webhookSink stay nil until Start().
		_playerStates = {},
		_loadWaiters = {},
		_releaseTracker = ReleaseTracker.new(),
		_pendingReleaseSections = {},
		_pendingReleaseNames = {},
		_unreleased = UnreleasedSessions.new({ Now = resolvedEnvironment.Now }),

		_saveFailedSignal = saveFailedSignal,
		_playerLoadedSignal = playerLoadedSignal,
		_diagnosticsSignal = dianogsticSignal,
		
		_connections = {},
		_threads = {},
	}, DataService)

	local service = (self :: unknown) :: DataService
	
	service._logger:AddSink(function(event: Logger.Event)
		dianogsticSignal:Fire(event)
	end, "Info")

	return service
end

function DataService.RegisterHandler<T>(self: DataService, handler: Handler<T>)
	assertIsService(self, "RegisterHandler")
	assert(not self._started, "DataService.RegisterHandler: cannot register a handler after Start() has been called")
	assert(type(handler) == "table", "DataService.RegisterHandler: handler must be a table")
	assert(
		type(handler.Namespace) == "string" and handler.Namespace ~= "",
		"DataService.RegisterHandler: handler.Namespace must be a non-empty string"
	)
	assert(
		self._handlersByNamespace[handler.Namespace] == nil,
		"DataService.RegisterHandler: a handler with this Namespace is already registered"
	)
	assert(type(handler.Default) == "function", "DataService.RegisterHandler: handler.Default must be a function")
	assert(type(handler.Sanitize) == "function", "DataService.RegisterHandler: handler.Sanitize must be a function")
	assert(type(handler.Load) == "function", "DataService.RegisterHandler: handler.Load must be a function")
	assert(type(handler.Save) == "function", "DataService.RegisterHandler: handler.Save must be a function")

	local storage: any = handler.Storage
	local required: any = handler.Required
	assert(
		storage == nil or storage == "Primary" or storage == "Secondary",
		'DataService.RegisterHandler: handler.Storage must be "Primary" or "Secondary" when set'
	)
	assert(
		required == nil or type(required) == "boolean",
		"DataService.RegisterHandler: handler.Required must be a boolean when set"
	)
	assert(
		required ~= true or storage == "Secondary",
		'DataService.RegisterHandler: handler.Required only applies to handlers with Storage = "Secondary"'
	)
	assert(
		storage ~= "Secondary" or #handler.Namespace <= DataSchema.Limits.MaxSecondaryNamespaceLength,
		"DataService.RegisterHandler: a Secondary handler's Namespace is too long to use in a DataStore key"
	)

	self._handlersByNamespace[handler.Namespace] = handler
	table.insert(self._handlers, handler)
end

-- Private helpers
local function buildContext(replicateTable: (key: string, value: { [any]: any }) -> ()): Context
	local leaderstats = Instance.new("Folder")
	leaderstats.Name = "leaderstats"
	local leaderstatsAdapter = LeaderStatsAdapter.new(leaderstats)

	local privateFolder = Instance.new("Folder")
	privateFolder.Name = "PrivateData"
	local privateAdapter = PrivateAdapter.new(privateFolder)

	local function replicate(key: string, value: any, private: boolean?)
		if type(value) == "table" then
			replicateTable(key, value)
		elseif private then
			privateAdapter:Show(key, value)
		else
			leaderstatsAdapter:ShowInLeaderStats(key, value)
		end
	end

	return {
		leaderstats = leaderstats,
		LeaderstatsAdapter = leaderstatsAdapter,
		privateFolder = privateFolder,
		PrivateAdapter = privateAdapter,
		Replicate = replicate,
	} :: Context
end

local function resolveLoad(self: DataService, player: Player, success: boolean)
	local waiters = self._loadWaiters[player]
	if waiters == nil then
		return
	end

	self._loadWaiters[player] = nil

	for _, waiter in waiters do
		task.spawn(waiter, success)
	end
end

local function loadHandlers(
	self: DataService,
	player: Player,
	ctx: Context,
	data: DataSchema.PlayerData,
	claims: SecondaryClaims
): ({ [string]: boolean }, number?, { string })
	local loadFailedNamespaces: { [string]: boolean } = table.clone(claims.Unavailable)
	local firstErrorCode: number? = nil
	local notes: { string } = table.clone(claims.Notes)

	if next(claims.Unavailable) ~= nil then
		firstErrorCode = ErrorCodes.Codes.NamespaceUnavailable
	end

	for _, handler in self._handlers do
		if claims.Unavailable[handler.Namespace] then
			continue
		end

		local raw: unknown = claims.Values[handler.Namespace]
		if raw == nil then
			raw = data[handler.Namespace]
		end

		local sanitizeOk, sanitized = pcall(handler.Sanitize, raw)

		if not sanitizeOk or sanitized == nil then
			loadFailedNamespaces[handler.Namespace] = true
			table.insert(notes, ("%s: Sanitize failed: %s"):format(handler.Namespace, tostring(sanitized)))

			firstErrorCode = firstErrorCode or ErrorCodes.Codes.HandlerSanitizeFailure
			continue
		end

		data[handler.Namespace] = sanitized

		local loadOk, loadErr = pcall(function(): string?
			handler.Load(player, ctx, sanitized)
			return nil
		end)
		if not loadOk then
			loadFailedNamespaces[handler.Namespace] = true
			firstErrorCode = firstErrorCode or ErrorCodes.Codes.HandlerLoadFailure
			table.insert(notes, ("%s: Load failed: %s"):format(handler.Namespace, tostring(loadErr)))
		end
	end
	return loadFailedNamespaces, firstErrorCode, notes
end

local function saveHandlers(self: DataService, player: Player, state: PlayerState): (DataSchema.PlayerData, boolean)
	local data: DataSchema.PlayerData = table.clone(state.Data)
	local anyHandlerFailed = false

	for _, handler in self._handlers do
		local namespace = handler.Namespace

		if state.LoadFailedNamespaces[namespace] then
			continue
		end

		local saveOk, value = pcall(handler.Save, player, state.Ctx)
		if not saveOk or value == nil then
			logHandlerFailure(
				self,
				ErrorCodes.Codes.HandlerSaveFailure,
				"Warning",
				"Save",
				player,
				namespace,
				"Save failed, the previous value is kept",
				value
			)
			anyHandlerFailed = true
			continue
		end

		local sanitizeOk, sanitized = pcall(handler.Sanitize, value)
		if not sanitizeOk or sanitized == nil then
			logHandlerFailure(
				self,
				ErrorCodes.Codes.HandlerSaveFailure,
				"Warning",
				"Save",
				player,
				namespace,
				"Sanitize failed on the saved value, the previous value is kept",
				sanitized
			)
			anyHandlerFailed = true
			continue
		end

		data[namespace] = sanitized
	end

	return data, anyHandlerFailed
end

local function saveSecondaryNamespaces(
	self: DataService,
	player: Player,
	state: PlayerState,
	data: DataSchema.PlayerData
): (DataSchema.PlayerData, NamespaceStore.SaveStatus)
	local namespaceStore = self._namespaceStore :: NamespaceStore.NamespaceStore
	local primaryPayload: DataSchema.PlayerData = table.clone(data)
	local worst: NamespaceStore.SaveStatus = "Saved"

	for _, handler in self._handlers do
		local namespace = handler.Namespace
		local value = data[namespace]

		-- A namespace whose Load failed or whose claim failed is never written, same as saveHandlers.
		if not isSecondary(handler) or state.LoadFailedNamespaces[namespace] or value == nil then
			continue
		end

		local status = namespaceStore:Save(player.UserId, namespace, state.SessionId, value)
		if status == "Saved" then
			primaryPayload[namespace] = nil
		else
			logIncident(self, {
				Code = ErrorCodes.Codes.NamespaceSaveFailed,
				Severity = if status == "Lost" then "Error" else "Warning",
				Fault = "Platform",
				Stage = "Save",
				Message = ("secondary namespace save returned %s"):format(status),
				UserId = player.UserId,
				SessionId = state.SessionId,
				Namespace = namespace,
			})

			if status == "Lost" then
				worst = "Lost"
			elseif worst ~= "Lost" then
				worst = "Failed"
			end
		end
	end

	return primaryPayload, worst
end

local function claimSecondaryNamespaces(self: DataService, player: Player, sessionId: string): SecondaryClaims
	local namespaceStore = self._namespaceStore :: NamespaceStore.NamespaceStore
	local claims: SecondaryClaims = { Values = {}, Unavailable = {}, RequiredUnavailable = false, Notes = {} }

	for _, handler in self._handlers do
		if not isSecondary(handler) then
			continue
		end

		local namespace = handler.Namespace
		local status, storedValue = namespaceStore:Claim(player.UserId, namespace, sessionId)

		if status == "Claimed" then
			claims.Values[namespace] = storedValue
			continue
		end
		table.insert(claims.Notes, ("%s: claim returned %s"):format(namespace, status)) -- kick carries the log
		claims.Unavailable[namespace] = true

		if handler.Required then
			claims.RequiredUnavailable = true
			break
		end
	end

	return claims
end

local function tryRelease(
	self: DataService,
	userId: number,
	sessionId: string,
	data: DataSchema.PlayerData
): SessionManager.ReleaseStatus
	local session = self._session :: SessionManager.SessionManager

	local ok, result = pcall(function()
		return session:Release(userId, sessionId, data)
	end)

	if not ok then
		if not ok then
			logIncident(self, {
				Code = ErrorCodes.Codes.ReleaseFailed,
				Severity = "Warning",
				Fault = "Unknown",
				Stage = "Release",
				Message = "the release call errored, the lock may go stale",
				UserId = userId,
				SessionId = sessionId,
				Detail = tostring(result),
			})
			return "Failed"
		end
		return "Failed"
	end

	if result == "Released" or result == "Lost" then
		return result
	end

	-- Anything else, including an unexpected value, counts as a failed release.
	return "Failed"
end

local function keepForRetry(
	self: DataService,
	userId: number,
	sessionId: string,
	data: DataSchema.PlayerData,
	detail: string?,
	username: string?
)
	local sections = self._pendingReleaseSections[userId]
	if sections == nil then
		sections = {}
		self._pendingReleaseSections[userId] = sections
	end
	for section in data do
		sections[section] = true
	end
	if username ~= nil then
		self._pendingReleaseNames[userId] = username
	end

	self._unreleased:Add(userId, sessionId, data)
	logIncident(self, {
		Code = ErrorCodes.Codes.ReleaseFailed,
		Severity = "Error",
		Fault = "Platform",
		Stage = "Release",
		Message = "release failed, the session is kept and retried in the background",
		UserId = userId,
		SessionId = sessionId,
		Detail = detail,
	})
end

local function beginTrackedRelease(
	self: DataService,
	userId: number,
	data: DataSchema.PlayerData,
	username: string?
): () -> ()
	local sections = self._pendingReleaseSections[userId]
	if sections == nil then
		sections = {}
		self._pendingReleaseSections[userId] = sections
	end
	for section in data do
		sections[section] = true
	end
	if username ~= nil then
		self._pendingReleaseNames[userId] = username
	end

	local finishRelease = self._releaseTracker:Begin(userId)
	local finished = false
	return function()
		if finished then
			return
		end
		finished = true
		finishRelease()
		if not self._releaseTracker:IsPending(userId) and self._unreleased:Get(userId) == nil then
			self._pendingReleaseSections[userId] = nil
			self._pendingReleaseNames[userId] = nil
		end
	end
end

local function retryEntry(self: DataService, entry: UnreleasedSessions.Entry)
	local finishRelease = beginTrackedRelease(self, entry.UserId, entry.Data)
	local status = tryRelease(self, entry.UserId, entry.SessionId, entry.Data)

	if status == "Failed" then
		self._unreleased:RecordFailure(entry.UserId, entry.SessionId)
	else
		self._unreleased:Remove(entry.UserId, entry.SessionId)
	end
	finishRelease()
end

local function flushUnreleasedSession(self: DataService, player: Player)
	local entry = self._unreleased:Get(player.UserId)
	if entry == nil then
		return
	end

	retryEntry(self, entry)

	if self._unreleased:Get(player.UserId) == entry then
		logIncident(self, {
			Code = ErrorCodes.Codes.ReleaseFailed,
			Severity = "Error",
			Fault = "Platform",
			Stage = "Join",
			Message = "the previous session could not be saved before the player rejoined, recent progress may be lost",
			UserId = player.UserId,
			SessionId = entry.SessionId,
			DataLossLikely = true,
		})
	end
end

local function requestReleaseFrom(self: DataService, userId: number, blocker: SessionManager.BlockingLock)
	local releaseCoordinator = self._releaseCoordinator
	if releaseCoordinator == nil or self._destroyed then
		return
	end

	releaseCoordinator:RequestRelease(blocker.ServerId, { UserId = userId, SessionId = blocker.SessionId })
end

local function unloadHandlers(self: DataService, player: Player)
	for _, handler in self._handlers do
		local unload = handler.Unload
		if unload == nil then
			continue
		end

		local unloadCallback: (Player) -> () = unload

		local ok, unloadError = pcall(function(): string?
			unloadCallback(player)
			return nil
		end)

		if not ok then
			logHandlerFailure(
				self,
				ErrorCodes.Codes.HandlerUnloadFailure,
				"Warning",
				"Release",
				player,
				handler.Namespace,
				"Unload errored, the player's release continued",
				unloadError
			)
		end
	end
end

local function abandonJoin(self: DataService, player: Player, sessionId: string, data: DataSchema.PlayerData)
	local finishRelease = beginTrackedRelease(self, player.UserId, data)
	local status = tryRelease(self, player.UserId, sessionId, data)
	finishRelease()

	if status == "Failed" then
		keepForRetry(self, player.UserId, sessionId, data, nil, player.Name)
	end

	self._playerStates[player] = nil
	resolveLoad(self, player, false)
end

type AcquireFailure = {
	Code: number,
	Severity: Logger.Severity,
	Fault: Logger.Fault,
}

local ACQUIRE_FAILURES: { [string]: AcquireFailure } = {
	Locked = { Code = ErrorCodes.Codes.SessionLocked, Severity = "Warning", Fault = "Platform" },
	TooNew = { Code = ErrorCodes.Codes.RecordTooNew, Severity = "Error", Fault = "Developer" },
	Invalid = { Code = ErrorCodes.Codes.RecordInvalid, Severity = "Error", Fault = "Unknown" },
	MigrationFailed = { Code = ErrorCodes.Codes.MigrationFailed, Severity = "Error", Fault = "Developer" },	
}

-- Any other status means the record could not be read at all.
local LOAD_FAILED: AcquireFailure = {
	Code = ErrorCodes.Codes.LoadFailed,
	Severity = "Error",
	Fault = "Platform",
}

local function acquireFailureFor(status: string): AcquireFailure
	return ACQUIRE_FAILURES[status] or LOAD_FAILED
end

--The player only ever sees the code, never the message or detail.
local function kickPlayer(self: DataService, player: Player, incident: Logger.EventInput)
	local input = table.clone(incident)
	input.UserId = player.UserId

	-- The player may already have left, in which case there is nobody to kick.
	local stillInGame = (player.Parent :: any) ~= nil
	input.Kicked = stillInGame

	-- A logging bug must never stop the kick, or the player would sit in the game with no data.
	local logged, logError = pcall(function(): Logger.Event
		return self._logger:Log(input)
	end)
	if not logged then
		warn(("DataService: could not log incident %d: %s"):format(incident.Code, tostring(logError)))
	end

	if stillInGame then
		player:Kick(ErrorCodes.KickMessage(incident.Code))
	end
end

local function onPlayerAdded(self: DataService, player: Player)
	assert(self._session ~= nil, "DataService: Start() must be called before players can join")
	local session = self._session :: SessionManager.SessionManager

	local replication = self._replicationService :: ReplicationService.ReplicationService

	if (player.Parent :: any) ~= nil then
		replication:AddPlayer(player)
	end

	local releaseCleared = self._releaseTracker:WaitUntilClear(player.UserId, DataSchema.Timing.ReleaseWaitSeconds)
	if not releaseCleared then
		logIncident(self, {
			Code = ErrorCodes.Codes.ReleaseWaitTimeout,
			Severity = "Warning",
			Fault = "Platform",
			Stage = "Join",
			Message = "the previous release did not finish in time, joining anyway",
			UserId = player.UserId,
		})
	end

	flushUnreleasedSession(self, player)

	if not player.Parent then
		resolveLoad(self, player, false)
		return
	end

	local block: { Blocker: SessionManager.BlockingLock?, StartedAt: number } = { Blocker = nil, StartedAt = 0 }

	local acquireStatus, record = session:AcquireWithRetry(player.UserId, function()
		return (player.Parent :: any) ~= nil
	end, function(blocker: SessionManager.BlockingLock)
		block.Blocker = blocker
		block.StartedAt = os.clock()
		task.spawn(requestReleaseFrom, self, player.UserId, blocker)
	end)

	local blocker = block.Blocker
	if blocker ~= nil then
		logIncident(self, {
			Code = ErrorCodes.Codes.JoinBlocked,
			Severity = "Info",
			Fault = "Platform",
			Stage = "Join",
			Message = "the join was blocked by another server's session lock",
			UserId = player.UserId,
			Detail = ("blocked by server %s for %.1fs (%s)"):format(
				blocker.ServerId,
				os.clock() - block.StartedAt,
				acquireStatus
			),
		})
	end

	if acquireStatus ~= "Acquired" or record == nil then
		resolveLoad(self, player, false)

		if not player.Parent then
			return
		end

		local failure = acquireFailureFor(acquireStatus)
		kickPlayer(self, player, {
			Code = failure.Code,
			Severity = failure.Severity,
			Fault = failure.Fault,
			Stage = "Join",
			Message = "could not acquire the session (" .. acquireStatus .. ")",
		})
		return
	end

	local sessionId = if record.Lock then record.Lock.SessionId else nil
	assert(sessionId ~= nil, "DataService: an Acquired record must carry a session lock")

	local ctx = buildContext(function(key: string, value: { [any]: any })
		replication:Replicate(player, key, value)
	end)

	local data = record.Data
	local originalData = TableUtil.DeepCopy(data)

	local state: PlayerState = {
		State = "Loading",
		SessionId = sessionId :: string,
		Data = data,
		Ctx = ctx,
		LastSaved = now(self),
		LoadFailedNamespaces = {},

		Meta = table.freeze({
			CreatedAt = record.Meta.CreatedAt,
			LastLogin = record.Meta.LastLogin,
			SchemaVersion = record.SchemaVersion,
		}),
	}

	self._playerStates[player] = state

	local claims = claimSecondaryNamespaces(self, player, sessionId :: string)

	if claims.RequiredUnavailable then
		-- Nothing has been loaded or changed yet, so the primary record goes back as it was.
		abandonJoin(self, player, sessionId :: string, data)
		kickPlayer(self, player, {
			Code = ErrorCodes.Codes.NamespaceUnavailable,
			Severity = "Error",
			Fault = "Platform",
			Stage = "Join",
			Message = "a Required secondary namespace could not be claimed",
			SessionId = sessionId :: string,
			Detail = table.concat(claims.Notes, "; "),
		})
		return
	end

	-- The player may have left while the claims were in flight. Skip Load, since Unload has already run for them.
	if not player.Parent then
		abandonJoin(self, player, sessionId :: string, originalData)
		return
	end

	local failedNamespaces, errorCode, notes = loadHandlers(self, player, ctx, data, claims)
	state.LoadFailedNamespaces = failedNamespaces

	if errorCode ~= nil then
		local failedNames: { string } = {}
		for namespace in failedNamespaces do
			table.insert(failedNames, namespace)
		end
		table.sort(failedNames)

		abandonJoin(self, player, sessionId :: string, originalData)
		kickPlayer(self, player, {
			Code = errorCode,
			Severity = "Error",
			Fault = "Developer",
			Stage = "Load",
			Message = "a handler failed during join, so the player was not loaded",
			SessionId = sessionId :: string,
			Detail = "namespaces failed: " .. table.concat(failedNames, ", ") .. " | " .. table.concat(notes, "; "),
		})
		return
	end

	if not player.Parent then
		abandonJoin(self, player, sessionId :: string, originalData)
		return
	end

	self._environment.AttachFolders(player, ctx)

	state.State = "Loaded"
	replication:SetLoaded(player)
	resolveLoad(self, player, true)
	self._playerLoadedSignal:Fire(player)
end

local function onPlayerRemoving(self: DataService, player: Player)
	local replication = self._replicationService
	if replication ~= nil then
		replication:RemovePlayer(player)
	end

	local requests = self._requestService
	if requests ~= nil then
		requests:RemovePlayer(player)
	end

	local security = self._security
	if security ~= nil then
		security:Clear(player.UserId)
	end

	if self._saveUtil then
		self._saveUtil:Cancel(player)
	end

	resolveLoad(self, player, false)

	local state = self._playerStates[player]
	self._playerStates[player] = nil

	if state == nil or state.State ~= "Loaded" then
		unloadHandlers(self, player)
		return
	end

	local session = self._session :: SessionManager.SessionManager

	state.State = "Releasing"

	local finishRelease = beginTrackedRelease(self, player.UserId, state.Data, player.Name)

	local handlerFailed = false
	-- Falls back to the last known data if saveHandlers itself errors.
	local dataToRelease = state.Data
	local releaseOk, releaseResult = pcall(function()
		local data, failed = saveHandlers(self, player, state)
		local primaryPayload, secondaryStatus = saveSecondaryNamespaces(self, player, state, data)
		handlerFailed = failed or secondaryStatus == "Failed"
		dataToRelease = primaryPayload
		return session:Release(player.UserId, state.SessionId, primaryPayload)
	end)
	finishRelease()
	unloadHandlers(self, player)

	if not releaseOk then
		keepForRetry(self, player.UserId, state.SessionId, dataToRelease, tostring(releaseResult), player.Name)
		state.State = "Failed"
		self._saveFailedSignal:Fire(player, "Failed")
		return
	end

	if releaseResult ~= "Released" then
		if releaseResult == "Failed" then
			keepForRetry(self, player.UserId, state.SessionId, dataToRelease, nil, player.Name)
		else
			logIncident(self, {
				Code = ErrorCodes.Codes.SessionLost,
				Severity = "DataLoss",
				Fault = "Platform",
				Stage = "Release",
				Message = "another server owns the session, progress since the last save is lost",
				UserId = player.UserId,
				SessionId = state.SessionId,
				DataLossLikely = true,
			})
		end

		state.State = "Failed"
		self._saveFailedSignal:Fire(player, if releaseResult == "Lost" then "Lost" else "Failed")
	else
		state.State = "Released"

		if handlerFailed then
			self._saveFailedSignal:Fire(player, "Failed")
		end
	end
end

local function performSave(self: DataService, player: Player): SaveUtil.SaveResult
	local state = self._playerStates[player]
	if state == nil or state.State ~= "Loaded" then
		return "NotLoaded"
	end

	if now(self) - state.LastSaved < DataSchema.Timing.MinSaveGapSeconds then
		return "SkippedGap"
	end

	local session = self._session :: SessionManager.SessionManager

	local data, handlerFailed = saveHandlers(self, player, state)
	state.Data = data

	local primaryPayload, secondaryStatus = saveSecondaryNamespaces(self, player, state, data)
	local status: SessionManager.SaveStatus = if secondaryStatus == "Lost"
		then "Lost"
		else session:Save(player.UserId, state.SessionId, primaryPayload)

	-- The player may have left while Save was yielding.
	if state.State ~= "Loaded" then
		return "NotLoaded"
	end

	if status == "Lost" then
		state.State = "Lost"
		self._saveFailedSignal:Fire(player, "Lost")
		kickPlayer(self, player, {
			Code = ErrorCodes.Codes.SessionLost,
			Severity = "DataLoss",
			Fault = "Platform",
			Stage = "Save",
			Message = "another server took the session lock, progress since the last save is lost",
			SessionId = state.SessionId,
			DataLossLikely = true,
		})
		return "Lost"
	end

	if status ~= "Saved" then
		logIncident(self, {
			Code = ErrorCodes.Codes.SaveFailed,
			Severity = "Warning",
			Fault = "Platform",
			Stage = "Save",
			Message = "save failed, the autosave will try again",
			UserId = player.UserId,
			SessionId = state.SessionId,
			Detail = status,
		})
		self._saveFailedSignal:Fire(player, "Failed")
		return "Failed"
	end

	if handlerFailed or secondaryStatus == "Failed" then
		self._saveFailedSignal:Fire(player, "Failed")
	end

	state.LastSaved = now(self)
	return "Saved"
end

function DataService.SaveNow(self: DataService, player: Player): boolean
	assertIsService(self, "SaveNow")
	assertIsPlayer(self, player, "SaveNow")
	return performSave(self, player) == "Saved"
end

function DataService.RequestSave(self: DataService, player: Player)
	assertIsService(self, "RequestSave")
	assertIsPlayer(self, player, "RequestSave")
	assert(self._saveUtil ~= nil, "DataService.RequestSave: Start() must be called first")

	local saveUtil = self._saveUtil :: SaveUtil.SaveUtil<Player>
	saveUtil:RequestSave(player)
end

function DataService.Replicate(self: DataService, player: Player, key: string, value: any, private: boolean?)
	assertIsService(self, "Replicate")
	assertIsPlayer(self, player, "Replicate")
	assert(type(key) == "string" and key ~= "", "DataService.Replicate: key must be a non-empty string")

	local state = self._playerStates[player]
	if state == nil or state.State ~= "Loaded" then
		return
	end
	state.Ctx.Replicate(key, value, private)
end

function DataService.RegisterRequest(self: DataService, route: string, handler: RequestService.RequestHandler)
	assertIsService(self, "RegisterRequest")
	local requests = self._requestService
	assert(requests ~= nil, "DataService.RegisterRequest: Start() must be called first")
	requests:RegisterRequest(route, handler)
end

function DataService.RegisterSend(self: DataService, route: string, handler: RequestService.SendHandler)
	assertIsService(self, "RegisterSend")
	local requests = self._requestService
	assert(requests ~= nil, "DataService.RegisterSend: Start() must be called first")
	requests:RegisterSend(route, handler)
end

function DataService.IsLoaded(self: DataService, player: Player): boolean
	assertIsService(self, "IsLoaded")
	assertIsPlayer(self, player, "IsLoaded")

	local state = self._playerStates[player]
	return state ~= nil and state.State == "Loaded"
end

function DataService.WaitForLoad(self: DataService, player: Player): boolean
	assertIsService(self, "WaitForLoad")
	assertIsPlayer(self, player, "WaitForLoad")

	if self:IsLoaded(player) then
		return true
	end

	if self._destroyed or (player.Parent :: any) == nil then
		return false
	end

	local waiters = self._loadWaiters[player] or {}
	self._loadWaiters[player] = waiters
	table.insert(waiters, coroutine.running())

	return coroutine.yield() == true
end

function DataService.GetLastSaved(self: DataService, player: Player): number?
	assertIsService(self, "GetLastSaved")
	assertIsPlayer(self, player, "GetLastSaved")

	local state = self._playerStates[player]
	if state == nil or state.State ~= "Loaded" then
		return nil
	end
	return state.LastSaved
end

function DataService.GetDiagnosticCounts(self: DataService): { [number]: number}
	assertIsService(self, "GetDiagnosticCounts")
	return self._logger:Counts()
end

function DataService.EditUnlocked(
	self: DataService,
	userId: number,
	edit: (data: DataSchema.PlayerData) -> boolean
): SessionManager.EditStatus
	assertIsService(self, "EditUnlocked")
	assert(type(userId) == "number", "DataService.EditUnlocked: userId must be a number")
	assert(type(edit) == "function", "DataService.EditUnlocked: edit must be a function")

	local session = self._session
	assert(session ~= nil, "DataService.EditUnlocked: Start() must be called first")

	return session:EditUnlocked(userId, edit)
end

function DataService.OnPlayerLoaded(self: DataService, callback: (player: Player) -> ()): Signal.Connection
	assertIsService(self, "OnPlayerLoaded")
	assert(type(callback) == "function", "DataService.OnPlayerLoaded: callback must be a function")

	local connection = self._playerLoadedSignal.Event:Connect(callback)

	-- Snapshot first: callbacks run on their own threads, and the table can change meanwhile.
	local alreadyLoaded: { Player } = {}
	for player, state in self._playerStates do
		if state.State == "Loaded" then
			table.insert(alreadyLoaded, player)
		end
	end
	for _, player in alreadyLoaded do
		task.spawn(callback, player)
	end

	return connection
end

local function hasUnfinishedShutdownWork(self: DataService, userIds: { number }): boolean
	for _, state in self._playerStates do
		if state.State == "Loading" then
			return true
		end
	end

	for _, userId in userIds do
		if self._releaseTracker:IsPending(userId) then
			return true
		end
	end

	return false
end

local function shutdownSave(self: DataService)
	if not self._started or self._destroyed then
		return
	end

	local playersToRelease: { Player } = {}
	local userIds: { number } = {}
	for player, state in self._playerStates do
		if state.State == "Loaded" then
			table.insert(playersToRelease, player)
			table.insert(userIds, player.UserId)
		end
	end

	for _, entry in self._unreleased:All() do
		table.insert(userIds, entry.UserId)
		task.spawn(retryEntry, self, entry)
	end
	for userId in self._pendingReleaseSections do
		table.insert(userIds, userId)
	end

	for _, player in playersToRelease do
		task.spawn(onPlayerRemoving, self, player)
	end

	local deadline = os.clock() + DataSchema.Timing.ShutdownTimeoutSeconds
	while hasUnfinishedShutdownWork(self, userIds) and os.clock() < deadline do
		task.wait(0.1)
	end

	if hasUnfinishedShutdownWork(self, userIds) then
		local usersAffected: { string } = {}
		local allSections: { [string]: boolean } = {}
		local reported: { [number]: boolean } = {}
		for _, userId in userIds do
			if self._releaseTracker:IsPending(userId) and not reported[userId] then
				reported[userId] = true
				local pendingSections = self._pendingReleaseSections[userId]
				if pendingSections ~= nil then
					for section in pendingSections do
						allSections[section] = true
					end
				end
				local username = self._pendingReleaseNames[userId] or "username unavailable"
				local user = username .. " (" .. tostring(userId) .. ")"
				table.insert(usersAffected, user)
			end
		end
		local sectionNames: { string } = {}
		for section in allSections do
			table.insert(sectionNames, section)
		end
		table.sort(sectionNames)
		local sections = if #sectionNames > 0 then table.concat(sectionNames, ", ") else "none"
		table.sort(usersAffected)
	
		logIncident(self, {
			Code = ErrorCodes.Codes.ShutdownIncomplete,
			Severity = "DataLoss",
			Fault = "Platform",
			Stage = "Shutdown",
			Message = "shutdown timed out before every save and release finished",
			Detail = ("Unfinished user IDs: %d\nUsers affected: %s\nSections: %s"):format(
				#usersAffected,
				table.concat(usersAffected, ", "),
				sections
			),
			DataLossLikely = true,
		})
	end
	
	-- The server is closing, so held summaries would otherwise never be delivered.
	local flushed, flushError = pcall(function(): Logger.Event?
		self._logger:FlushSummaries(true)
		stepIncidentSink(self, true)
		stepWebhookSink(self, true)
		return nil
	end)
	if not flushed then
		warn(("DataService: could not flush log summaries at shutdown: %s"):format(tostring(flushError)))
	end
end

local function retryUnreleasedSessions(self: DataService)
	for _, entry in self._unreleased:DropExpired() do
		logIncident(self, {
			Code = ErrorCodes.Codes.ReleaseAbandoned,
			Severity = "DataLoss",
			Fault = "Platform",
			Stage = "Release",
			Message = "gave up releasing the session, the lock will go stale on its own",
			UserId = entry.UserId,
			SessionId = entry.SessionId,
			DataLossLikely = true,
		})
	end

	for _, entry in self._unreleased:Due() do
		local isCurrent = self._unreleased:Get(entry.UserId) == entry
		if isCurrent and not self._releaseTracker:IsPending(entry.UserId) then
			retryEntry(self, entry)
		end
	end
end

local function unreleasedRetryLoop(self: DataService)
	while true do
		task.wait(DataSchema.Timing.UnreleasedRetryTickSeconds)
		retryUnreleasedSessions(self)
	end
end

local function logFlushLoop(self: DataService)
	while true do
		task.wait(DataSchema.Timing.LogFlushTickSeconds)
		pcall(function(): Logger.Event?
			self._logger:FlushSummaries(false)
			return nil
		end)
		stepIncidentSink(self, false)
		stepWebhookSink(self, false)
	end
end

local function onReleaseRequested(self: DataService, request: ReleaseCoordinator.ReleaseRequest)
	if self._destroyed then
		return
	end

	local entry = self._unreleased:Get(request.UserId)
	-- The SessionId check stops a stale request from releasing a newer session.
	if entry == nil or entry.SessionId ~= request.SessionId then
		return
	end

	if self._releaseTracker:IsPending(request.UserId) then
		return
	end

	retryEntry(self, entry)
end

local function autosaveLoop(self: DataService)
	while true do
		task.wait(DataSchema.Timing.AutosaveMinSeconds)

		local saveUtil = self._saveUtil
		if saveUtil == nil then
			continue
		end

		local nowTime = now(self)
		for player, state in self._playerStates do
			if state.State == "Loaded" and (nowTime - state.LastSaved) >= DataSchema.Timing.AutosaveMinSeconds then
				saveUtil:RequestSave(player)
			end
		end
	end
end

local function saveQueueLoop(self: DataService)
	while true do
		task.wait(DataSchema.Store.SaveQueueTickSeconds)
		if self._saveUtil then
			self._saveUtil:Update()
		end
	end
end

function DataService.Get<T>(self: DataService, player: Player, handler: Handler<T>): T?
	assertIsService(self, "Get")
	assertIsPlayer(self, player, "Get")
	assert(type(handler) == "table", "DataService.Get: handler must be a handler table")
	assert(
		self._handlersByNamespace[handler.Namespace] == handler,
		"DataService.Get: handler is not registered with this service"
	)

	local state = self._playerStates[player]
	if state == nil or state.State ~= "Loaded" then
		return nil
	end

	if state.LoadFailedNamespaces[handler.Namespace] then
		return nil
	end

	local value = state.Data[handler.Namespace]
	if value == nil then
		return nil
	end

	return (TableUtil.DeepCopy(value) :: any) :: T
end

function DataService.Start(
	self: DataService,
	adapter: StoreHandler.Adapter?,
	storeOptions: StoreHandler.Options?,
	incidentAdapter: DataStoreSink.Adapter?
)
	assertIsService(self, "Start")
	assert(
		storeOptions == nil or type(storeOptions) == "table",
		"DataService.Start: storeOptions must be a table when provided"
	)
	assert(not self._destroyed, "DataService.Start: this service has been destroyed")
	assert(not self._started, "DataService.Start: already started")
	assert(#self._handlers > 0, "DataService.Start: at least one handler must be registered before Start()")

	local security = SecurityService.new({
		Settings = DataSchema.Security,
		Now = self._environment.Now,
		Log = function(input: Logger.EventInput)
			logIncident(self, input)
		end,
		Kick = function(player: Player, incident: Logger.EventInput)
			kickPlayer(self, player, incident)
		end,
		IsStudio = RunService:IsStudio(),
		CreatorId = if game.CreatorType == Enum.CreatorType.User then game.CreatorId else 0,
	})
	self._security = security
	
	self._started = true
	
	self._started = true

	local environment = self._environment

	local storeHandler = StoreHandler.new(DataSchema.STORE_NAME, adapter, storeOptions)
	self._storeHandler = storeHandler

	local serverId = if game.JobId ~= "" then game.JobId else HttpService:GenerateGUID(false)

	self._session = SessionManager.new(storeHandler, serverId, { Now = environment.Now })
	self._namespaceStore = NamespaceStore.new(storeHandler, { Now = environment.Now })
	attachIncidentSink(self, incidentAdapter)
	attachWebhookSink(self)

	-- SaveUtil only knows how to call a function with a key, so the closure carries `self` for it.
	self._saveUtil = SaveUtil.new(function()
		return storeHandler:GetBudget()
	end, function(player: Player): SaveUtil.SaveResult
		return performSave(self, player)
	end, { Now = environment.Now })

	local remotes = environment.CreateRemotes()
	self._remotes = remotes

	local replication = ReplicationService.new(remotes, {
		OnRejected = function(player: Player, reason: ReplicationService.RejectionReason)
			security:Report(player, reason, nil, "Replication")
		end,
	})

	self._replicationService = replication
	replication:Start()

	local requests = RequestService.new(remotes, {
		IsLoaded = function(player: Player): boolean
			return self:IsLoaded(player)
		end,
		OnRejected = function(player: Player, route: any, reason: RequestService.FailureReason)
			security:Report(player, reason, route, "Request")
		end,
	})
	self._requestService = requests
	requests:Start()

	table.insert(
		self._connections,
		environment.PlayerAdded:Connect(function(player: Player)
			onPlayerAdded(self, player)
		end)
	)
	table.insert(
		self._connections,
		environment.PlayerRemoving:Connect(function(player: Player)
			onPlayerRemoving(self, player)
		end)
	)

	for _, player in environment.GetPlayers() do
		task.spawn(onPlayerAdded, self, player)
	end

	table.insert(
		self._threads,
		task.spawn(function()
			unreleasedRetryLoop(self)
		end)
	)

	local releaseCoordinator = ReleaseCoordinator.new(environment.Messaging, serverId, function(request)
		onReleaseRequested(self, request)
	end)
	self._releaseCoordinator = releaseCoordinator

	table.insert(
		self._threads,
		task.spawn(function()
			if not releaseCoordinator:Start() then
				logIncident(self, {
					Code = ErrorCodes.Codes.ReleaseListenerFailed,
					Severity = "Warning",
					Fault = "Platform",
					Stage = "Release",
					Message = "could not listen for release requests, blocked joins will wait for the lock normally",
				})
			end
		end)
	)

	table.insert(
		self._threads,
		task.spawn(function()
			autosaveLoop(self)
		end)
	)
	table.insert(
		self._threads,
		task.spawn(function()
			saveQueueLoop(self)
		end)
	)
	table.insert(
		self._threads,
		task.spawn(function()
			logFlushLoop(self)
			stepIncidentSink(self, false)
		end)
	)

	environment.BindToClose(function()
		shutdownSave(self)
	end)
end

-- Stops this service's background work and disconnects it from Players. It does NOT
-- save or release loaded players: it exists so tests and hot-swaps can throw an
-- instance away cleanly, not as a substitute for the normal shutdown path.
function DataService.Destroy(self: DataService)
	assertIsService(self, "Destroy")
	if self._destroyed then
		return
	end
	self._destroyed = true

	for _, connection in self._connections do
		connection:Disconnect()
	end
	table.clear(self._connections)

	for _, thread in self._threads do
		task.cancel(thread)
	end
	table.clear(self._threads)

	for player, state in self._playerStates do
		if state.State == "Loaded" then
			unloadHandlers(self, player)
		end
	end

	-- Unblock anything still stuck in WaitForLoad.
	for player in self._loadWaiters do
		resolveLoad(self, player, false)
	end

	local releaseCoordinator = self._releaseCoordinator
	if releaseCoordinator ~= nil then
		releaseCoordinator:Stop()
	end

	local requestService = self._requestService
	if requestService ~= nil then
		requestService:Stop()
	end

	local replicationService = self._replicationService
	if replicationService ~= nil then
		replicationService:Stop()
	end

	local remotes = self._remotes
	if remotes ~= nil then
		remotes:Destroy()
	end

	self._saveFailedSignal:Destroy()
	self._playerLoadedSignal:Destroy()
	self._diagnosticsSignal:Destroy()
end

return DataService
