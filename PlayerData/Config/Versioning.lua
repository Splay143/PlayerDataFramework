--!strict
--@Splay

local ServerScriptService = game:GetService("ServerScriptService")
local DataSchema = require(ServerScriptService.PlayerData.Config.DataSchema)
local TableUtil = require(ServerScriptService.PlayerData.Utils.TableUtil)

export type MigrateStatus = "Ok" | "TooNew" | "Invalid" | "MigrationFailed"
export type Migration = (record: any) -> ()
export type MigrationTable = { [number]: Migration}

local Versioning = {}

local Migrations: MigrationTable = {}
Versioning.Migrations = Migrations

function Versioning.IsTooNew(record: any): boolean
	if type(record) ~= "table" then
		return false
	end
	
	local version = record.SchemaVersion
	return type(version) == "number" and version > DataSchema.CURRENT_VERSION
end

local function repairStructure(record: any)
	if type(record.Data)  ~= "table" then
		record.Data = {}
	end
	
	local data = record.Data
	local sectionKeys = DataSchema.SectionKeys :: { string }
	
	for _, key in sectionKeys do
		if type(data[key]) ~= "table" then
			data[key] = DataSchema.NewSection(key)
		end
	end
	
	if type(record.Meta) ~= "table" then
		record.Meta = {}
	end
	
	local meta = record.Meta
	if type(meta.CreatedAt) ~= "number" then
		meta.CreatedAt = 0
	end
	
	if type(meta.LastSaved) ~= "number" then
		meta.LastSaved = 0
	end
end

--[[
	Migrate(record) -> (status, record?)

	"Ok"              record is current. Returned table is the migrated copy, or
	                  the same table (repaired in place) if it was already current.
	"TooNew"          SchemaVersion is newer than this code. Nothing is returned;
	                  the caller must not load or overwrite the record.
	"Invalid"         Not a table, or SchemaVersion is missing, not a whole
	                  number, or negative.
	"MigrationFailed" A migration is missing or threw. The input is untouched.

	Treat everything except "Ok" like a failed load: never run the player on
	blank data and never write over the stored record.

	targetVersion and migrations are optional and exist so tests can exercise the
	migration chain without changing the real schema.
]]

function Versioning.Migrate(
	record: any,
	targetVersion: number?,
	migrations: MigrationTable?
): (MigrateStatus, any?)
	
	assert(
		targetVersion == nil or (targetVersion >= 0 and targetVersion == math.floor(targetVersion)),
		"Versioning.Migrate: targetVersion must be a whole number of at least 0"
	)
	assert(migrations == nil or type(migrations) == "table", "Versioning.Migrate: migrations must be a table")
	
	local target = targetVersion or DataSchema.CURRENT_VERSION
	local steps = migrations or Migrations
	
	if type(record) ~= "table" then
		return "Invalid", nil
	end
	
	local version = record.SchemaVersion
	if type(version) ~= "number" or version ~= math.floor(version) or version < 0 then
		return "Invalid", nil
	end
	
	if version > target then
		return "TooNew", nil
	end
	
	local working: any = record
	if version < target then
		working = TableUtil.DeepCopy(record)
		while version < target do
			local migration = steps[version]
			if migration == nil then
				return "MigrationFailed", nil
			end
			
			local ok = pcall(migration, working)
			if not ok then
				return "MigrationFailed", nil
			end
			
			version += 1
			working.SchemaVersion = version
		end
	end
	
	repairStructure(working)
	return "Ok", working
end

return Versioning
	