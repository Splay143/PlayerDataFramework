--!strict
--@Splay

--[[
	FakeEnvironment

	A pretend Roblox world for lifecycle tests. Fake players are plain tables with just the
	members DataService touches (Name, UserId, Parent, Kick). Leaving fires PlayerRemoving
	exactly as the real service would, and CloseServer mimics a real shutdown: everyone is
	removed first, then the BindToClose callbacks run.
]]

local ServerScriptService = game:GetService("ServerScriptService")

local PlayerEnvironment = require(ServerScriptService.PlayerData.Data.PlayerEnvironment)

export type FakeWorld = {
	Environment: PlayerEnvironment.Environment,
	Join: (name: string, userId: number) -> Player,
	Leave: (player: Player) -> (),
	CloseServer: () -> (),
	Advance: (seconds: number) -> (),
	WasAttached: (player: Player) -> boolean,
	KickReasonOf: (player: Player) -> string?,
}

local FakeEnvironment = {}

function FakeEnvironment.new(startTime: number): FakeWorld
	assert(type(startTime) == "number", "FakeEnvironment.new: startTime must be a number")

	local playerAdded = Instance.new("BindableEvent")
	local playerRemoving = Instance.new("BindableEvent")

	local present: { [Player]: boolean } = {}
	local attached: { [Player]: boolean } = {}
	local closeCallbacks: { () -> () } = {}
	local currentTime = startTime

	-- Any non-nil value works as a Parent: DataService only checks that it is not nil.
	local inGameMarker = {}

	local function leave(player: Player)
		local fake = player :: any
		if fake.Parent == nil then
			return
		end

		fake.Parent = nil
		present[player] = nil
		playerRemoving:Fire(player)
	end

	local function join(name: string, userId: number): Player
		assert(type(name) == "string" and name ~= "", "FakeWorld.Join: name must be a non-empty string")
		assert(type(userId) == "number", "FakeWorld.Join: userId must be a number")

		local fake: any = {
			Name = name,
			UserId = userId,
			Parent = inGameMarker,
			KickReason = nil,
		}
		function fake.Kick(self: any, reason: string?)
			self.KickReason = reason
			leave(self)
		end

		local player = fake :: Player
		present[player] = true
		playerAdded:Fire(player)
		return player
	end

	local environment: PlayerEnvironment.Environment = {
		PlayerAdded = playerAdded.Event,
		PlayerRemoving = playerRemoving.Event,
		GetPlayers = function(): { Player }
			local list: { Player } = {}
			for player in present do
				table.insert(list, player)
			end
			return list
		end,
		IsPlayer = function(value: any): boolean
			return type(value) == "table" and type(value.UserId) == "number" and type(value.Kick) == "function"
		end,
		Now = function(): number
			return currentTime
		end,
		AttachFolders = function(player: Player)
			attached[player] = true
		end,
		BindToClose = function(callback: () -> ())
			table.insert(closeCallbacks, callback)
		end,
	}

	return {
		Environment = environment,
		Join = join,
		Leave = leave,
		CloseServer = function()
			for _, player in environment.GetPlayers() do
				leave(player)
			end
			for _, callback in closeCallbacks do
				callback()
			end
		end,
		Advance = function(seconds: number)
			assert(type(seconds) == "number" and seconds >= 0, "FakeWorld.Advance: seconds must be at least 0")
			currentTime += seconds
		end,
		WasAttached = function(player: Player): boolean
			return attached[player] == true
		end,
		KickReasonOf = function(player: Player): string?
			return (player :: any).KickReason
		end,
	}
end

return FakeEnvironment