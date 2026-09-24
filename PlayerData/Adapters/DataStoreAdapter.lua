--!strict
--@Splay

local DataStoreService = game:GetService("DataStoreService")

export type Adapter = {
	GetAsync: (self: Adapter, key:string) -> any,
	UpdateAsync: (self: Adapter, key: string, transform:  (any?) -> any?) -> any?,
}

local DataStoreAdapter = {}
DataStoreAdapter.__index = DataStoreAdapter

function DataStoreAdapter.new(storeName: string): Adapter
	assert(type(storeName) == "string" and storeName ~= "" , "DataStoreAdapater.new: storeName must be a non-empty string")
	
	local self = setmetatable({
		_store = DataStoreService:GetDataStore(storeName),
	}, DataStoreAdapter)
	
	return (self :: any) :: Adapter
end

function DataStoreAdapter:GetAsync(key: string): any
	assert(type(key) == "string" and key ~= "", "DataStoreAdapter:GetAsync: must be a non-empty string")
	return self._store:GetAsync(key)
end

function DataStoreAdapter:UpdateAsync(key: string, transform: (any?) -> any?): any?
	assert(type(key) == "string" and key ~= "", "DataStoreAdapter:UpdateAsync: key must be a non-empty string")
	assert(type(transform) == "function", "DataStoreAdapter:UpdateAsync: transform must be a function")
	return self._store:UpdateAsync(key, transform)
end

return DataStoreAdapter