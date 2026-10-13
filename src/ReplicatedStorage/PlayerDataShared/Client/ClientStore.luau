--!strict
--@Splay

local Shared = script.Parent.Parent.Shared

local DeltaUtil = require (Shared.DeltaUtil)
local Protocol = require(Shared.Protocol)
local TableUtil = require(Shared.TableUtil)

export type ApplyStatus = "Applied" | "Ignored" | "NeedsSnapshot"

type Listener = {
    Callback: (value: any?) -> (),
    Active: boolean,
}

export type ClientStore = {
	Apply: (self: ClientStore, message: Protocol.Message) -> ApplyStatus,
	Get: (self: ClientStore, key: string) -> any?,
	Changed: (self: ClientStore, key: string, callback: (value: any?) -> ()) -> () -> (),
	IsReady: (self: ClientStore) -> boolean,
}

local ClientStore = {}
ClientStore.__index = ClientStore

function ClientStore.new(): ClientStore
    local self = setmetatable({
        _data = {} :: { [string]: any},
        _sequence = 0,
        _ready = false,
        _stale = false,
        _listeners = {} :: { [string]: { Listener} },
    }, ClientStore)

    return (self :: any) :: ClientStore
end

local function changedKeysBetween(previous: { [string]: any}, current: { [string]: any}): { string }
    local keys: { string} = {}
    local seen: { [string]: boolean } = {}

    for _, source in { previous , current } do
        for key in source do
            if not seen[key] then
                seen[key] = true
                if not TableUtil.DeepEqual(previous[key], current[key]) then
                    table.insert(keys, key)
                end
            end
        end
    end
    return keys
end

local function changedKeysFrom(changes: { any }): { string }
    local keys: { string} = {}
    local seen: { [string]: boolean } = {}

    for _, change in changes do
        local key = change.Path[1]
        if type(key) == "string" and not seen[key] then
            seen[key] = true
            table.insert(keys, key)
        end
    end
    return keys
end

local function notify(self: any, keys: { string })
	for _, key in keys do
		local listeners: { Listener }? = self._listeners[key]
		if listeners ~= nil then
			for _, listener in table.clone(listeners) do
				if listener.Active then
					task.spawn(listener.Callback, TableUtil.DeepCopy(self._data[key]))
				end
			end
		end
	end
end

local function applySnapshot(self: any, message: Protocol.SnapshotMessage): ApplyStatus
    if self._ready and message.Sequence <= self._sequence then
        return "Ignored"
    end

    local previous = self._data
    self._data = TableUtil.DeepCopy(message.Data)
    self._sequence = message.Sequence
    self._ready = true
    self._stale = false
    	notify(self, changedKeysBetween(previous, self._data))
    return "Applied"
end

local function applyDelta(self: any, message: Protocol.DeltaMessage): ApplyStatus
    if not self._ready or self._stale then
        return "Ignored"
    end

    if message.Sequence <= self._sequence then
        return "Ignored"
    end

    if message.Sequence ~= self._sequence + 1 then
        self._stale = true
        return "NeedsSnapshot"
    end

    local working = TableUtil.DeepCopy(self._data)
    if not DeltaUtil.Apply(working, message.Changes :: any) then
    self._stale = true
    return "NeedsSnapshot"
    end

    self._data = working
    self._sequence = message.Sequence
    notify(self, changedKeysFrom(message.Changes :: any))
    return "Applied"
end

function ClientStore.Apply(self: any, message: Protocol.Message): any?
    if not Protocol.IsValidMessage(message) then
        return "Ignored"
    end

    if message.Type == "Snapshot" then
        return applySnapshot(self, message)
    end
    return applyDelta(self, message)
end

function ClientStore.Get(self: any, key: string): any?
    assert(type(key) == "string" and key ~= "", "ClientStore.Get: Key must be a non-empty string")

    return TableUtil.DeepCopy(self._data[key])
end

function ClientStore.Changed(self: any, key: string, callback: (value: any?) -> ()): () -> ()
	assert(type(key) == "string" and key ~= "", "ClientStore:Changed: key must be a non-empty string")
	assert(type(callback) == "function", "ClientStore:Changed: callback must be a function")

	local listener: Listener = { Callback = callback, Active = true }
	local listeners = self._listeners[key]
	if listeners == nil then
		listeners = {}
		self._listeners[key] = listeners
	end
	table.insert(listeners, listener)

	return function()
		listener.Active = false
		local index = table.find(listeners, listener)
		if index ~= nil then
			table.remove(listeners, index)
		end
	end
end

function ClientStore.IsReady(self: any): boolean
    return self._ready
end

return ClientStore
    