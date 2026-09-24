--!strict
--@Splay

local ServerScriptService = game:GetService("ServerScriptService")
local DataSchema = require(ServerScriptService.PlayerData.Config.DataSchema)
local DataStoreAdapter = require(ServerScriptService.PlayerData.Adapters.DataStoreAdapter)

export type Status = "Ok" | "Cancelled" | "Failed"

export type Adapter = {
	GetAsync: (self: Adapter, key:string) -> any,
	UpdateAsync: (self: Adapter, key: string, transform:  (any?) -> any?) -> any?,
}

export type Options = {
	MaxAttempts: number?,
	BaseBackoffSeconds: number?,
	MaxBackoffSeconds: number?,
	
	Wait: ((seconds: number) -> ())?,
}

export type StoreHandler = {
	Get: (self: StoreHandler, key: string) -> (Status, any?),
	Update: (self: StoreHandler, key:string, transform: (any?) -> any?) -> (Status, any?),
}

local StoreHandler = {}
StoreHandler .__index = StoreHandler


function StoreHandler.ExponentialBackoff(attempt: number, baseSeconds: number, maxSeconds: number): number
	assert(attempt >= 1, "StoreHandler.ExponentialBackoff: attempt must be at least 1")
	assert(baseSeconds >= 0, "StoreHandler.ExponentialBackoff: baseSeconds must be at least 0")
	assert(maxSeconds >= baseSeconds, "StoreHandler.ExponentialBackoff maxSeconds must be at least baseSeconds")
	return math.min(baseSeconds *(2 ^ (attempt - 1)), maxSeconds)
end

function StoreHandler.new(storeName: string, adapter: Adapter?, options: Options?): StoreHandler
	assert(type(storeName) == "string" and storeName ~= "", "StoreHandler.new: storeName must be a non-empty string")
	
	
	local resolvedAdapter: Adapter
	if adapter ~= nil then
		resolvedAdapter = adapter
	else
		resolvedAdapter = DataStoreAdapter.new(storeName)
	end
	
	local maxAttempts = (options and options.MaxAttempts) or DataSchema.Store.MaxAttempts
	local baseBackoff = (options and options.BaseBackoffSeconds) or DataSchema.Store.BaseBackoffSeconds
	local maxBackoff = (options and options.MaxBackoffSeconds) or DataSchema.Store.MaxBackoffSeconds
	local wait = (options and options.Wait) or function(seconds: number)
		task.wait(seconds)
	end

	assert(maxAttempts >= 1, "StoreHandler.new: MaxAttempts must be at least 1")
	assert(baseBackoff >= 0, "StoreHandler.new: BaseBackoffSeconds must be at least 0")
	assert(maxBackoff >= baseBackoff, "StoreHandler.new: MaxBackoffSeconds must be at least BaseBackoffSeconds")

	local self = setmetatable({
		_adapter = resolvedAdapter,
		_maxAttempts = maxAttempts,
		_baseBackoff = baseBackoff,
		_maxBackoff = maxBackoff,
		_wait = wait,
	}, StoreHandler)

	return (self :: any) :: StoreHandler
end

local function backoffIfMoreAttemptsRemain(self, attempt: number)
	if attempt < self._maxAttempts then
		self._wait(StoreHandler.ExponentialBackoff(attempt, self._baseBackoff, self._maxBackoff))
	end
end

function StoreHandler:Get(key: string): (Status, any?)
	assert(type(key) == "string" and key ~= "", "StoreHandler:Get: key must be a non-empty string")
	
	local attempt = 0
	while true do
		attempt += 1
		local ok, result = pcall(function()
			return self._adapter:GetAsync(key)
		end)
		
		if ok then
			return "Ok", result
		end
		
		if attempt >= self._maxAttempts then
			return "Failed", nil
		end
		backoffIfMoreAttemptsRemain(self, attempt)
	end
end

function StoreHandler:Update(key: string, transform: (any?) -> any?): (Status, any?)
	assert(type(key) == "string" and key ~= "", "StoreHandler:Update: key must be a non-empty string")
	assert(type(transform) == "function", "StoreHandler:Update: transform must be a function")

	local attempt = 0
	while true do
		attempt += 1

		local cancelled = false
		local wrappedTransform = function(current: any?): any?
			local result = transform(current)
			if result == nil then
				cancelled = true
			end
			return result
		end

		local ok, result = pcall(function()
			return self._adapter:UpdateAsync(key, wrappedTransform)
		end)

		if ok then
			if cancelled then
				return "Cancelled", nil
			end
			return "Ok", result
		end

		if attempt >= self._maxAttempts then
			return "Failed", nil
		end
		backoffIfMoreAttemptsRemain(self, attempt)
	end
end

return StoreHandler