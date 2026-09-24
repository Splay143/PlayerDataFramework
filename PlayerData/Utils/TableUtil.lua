--!strict
--@Splay

local TableUtil = {}

local function copy(value: any, seen: { [any]: any}): any
	if type(value) ~= "table" then
		return value
	end
	
	local existing = seen[value]
	if existing ~= nil then
		return existing
	end
	
	local result: { [any]: any} = {}
	seen[value] = result
	
	for key, child in pairs(value) do
		result[key] = copy(child, seen)
	end
	return result
end

function TableUtil.DeepCopy<T>(value: T): T
	return copy(value, {}) :: any
end

function TableUtil.Count(value: any): number
	if type(value) ~= "table" then
		return 0
	end

	local count = 0
	for _ in pairs(value) do
		count += 1
	end
	return count
end

function TableUtil.IsArray(value: any): boolean
	if type(value) ~= "table" then
		return false
	end
	
	local count = 0
	
	for _ in pairs(value) do
		count += 1
	end
	
	for index = 1, count do
		if value[index] == nil then
			return false
		end
	end
	return true
end

function TableUtil.DeepEqual(a: any, b: any): boolean
	if a == b then
		return true
	end
	
	if type(a) ~= "table" or type(b) ~= "table" then
		return false
	end
	
	for key, value in pairs(a) do
		if not TableUtil.DeepEqual(value, b[key]) then
			return false
		end
	end
	for key in pairs(b) do
		if a[key] == nil then
			return false
		end
	end
	return true
end

function TableUtil.Reconcile(target: any, defaults: any): any
	if type(defaults) ~= "table" then
		if target == nil then
			return defaults
		end
		return target
	end

	if type(target) ~= "table" then
		return TableUtil.DeepCopy(defaults)
	end

	for key, defaultValue in pairs(defaults) do
		local current = target[key]
		if current == nil then
			target[key] = TableUtil.DeepCopy(defaultValue)
		elseif type(defaultValue) == "table" then
			if type(current) ~= "table" then
				target[key] = TableUtil.DeepCopy(defaultValue)
			elseif not TableUtil.IsArray(defaultValue) then
				TableUtil.Reconcile(current, defaultValue)
			end
		end
	end

	return target
end

function TableUtil.ToSet(list: any): { [string]: boolean}
	local set: { [string]: boolean } = {}
	if type(list) ~= "table" then
		return set
	end
	
	for _, item in pairs(list) do
		if type(item) == "string" and item ~= "" then
			set[item] = true
		end
	end
	return set
end

function TableUtil.ToArray(set: any): { string }
	local list: { string } = {}
	if type(set) ~= "table" then
		return list
	end
	
	for key, value in pairs(set) do if type(key) == "string" and value == true then
			table.insert(list, key)
		end
	end
	table.sort(list)
	return list
end

return TableUtil