--!strict
--@Splay

local ServerScriptService = game:GetService("ServerScriptService")
local DataSchema = require(ServerScriptService.PlayerData.Config.DataSchema)

export type SaveResult = "Saved" | "SkippedGap" | "NotLoaded" | "Failed"
export type PerformSave = (player: Player) -> SaveResult
export type GetBudget = () -> number

export type SaveUtil = {
	RequestSave: (self: SaveUtil, player: Player) -> (),
	Cancel: (self: SaveUtil, player: Player) -> (),
	Update: (self: SaveUtil) -> (),
}

local SaveUtil = {}
SaveUtil.__index = SaveUtil

function SaveUtil.new(getBudget: GetBudget, performSave: PerformSave): SaveUtil
    assert(type(getBudget) == "function", "SaveUtil.new: getBudget must be a function")
	assert(type(performSave) == "function", "SaveUtil.new: performSave must be a function")

    local self = setmetatable({
        _getBudget = getBudget,
        _performSave = performSave,
        _queue = {} :: { Player },
        _queued = {} :: { [Player]: boolean},
        _cooldownUntil = 0,

    }, SaveUtil)

    return (self :: any) :: SaveUtil
end

function SaveUtil:RequestSave(player: Player)
	assert(typeof(player) == "Instance" and player:IsA("Player"), "SaveUtil:RequestSave: player must be a Player")

	if self._queued[player] then
		return -- already pending, dedup
	end

	self._queued[player] = true
	table.insert(self._queue, player)
end

function SaveUtil:Cancel(player: Player)
	if not self._queued[player] then
		return
	end

	self._queued[player] = nil
	for i, queuedPlayer in self._queue do
		if queuedPlayer == player then
			table.remove(self._queue, i)
			break
		end
	end
end

function SaveUtil:Update()
	if #self._queue == 0 then
		return
	end

	if os.time() < self._cooldownUntil then
		return -- backing off after a recent failure; try again on a later tick
	end

	local budget: number = self._getBudget()
	local allowance = math.floor(budget * DataSchema.Store.SaveQueueBudgetFraction)
	if allowance <= 0 then
		return -- not enough safe budget this tick; wait rather than force it
	end

	local sendCount = math.min(allowance, #self._queue)

	for _ = 1, sendCount do
		local player = table.remove(self._queue, 1)
		if player == nil then
			break
		end
		self._queued[player] = nil

		local result = self._performSave(player)
		if result == "Failed" then
			self._cooldownUntil = os.time() + DataSchema.Store.SaveQueueCooldownSeconds
			break
		end
	end
end

return SaveUtil