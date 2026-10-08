--!strict
--@Splay

local HttpService = game:GetService("HttpService")
local ServerScriptService = game:GetService("ServerScriptService")
local PlayerData = ServerScriptService.PlayerData

local DataSchema = require(PlayerData.Config.DataSchema)
local NamespaceStore = require(PlayerData.Data.NamespaceStore)
local PlayerEnvironment = require(PlayerData.Data.PlayerEnvironment)
local SessionManager = require(PlayerData.Data.SessionManager)
local StoreHandler = require(PlayerData.Data.StoreHandler)

local BaseUtil = require(PlayerData.Utils.BaseUtil)
local ReleaseTracker = require(PlayerData.Utils.ReleaseTracker)
local SaveUtil = require(PlayerData.Utils.SaveUtil)
local TableUtil = require(PlayerData.Utils.TableUtil)
local UnreleasedSessions = require(PlayerData.Utils.UnreleasedSessions)

local LeaderStatsAdapter = require(PlayerData.Adapters.LeaderstatsAdapter)
local PrivateAdapter = require(PlayerData.Adapters.PrivateAdapter)

type AnyHandler = BaseUtil.Handler<any>
export type Handler<T> = BaseUtil.Handler<T>
export type Context = BaseUtil.Context
export type Environment = PlayerEnvironment.Environment

type LoadState = "Loading" | "Loaded" | "Releasing" | "Released" | "Failed" | "Lost"

export type SaveFailureReason = "Failed" | "Lost"

type PlayerState = {
	State: LoadState,
	SessionId: string,
	Data: DataSchema.PlayerData,
	Ctx: Context,
	LastSaved: number,
	LoadFailedNamespaces: { [string]: boolean },
}

type SecondaryClaims = {
	Values: { [string]: any },
	Unavailable: { [string]: boolean },
	RequiredUnavailable: boolean,
}

