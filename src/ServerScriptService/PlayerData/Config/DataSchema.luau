--!strict

-- @Splay

--[[
	DataSchema

	Configuration boundary between the framework's public API and its internal
	implementation.

	This file defines the persistent player data structure, including the
	framework-owned record envelope and the game's PlayerData sections.

	The consuming game is expected to define:
		- PlayerData sections
		- Default values for those sections
		- Schema version
		- Storage and timing configuration when required

	Most configuration values have safe defaults and should not normally need
	to be changed. They exist to allow experienced developers to tune the
	framework for specific game requirements.

	Changing timing, retry, budget, locking, or storage limits without
	understanding the mechanisms behind them can cause unintended behaviour,
	including increased DataStore usage, failed saves, longer waits, or
	session-lock issues.

	Therefore:
		- Beginners should generally use the provided defaults.
		- Developers may adjust configuration when they understand its effects.
		- Framework internals should not be modified through this file unless
		  the developer understands the relevant system.

	The framework owns the record envelope, session lock, metadata, timing
	configuration, storage configuration, and limits.

	The consuming game owns the PlayerData structure and default values.

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
	LastLogin: number,
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

-- Increment this when the persistent data structure changes and add the
-- corresponding migration to Versioning.Migrations.
DataSchema.CURRENT_VERSION = 1

-- Use a versioned name when appropriate, for example "PlayerData_V1".
-- Treat the store name as permanent once data is in production. Changing it
-- points the framework at a different store and can make existing data appear
-- missing unless an intentional migration is performed.
DataSchema.STORE_NAME = "PlayerData"

DataSchema.KEY_PREFIX = "Player_"

DataSchema.Timing = {
	StaleLockSeconds = 300,
	AutosaveMinSeconds = 60,
	AutosaveMaxSeconds = 120,
	MinSaveGapSeconds = 15,
	PlayerGuiWaitSeconds = 30,

	AcquireRetryWindowSeconds = 10,
	AcquireRetryIntervalSeconds = 2,

	ReleaseWaitSeconds = 10, -- how long a prev rejoining player waits for release
	ShutdownTimeoutSeconds = 25,
}

-- Retry/backoff for StoreHandler.
-- MaxAttempts includes the initial attempt.
DataSchema.Store = {
	MaxAttempts = 5,
	BaseBackoffSeconds = 1,
	MaxBackoffSeconds = 8,

	SaveQueueTickSeconds = 5,
	SaveQueueBudgetFraction = 0.5, -- spend at most half the available budget per tick; Acquire/Release share the same pool
	SaveQueueCooldownSeconds = 10, -- pause the whole queue after a real save failure
}

DataSchema.Limits = {
	MaxInt = 2147483647,
	MaxIdLength = 64,
	FutureTimeSkewSeconds = 300,
	MaxSecondaryNamespaceLength = 24,
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
	return value == math.floor(value) and value > -math.huge and value < math.huge
end

function DataSchema.KeyFor(userId: number): string
	assert(isWholeNumber(userId), "DataSchema.KeyFor: userId must be a whole number")

	return DataSchema.KEY_PREFIX .. tostring(userId)
end

function DataSchema.SecondaryKeyFor(userId: number, namespace: string): string
	assert(
		type(namespace) == "string" and namespace ~= "",
		"DataSchema.SecondaryKeyFor: namespacemust be a non-empty string"
	)
	assert(
		#namespace <= DataSchema.Limits.MaxSecondaryNamespaceLength,
		"DataSchema.SecondaryKeyFor: namespace is too long for a DataStore key"
	)

	return DataSchema.KeyFor(userId) .. "_" .. namespace
end

function DataSchema.NewData(): PlayerData
	return TableUtil.DeepCopy(DEFAULT_DATA)
end

function DataSchema.NewSection(key: string): any
	local template = (DEFAULT_DATA :: any)[key]

	assert(type(template) == "table", "DataSchema.NewSection: unknown section " .. tostring(key))

	return TableUtil.DeepCopy(template)
end

function DataSchema.NewRecord(now: number): PlayerRecord
	assert(isWholeNumber(now), "DataSchema.NewRecord: now must be a whole number (os.time())")

	return {
		SchemaVersion = DataSchema.CURRENT_VERSION,
		Lock = nil,
		Data = DataSchema.NewData(),
		Meta = {
			CreatedAt = now,
			LastSaved = 0,
			LastLogin = now,
		},
	}
end

local function validateSections()
	local sectionSet: { [string]: boolean } = {}

	for _, key in SectionKeys do
		assert(type(key) == "string" and key ~= "", "DataSchema: SectionKeys contains an invalid section name")

		assert(not sectionSet[key], "DataSchema: duplicate section key " .. key)

		assert(
			(DEFAULT_DATA :: any)[key] ~= nil,
			"DataSchema: SectionKeys contains section without default data: " .. key
		)

		sectionSet[key] = true
	end

	for key in DEFAULT_DATA do
		assert(sectionSet[key], "DataSchema: default data section is missing from SectionKeys: " .. key)
	end
end

validateSections()
return DataSchema
