--!strict
--@Splay
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Protocol = require(ReplicatedStorage.PlayerDataShared.Shared.Protocol)

export type Reason =
	"NotATable"
	| "BadValueType"
	| "BadKeyType"
	| "BadNumber"
	| "StringTooLong"
	| "TooDeep"
	| "TooLarge"
	| "Cycle"

type State = {
	Nodes: number,
	InPath: { [any]: boolean },
}

local Reasons = {
	NotATable = "NotATable" :: Reason,
	BadValueType = "BadValueType" :: Reason,
	BadKeyType = "BadKeyType" :: Reason,
	BadNumber = "BadNumber" :: Reason,
	StringTooLong = "StringTooLong" :: Reason,
	TooDeep = "TooDeep" :: Reason,
	TooLarge = "TooLarge" :: Reason,
	Cycle = "Cycle" :: Reason,
}

local PayloadValidator = {}

local function checkString(text: string): Reason?
	if #text > Protocol.Limits.MaxStringLength then
		return Reasons.StringTooLong
	end
	return nil
end

local function checkValue(value: any, depth: number, state: State): Reason?
	state.Nodes += 1
	if state.Nodes > Protocol.Limits.MaxPayloadNodes then
		return Reasons.TooLarge
	end

	local valueType = type(value)

	if valueType == "boolean" then
		return nil
	elseif valueType == "number" then
		-- NaN is the only number not equal to itself.
		if value ~= value or value == math.huge or value == -math.huge then
			return Reasons.BadNumber
		end
		return nil
	elseif valueType == "string" then
		return checkString(value)
	elseif valueType ~= "table" then
		-- Functions, Instances, userdata and threads never belong in a payload.
		return Reasons.BadValueType
	end

	if depth > Protocol.Limits.MaxPayloadDepth then
		return Reasons.TooDeep
	end

	if state.InPath[value] then
		return Reasons.Cycle
	end
	state.InPath[value] = true

	for key, child in value do
		local keyType = type(key)
		if keyType == "string" then
			local keyReason = checkString(key)
			if keyReason ~= nil then
				return keyReason :: Reason
			end
		elseif keyType ~= "number" then
			return Reasons.BadKeyType
		end

		local childReason = checkValue(child, depth + 1, state)
		if childReason ~= nil then
			return childReason :: Reason
		end
	end

	-- Only ancestors count as a cycle, so the same table used twice side by side is fine.
	state.InPath[value] = nil
	return nil
end

function PayloadValidator.Validate(payload: any): (boolean, Reason?)
	if type(payload) ~= "table" then
		return false, Reasons.NotATable
	end

	local reason = checkValue(payload, 1, { Nodes = 0, InPath = {} })
	if reason ~= nil then
		return false, reason :: Reason
	end
	return true, nil
end

return PayloadValidator
