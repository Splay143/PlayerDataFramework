--!strict
--@Splay

local ServerScriptService = game:GetService("ServerScriptService")
local DataSchema = require(ServerScriptService.PlayerData.Config.DataSchema)

export type SaveResult = "Saved" | "SkippedGap" | "NotLoaded" | "Failed"

export type Options = {
	Now: (() -> number)?,
}

export type SaveUtil<Key> = {
	RequestSave: (self: SaveUtil<Key>, key: Key) -> (),
	Cancel: (self: SaveUtil<Key>, key: Key) -> (),
	Update: (self: SaveUtil<Key>) -> (),
}

local SaveUtil = {}
SaveUtil.__index = SaveUtil

function SaveUtil.new<Key>(getBudget: () -> number, performSave: (key: Key) -> SaveResult, options: Options?): SaveUtil<Key>
	assert(type(getBudget) == "function", "SaveUtil.new: getBudget must be a function")
	assert(type(performSave) == "function", "SaveUtil.new: performSave must be a function")

	local now: () -> number = (options and options.Now) or function()
		return os.time()
	end

	local self = setmetatable({
		_getBudget = getBudget,
		_performSave = performSave,
		_now = now,
		_queue = {} :: { Key },
		_queued = {} :: { [Key]: boolean },
		_cooldownUntil = 0,
	}, SaveUtil)

	return (self :: any) :: SaveUtil<Key>
end

function SaveUtil:RequestSave<Key>(key: Key)
	assert(key ~= nil, "SaveUtil:RequestSave: key must not be nil")

	if self._queued[key] then
		return -- already pending, dedup
	end

	self._queued[key] = true
	table.insert(self._queue, key)
end

function SaveUtil:Cancel<Key>(key: Key)
	if not self._queued[key] then
		return
	end

	self._queued[key] = nil
	for i, queuedKey in self._queue do
		if queuedKey == key then
			table.remove(self._queue, i)
			break
		end
	end
end

function SaveUtil.Update(self: any)
	if #self._queue == 0 then
		return
	end

	if self._now() < self._cooldownUntil then
		return -- backing off after a recent failure; try again on a later tick
	end

	local budget: number = self._getBudget()
	local allowance = math.floor(budget * DataSchema.Store.SaveQueueBudgetFraction)
	if allowance <= 0 then
		return -- not enough safe budget this tick; wait rather than force it
	end

	local sendCount = math.min(allowance, #self._queue)

	for _ = 1, sendCount do
		local key = table.remove(self._queue, 1)
		if key == nil then
			break
		end
		self._queued[key] = nil

		local result = self._performSave(key)
		if result == "Failed" then
			self._cooldownUntil = self._now() + DataSchema.Store.SaveQueueCooldownSeconds
			break
		end
	end
end

return SaveUtil