--!strict
--@Splay

local Protocol = require(script.Parent.Protocol)
local TableUtil = require(script.Parent.TableUtil)

export type PathKey = string | number

export type Change = {
	Type: string,
	Path: { PathKey },
	Value: any?,
}

local DeltaUtil = {}

local function extendPath(path: { PathKey }, key: PathKey): { PathKey }
	local extended = table.clone(path)
	table.insert(extended, key)
	return extended
end

-- Numbers sort before strings so mixed-key tables still have one stable order.
local function keyOrder(a: PathKey, b: PathKey): boolean
	local aIsNumber = type(a) == "number"
	local bIsNumber = type(b) == "number"
	if aIsNumber ~= bIsNumber then
		return aIsNumber
	end
	return (a :: any) < (b :: any)
end

local function collectSortedKeys(oldTable: { [any]: any }, newTable: { [any]: any }): { PathKey }
	local seen: { [PathKey]: boolean } = {}
	local keys: { PathKey } = {}

	for _, source in { oldTable, newTable } do
		for key in source do
			assert(
				type(key) == "string" or type(key) == "number",
				"DeltaUtil.Diff: replicated tables may only use string or number keys"
			)
			if not seen[key] then
				seen[key] = true
				table.insert(keys, key)
			end
		end
	end

	table.sort(keys, keyOrder)
	return keys
end

local function addSet(changes: { Change }, path: { PathKey }, value: any)
	-- Copied because the change waits in a queue and the source table may be mutated before it is sent.
	table.insert(changes, {
		Type = Protocol.ChangeType.Set,
		Path = path,
		Value = TableUtil.DeepCopy(value),
	})
end

local diffValue

local function diffChildren(oldTable: { [any]: any }, newTable: { [any]: any }, path: { PathKey }, changes: { Change })
	for _, key in collectSortedKeys(oldTable, newTable) do
		local oldChild = oldTable[key]
		local newChild = newTable[key]
		local childPath = extendPath(path, key)

		if newChild == nil then
			table.insert(changes, { Type = Protocol.ChangeType.Remove, Path = childPath })
		elseif oldChild == nil then
			addSet(changes, childPath, newChild)
		else
			diffValue(oldChild, newChild, childPath, changes)
		end
	end
end

function diffValue(oldValue: any, newValue: any, path: { PathKey }, changes: { Change })
	if type(oldValue) ~= "table" or type(newValue) ~= "table" then
		if oldValue ~= newValue then
			addSet(changes, path, newValue)
		end
		return
	end

	-- Past the depth cap the receiver would reject a longer path, so replace the whole subtree instead.
	if #path >= Protocol.Limits.MaxPathDepth then
		if not TableUtil.DeepEqual(oldValue, newValue) then
			addSet(changes, path, newValue)
		end
		return
	end

	-- A different kind or array length always means different content, so no deeper comparison is needed.
	local oldIsArray = TableUtil.IsArray(oldValue)
	local newIsArray = TableUtil.IsArray(newValue)
	if oldIsArray ~= newIsArray or (oldIsArray and #oldValue ~= #newValue) then
		addSet(changes, path, newValue)
		return
	end

	diffChildren(oldValue, newValue, path, changes)
end

function DeltaUtil.Diff(oldData: { [any]: any }, newData: { [any]: any }): { Change }
	assert(type(oldData) == "table", "DeltaUtil.Diff: oldData must be a table")
	assert(type(newData) == "table", "DeltaUtil.Diff: newData must be a table")

	local changes: { Change } = {}
	diffChildren(oldData, newData, {}, changes)
	return changes
end

return DeltaUtil
