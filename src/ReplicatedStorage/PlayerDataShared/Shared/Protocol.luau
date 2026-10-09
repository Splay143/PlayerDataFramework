--!strict
--@Splay

local Protocol = {}

Protocol.RemoteNames = {
	Replication = "PlayerDataReplication",
	Request = "PlayerDataRequest",
	Send = "PlayerDataSend",
}

Protocol.ChangeType = {
	Set = "Set",
	Remove = "Remove",
}

Protocol.MessageType = {
	Snapshot = "Snapshot",
	Delta = "Delta",
}

Protocol.Limits = {
	MaxRouteNameLength = 64,
	MaxPayloadDepth = 8,
	MaxPathDepth = 8,
}

local function assertNonEmptyString(value: any, label: string)
	assert(type(value) == "string" and value ~= "", label .. " must be a non-empty string")
end

function Protocol.IsValidRouteName(routeName: any): boolean
	return type(routeName) == "string" and routeName ~= "" and #routeName <= Protocol.Limits.MaxRouteNameLength
end

function Protocol.AssertRouteName(routeName: any)
	assertNonEmptyString(routeName, "Protocol.AssertRouteName")
	assert(#routeName <= Protocol.Limits.MaxRouteNameLength, "Protocol.AssertRouteName: routeName is too long")
end

return Protocol
