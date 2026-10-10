--!strict
--@Splay
--[[
	One player's replication bookkeeping

	Changes are coalesced: marking a key dirty five times in one interval still produces
	one message, built from the key's latest value. The mirror is a private copy of what
	the client is known to hold, so a delta is only the real difference.

	A client has no baseline until it asks for a snapshot, so nothing else is sent to it
	before then. Dirty keys keep coalescing in the meantime.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local DeltaUtil = require(ReplicatedStorage.PlayerDataShared.Shared.DeltaUtil)
local Protocol = require(ReplicatedStorage.PlayerDataShared.Shared.Protocol)
local TableUtil = require(ReplicatedStorage.PlayerDataShared.Shared.TableUtil)

export type ReplicationState = {
	MarkDirty: (self: ReplicationState, key: string, value: { [any]: any }) -> (),
	RequestSnapshot: (self: ReplicationState) -> (),
	HasPending: (self: ReplicationState) -> boolean,
	BuildMessage: (self: ReplicationState) -> Protocol.Message?,
}


local ReplicationState = {}
ReplicationState.__index = ReplicationState

function ReplicationState.new(): ReplicationState
    local self = setmetatable({
		-- The latest value the game supplied per key. Held by reference on purpose, see MarkDirty.
		_latest = {} :: { [string]: any },
		-- What the client is known to hold. Always a private copy.
		_mirror = {} :: { [string]: any },
		_dirty = {} :: { [string]: boolean },
		_sequence = 0,
		_needsSnapshot = false,
		_ready = false,
	    }, ReplicationState)

    return (self :: any):: ReplicationState
end

function ReplicationState.MarkDirty(self: any, key: string, value: { [any]: any})
    assert(type(key) == "string" and key ~= "", "ReplicationState:MarkDirty: key must be a non-empty string")
	assert(type(value) == "table", "ReplicationState:MarkDirty: value must be a table")

    self._latest[key] = value
    self._dirty[key] = true
end

function ReplicationState.RequestSnapshot(self: any)
    self._needsSnapshot = true
end

function ReplicationState.HasPending(self: any): boolean
    	if self._needsSnapshot then
		return true
	end
    return self._ready and next(self._dirty) ~= nil
end

local function findProblem(value: any, inPath: { [any]: boolean }): string?
	local valueType = type(value)

	if valueType == "boolean" or valueType == "string" then
		return nil
	elseif valueType == "number" then
		-- NaN never equals itself, so it would look changed on every flush.
		if value ~= value or value == math.huge or value == -math.huge then
			return "a number that is NaN or infinite"
		end
		return nil
	elseif valueType ~= "table" then
		return "a value of type " .. valueType
	end

	if inPath[value] then
		return "a table that contains itself"
	end
	inPath[value] = true

	local hasNumberKey = false
	local hasStringKey = false

	for key, child in value do
		local keyType = type(key)
		if keyType == "number" then
			hasNumberKey = true
		elseif keyType == "string" then
			hasStringKey = true
		else
			return "a key of type " .. keyType
		end

		local problem = findProblem(child, inPath)
		if problem ~= nil then
			return problem
		end
	end


	if hasNumberKey and hasStringKey then
		return "a table that mixes number and string keys"
	end

	if hasNumberKey and not TableUtil.IsArray(value) then
		return "a number-keyed table with gaps or keys outside 1..n"
	end

	inPath[value] = nil
	return nil
end

local function rejectUnreplicable(self: any, keys: { [string]: any }): string?
	local report: string? = nil

	for key in keys do
		local problem = findProblem(self._latest[key], {})
		if problem ~= nil then
			self._latest[key] = nil
			self._dirty[key] = nil
			if report == nil then
				report = ('"%s" contains %s'):format(key, problem)
			end
		end
	end

	return report
end

local function buildSnapshot(self: any): Protocol.Message
    local report = rejectUnreplicable(self, self._latest)
	if report ~= nil then
		error("ReplicationState: dropped data that cannot be replicated: " .. report)
	end

    self._needsSnapshot = false
    self._ready = true

    -- A snapshot already contains every dirty key's latest value.
    table.clear(self._dirty)
    self._mirror = TableUtil.DeepCopy(self._latest)

    self._sequence += 1
    return Protocol.NewSnapshot(self._sequence, TableUtil.DeepCopy(self._mirror))
end

local function buildDelta(self: any): Protocol.Message?
    local report = rejectUnreplicable(self, self._dirty)
	if report ~= nil then
		-- Valid keys marked in the same interval stay dirty and go out on the next tick.
		error("ReplicationState: dropped data that cannot be replicated: " .. report)
	end

	-- Only the dirty keys are diffed, so unrelated replicated data costs nothing.
	local oldRoot: { [string]: any } = {}
	local newRoot: { [string]: any } = {}
	for key in self._dirty do
		oldRoot[key] = self._mirror[key]
		newRoot[key] = self._latest[key]
	end

	table.clear(self._dirty)

	local changes = DeltaUtil.Diff(oldRoot, newRoot)

	for key, value in newRoot do
		self._mirror[key] = TableUtil.DeepCopy(value)
	end

	-- Marked dirty but unchanged: send nothing and keep the sequence gapless.
	if #changes == 0 then
		return nil
	end

	self._sequence += 1
	return Protocol.NewDelta(self._sequence, changes)
end

function ReplicationState.BuildMessage(self: any): Protocol.Message?
    	if self._needsSnapshot then
		return buildSnapshot(self)
	end

    if not self._ready or next(self._dirty) == nil then
        return nil
    end

    return buildDelta(self)
end

return ReplicationState

