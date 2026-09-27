--!strict
--@Splay

local ServerScriptService = game:GetService("ServerScriptService")
local ValueReplication = require(ServerScriptService.PlayerData.Utils.ValueReplication)

export type ValueTypeName = ValueReplication.ValueTypeName

export type PrivateAdapter = {
	Show: (self: PrivateAdapter, name: string, initialValue: any, valueType: ValueTypeName?) -> ValueBase,
	Get: (self: PrivateAdapter, name: string) -> any?,
	Set: (self: PrivateAdapter, name: string, value: any) -> (),
}


local PrivateAdapter = {}
PrivateAdapter.__index = PrivateAdapter

function PrivateAdapter.new(privateFolder: Folder): PrivateAdapter
    local self = setmetatable({
        _values = ValueReplication.new(privateFolder)
    }, PrivateAdapter)

    return (self :: any) :: PrivateAdapter
end

function PrivateAdapter:Show(name: string, initalValue: any, valueType: ValueTypeName?): ValueBase
    return self._values:Show(name, initalValue, valueType)
end

function PrivateAdapter:Get(name: string): any?
    return self._values:Get(name)
end

function PrivateAdapter:Set(name: string?, value: any)
    self._values:Set(name, value)
end

return PrivateAdapter