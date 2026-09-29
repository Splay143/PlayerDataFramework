--!strict
--@Splay

local HttpService = game:GetService("HttpService")
local ServerScriptService = game:GetService("ServerScriptService")
local PlayerData = ServerScriptService.PlayerData

local DataSchema = require(PlayerData.Config.DataSchema)
local SessionManager = require(PlayerData.Data.SessionManager)
local StoreHandler = require(PlayerData.Data.StoreHandler)
local PlayerEnvironment = require(PlayerData.Data.PlayerEnvironment)

local BaseUtil = require(PlayerData.Utils.BaseUtil)
local TableUtil = require(PlayerData.Utils.TableUtil)
local SaveUtil = require(PlayerData.Utils.SaveUtil)
local ReleaseTracker = require(PlayerData.Utils.ReleaseTracker)

local LeaderStatsAdapter = require(PlayerData.Adapters.LeaderstatsAdapter)
local PrivateAdapter = require(PlayerData.Adapters.PrivateAdapter)

export type Handler = BaseUtil.Handler
export type Context = BaseUtil.Context
export type Environment  = PlayerEnvironment.Environment

type LoadState = "Loading" | "Loaded" | "Releasing" | "Released" | "Failed" | "Lost"

export type SaveFailureReason = "Failed" | "Lost"

type PlayerState = {
	State: LoadState,
	SessionId: string,
	Data: DataSchema.PlayerData,
	Ctx: Context,
	LastSaved: number,
}

export type DataService = {
	SaveFailed: RBXScriptSignal,
	PlayerLoaded: RBXScriptSignal,

	RegisterHandler: (self: DataService, handler: Handler) -> (),
	Start: (self: DataService, adapter: StoreHandler.Adapter?) -> (),
	Destroy: (self: DataService) -> (),
	Get: (self: DataService, player: Player, namespace: string) -> any?,
	SaveNow: (self: DataService, player: Player) -> boolean,
	RequestSave: (self: DataService, player: Player) -> (),
	Replicate: (self: DataService, player: Player, key: string, value: any, private: boolean?) -> (),
	IsLoaded: (self: DataService, player: Player) -> boolean,
	WaitForLoad: (self: DataService, player: Player) -> boolean,
	GetLastSaved: (self: DataService, player: Player) -> number?,
	OnPlayerLoaded: (self: DataService, callback: (player: Player) -> ()) -> RBXScriptConnection,

	-- Private by convention: only this file touches these.
	_handlers: { Handler },
	_handlersByNamespace: { [string]: Handler },
	_started: boolean,
	_destroyed: boolean,
	_session: SessionManager.SessionManager?,
	_storeHandler: StoreHandler.StoreHandler?,
	_saveUtil: SaveUtil.SaveUtil<Player>?,
	_playerStates: { [Player]: PlayerState },
	_loadWaiters: { [Player]: { thread } },
	_releaseTracker: ReleaseTracker.ReleaseTracker,
	_saveFailedSignal: BindableEvent,
	_playerLoadedSignal: BindableEvent,
	_connections: { RBXScriptConnection },
	_threads: { thread },
	_environment: PlayerEnvironment.Environment,
}

local DataService = {}
DataService.__index = DataService

local function now(self: DataService): number
	return self._environment.Now()
end

-- v2 is a breaking change, so old-style dot calls like DataService.Get(player, "Coins")
-- will be the most common mistake. Without this, the error would be a confusing
-- "not a valid member" on the player object that landed in `self`.
local function assertIsService(self: any, methodName: string)
	assert(
		type(self) == "table" and getmetatable(self) == DataService,
		("DataService.%s: call it on an instance with a colon, e.g. dataService:%s(...)"):format(methodName, methodName)
	)
end

local function assertIsPlayer(self: DataService, player: any, methodName: string)
	assert(self._environment.IsPlayer(player), ("DataService.%s: player must be a Player"):format(methodName))
end

