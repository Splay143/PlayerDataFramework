--!strict
--@Splay

--[[
	Decides WHEN replication happens: it keeps one ReplicationState per loaded player,
	flushes them on a short interval, and sends only the messages that exist. A tick where
	nothing changed fires no remote at all.

	It never throws out of Flush: this runs forever for every player, so one player's bad
	data or a failed send must not stop replication for everyone else.
]]

local ServerScriptService = game:GetService("ServerScriptService")

local DataSchema = require(ServerScriptService.PlayerData.Config.DataSchema)
local RateLimiter = require(ServerScriptService.PlayerData.Utils.RateLimiter)
local RemoteAdapter = require(ServerScriptService.PlayerData.Adapters.RemoteAdapter)
local ReplicationState = require(ServerScriptService.PlayerData.Networking.ReplicationState)

export type RejectionReason = "UnknownPlayer" | "SnapshotRateLimited"

export type Options = {
	IntervalSeconds: number?,
	Now: (() -> number)?,
	OnRejected: ((player: Player, reason: RejectionReason) -> ())?,
}

export type ReplicationService = {
	Start: (self: ReplicationService) -> (),
	Stop: (self: ReplicationService) -> (),
	AddPlayer: (self: ReplicationService, player: Player) -> (),
	RemovePlayer: (self: ReplicationService, player: Player) -> (),
	Replicate: (self: ReplicationService, player: Player, key: string, value: { [any]: any }) -> (),
	Flush: (self: ReplicationService) -> (),
}

local Rejections = {
	UnknownPlayer = "UnknownPlayer" :: RejectionReason,
	SnapshotRateLimited = "SnapshotRateLimited" :: RejectionReason,
}

local SNAPSHOT_BUCKET = "Snapshot"

local ReplicationService = {}
ReplicationService.__index = ReplicationService

local function playerName(player: any): string
	return tostring(player.Name)
end

function ReplicationService.new(adapter: RemoteAdapter.Adapter, options: Options?): ReplicationService
	assert(type(adapter) == "table", "ReplicationService.new: adapter must be a RemoteAdapter")

	local interval = (options and options.IntervalSeconds) or DataSchema.Replication.IntervalSeconds
	assert(
		type(interval) == "number" and interval > 0,
		"ReplicationService.new: IntervalSeconds must be greater than 0"
	)

	local onRejected = options and options.OnRejected
	assert(
		onRejected == nil or type(onRejected) == "function",
		"ReplicationService.new: OnRejected must be a function when provided"
	)

	local limiter = RateLimiter.new({
		Capacity = DataSchema.Replication.SnapshotRequestCapacity,
		RefillPerSecond = DataSchema.Replication.SnapshotRequestRefillPerSecond,
	}, { Now = options and options.Now })

	local self = setmetatable({
		_adapter = adapter,
		_interval = interval,
		_onRejected = onRejected,
		_limiter = limiter,
		_states = {} :: { [any]: ReplicationState.ReplicationState },
		_started = false,
		_unsubscribe = nil :: (() -> ())?,
		_thread = nil :: thread?,
	}, ReplicationService)

	return (self :: any) :: ReplicationService
end

local function reject(self: any, player: Player, reason: RejectionReason)
	local hook = self._onRejected
	if hook == nil then
		return
	end

	xpcall(hook, function(hookError: any)
		warn(("ReplicationService: OnRejected errored: %s"):format(tostring(hookError)))
	end, player, reason)
end

local function onSnapshotRequested(self: any, player: Player)
	local state = self._states[player]
	if state == nil then
		reject(self, player, Rejections.UnknownPlayer)
	end

	if not self._limiter:TryConsume(player, SNAPSHOT_BUCKET) then
		reject(self, player, Rejections.SnapshotRateLimited)
		return
	end

	state:RequestSnapshot()
end

local function flushPlayer(self: any, player: Player, state: ReplicationState.ReplicationState)
	local built, result = pcall(function(...)
		return state:BuildMessage()
	end)

	if not built then
		warn(("ReplicationService: could not build a message for %s: %s"):format(playerName(player), tostring(result)))
		return
	end

	if result == nil then
		return
	end

	local sent, sendError = pcall(function()
		self._adapter:SendReplication(player, result)
	end)

	if not sent then
		warn(("ReplicationService: could not send to %s: %s"):format(playerName(player), tostring(sendError)))
		state:RequestSnapshot()
	end
end

function ReplicationService.Start(self: any)
	assert(not self._started, "ReplicationService:Start: already started")
	self._started = true

	self._unsubscribe = self._adapter:OnSnapshotRequested(function(player: Player)
		onSnapshotRequested(self, player)
	end)

	self._thread = task.spawn(function()
		while true do
			task.wait(self._interval)
			self:Flush()
		end
	end)
end

function ReplicationService.Stop(self: any)
	local unsubscribe = self._unsubscribe
	if unsubscribe ~= nil then
		self._unsubscribe = nil
		unsubscribe()
	end

	local thread = self._thread
	if thread ~= nil then
		self._thread = nil
		task.cancel(thread)
	end

	table.clear(self._states)
end

function ReplicationService.AddPlayer(self: any, player: Player)
	assert((player :: any) ~= nil, "ReplicationService:AddPlayer: player must not be nil")

	if self._states[player] == nil then
		self._states[player] = ReplicationState.new()
	end
end

function ReplicationService.RemovePlayer(self: any, player: Player)
	assert((player :: any) ~= nil, "ReplicationService:RemovePlayer: player must not be nil")

	self._states[player] = nil
	self._limiter:Remove(player)
end

function ReplicationService.Replicate(self: any, player: Player, key: string, value: { [any]: any })
	assert((player :: any) ~= nil, "ReplicationService:Replicate: player must not be nil")

	local state = self._states[player]
	if state == nil then
		return
	end

	state:MarkDirty(key, value)
end

function ReplicationService.Flush(self: any)
	local states: { [any]: ReplicationState.ReplicationState } = table.clone(self._states)

	for player, state in states do
		if self._states[player] == state then
			flushPlayer(self, player, state)
		end
	end
end

return ReplicationService
