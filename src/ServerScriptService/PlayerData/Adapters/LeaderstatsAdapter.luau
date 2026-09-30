--!strict
--@Splay

local ServerScriptService = game:GetService("ServerScriptService")
local ValueReplication = require(ServerScriptService.PlayerData.Utils.ValueReplication)

export type ValueTypeName = ValueReplication.ValueTypeName

export type LeaderstatsAdapter = {
	ShowInLeaderStats: (
		self: LeaderstatsAdapter,
		name: string,
		initialValue: any,
		valueType: ValueTypeName?
	) -> ValueBase,
	Get: (self: LeaderstatsAdapter, name: string) -> any?,
	Set: (self: LeaderstatsAdapter, name: string, value: any) -> (),
}

local LeaderstatsAdapter = {}
LeaderstatsAdapter.__index = LeaderstatsAdapter

function LeaderstatsAdapter.new(leaderstatsFolder: Folder): LeaderstatsAdapter
	local self = setmetatable({
		_values = ValueReplication.new(leaderstatsFolder),
	}, LeaderstatsAdapter)

	return (self :: any) :: LeaderstatsAdapter
end

function LeaderstatsAdapter:ShowInLeaderStats(name: string, initialValue: any, valueType: ValueTypeName?): ValueBase
	return self._values:Show(name, initialValue, valueType)
end

function LeaderstatsAdapter:Get(name: string): any?
	return self._values:Get(name)
end

function LeaderstatsAdapter:Set(name: string, value: any)
	self._values:Set(name, value)
end

return LeaderstatsAdapter
