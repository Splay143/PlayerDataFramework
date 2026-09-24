--!strict

-- @Splay

--[[
	DataSchema

	Single source of truth for the persistent player record structure.

	The framework owns the record envelope, session lock, metadata,
	timing configuration, storage configuration, and limits.

	The consuming game defines the PlayerData structure and default values.

	Keep PlayerData sections in load order.
]]

local ServerScriptService = game:GetService("ServerScriptService")

local TableUtil = require(ServerScriptService.PlayerData.Utils.TableUtil)

local DataSchema = {}

export type Lock = {
	ServerId: string,
	SessionId: string,
	Time: number,
}

export type Meta = {
	CreatedAt: number,
	LastSaved: number,
}

--[[
	Define your player data sections here.

	Example:

		Currency: CurrencyData,
		Inventory: InventoryData,
		Progression: ProgressionData,
]]
export type PlayerData = {
	[string]: any,
	--[[ Put your data tables in load order here. ]]
}

export type PlayerRecord = {
	SchemaVersion: number,
	Lock: Lock?,
	Data: PlayerData,
	Meta: Meta,
}

-- Bump this together with a new entry in Versioning.Migrations.
DataSchema.CURRENT_VERSION = 1

DataSchema.STORE_NAME = "PlayerData"

DataSchema.KEY_PREFIX = "Player_"

DataSchema.Timing = {
	StaleLockSeconds = 300,
	AutosaveMinSeconds = 60,
	AutosaveMaxSeconds = 120,
	MinSaveGapSeconds = 15,
}

-- Retry/backoff for StoreHandler.
-- MaxAttempts includes the initial attempt.
DataSchema.Store = {
	MaxAttempts = 5,
	BaseBackoffSeconds = 1,
	MaxBackoffSeconds = 8,
}

DataSchema.Limits = {
	MaxInt = 2147483647,
	MaxIdLength = 64,
	FutureTimeSkewSeconds = 300,
}

--[[
	Keep these in the same order as the PlayerData type above.

	Example:

		"Currency",
		"Inventory",
		"Progression",
]]
local SectionKeys: { string } = {
	--[[ Put your section names here in load order. ]]
}
DataSchema.SectionKeys = SectionKeys

--[[
	Define the default value for every PlayerData section here.

	Example:

		Currency = {
			Coins = 0,
		},

		Inventory = {
			Items = {},
		},
]]
local DEFAULT_DATA: PlayerData = {
	--[[ Put your default data here. ]]
}

DataSchema.DEFAULT_DATA = DEFAULT_DATA

local function isWholeNumber(value: number): boolean
	return value == math.floor(value)
		and value > -math.huge
		and value < math.huge
end

function DataSchema.KeyFor(userId: number): string
	assert(
		isWholeNumber(userId),
		"DataSchema.KeyFor: userId must be a whole number"
	)

	return DataSchema.KEY_PREFIX .. tostring(userId)
end

function DataSchema.NewData(): PlayerData
	return TableUtil.DeepCopy(DEFAULT_DATA)
end

function DataSchema.NewSection(key: string): any
	local template = (DEFAULT_DATA :: any)[key]

	assert(
		type(template) == "table",
		"DataSchema.NewSection: unknown section " .. tostring(key)
	)

	return TableUtil.DeepCopy(template)
end

function DataSchema.NewRecord(now: number): PlayerRecord
	assert(
		isWholeNumber(now),
		"DataSchema.NewRecord: now must be a whole number (os.time())"
	)

	return {
		SchemaVersion = DataSchema.CURRENT_VERSION,
		Lock = nil,
		Data = DataSchema.NewData(),
		Meta = {
			CreatedAt = now,
			LastSaved = 0,
		},
	}
end

return DataSchema