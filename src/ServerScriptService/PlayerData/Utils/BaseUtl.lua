--!strict
--@Splay

local ServerScriptService = game:GetService("ServerScriptService")
local DataSchema = require(ServerScriptService.PlayerData.Config.DataSchema)

export type Context = {
	Data: Folder,
	leaderstats: Folder,
}

export type Handler = {
	Key: string,
	Default: () -> any,
	Sanitize: (raw: any?) -> any,
	Load: (player: Player, ctx: Context, value: any) -> (),
	Save: (player: Player, ctx: Context) -> any,
}

local BaseUtil = {}

local function isFinite(value: number): boolean
	return value == value and value ~= math.huge and value ~= -math.huge
end

function BaseUtil.SanitizeInt(value: any, default: number, min: number?, max: number?): number
	local lower = min or 0
	local upper = max or DataSchema.Limits.MaxInt
	assert(isFinite(default), "BaseUtil.SanitizeInt: default must be a finite number")
	assert(lower <= upper, "BaseUtil.SanitizeInt: min must not be greater than max")

	local result = math.floor(default)
	if type(value) == "number" and isFinite(value) then
		result = math.floor(value)
	end
	return math.clamp(result, lower, upper)
end

function BaseUtil.SanitizeTimestamp(value: any, now: number): number
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

function BaseUtil.SanitizeString(value: any, default: string, maxLength: number?): string
	assert(maxLength == nil or maxLength > 0, "BaseUtil.SanitizeString: maxLength must be greater than 0")
	if type(value) ~= "string" then
		return default
	end
	if #value > (maxLength or DataSchema.Limits.MaxIdLength) then
		return default
	end
	return value
end

function BaseUtil.SanitizeBool(value: any, default: boolean): boolean
	if type(value) == "boolean" then
		return value
	end
	return default
end

function BaseUtil.SanitizeIdSet(value: any): { [string]: boolean }
	local set: { [string]: boolean } = {}
	if type(value) ~= "table" then
		return set
	end

	local maxLength = DataSchema.Limits.MaxIdLength
	for key, entry in pairs(value) do
		local id: any = nil
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

function BaseUtil.AsTable(value: any): { [any]: any }
	if type(value) == "table" then
		return value
	end
	return {}
end

return BaseUtil