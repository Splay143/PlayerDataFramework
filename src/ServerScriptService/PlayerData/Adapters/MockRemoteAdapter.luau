--!strict
--@Splay

--[[
	MockRemoteAdapter

	An in-memory stand-in for RemoteAdapter. Fake players are plain tables, so tests
	never need real Player instances.

	The test plays the client: SimulateSend, SimulateRequest and SimulateSnapshotRequest
	deliver "client" calls, and ReplicatedTo reads back what the server sent.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Protocol = require(ReplicatedStorage.PlayerDataShared.Shared.Protocol)
local RemoteAdapter = require(ServerScriptService.PlayerData.Adapters.RemoteAdapter)
local TableUtil = require(ReplicatedStorage.PlayerDataShared.Shared.TableUtil)

export type MockRemoteAdapter = RemoteAdapter.Adapter & {
	SimulateSend: (self: MockRemoteAdapter, player: Player, route: any, payload: any) -> (),
	SimulateRequest: (self: MockRemoteAdapter, player: Player, route: any, payload: any) -> any,
	SimulateSnapshotRequest: (self: MockRemoteAdapter, player: Player) -> (),
	ReplicatedTo: (self: MockRemoteAdapter, player: Player) -> { Protocol.Message },
}

type Listener<Callback> = {
	Callback: Callback,
	Active: boolean,
}

local MockRemoteAdapter = {}
MockRemoteAdapter.__index = MockRemoteAdapter

local function addListener<Callback>(listeners: { Listener<Callback> }, callback: Callback): RemoteAdapter.Disconnect
	local listener: Listener<Callback> = { Callback = callback, Active = true }
	table.insert(listeners, listener)

	return function()
		listener.Active = false
	end
end

function MockRemoteAdapter.new(): MockRemoteAdapter
	local self = setmetatable({
		_replicated = {} :: { [any]: { Protocol.Message } },
		_snapshotListeners = {} :: { Listener<RemoteAdapter.SnapshotHandler> },
		_sendListeners = {} :: { Listener<RemoteAdapter.IncomingHandler> },
		_requestHandler = nil :: RemoteAdapter.RequestHandler?,
	}, MockRemoteAdapter)

	return (self :: any) :: MockRemoteAdapter
end

function MockRemoteAdapter.SendReplication(self: any, player: Player, message: Protocol.Message)
	assert(player :: any ~= nil, "MockRemoteAdapter:SendReplication: player must not be nil")
	assert(
		Protocol.IsValidMessage(message),
		"MockRemoteAdapter:SendReplication: message is not a valid protocol message"
	)

	local sent = self._replicated[player]
	if sent == nil then
		sent = {}
		self._replicated[player] = sent
	end
	table.insert(sent, TableUtil.DeepCopy(message))
end

function MockRemoteAdapter.OnSnapshotRequested(
	self: any,
	handler: RemoteAdapter.SnapshotHandler
): RemoteAdapter.Disconnect
	assert(type(handler) == "function", "MockRemoteAdapter:OnSnapshotRequested: handler must be a function")
	return addListener(self._snapshotListeners, handler)
end

function MockRemoteAdapter.OnSend(self: any, handler: RemoteAdapter.IncomingHandler): RemoteAdapter.Disconnect
	assert(type(handler) == "function", "MockRemoteAdapter:OnSend: handler must be a function")
	return addListener(self._sendListeners, handler)
end

function MockRemoteAdapter.SetRequestHandler(self: any, handler: RemoteAdapter.RequestHandler)
	assert(type(handler) == "function", "MockRemoteAdapter:SetRequestHandler: handler must be a function")
	assert(self._requestHandler == nil, "MockRemoteAdapter:SetRequestHandler: a request handler is already set")
	self._requestHandler = handler
end

function MockRemoteAdapter.Destroy(self: any)
	table.clear(self._snapshotListeners)
	table.clear(self._sendListeners)
	self._requestHandler = nil
end

function MockRemoteAdapter.SimulateSnapshotRequest(self: any, player: Player)
	local listeners: { Listener<RemoteAdapter.SnapshotHandler> } = table.clone(self._snapshotListeners)

	for _, listener in listeners do
		if listener.Active then
			xpcall(listener.Callback, function(callbackError: any)
				warn(("MockRemoteAdapter: a snapshot handler errored: %s"):format(tostring(callbackError)))
			end, player)
		end
	end
end

function MockRemoteAdapter.SimulateSend(self: any, player: Player, route: any, payload: any)
	local listeners: { Listener<RemoteAdapter.IncomingHandler> } = table.clone(self._sendListeners)

	for _, listener in listeners do
		if listener.Active then
			-- A fresh copy per listener, like each real connection getting its own deserialised args.
			xpcall(listener.Callback, function(callbackError: any)
				warn(("MockRemoteAdapter: a send handler errored: %s"):format(tostring(callbackError)))
			end, player, route, TableUtil.DeepCopy(payload))
		end
	end
end

function MockRemoteAdapter.SimulateRequest(self: any, player: Player, route: any, payload: any): any
	local handler = self._requestHandler
	assert(handler ~= nil, "MockRemoteAdapter:SimulateRequest: no request handler is set")
	return handler(player, route, TableUtil.DeepCopy(payload))
end

function MockRemoteAdapter.ReplicatedTo(self: any, player: Player): { Protocol.Message }
	return TableUtil.DeepCopy(self._replicated[player] or {})
end

return MockRemoteAdapter
