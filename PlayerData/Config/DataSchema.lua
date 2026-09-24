--!strict
--@Splay

--[[
	DataSchema
	Single source of truth for the shape of a player record.

	A record lives under KEY_PREFIX .. UserId in STORE_NAME:

		{
			SchemaVersion = 1,
			Lock = { ServerId, SessionId, Time } | nil,   -- nil when released
			Data = PlayerData,                            -- one table per section
			Meta = { CreatedAt, LastSaved },
		}

	Every section in Data has exactly one handler in Handlers/ whose Key matches
	the section name below. DEFAULT_DATA is the only place a default value is
	written; everything else copies from it, so nothing is ever shared between
	players.
]]
local ServerScriptService = game:GetService("ServerScriptService")
local TableUtil = require(ServerScriptService.PlayerData.Utils.TableUtil)

export type Lock = {
	ServerId: string,
	SessionId: string,
	Time: number,
}

export type Meta = {
	CreatedAt: number,
	LastSaved: number,
}

export type CurrencyData = {
	Gold: number,
	Diamond: number,
	Spins: number,
	Exp: number,
}

export type ProgressionData = {
	Level: number,
	Wins: number,
	WinStreak: number,
}

export type TimersData = {
	RewardDay: number,
	LastRewardTime: number,
	LastWheelTime: number,
}

-- Sets are { [id] = true } maps.
export type InventoryData = {
	Characters: { [string]: boolean },
	Auras: { [string]: boolean },
	Pets: { [string]: boolean },
	RedeemedCodes: { [string]: boolean },
	OwnedProducts: { [string]: boolean },
}

export type EquippedData = {
	Character: string,
	Aura: string,
	Pets: { string },
}

export type FlagsData = {
	HasSeenTutorial: boolean,
}

-- [PurchaseId] = unix time, capped to the newest MaxPurchaseLedger entries.
export type PurchasesData = { [string]: number }

export type QuestsData = {
	Date: string,
	List: { { [string]: any } },
}

-- [name] = { Value = 0, Tier = "Bronze" }
export type MilestonesData = { [string]: { Value: number, Tier: string } }

export type PlayerData = {
	[string]: any,
	Currency: CurrencyData,
	Progression: ProgressionData,
	Timers: TimersData,
	Inventory: InventoryData,
	Equipped: EquippedData,
	Flags: FlagsData,
	Purchases: PurchasesData,
	Quests: QuestsData,
	Milestones: MilestonesData,
}

export type PlayerRecord = {
	SchemaVersion: number,
	Lock: Lock?,
	Data: PlayerData,
	Meta: Meta,
}

local DataSchema = {}

-- Bump this together with a new entry in Versioning.Migrations.
DataSchema.CURRENT_VERSION = 1

DataSchema.STORE_NAME = "PlayerData_V5"
DataSchema.KEY_PREFIX = "Player_"

DataSchema.Timing = {
	StaleLockSeconds = 300,
	AutosaveMinSeconds = 60,
	AutosaveMaxSeconds = 120,
	MinSaveGapSeconds = 15,
}

-- Retry/backoff for StoreHandler. Backoff is BaseBackoffSeconds doubled each
-- attempt, capped at MaxBackoffSeconds (see StoreHandler.ExponentialBackoff).
-- MaxAttempts counts the first try, so 5 means up to 4 retries.
DataSchema.Store = {
	MaxAttempts = 5,
	BaseBackoffSeconds = 1,
	MaxBackoffSeconds = 8,
}

DataSchema.Limits = {
	MaxInt = 2147483647, -- IntValue is a signed 32-bit integer
	MaxIdLength = 64, -- item, code, product and milestone names
	MaxQuests = 3,
	MaxEquippedPets = 3,
	MaxPurchaseLedger = 100, -- newest PurchaseIds kept
	FutureTimeSkewSeconds = 300, -- a saved timestamp further ahead than this is reset
}

local SectionKeys: { string } = {
	"Currency",
	"Progression",
	"Timers",
	"Inventory",
	"Equipped",
	"Flags",
	"Purchases",
	"Quests",
	"Milestones",
}
DataSchema.SectionKeys = SectionKeys

local DEFAULT_DATA: PlayerData = {
	Currency = { Gold = 500, Diamond = 0, Spins = 0, Exp = 0 },

	Progression = { Level = 1, Wins = 0, WinStreak = 0 },

	Timers = { RewardDay = 1, LastRewardTime = 0, LastWheelTime = 0 },

	Inventory = {
		Characters = { Pain = true },
		Auras = {},
		Pets = {},
		RedeemedCodes = {},
		OwnedProducts = {},
	},

	Equipped = { Character = "Pain", Aura = "", Pets = {} },

	Flags = { HasSeenTutorial = false },

	Purchases = {},

	Quests = { Date = "", List = {} },

	Milestones = {},
}

DataSchema.DEFAULT_DATA = DEFAULT_DATA

local function isWholeNumber(value: number): boolean
	return value == math.floor(value) and value > -math.huge and value < math.huge
end

function DataSchema.KeyFor(userId: number): string
	assert(isWholeNumber(userId), "DataSchema.KeyFor: userId must be a whole number")
	return DataSchema.KEY_PREFIX .. tostring(userId)
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
		Meta = { CreatedAt = now, LastSaved = 0 },
	}
end

return DataSchema