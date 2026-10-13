--strict
--@Splay

local ErrorCodes = {} :: {
	Codes: { [string]: number },
	KickMessage: (number) -> string,
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

local knownCodes: { [number]: boolean } = {}
for _, code in ErrorCodes.Codes do
	assert(not knownCodes[code], "ErrorCodes: duplicate code " .. tostring(code))
	knownCodes[code] = true
end

-- The player only ever sees this text: no handler names, stack traces or schema details.
function ErrorCodes.KickMessage(code: number): string
	assert(knownCodes[code], "ErrorCodes.KickMessage: unknown error code " .. tostring(code))

	return ("There was an issue with the Data system. Please try rejoining, if this issue persists please contact support.\n\nError Code: %d"):format(
		code
	)
end

return ErrorCodes