function DataService.new(environment: PlayerEnvironment.Environment?): DataService
	assert(
		environment == nil or type(environment) == "table",
		"DataService.new: environment must be a table when provided"
	)
	-- One signal pair per instance, so two services never fire each other's events.
	local saveFailedSignal = Instance.new("BindableEvent")
	local playerLoadedSignal = Instance.new("BindableEvent")

	local self = setmetatable({
		SaveFailed = saveFailedSignal.Event,
		PlayerLoaded = playerLoadedSignal.Event,
		_environment = environment or PlayerEnvironment.Default(),

		_handlers = {},
		_handlersByNamespace = {},
		_started = false,
		_destroyed = false,

		-- _session, _storeHandler and _saveUtil stay nil until Start().
		_playerStates = {},
		_loadWaiters = {},
		_releaseTracker = ReleaseTracker.new(),

		_saveFailedSignal = saveFailedSignal,
		_playerLoadedSignal = playerLoadedSignal,

		_connections = {},
		_threads = {},
	}, DataService)

	return (self :: any) :: DataService
end

function DataService.RegisterHandler(self: DataService, handler: Handler)
	assertIsService(self, "RegisterHandler")
	assert(not self._started, "DataService.RegisterHandler: cannot register a handler after Start() has been called")
	assert(type(handler) == "table", "DataService.RegisterHandler: handler must be a table")
	assert(
		type(handler.Namespace) == "string" and handler.Namespace ~= "",
		"DataService.RegisterHandler: handler.Namespace must be a non-empty string"
	)
	assert(type(handler.Default) == "function", "DataService.RegisterHandler: handler.Default must be a function")
	assert(type(handler.Sanitize) == "function", "DataService.RegisterHandler: handler.Sanitize must be a function")
	assert(type(handler.Load) == "function", "DataService.RegisterHandler: handler.Load must be a function")
	assert(type(handler.Save) == "function", "DataService.RegisterHandler: handler.Save must be a function")
	assert(
		self._handlersByNamespace[handler.Namespace] == nil,
		"DataService.RegisterHandler: a handler is already registered for namespace \"" .. handler.Namespace .. "\""
	)

	self._handlersByNamespace[handler.Namespace] = handler
	table.insert(self._handlers, handler)
end

-- Private helpers. They stay local functions (private by scope). The ones that
-- touch service state take `self` as their first argument instead of being methods.

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

