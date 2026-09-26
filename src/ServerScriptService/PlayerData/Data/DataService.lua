--!strict
--@Splay

local Players = game:GetService("Players")
local HttpService = game:GetService("HttpService")
local ServerScriptService = game:GetService("ServerScriptService")

local DataSchema = require(ServerScriptService.PlayerData.Config.DataSchema)
local SessionManager = require(ServerScriptService.PlayerData.Data.SessionManager)
local StoreHandler = require(ServerScriptService.PlayerData.Data.StoreHandler)
local BaseUtil = require(ServerScriptService.PlayerData.Utils.BaseUtil)
local TableUtil = require(ServerScriptService.PlayerData.Utils.TableUtil)
local LeaderStatsAdapter = require(ServerScriptService.PlayerData.Adapters.LeaderstatsAdapter)

export type Handler = BaseUtil.Handler
export type Context = BaseUtil.Context

type LoadState = "Loading" | "Loaded" | "Releasing" | "Released" | "Failed"

type PlayerState = {
    State: LoadState,
    SessionId: string,
    Data: DataSchema.PlayerData,
    Ctx: Context,
    LastSaved: number,
}

local DataService = {}

local _handlers: { Handler } = {}
local _handlersByNamespace: { [string]: Handler} = {}
local _started = false

local _session: SessionManager.SessionManager? = nil
local _playerStates: { [Player]: PlayerState } = {}
local _loadedSignals: { [Player]: BindableEvent} = {}

local function now(): number
    return os.time()
end

function DataService.RegisterHandler(handler: Handler)
    assert(not _started, "DataService.RegisterHandler: cannot register a handler after Start() has been called")
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
		_handlersByNamespace[handler.Namespace] == nil,
		"DataService.RegisterHandler: a handler is already registered for namespace \"" .. handler.Namespace .. "\""
	)

    _handlersByNamespace[handler.Namespace] = handler
    table.insert(_handlers, handler)
end

local function buildContext(): Context
	local leaderstats = Instance.new("Folder")
	leaderstats.Name = "leaderstats"

	return {
		leaderstats = leaderstats,
		LeaderstatsAdapter  = LeaderStatsAdapter.new(leaderstats),
	} :: Context
end

local function resolveLoad(player: Player, success: boolean)
	local signal = _loadedSignals[player]
	if signal then
		signal:Fire(success)
	end
end

local function loadHandlers(player: Player, ctx: Context, data: DataSchema.PlayerData)
	for _, handler in _handlers do
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

local function saveHandlers(player: Player, ctx: Context, previous: DataSchema.PlayerData): DataSchema.PlayerData
	local data: DataSchema.PlayerData = {}

	for _, handler in _handlers do
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

local function onPlayerAdded(player: Player)
    assert(_session ~= nil, "DataService: Start() must be called before players can join")
    local session = _session :: SessionManager.SessionManager

    local acquireStatus, record = session:Acquire(player.UserId)

    if acquireStatus ~= "Acquired" or record == nil then
        warn(("DataService:Failed to acquire session for %s (%s)"): format(player.Name, acquireStatus))
        resolveLoad(player, false)
        player:Kick("We couldn't load your data. Please rejoin in a moment. If this persists contact support")
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
        LastSaved = now(),
    }

    _playerStates[player] = state

    loadHandlers(player, ctx, data)

    if not player.Parent then
        session:Release(player.UserId, sessionId :: string, data)
        _playerStates[player] = nil
        resolveLoad(player, false)
        return
    end

    ctx.leaderstats.Parent = player
    
    state.State = "Loaded"
    resolveLoad(player, true)
end

local function onPlayerRemoving(player: Player)
	local state = _playerStates[player]
	_playerStates[player] = nil

	if state == nil or state.State ~= "Loaded" then
		return
	end
	local session = _session :: SessionManager.SessionManager

	state.State = "Releasing"

	local data = saveHandlers(player, state.Ctx, state.Data)

	local releaseStatus = session:Release(player.UserId, state.SessionId, data)
	if releaseStatus ~= "Released" then
		warn(("DataService: release failed for %s (%s), lock may go stale"):format(player.Name, releaseStatus))
		state.State = "Failed"
	else
		state.State = "Released"
	end

	local signal = _loadedSignals[player]
	if signal then
		_loadedSignals[player] = nil
	end
end

function DataService.SaveNow(player: Player): boolean
    assert(typeof(player) == "Instance" and player:IsA("Player"), "DataService.SaveNow: player must be a Player")

    local state = _playerStates[player]
    if state == nil or state.State ~= "Loaded" then
        return false
    end

    local session = _session :: SessionManager.SessionManager

    local data = saveHandlers(player, state.Ctx, state.Data)
    state.Data = data

    local status = session:Save(player.UserId, state.SessionId, data)
    if status ~= "Saved" then
        warn(("DataService: SaveNow failed for %s (%s)"):format(player.Name, status))
		return false
	end

    state.LastSaved = now()
    return true
end

function DataService.IsLoaded(player: Player): boolean
    local state = _playerStates[player]
    return state ~= nil and state.State == "Loaded"
end

function DataService.WaitForLoad(player: Player): boolean
	assert(typeof(player) == "Instance" and player:IsA("Player"), "DataService.WaitForLoad: player must be a Player")

	if DataService.IsLoaded(player) then
		return true
	end

	local signal = _loadedSignals[player]
    if not signal then
        signal = Instance.new("BindableEvent")
        _loadedSignals[player] = signal
    end

	local success = signal.Event:Wait()
	return success == true
end

local function autosaveLoop()
    while true do
        task.wait(DataSchema.Timing.AutosaveMinSeconds)

        local nowTime = now()
        for player, state in _playerStates do
            if state.State == "Loaded" and (nowTime - state.LastSaved) >= DataSchema.Timing.AutosaveMinSeconds then
                DataService.SaveNow(player)
            end
        end
    end
end

function DataService.Get(player: Player, namespace: string): any?
	assert(typeof(player) == "Instance" and player:IsA("Player"), "DataService.Get: player must be a Player")
	assert(type(namespace) == "string" and namespace ~= "", "DataService.Get: namespace must be a non-empty string")
	assert(
		_handlersByNamespace[namespace] ~= nil,
		"DataService.Get: no handler registered for namespace \"" .. namespace .. "\""
	)

	local state = _playerStates[player]
	if state == nil or state.State ~= "Loaded" then
		return nil
	end

	local value = state.Data[namespace]
	if value == nil then
		return nil
	end

	return TableUtil.DeepCopy(value)
end

function DataService.Start()
	assert(not _started, "DataService.Start: already started")
	assert(#_handlers > 0, "DataService.Start: at least one handler must be registered before Start()")

	_started = true

	local storeHandler = StoreHandler.new(DataSchema.STORE_NAME)
	local serverId = if game.JobId ~= "" then game.JobId else HttpService:GenerateGUID(false)
	_session = SessionManager.new(storeHandler, serverId)

	Players.PlayerAdded:Connect(onPlayerAdded)
	Players.PlayerRemoving:Connect(onPlayerRemoving)

	for _, player in Players:GetPlayers() do
		task.spawn(onPlayerAdded, player)
	end

	task.spawn(autosaveLoop)
end

return DataService