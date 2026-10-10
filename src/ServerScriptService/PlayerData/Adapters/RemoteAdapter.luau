--!strict
--@ Splay

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Protocol = require(ReplicatedStorage.PlayerDataShared.Shared.Protocol)

export type Disconnect = () -> ()
export type SnapshotHandler = (player: Player) -> ()
export type IncomingHandler = (player: Player, route: any, payload: any) -> ()
export type RequestHandler = (player: Player, route: any, payload: any) -> any

export type Adapter = {
	SendReplication: (self: Adapter, player: Player, message: Protocol.Message) -> (),
	OnSnapshotRequested: (self: Adapter, handler: SnapshotHandler) -> Disconnect,
	OnSend: (self: Adapter, handler: IncomingHandler) -> Disconnect,
	SetRequestHandler: (self: Adapter, handler: RequestHandler) -> (),
	Destroy: (self: Adapter) -> (),
}

local RemoteAdapter = {}
RemoteAdapter.__index = RemoteAdapter

local function newRemote(className: string, name: string, folder: Folder): Instance
	local remote = Instance.new(className)
	remote.Name = name
	remote.Parent = folder
	return remote
end

function RemoteAdapter.new(): Adapter
	assert(
		ReplicatedStorage:FindFirstChild(Protocol.RemoteFolderName) == nil,
		"RemoteAdapater.new: the remotes already exist, only one adapter can run at a time"
	)

	local folder = Instance.new("Folder")
	folder.Name = Protocol.RemoteFolderName

	local self = setmetatable({
		_folder = folder,
		_replication = newRemote("RemoteEvent", Protocol.RemoteNames.Replication, folder),
		_send = newRemote("RemoteEvent", Protocol.RemoteNames.Send, folder),
		_request = newRemote("RemoteFunction", Protocol.RemoteNames.Request, folder),
		_requestHandlerSet = false,
	}, RemoteAdapter)

	folder.Parent = ReplicatedStorage

	return (self :: any) :: Adapter
end

function RemoteAdapter.SendReplication(self: any, player: Player, message: Protocol.Message)
	assert(
		typeof(player) == "Instance" and player:IsA("Player"),
		"RemoteAdapter:SendReplication: player must be a Player"
	)
	assert(Protocol.IsValidMessage(message), "RemoteAdapter:SendReplication: message is not a valid protocol message")

	self._replication:FireClient(player, message)
end

function RemoteAdapter.OnSnapshotRequested(self: any, handler: SnapshotHandler): Disconnect
	assert(type(handler) == "function", "RemoteAdapter:OnSnapshotRequested: handler must be a function")

	-- Anything the client sends along with the signal is ignored on purpose.
	local connection = self._replication.OnServerEvent:Connect(function(player: Player)
		handler(player)
	end)

	return function()
		connection:Disconnect()
	end
end

function RemoteAdapter.SetRequestHandler(self: any, handler: RequestHandler)
	assert(type(handler) == "function", "RemoteAdapter:SetRequestHandler: handler must be a function")
	-- A RemoteFunction has exactly one callback, so a second one would silently replace the first.
	assert(not self._requestHandlerSet, "RemoteAdapter:SetRequestHandler: a request handler is already set")

	self._requestHandlerSet = true
	self._request.OnServerInvoke = function(player: Player, route: any, payload: any): any
		return handler(player, route, payload)
	end
end

function RemoteAdapter.Destroy(self: any)
	self._request.OnServerInvoke = nil
	self._folder:Destroy()
end

return RemoteAdapter