local function loadHandlers(self: DataService, player: Player, ctx: Context, data: DataSchema.PlayerData)
	for _, handler in self._handlers do
		local raw = data[handler.Namespace]

		local sanitizeOk, sanitized = pcall(handler.Sanitize, raw)

		if not sanitizeOk then
			warn(
				("DataService: handler \"%s\".Sanitize errored for %s, using Default(): %s"):format(
					handler.Namespace,
					player.Name,
					tostring(sanitized)
				)
			)
			sanitized = handler.Default()
		elseif sanitized == nil then
			warn(
				("DataService: handler \"%s\".Sanitize returned nil for %s, using Default()"):format(
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
			warn(
				("DataService: handler \"%s\".Load errored for %s: %s"):format(
					handler.Namespace,
					player.Name,
					tostring(loadErr)
				)
			)
		end
	end
end

local function saveHandlers(
	self: DataService,
	player: Player,
	ctx: Context,
	previous: DataSchema.PlayerData
): DataSchema.PlayerData
	local data: DataSchema.PlayerData = {}

	for _, handler in self._handlers do
		local saveOk, value = pcall(handler.Save, player, ctx)

		if saveOk then
			local sanitizeOk, sanitized = pcall(handler.Sanitize, value)
			if sanitizeOk then
				data[handler.Namespace] = sanitized
			else
				warn(
					("DataService: handler \"%s\".Sanitize (post-Save) errored for %s, keeping previous value: %s"):format(
						handler.Namespace,
						player.Name,
						tostring(sanitized)
					)
				)
				data[handler.Namespace] = previous[handler.Namespace]
			end
		else
			warn(
				("DataService: handler \"%s\".Save errored for %s, keeping previous value: %s"):format(
					handler.Namespace,
					player.Name,
					tostring(value)
				)
			)
			data[handler.Namespace] = previous[handler.Namespace]
		end
	end

	return data
end

local function onPlayerAdded(self: DataService, player: Player)
	assert(self._session ~= nil, "DataService: Start() must be called before players can join")
	local session = self._session :: SessionManager.SessionManager

	local releaseCleared = self._releaseTracker:WaitUntilClear(player.UserId, DataSchema.Timing.ReleaseWaitSeconds)
	if not releaseCleared then
		warn(("DataService: previous release for %s did not finish in time, continuing anyway"):format(player.Name))
	end

	if not player.Parent then
		resolveLoad(self, player, false)
		return
	end

	local acquireStatus, record = session:AcquireWithRetry(player.UserId, function()
		return (player.Parent :: any) ~= nil
	end)

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
	}

	self._playerStates[player] = state

	loadHandlers(self, player, ctx, data)

	if not player.Parent then
		local finishRelease = self._releaseTracker:Begin(player.UserId)
		local releaseOk, releaseError = pcall(function()
			session:Release(player.UserId, sessionId :: string, data)
		end)
		finishRelease()

		if not releaseOk then
			warn(
				("DataService: release errored for %s, lock may go stale: %s"):format(
					player.Name,
					tostring(releaseError)
				)
			)
		end

		self._playerStates[player] = nil
		resolveLoad(self, player, false)
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
	local releaseOk, releaseResult = pcall(function()
		local data = saveHandlers(self, player, state.Ctx, state.Data)
		return session:Release(player.UserId, state.SessionId, data)
	end)
	finishRelease()

	if not releaseOk then
		warn(
			("DataService: release errored for %s, lock may go stale: %s"):format(
				player.Name,
				tostring(releaseResult)
			)
		)
		state.State = "Failed"
		self._saveFailedSignal:Fire(player, "Failed")
		return
	end

	if releaseResult ~= "Released" then
		warn(
			("DataService: release failed for %s (%s), lock may go stale"):format(
				player.Name,
				tostring(releaseResult)
			)
		)
		state.State = "Failed"
		self._saveFailedSignal:Fire(player, if releaseResult == "Lost" then "Lost" else "Failed")
	else
		state.State = "Released"
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

	local data = saveHandlers(self, player, state.Ctx, state.Data)
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

	for _, player in playersToRelease do
		task.spawn(onPlayerRemoving, self, player)
	end

	local deadline = os.clock() + DataSchema.Timing.ShutdownTimeoutSeconds
	while hasUnfinishedShutdownWork(self, userIds) and os.clock() < deadline do
		task.wait(0.1)
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

function DataService.Get(self: DataService, player: Player, namespace: string): any?
	assertIsService(self, "Get")
	assertIsPlayer(self, player, "Get")
	assert(type(namespace) == "string" and namespace ~= "", "DataService.Get: namespace must be a non-empty string")
	assert(
		self._handlersByNamespace[namespace] ~= nil,
		"DataService.Get: no handler registered for namespace \"" .. namespace .. "\""
	)

	local state = self._playerStates[player]
	if state == nil or state.State ~= "Loaded" then
		return nil
	end

	local value = state.Data[namespace]
	if value == nil then
		return nil
	end

	return TableUtil.DeepCopy(value)
end

function DataService.Start(self: DataService, adapter: StoreHandler.Adapter?)
	assertIsService(self, "Start")
	assert(not self._destroyed, "DataService.Start: this service has been destroyed")
	assert(not self._started, "DataService.Start: already started")
	assert(#self._handlers > 0, "DataService.Start: at least one handler must be registered before Start()")

	self._started = true

	local environment = self._environment

	local storeHandler = StoreHandler.new(DataSchema.STORE_NAME, adapter)
	self._storeHandler = storeHandler

	local serverId = if game.JobId ~= "" then game.JobId else HttpService:GenerateGUID(false)

	-- Both take the environment's clock so lock times and save gaps follow the same time
	-- source as the rest of the service (a fake clock in tests, os.time live).
	self._session = SessionManager.new(storeHandler, serverId, { Now = environment.Now })

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