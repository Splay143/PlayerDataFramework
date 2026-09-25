--!strict
--@Splay
export type ValueTypeName = "IntValue" | "NumberValue" | "StringValue" | "BoolValue"

export type LeaderstatsAdapter = {
	ShowInLeaderStats: (self: LeaderstatsAdapter, name: string, initialValue: any, valueType: ValueTypeName?) -> ValueBase,
	Get: (self: LeaderstatsAdapter, name: string) -> any?,
	Set: (self: LeaderstatsAdapter, name: string, value: any) -> (),
}

local LeaderstatsAdapter = {}
LeaderstatsAdapter.__index = LeaderstatsAdapter

local function inferValueType(value: any): ValueTypeName
	if type(value) == "boolean" then
		return "BoolValue"
	elseif type(value) == "string" then
		return "StringValue"
	elseif type(value) == "number" then
		if value == math.floor(value) then
			return "IntValue"
		end
		return "NumberValue"
	end
	error("LeaderstatsAdapter: cannot infer a leaderstat type for a " .. type(value) .. " value")
end

function LeaderstatsAdapter.new(leaderstatsFolder: Folder): LeaderstatsAdapter
	assert(
		typeof(leaderstatsFolder) == "Instance" and leaderstatsFolder:IsA("Folder"),
		"LeaderstatsAdapter.new: leaderstatsFolder must be a Folder"
	)

	local self = setmetatable({
		_folder = leaderstatsFolder,
	}, LeaderstatsAdapter)

	return (self :: any) :: LeaderstatsAdapter
end

function LeaderstatsAdapter:ShowInLeaderStats(name: string, initialValue: any, valueType: ValueTypeName?): ValueBase
	assert(type(name) == "string" and name ~= "", "LeaderstatsAdapter:ShowInLeaderStats: name must be a non-empty string")

	local resolvedType = valueType or inferValueType(initialValue)
	local existing: Instance? = self._folder:FindFirstChild(name)

	if existing ~= nil and existing.ClassName ~= resolvedType then
		warn(
			("LeaderstatsAdapter: \"%s\" already exists as %s, replacing with %s"):format(
				name,
				existing.ClassName,
				resolvedType
			)
		)
		existing:Destroy()
		existing = nil
	end

	if existing then
		(existing :: any).Value = initialValue
		return existing :: ValueBase
	end

	local stat = Instance.new(resolvedType :: any) :: ValueBase
	stat.Name = name
	;(stat :: any).Value = initialValue
	stat.Parent = self._folder
	return stat
end

function LeaderstatsAdapter:Get(name: string): any?
	assert(type(name) == "string" and name ~= "", "LeaderstatsAdapter:Get: name must be a non-empty string")

	local stat = self._folder:FindFirstChild(name)
	if stat == nil then
		return nil
	end
	return (stat :: any).Value
end

function LeaderstatsAdapter:Set(name: string, value: any)
	assert(type(name) == "string" and name ~= "", "LeaderstatsAdapter:Set: name must be a non-empty string")

	local stat = self._folder:FindFirstChild(name)
	assert(stat ~= nil, "LeaderstatsAdapter:Set: \"" .. name .. "\" was never registered via ShowInLeaderStats")

	;(stat :: any).Value = value
end

return LeaderstatsAdapter