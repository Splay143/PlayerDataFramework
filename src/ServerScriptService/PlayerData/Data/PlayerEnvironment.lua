--!strict
--@Splay

--[[
	PlayerEnvironment

	Everything DataService needs from the live Roblox world: which players exist,
	when they join and leave, what time it is, how folders get attached to a player,
	and what to do at shutdown. DataService only talks to this object, so tests can
	swap in a fake (Tests/FakeEnvironment) and drive a full join -> save -> leave
	lifecycle without real Player instances, which scripts cannot create.

	Join/leave notifications use the minimal PlayerSignal shape rather than
	RBXScriptSignal so a fake can provide one without a BindableEvent (which would
	copy fake-player tables and break identity lookups).
]]

local Players = game:GetService("Players")
local ServerScriptService = game:GetService("ServerScriptService")

local DataSchema = require(ServerScriptService.PlayerData.Config.DataSchema)
local BaseUtil = require(ServerScriptService.PlayerData.Utils.BaseUtil)

export type PlayerConnection = {
	Disconnect: (self: PlayerConnection) -> (),
}

export type PlayerSignal = {
	Connect: (self: PlayerSignal, callback: (player: Player) -> ()) -> PlayerConnection,
}

export type Environment = {
	PlayerAdded: PlayerSignal,
	PlayerRemoving: PlayerSignal,
	GetPlayers: () -> { Player },
	IsPlayer: (value: any) -> boolean,
	Now: () -> number,
	AttachFolders: (player: Player, ctx: BaseUtil.Context) -> (),
	BindToClose: (callback: () -> ()) -> (),
}

local PlayerEnvironment = {}

local function wrapSignal(signal: RBXScriptSignal): PlayerSignal
	return {
		Connect = function(_self: PlayerSignal, callback: (player: Player) -> ()): PlayerConnection
			local connection = signal:Connect(callback)
			return {
				Disconnect = function(_connection: PlayerConnection)
					connection:Disconnect()
				end,
			}
		end,
	}
end

local function attachFolders(player: Player, ctx: BaseUtil.Context)
	ctx.leaderstats.Parent = player

	task.spawn(function()
		local playerGui = player:WaitForChild("PlayerGui", DataSchema.Timing.PlayerGuiWaitSeconds)
		if playerGui == nil or (player.Parent :: any) == nil then
			return
		end
		ctx.privateFolder.Parent = playerGui
	end)
end

function PlayerEnvironment.Default(): Environment
	return {
		PlayerAdded = wrapSignal(Players.PlayerAdded),
		PlayerRemoving = wrapSignal(Players.PlayerRemoving),
		GetPlayers = function(): { Player }
			return Players:GetPlayers()
		end,
		IsPlayer = function(value: any): boolean
			return typeof(value) == "Instance" and value:IsA("Player")
		end,
		Now = function(): number
			return os.time()
		end,
		AttachFolders = attachFolders,
		BindToClose = function(callback: () -> ())
			game:BindToClose(callback)
		end,
	}
end

return PlayerEnvironment