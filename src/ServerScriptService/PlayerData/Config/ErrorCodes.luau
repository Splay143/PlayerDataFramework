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
	TamperingNotice: string,
	Codes: { [string]: number },
	IsKnown: (code: number) -> boolean,
	NameOf: (code: number) -> string,
	KickMessage: (code: number) -> string,
}

ErrorCodes.TamperingNotice = "Tampering Detected. If you believe this is false , contact support."

ErrorCodes.Codes = {
	HandlerSanitizeFailure = 201,
	HandlerLoadFailure = 202,
	HandlerSaveFailure = 203,
	HandlerUnloadFailure = 204,
	RecordTooNew = 301,
	SessionLocked = 401,
	LoadFailed = 402,
	NamespaceUnavailable = 403,
	SessionLost = 404,
	NamespaceSaveFailed = 405,
	SaveFailed = 406,
	ReleaseFailed = 407,
	ReleaseAbandoned = 408,
	ShutdownIncomplete = 409,
	ReleaseWaitTimeout = 601,
	ReleaseListenerFailed = 602,
	JoinBlocked = 603,
	MigrationFailed = 302,
	RecordInvalid = 303,
	SecurityWouldAct = 701,
	SecurityKick = 702,
	SecurityBan = 703,
	SecurityBanFailed = 704,
	SecurityMassTrigger = 705,
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

	if code == ErrorCodes.Codes.SecurityBan or code == ErrorCodes.Codes.SecurityBanFailed then
		return ("%s\n\nError Code: %d"):format(ErrorCodes.TamperingNotice, code)
	end

	return ("There was an issue with the Data system. Please try rejoining, if this issue persists please comtact support.\n\nError Code: %d"):format(
		code
	)
end

return ErrorCodes