export type DataService = {
	SaveFailed: RBXScriptSignal,
	PlayerLoaded: RBXScriptSignal,

	RegisterHandler: <T>(self: DataService, handler: Handler<T>) -> (),
	Start: (self: DataService, adapter: StoreHandler.Adapter?, storeOptions: StoreHandler.Options?) -> (),
	Destroy: (self: DataService) -> (),
	Get: <T>(self: DataService, player: Player, handler: Handler<T>) -> T?,
	SaveNow: (self: DataService, player: Player) -> boolean,
	RequestSave: (self: DataService, player: Player) -> (),
	Replicate: (self: DataService, player: Player, key: string, value: any, private: boolean?) -> (),
	IsLoaded: (self: DataService, player: Player) -> boolean,
	WaitForLoad: (self: DataService, player: Player) -> boolean,
	GetLastSaved: (self: DataService, player: Player) -> number?,
	OnPlayerLoaded: (self: DataService, callback: (player: Player) -> ()) -> RBXScriptConnection,

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
	_releaseTracker: ReleaseTracker.ReleaseTracker,
	_unreleased: UnreleasedSessions.UnreleasedSessions,
	_saveFailedSignal: BindableEvent,
	_playerLoadedSignal: BindableEvent,
	_connections: { PlayerEnvironment.PlayerConnection },
	_threads: { thread },
	_environment: PlayerEnvironment.Environment,
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

function DataService.new(environment: PlayerEnvironment.Environment?): DataService
	assert(
		environment == nil or type(environment) == "table",
		"DataService.new: environment must be a table when provided"
	)
	-- One signal pair per instance, so two services never fire each other's events.
	local saveFailedSignal = Instance.new("BindableEvent")
	local playerLoadedSignal = Instance.new("BindableEvent")
	local resolvedEnvironment = environment or PlayerEnvironment.Default()

	local self = setmetatable({
		SaveFailed = saveFailedSignal.Event,
		PlayerLoaded = playerLoadedSignal.Event,
		_environment = resolvedEnvironment,

		_handlers = {},
		_handlersByNamespace = {},
		_started = false,
		_destroyed = false,

		-- _session, _storeHandler and _saveUtil stay nil until Start().
		_playerStates = {},
		_loadWaiters = {},
		_releaseTracker = ReleaseTracker.new(),
		_unreleased = UnreleasedSessions.new({ Now = resolvedEnvironment.Now }),

		_saveFailedSignal = saveFailedSignal,
		_playerLoadedSignal = playerLoadedSignal,

		_connections = {},
		_threads = {},
	}, DataService)

	return (self :: any) :: DataService
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
local function buildContext(): Context
	local leaderstats = Instance.new("Folder")
	leaderstats.Name = "leaderstats"
	local leaderstatsAdapter = LeaderStatsAdapter.new(leaderstats)

	local privateFolder = Instance.new("Folder")
	privateFolder.Name = "PrivateData"
	local privateAdapter = PrivateAdapter.new(privateFolder)

	local function replicate(key: string, value: any, private: boolean?)
		if private then
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
): { [string]: boolean }
	local loadFailedNamespaces: { [string]: boolean } = table.clone(claims.Unavailable)

	for _, handler in self._handlers do
		if claims.Unavailable[handler.Namespace] then
			continue
		end

		local raw = claims.Values[handler.Namespace]
		if raw == nil then
			raw = data[handler.Namespace]
		end

		local sanitizeOk, sanitized = pcall(handler.Sanitize, raw)

		if not sanitizeOk then
			warn(
				('DataService: handler "%s".Sanitize errored for %s, using Default(): %s'):format(
					handler.Namespace,
					player.Name,
					tostring(sanitized)
				)
			)
			sanitized = handler.Default()
		elseif sanitized == nil then
			warn(
				('DataService: handler "%s".Sanitize returned nil for %s, using Default()'):format(
					handler.Namespace,
					player.Name
				)
			)
			sanitized = handler.Default()
		end

		data[handler.Namespace] = sanitized

		local loadOk, loadErr = pcall(function(): string?
			handler.Load(player, ctx, sanitized)
			return nil
		end)
		if not loadOk then
			loadFailedNamespaces[handler.Namespace] = true
			warn(
				('DataService: handler "%s".Load errored for %s: %s'):format(
					handler.Namespace,
					player.Name,
					tostring(loadErr)
				)
			)
		end
	end
	return loadFailedNamespaces
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
			warn(
				('DataService: handler "%s".Save failed for %s, keeping previous value: %s'):format(
					namespace,
					player.Name,
					tostring(value)
				)
			)
			anyHandlerFailed = true
			continue
		end

		local sanitizeOk, sanitized = pcall(handler.Sanitize, value)
		if not sanitizeOk or sanitized == nil then
			warn(
				('DataService: handler "%s".Sanitize failed for %s, keeping previous value: %s'):format(
					namespace,
					player.Name,
					tostring(sanitized)
				)
			)
			anyHandlerFailed = true
			continue
		end

		data[namespace] = sanitized
	end

	return data, anyHandlerFailed
end

local function claimSecondaryNamespaces(self: DataService, player: Player, sessionId: string): SecondaryClaims
	local namespaceStore = self._namespaceStore :: NamespaceStore.NamespaceStore
	local claims: SecondaryClaims = { Values = {}, Unavailable = {}, RequiredUnavailable = false }

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

		warn(('DataService: could not claim "%s" for %s (%s)'):format(namespace, player.Name, status))
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
		warn(("DataService: release errored for %d, lock may go stale: %s"):format(userId, tostring(result)))
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
	playerName: string,
	userId: number,
	sessionId: string,
	data: DataSchema.PlayerData
)
	self._unreleased:Add(userId, sessionId, data)
	warn(("DataService: release failed for %s (%d), will keep retrying in the background"):format(playerName, userId))
end

