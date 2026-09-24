--!strict
--@Splay

local ServerScriptService = game:GetService("ServerScriptService")
local TableUtil = require(ServerScriptService.PlayerData.Utils.TableUtil)

export type Adapter = {
	GetAsync: (self: Adapter, key:string) -> any,
	UpdateAsync: (self: Adapter, key: string, transform:  (any?) -> any?) -> any?,
}

export type MockAdapter = Adapter & {
	FailNext: (self: MockAdapter, count: number) -> (),
	SetLatency: (self: MockAdapter, seconds: number) -> (),
	CallCount: (self: MockAdapter) -> number,
	Peek: (self: MockAdapter, key: string) -> any,
}

local MockAdapter = {}
MockAdapter.__index = MockAdapter

function MockAdapter.new(wait: ((seconds: number) -> ())?): MockAdapter
	local self = setmetatable({
		_store = {} :: { [string]: any},
		_failuresRemaining = 0,
		_latencySeconds = 0,
		_calls = 0,
		_wait = wait or function() end,
	}, MockAdapter)

	return (self :: any) :: MockAdapter
end

local function consumeFailure(self: any): boolean
	self._calls += 1
	if self._latencySeconds > 0 then
		self._wait(self._latencySeconds)
	end
	if self._failuresRemaining > 0 then
		self._failuresRemaining -= 1
		return true
	end
	return false
end

function MockAdapter:FailNext(count: number)
	assert(type(count) == "number" and count >= 0 and count == math.floor(count), "MockAdapter:FailNext: count must be a whole number of at least 0")
	self._failuresRemaining = count
end

function MockAdapter:SetLatency(seconds: number)
	assert(type(seconds) == "number" and seconds >= 0, "MockAdapter:SetLatency: seconds must be at least 0")
	self._latencySeconds = seconds
end

function MockAdapter:CallCount(): number
	return self._calls
end

function MockAdapter:Peek(key: string): any
	return self._store[key]
end

function MockAdapter:GetAsync(key: string): any
	assert(type(key) == "string" and key ~= "", "MockAdapter:GetAsync: key must be a non-empty string")
	if consumeFailure(self) then
		error("MockAdapter: simulated GetAsync failure")
	end
	return TableUtil.DeepCopy(self._store[key])
end

function MockAdapter:UpdateAsync(key: string, transform: (any?) -> any?): any
	assert(type(key) == "string" and key ~= "", "MockAdapter:UpdateAsync: key must be a non-empty string")
	assert(type(transform) == "function", "MockAdapter:UpdateAsync: transform must be a function")
	if consumeFailure(self) then
		error("MockAdapter: simulated UpdateAsync failure")
	end

	local current = TableUtil.DeepCopy(self._store[key])
	local updated = transform(current)
	if updated == nil then
		return nil
	end

	self._store[key] = TableUtil.DeepCopy(updated)
	return updated
end

return MockAdapter