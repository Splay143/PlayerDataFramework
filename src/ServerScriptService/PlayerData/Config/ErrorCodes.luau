--!strict
--@Splay

--[[
	ErrorCodes

	Ranges:
		1xx configuration / integration
		2xx handler
		3xx data / schema / migration
		4xx storage / persistence (401 and 404 are session codes kept here because they shipped in V2.0.1)
		5xx framework internal
		6xx session / locking (new codes)
		7xx security
]]

local ErrorCodes = {} :: {
	Codes: { [string]: number },
	IsKnown: (code: number) -> boolean,
	NameOf: (code: number) -> string,
	KickMessage: (code: number) -> string,
}

ErrorCodes.Codes = {
	HandlerSanitizeFailure = 201,
	HandlerLoadFailure = 202,
	RecordTooNew = 301,
	SessionLocked = 401,
	LoadFailed = 402,
	NamespaceUnavailable = 403,
	SessionLost = 404,
}

local namesByCode: { [number]: string } = {}
for name, code in ErrorCodes.Codes do
	assert(namesByCode[code] == nil, "ErrorCodes: duplicate code " .. tostring(code))
	namesByCode[code] = name
end

function ErrorCodes.IsKnown(code: number): boolean
	return namesByCode[code] ~= nil
end

function ErrorCodes.NameOf(code: number): string
	local name = namesByCode[code]
	assert(name ~= nil, "ErrorCodes.NameOf: unknown error code " .. tostring(code))
	return name
end

-- The player only ever sees this text: no handler names, stack traces or schema details.
function ErrorCodes.KickMessage(code: number): string
	assert(namesByCode[code] ~= nil, "ErrorCodes.KickMessage: unknown error code " .. tostring(code))

	return ("There was an issue with the Data system. Please try rejoining, if this issue persists please contact support.\n\nError Code: %d"):format(
		code
	)
end

return ErrorCodes