local function retryEntry(self: DataService, entry: UnreleasedSessions.Entry)
	local finishRelease = self._releaseTracker:Begin(entry.UserId)
	local status = tryRelease(self, entry.UserId, entry.SessionId, entry.Data)
	finishRelease()

	if status == "Failed" then
		self._unreleased:RecordFailure(entry.UserId, entry.SessionId)
	else
		self._unreleased:Remove(entry.UserId, entry.SessionId)
	end
end

local function flushUnreleasedSession(self: DataService, player: Player)
	local entry = self._unreleased:Get(player.UserId)
	if entry == nil then
		return
	end

	retryEntry(self, entry)

	if self._unreleased:Get(player.UserId) == entry then
		warn(
			("DataService: could not save the previous session for %s before they rejoined, recent progress may be lost"):format(
				player.Name
			)
		)
	end
end

local function abandonJoin(self: DataService, player: Player, sessionId: string, data: DataSchema.PlayerData)
	local finishRelease = self._releaseTracker:Begin(player.UserId)
	local status = tryRelease(self, player.UserId, sessionId, data)
	finishRelease()

	if status == "Failed" then
		keepForRetry(self, player.Name, player.UserId, sessionId, data)
	end

	self._playerStates[player] = nil
	resolveLoad(self, player, false)
end

local function onPlayerAdded(self: DataService, player: Player)
	assert(self._session ~= nil, "DataService: Start() must be called before players can join")
	local session = self._session :: SessionManager.SessionManager

	local releaseCleared = self._releaseTracker:WaitUntilClear(player.UserId, DataSchema.Timing.ReleaseWaitSeconds)
	if not releaseCleared then
		warn(("DataService: previous release for %s did not finish in time, continuing anyway"):format(player.Name))
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
	end)

	if block.Blocker ~= nil then
		print(
			("DataService: join for %s was blocked by server %s for %.1fs (%s)"):format(
				player.Name,
				block.Blocker.ServerId,
				os.clock() - block.StartedAt,
				acquireStatus
			)
		)
	end

	if acquireStatus ~= "Acquired" or record == nil then
		resolveLoad(self, player, false)

		if not player.Parent then
			return
		end

		warn(("DataService: Failed to acquire session for %s (%s)"):format(player.Name, acquireStatus))
		player:Kick("We couldn't load your data. Please rejoin in a moment if this persists contact support")
		return
	end

	local sessionId = if record.Lock then record.Lock.SessionId else nil
	assert(sessionId ~= nil, "DataService: an Acquired record must carry a session lock")

	local ctx = buildContext()
	local data = record.Data

	local state: PlayerState = {
		State = "Loading",
		SessionId = sessionId :: string,
		Data = data,
		Ctx = ctx,
		LastSaved = now(self),
		LoadFailedNamespaces = {},
	}

	self._playerStates[player] = state

	local claims = claimSecondaryNamespaces(self, player, sessionId :: string)

	if claims.RequiredUnavailable then
		-- Nothing has been loaded or changed yet, so the primary record goes back as it was.
		abandonJoin(self, player, sessionId :: string, data)
		if player.Parent then
			player:Kick("We couldn't load your data. Please rejoin in a moment if this persists contact support")
		end
		return
	end

	state.LoadFailedNamespaces = loadHandlers(self, player, ctx, data, claims)

	if not player.Parent then
		abandonJoin(self, player, sessionId :: string, data)
		return
	end

	self._environment.AttachFolders(player, ctx)

	state.State = "Loaded"
	resolveLoad(self, player, true)
	self._playerLoadedSignal:Fire(player)
end

