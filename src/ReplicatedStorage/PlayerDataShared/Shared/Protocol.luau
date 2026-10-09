--!strict
--@Splay

local Protocol = {}

export type SnapshotMessage = {
	Type: "Snapshot",
	Sequence: number,
	Data: { [string]: any },
}

export type DeltaMessage = {
	Type: "Delta",
	Sequence: number,
	Changes: { any },
}

export type Message = SnapshotMessage | DeltaMessage

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

local function isValidSequence(value: any): boolean
	return type(value) == "number" and value >= 0 and value == math.floor(value) and value < math.huge
end

function Protocol.IsValidRouteName(routeName: any): boolean
	return type(routeName) == "string" and routeName ~= "" and #routeName <= Protocol.Limits.MaxRouteNameLength
end

function Protocol.AssertRouteName(routeName: any)
	assertNonEmptyString(routeName, "Protocol.AssertRouteName")
	assert(#routeName <= Protocol.Limits.MaxRouteNameLength, "Protocol.AssertRouteName: routeName is too long")
end

function Protocol.NewSnapshot(sequence: number, data: { [string]: any }): SnapshotMessage
	assert(isValidSequence(sequence), "Protocol.NewSnapshot: sequence must be a whole number of at least 0")
	assert(type(data) == "table", "Protocol.NewSnapshot: data must be a table")

	return { Type = "Snapshot", Sequence = sequence, Data = data }
end

function Protocol.NewDelta(sequence: number, changes: { any }): DeltaMessage
	assert(isValidSequence(sequence), "Protocol.NewDelta: sequence must be a whole number of at least 0")
	assert(type(changes) == "table", "Protocol.NewDelta: changes must be a table")

	return { Type = "Delta", Sequence = sequence, Changes = changes }
end

function Protocol.IsValidMessage(message: any): boolean
	if type(message) ~= "table" or not isValidSequence(message.Sequence) then
		return false
	end

	if message.Type == Protocol.MessageType.Snapshot then
		return type(message.Data) == "table"
	elseif message.Type == Protocol.MessageType.Delta then
		return type(message.Changes) == "table"
	end

	return false
end

return Protocol
