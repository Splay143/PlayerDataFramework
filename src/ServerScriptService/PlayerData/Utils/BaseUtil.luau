--!strict
--@Splay

local ServerScriptService = game:GetService("ServerScriptService")

local DataSchema = require(ServerScriptService.PlayerData.Config.DataSchema)
local LeaderstatsAdapter = require(ServerScriptService.PlayerData.Adapters.LeaderstatsAdapter)
local PrivateAdapter = require(ServerScriptService.PlayerData.Adapters.PrivateAdapter)

export type StorageKind = "Primary" | "Secondary"

export type Context = {
	leaderstats: Folder,
	LeaderstatsAdapter: LeaderstatsAdapter.LeaderstatsAdapter,

	privateFolder: Folder,
	PrivateAdapter: PrivateAdapter.PrivateAdapter,
	Replicate: (key: string, value: any, private: boolean?) -> (),
}

export type Handler<T> = {
	Namespace: string,
	Storage: StorageKind?, -- Nil = primary
	Required: boolean?, --only for secondary, kick player if namespace can't be read
	Default: () -> T,
	Sanitize: (raw: any?) -> T,
	Load: (player: Player, ctx: Context, value: T) -> (),
	Save: (player: Player, ctx: Context) -> T,
	Unload: ((player: Player) -> ())?,
}

local BaseUtil = {}

local function isFinite(value: number): boolean
	return value == value and value ~= math.huge and value ~= -math.huge
end

function BaseUtil.AssertIsPlayer(player: any, callerName: string)
	assert(typeof(player) == "Instance" and player:IsA("Player"), callerName .. ": player must be a Player")
end

-- Accepts the current shape ({ Id = true }) and the old array shape ({ "Id" }).
-- Duplicates in the array form collapse to one entry on purpose: the result is a set.
-- Decimals are floored, never rounded. Flooring can only lower a value, so a
-- fractional or corrupt stored number can never grant more currency or XP than
-- was saved. The catch is float arithmetic: 0.57 * 100 is 56.99999999999999,
-- which floors to 56, one too low. Handlers should store whole numbers.
function BaseUtil.SanitizeInt(value: unknown, default: number, min: number?, max: number?): number
	local lower = min or 0
	local upper = max or DataSchema.Limits.MaxInt
	assert(isFinite(default), "BaseUtil.SanitizeInt: default must be a finite number")
	assert(isFinite(lower) and lower == math.floor(lower), "BaseUtil.SanitizeInt: min must be a finite integer")
	assert(isFinite(upper) and upper == math.floor(upper), "BaseUtil.SanitizeInt: max must be a finite integer")
	assert(lower <= upper, "BaseUtil.SanitizeInt: min must not be greater than max")

	local result = math.floor(default)
	if type(value) == "number" and isFinite(value) then
		result = math.floor(value)
	end
	return math.clamp(result, lower, upper)
end

function BaseUtil.SanitizeTimestamp(value: unknown, now: number): number
	assert(isFinite(now), "BaseUtil.SanitizeTimestamp: now must be a finite number")
	if type(value) ~= "number" or not isFinite(value) then
		return 0
	end

	local stamp = math.floor(value)
	if stamp < 0 or stamp > now + DataSchema.Limits.FutureTimeSkewSeconds then
		return 0
	end
	return stamp
end

function BaseUtil.SanitizeString(value: unknown, default: string, maxLength: number?): string
	assert(maxLength == nil or maxLength > 0, "BaseUtil.SanitizeString: maxLength must be greater than 0")
	if type(value) ~= "string" then
		return default
	end
	if #value > (maxLength or DataSchema.Limits.MaxIdLength) then
		return default
	end
	return value
end

function BaseUtil.SanitizeBool(value: unknown, default: boolean): boolean
	if type(value) == "boolean" then
		return value
	end
	return default
end

function BaseUtil.SanitizeIdSet(value: unknown): { [string]: boolean }
	local set: { [string]: boolean } = {}
	if type(value) ~= "table" then
		return set
	end

	local maxLength = DataSchema.Limits.MaxIdLength
	-- The table guard does not expose iterable key and value types.
	for key, entry in value :: { [unknown]: unknown } do
		local id: string? = nil
		if type(key) == "string" and entry == true then
			id = key
		elseif type(key) == "number" and type(entry) == "string" then
			id = entry
		end

		if type(id) == "string" and id ~= "" and #id <= maxLength then
			set[id] = true
		end
	end
	return set
end

function BaseUtil.AsTable(value: unknown): { [any]: any }
	if type(value) == "table" then
		-- Preserve the established indexable return type after the runtime table guard.
		return value :: { [any]: any }
	end
	return {}
end

return BaseUtil
