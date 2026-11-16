--!strict
--@Splay

local Players = game:GetService("Players")
local ServerScriptService = game:GetService("ServerScriptService")

local ErrorCodes = require(ServerScriptService.PlayerData.Config.ErrorCodes)

const DISPLAY_REASON = ErrorCodes.TamperingNotice

const MAX_PRIVATE_REASON_LENGTH = 400

export type BanConfig = {
	UserIds: { number },
	ApplyToUniverse: boolean,
	Duration: number,
	DisplayReason: string,
	PrivateReason: string,
	ExcludeAltAccounts: boolean,
	ApplyDeviceBlock: boolean?,
}

export type UnbanConfig = {
	UserIds: { number },
	ApplyToUniverse: boolean,
}

export type Options = {
	BanAltAccounts: boolean,
	ApplyDeviceBlock: boolean?,
	BanAsync: ((config: BanConfig) -> ())?,
	UnbanAsync: ((config: UnbanConfig) -> ())?,
}

type Fields = {
	_banAltAccounts: boolean,
	_applyDeviceBlock: boolean,
	_banAsync: (config: BanConfig) -> (),
	_unbanAsync: (config: UnbanConfig) -> (),
}

local function BanWithRoblox(config: BanConfig)
	Players:BanAsync({
		UserIds = config.UserIds,
		ApplyToUniverse = config.ApplyToUniverse,
		Duration = config.Duration,
		DisplayReason = config.DisplayReason,
		PrivateReason = config.PrivateReason,
		ExcludeAltAccounts = config.ExcludeAltAccounts,
		ApplyDeviceBlock = if config.ApplyDeviceBlock == true then true else nil,
	})
end

local function UnbanWithRoblox(config: UnbanConfig)
	Players:UnbanAsync({
		UserIds = config.UserIds,
		ApplyToUniverse = config.ApplyToUniverse,
	})
end

local RobloxBanAdapter = {}
RobloxBanAdapter.__index = RobloxBanAdapter

export type RobloxBanAdapter = typeof(setmetatable({} :: Fields, RobloxBanAdapter))

function RobloxBanAdapter.new(options: Options): RobloxBanAdapter
	assert(type(options) == "table", "RobloxBanAdapter.new: options must be a table")
	assert(type(options.BanAltAccounts) == "boolean", "RobloxBanAdapter.new: options.BanAltAccounts must be a boolean")
	assert(
		options.BanAsync == nil or type(options.BanAsync) == "function",
		"RobloxBanAdapter.new: options.BanAsync must be a function or nil"
	)
	assert(
		options.UnbanAsync == nil or type(options.UnbanAsync) == "function",
		"RobloxBanAdapter.new: options.UnbanAsync must be a function or nil"
	)
	assert(
		options.ApplyDeviceBlock == nil or type(options.ApplyDeviceBlock) == "boolean",
		"RobloxBanAdapter.new: ApplyDeviceBlock must be a boolean when provided"
	)

	return setmetatable({
		_banAltAccounts = options.BanAltAccounts,
		_applyDeviceBlock = options.ApplyDeviceBlock == true,
		_banAsync = options.BanAsync or BanWithRoblox,
		_unbanAsync = options.UnbanAsync or UnbanWithRoblox,
	}, RobloxBanAdapter)
end

function RobloxBanAdapter.Ban(self: RobloxBanAdapter, userId: number, reason: string, durationSeconds: number)
	assert(type(userId) == "number" and userId > 0, "RobloxBanAdapter:Ban: userId must be a positive number")
	assert(type(reason) == "string", "RobloxBanAdapter:Ban: reason must be a string")
	assert(
		type(durationSeconds) == "number" and (durationSeconds == -1 or durationSeconds > 0),
		"RobloxBanAdapter:Ban: durationSeconds must be -1 (permanent) or above 0"
	)

	self._banAsync({
		UserIds = { userId },
		ApplyToUniverse = true,
		Duration = durationSeconds,
		DisplayReason = DISPLAY_REASON,
		PrivateReason = string.sub(reason, 1, MAX_PRIVATE_REASON_LENGTH),
		--Setting is the positive way round; Roblox's is inverted.
		ExcludeAltAccounts = not self._banAltAccounts,
		ApplyDeviceBlock = if self._applyDeviceBlock then true else nil,
	})
end

function RobloxBanAdapter.Unban(self: RobloxBanAdapter, userId: number)
	assert(type(userId) == "number" and userId > 0, "RobloxBanAdapter:Unban: userId must be a positive number")

	self._unbanAsync({ UserIds = { userId }, ApplyToUniverse = true })
end

-- SecurityService wants a plain function, not an object.
function RobloxBanAdapter.AsHandler(
	self: RobloxBanAdapter
): (userId: number, reason: string, durationSeconds: number) -> ()
	return function(userId: number, reason: string, durationSeconds: number)
		self:Ban(userId, reason, durationSeconds)
	end
end

return RobloxBanAdapter