local function onPlayerRemoving(self: DataService, player: Player)
	if self._saveUtil then
		self._saveUtil:Cancel(player)
	end

	resolveLoad(self, player, false)

	local state = self._playerStates[player]
	self._playerStates[player] = nil

	if state == nil or state.State ~= "Loaded" then
		return
	end

	local session = self._session :: SessionManager.SessionManager

	state.State = "Releasing"

	local finishRelease = self._releaseTracker:Begin(player.UserId)

	local handlerFailed = false
	-- Falls back to the last known data if saveHandlers itself errors.
	local dataToRelease = state.Data
	local releaseOk, releaseResult = pcall(function()
		local data, failed = saveHandlers(self, player, state)
		handlerFailed = failed
		dataToRelease = data
		return session:Release(player.UserId, state.SessionId, data)
	end)
	finishRelease()

	if not releaseOk then
		warn(("DataService: release errored for %s: %s"):format(player.Name, tostring(releaseResult)))
		keepForRetry(self, player.Name, player.UserId, state.SessionId, dataToRelease)
		state.State = "Failed"
		self._saveFailedSignal:Fire(player, "Failed")
		return
	end

	if releaseResult ~= "Released" then
		warn(("DataService: release failed for %s (%s)"):format(player.Name, tostring(releaseResult)))
		if releaseResult == "Failed" then
			keepForRetry(self, player.Name, player.UserId, state.SessionId, dataToRelease)
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

	local status = session:Save(player.UserId, state.SessionId, data)

	-- The player may have left while Save was yielding.
	if state.State ~= "Loaded" then
		return "NotLoaded"
	end

	if status == "Lost" then
		state.State = "Lost"
		self._saveFailedSignal:Fire(player, "Lost")
		warn(("DataService: session lost for %s, removing player"):format(player.Name))
		player:Kick("Your data session was taken over by another server. Please rejoin")
		return "Lost"
	end

	if status ~= "Saved" then
		warn(("DataService: save failed for %s (%s)"):format(player.Name, status))
		self._saveFailedSignal:Fire(player, "Failed")
		return "Failed"
	end

	if handlerFailed then
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

function DataService.OnPlayerLoaded(self: DataService, callback: (player: Player) -> ()): RBXScriptConnection
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

	for _, player in playersToRelease do
		onPlayerRemoving(self, player)
	end

	local deadline = os.clock() + DataSchema.Timing.ShutdownTimeoutSeconds
	while hasUnfinishedShutdownWork(self, userIds) and os.clock() < deadline do
		task.wait(0.1)
	end
end

local function retryUnreleasedSessions(self: DataService)
	for _, entry in self._unreleased:DropExpired() do
		warn(
			("DataService: gave up releasing the session for user %s, the lock will go stale on its own"):format(
				tostring(entry.UserId)
			)
		)
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

function DataService.Start(self: DataService, adapter: StoreHandler.Adapter?, storeOptions: StoreHandler.Options?)
	assertIsService(self, "Start")
	assert(
		storeOptions == nil or type(storeOptions) == "table",
		"DataService.Start: storeOptions must be a table when provided"
	)
	assert(not self._destroyed, "DataService.Start: this service has been destroyed")
	assert(not self._started, "DataService.Start: already started")
	assert(#self._handlers > 0, "DataService.Start: at least one handler must be registered before Start()")

	self._started = true

	local environment = self._environment

	local storeHandler = StoreHandler.new(DataSchema.STORE_NAME, adapter, storeOptions)
	self._storeHandler = storeHandler

	local serverId = if game.JobId ~= "" then game.JobId else HttpService:GenerateGUID(false)

	self._session = SessionManager.new(storeHandler, serverId, { Now = environment.Now })
	self._namespaceStore = NamespaceStore.new(storeHandler, { Now = environment.Now })

	-- SaveUtil only knows how to call a function with a key, so the closure carries `self` for it.
	self._saveUtil = SaveUtil.new(function()
		return storeHandler:GetBudget()
	end, function(player: Player): SaveUtil.SaveResult
		return performSave(self, player)
	end, { Now = environment.Now })

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

	-- Unblock anything still stuck in WaitForLoad.
	for player in self._loadWaiters do
		resolveLoad(self, player, false)
	end

	self._saveFailedSignal:Destroy()
	self._playerLoadedSignal:Destroy()
end

return DataService
