--!strict
--@Splay

--[[
	ExampleHandler

	Reference implementation of the Handler contract (Utils/BaseUtil.luau).
	Copy this file as the starting point for a real section handler.

	A handler owns exactly one Namespace of PlayerData and is the only code
	that ever touches that namespace's raw value. DataService never reads
	or writes it directly - it only calls these five functions and passes
	whatever comes back through.

	Contract:
		Default()        -> a value for a namespace that's never been saved
		Sanitize(raw)     -> raw, possibly nil/stale/corrupt, in; a safe
		                      value out. Must handle raw == nil the same way
		                      as Default() would.
		Load(plr, ctx, v) -> turn a safe value into visible/usable state
		                      (leaderstats via the adapter, etc.)
		Save(plr, ctx)    -> read that visible state back into a plain value
]]

local ServerScriptService = game:GetService("ServerScriptService")
local BaseUtil = require(ServerScriptService.PlayerData.Utils.BaseUtil)

export type ExampleData = {
	Points: number,
	LoginCount: number,
}

local MAX_POINTS = 1_000_000
local MAX_LOGIN_COUNT = 1_000_000

local ExampleHandler = {}

print("Examplehandler is running")
-- Must be unique across every handler passed to DataService.RegisterHandler.
ExampleHandler.Namespace = "Example"
ExampleHandler.Key = "Example"

function ExampleHandler.Default(): ExampleData
	return {
		Points = 0,
		LoginCount = 0,
	}
end

function ExampleHandler.Sanitize(raw: any?): ExampleData
	local rawTable = BaseUtil.AsTable(raw)
	return {
		Points = BaseUtil.SanitizeInt(rawTable.Points, 0, 0, MAX_POINTS),
		LoginCount = BaseUtil.SanitizeInt(rawTable.LoginCount, 0, 0, MAX_LOGIN_COUNT),
	}
end

function ExampleHandler.Load(player: Player, ctx: BaseUtil.Context, value: any): ()
	assert(typeof(player) == "Instance" and player:IsA("Player"), "ExampleHandler.Load: player must be a Player")

	local data = value :: ExampleData
	ctx.LeaderstatsAdapter:ShowInLeaderStats("Points", data.Points)
	-- LoginCount is intentionally not shown - no live write path for it yet, see the open note in playerdata-framework.md
end

function ExampleHandler.Save(player: Player, ctx: BaseUtil.Context): any
	assert(typeof(player) == "Instance" and player:IsA("Player"), "ExampleHandler.Save: player must be a Player")

	return {
		Points = ctx.LeaderstatsAdapter:Get("Points") or 0,
		LoginCount = 0,
	} :: ExampleData
end
print("Examplehandler ran")
return ExampleHandler