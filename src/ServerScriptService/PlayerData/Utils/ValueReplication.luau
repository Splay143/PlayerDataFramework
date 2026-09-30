--!strict
--@Splay

export type ValueTypeName = "IntValue" | "NumberValue" | "StringValue" | "BoolValue"

export type ValueReplication = {
	Show: (self: ValueReplication, name: string, initalValue: any, valueType: ValueTypeName?) -> ValueBase,
	Get: (self: ValueReplication, name: string) -> any?,
	Set: (Self: ValueReplication, name: string, value: any?) -> (),
}

local ValueReplication = {}
ValueReplication.__index = ValueReplication

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
	error("ValueReplication: cannot infer a value type for a " .. type(value) .. " value")
end

function ValueReplication.new(folder: Folder): ValueReplication
	assert(typeof(folder) == "Instance" and folder:IsA("Folder"), "ValueReplication.new: folder must be a Folder")

	local self = setmetatable({
		_folder = folder,
	}, ValueReplication)

	return (self :: any) :: ValueReplication
end

function ValueReplication:Show(name: string, initalValue: any, valueType: ValueTypeName?): ValueBase
	assert(type(name) == "string" and name ~= "", "ValueRepliction:Show: name must be a non-empty string")

	local resolvedType = valueType or inferValueType(initalValue)
	local existing: Instance? = self._folder:FindFirstChild(name)

	if existing ~= nil and existing.ClassName ~= resolvedType then
		warn(
			('ValueReplication: "%s" already exists as %s, replacing with %s'):format(
				name,
				existing.ClassName,
				resolvedType
			)
		)
		existing:Destroy()
		existing = nil
	end

	if existing then
		(existing :: any).Value = initalValue
		return existing :: ValueBase
	end

	local stat = Instance.new(resolvedType :: any) :: ValueBase
	stat.Name = name
	local newValueObject = stat :: any
	newValueObject.Value = initalValue
	stat.Parent = self._folder
	return stat
end

function ValueReplication:Get(name: string): any?
	assert(type(name) == "string" and name ~= "", "ValueReplication:Get: name must not be a non-empty string")

	local stat = self._folder:FindFirstChild(name)
	if stat == nil then
		return nil
	end
	return (stat :: any).Value
end

function ValueReplication:Set(name: string, value: any)
	assert(type(name) == "string" and name ~= "", "ValueReplication:Set: name must be a non-empty string")

	local stat = self._folder:FindFirstChild(name)
	assert(stat ~= nil, 'ValueReplication:Set "' .. name .. '" was never registered via show')
	local valueObject = stat :: any
	valueObject = value
end

return ValueReplication