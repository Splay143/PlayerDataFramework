--!strict

--[[
	Phae 1 tests: TableUtil, DataSchema, Versioning, BaseUtil.
	It returns true when every check passed.
]]

local ServerScriptService = game:GetService("ServerScriptService")
local PlayerData = ServerScriptService.PlayerData
local TableUtil = require(PlayerData.Utils.TableUtil)
local BaseUtil = require(PlayerData.Utils.BaseUtl)
local DataSchema = require(PlayerData.Config.DataSchema)
local Versioning = require(PlayerData.Config.Versioning)
local Harness = require(PlayerData.Tests.Harness)

return function(): boolean
	local t = Harness.new("Phase1")

	-- TableUtil
	do
		local original = { A = 1, B = { C = { 2, 3 } } }
		local copy = TableUtil.DeepCopy(original)
		t.Equal("DeepCopy equals the original", copy, original)
		copy.B.C[1] = 99
		t.Check("DeepCopy is independent of the original", original.B.C[1] == 2)

		local loop: any = { Name = "loop" }
		loop.Self = loop
		local loopCopy: any = TableUtil.DeepCopy(loop)
		t.Check("DeepCopy survives a cycle", loopCopy ~= loop and loopCopy.Self == loopCopy)
	end

	do
		local defaults = { Gold = 0, Nested = { A = 1, B = 2 }, Tags = {} }

		local loaded: any = { Gold = 50, Nested = { A = 9 } }
		TableUtil.Reconcile(loaded, defaults)
		t.Equal(
			"Reconcile fills gaps and keeps existing values",
			loaded,
			{ Gold = 50, Nested = { A = 9, B = 2 }, Tags = {} }
		)

		loaded.Tags.Extra = true
		t.Check("Reconcile copies defaults instead of sharing them", next(defaults.Tags) == nil)

		local broken: any = { Nested = "oops" }
		TableUtil.Reconcile(broken, defaults)
		t.Equal("Reconcile replaces a non-table where a table is expected", broken.Nested, { A = 1, B = 2 })
		t.Check("Reconcile fills a missing scalar", broken.Gold == 0)

		t.Equal("Reconcile of nil returns a copy of the defaults", TableUtil.Reconcile(nil, defaults), defaults)
		t.Check("Reconcile of nil does not return the defaults table itself", TableUtil.Reconcile(nil, defaults) ~= defaults)
		t.Equal("Reconcile of a non-table returns a copy of the defaults", TableUtil.Reconcile(5, defaults), defaults)

		local listDefaults = { Items = { "a", "b" } }
		local listTarget: any = { Items = { "x" } }
		TableUtil.Reconcile(listTarget, listDefaults)
		t.Equal("Reconcile does not merge arrays index by index", listTarget.Items, { "x" })
	end

	do
		local mixedList: any = { "Pain", "Goku", "Pain", "" }
		mixedList[5] = 5
		t.Equal("ToSet builds a set and skips junk", TableUtil.ToSet(mixedList), { Pain = true, Goku = true })
		t.Equal("ToSet of a non-table is empty", TableUtil.ToSet(nil), {})
		t.Equal("ToArray is sorted and skips false values", TableUtil.ToArray({ Pain = true, Goku = true, Mambo = false }), { "Goku", "Pain" })
		t.Equal("ToArray of a non-table is empty", TableUtil.ToArray("nope"), {})
		t.Equal("ToArray(ToSet(x)) round-trips", TableUtil.ToArray(TableUtil.ToSet({ "B", "A" })), { "A", "B" })
	end

	do
		t.Check("IsArray: filled array", TableUtil.IsArray({ 1, 2, 3 }))
		t.Check("IsArray: empty table", TableUtil.IsArray({}))
		t.Check("IsArray: dictionary is not an array", not TableUtil.IsArray({ A = 1 }))
		t.Check("IsArray: gap is not an array", not TableUtil.IsArray({ [1] = 1, [3] = 3 }))
		t.Check("IsArray: non-table", not TableUtil.IsArray("x"))
		t.Check("Count", TableUtil.Count({ A = 1, B = 2 }) == 2 and TableUtil.Count(nil) == 0)

		t.Check("DeepEqual: equal nested tables", TableUtil.DeepEqual({ A = { 1 } }, { A = { 1 } }))
		t.Check("DeepEqual: extra key on the right", not TableUtil.DeepEqual({ A = 1 }, { A = 1, B = 2 }))
		t.Check("DeepEqual: extra key on the left", not TableUtil.DeepEqual({ A = 1, B = 2 }, { A = 1 }))
		t.Check("DeepEqual: different values", not TableUtil.DeepEqual({ A = 1 }, { A = 2 }))
	end

	-- DataSchema
	do
		local data = DataSchema.NewData()
		for _, key in DataSchema.SectionKeys do
			t.Check("NewData has a table for section " .. key, type((data :: any)[key]) == "table")
		end

		local a = DataSchema.NewData()
		local b = DataSchema.NewData()
		a.Currency.Gold = 999
		a.Inventory.Characters.Goku = true
		t.Check("NewData returns fresh tables every call", b.Currency.Gold ~= 999 and b.Inventory.Characters.Goku == nil)

		t.Check("Pain is unlocked and equipped by default", data.Inventory.Characters.Pain == true and data.Equipped.Character == "Pain")
		t.Check("Default level and reward day start at 1", data.Progression.Level == 1 and data.Timers.RewardDay == 1)
		t.Equal("KeyFor builds the store key", DataSchema.KeyFor(123), "Player_123")
		t.Check("New players start with 500 Gold", data.Currency.Gold == 500)

		local defaultKeys = 0
		for _ in pairs(DataSchema.DEFAULT_DATA :: any) do
			defaultKeys += 1
		end
		t.Check("SectionKeys lists every section in DEFAULT_DATA", defaultKeys == #DataSchema.SectionKeys)
		for _, key in DataSchema.SectionKeys do
			t.Check("DEFAULT_DATA has section " .. key, (DataSchema.DEFAULT_DATA :: any)[key] ~= nil)
		end

		local section = DataSchema.NewSection("Currency")
		section.Gold = 1
		t.Check("NewSection returns a copy, not the template", DataSchema.DEFAULT_DATA.Currency.Gold == 500)
		t.Check("NewSection asserts on an unknown section", not pcall(DataSchema.NewSection, "Nope"))
		t.Check("KeyFor asserts on a fractional id", not pcall(DataSchema.KeyFor, 1.5))
		t.Check("NewRecord asserts on a bad time", not pcall(DataSchema.NewRecord, 0 / 0))

		local record = DataSchema.NewRecord(1000)
		t.Check("NewRecord is current, unlocked and stamped", record.SchemaVersion == DataSchema.CURRENT_VERSION and record.Lock == nil and record.Meta.CreatedAt == 1000)
		t.Check("Autosave stays well under the stale lock timeout", DataSchema.Timing.AutosaveMaxSeconds * 2 <= DataSchema.Timing.StaleLockSeconds)
	end

	-- Versioning
	do
		local status, migrated = Versioning.Migrate(DataSchema.NewRecord(1000))
		t.Check("Migrate accepts a fresh record", status == "Ok" and migrated ~= nil)

		local partial: any = {
			SchemaVersion = DataSchema.CURRENT_VERSION,
			Data = { Currency = { Gold = 5 }, Inventory = "garbage" },
		}
		local partialStatus, repaired: any = Versioning.Migrate(partial)
		t.Check("Migrate accepts a record with missing sections", partialStatus == "Ok")
		for _, key in DataSchema.SectionKeys do
			t.Check("Migrate filled section " .. key, type(repaired.Data[key]) == "table")
		end
		t.Check("Migrate leaves a present section alone", repaired.Data.Currency.Gold == 5)
		t.Equal("Migrate replaces a corrupt section with defaults", repaired.Data.Inventory, DataSchema.NewSection("Inventory"))
		t.Check("Migrate fills Meta", repaired.Meta.CreatedAt == 0 and repaired.Meta.LastSaved == 0)

		local noData: any = { SchemaVersion = DataSchema.CURRENT_VERSION }
		local noDataStatus, noDataResult: any = Versioning.Migrate(noData)
		t.Check("Migrate builds Data when it is missing", noDataStatus == "Ok" and type(noDataResult.Data.Currency) == "table")

		local locked = DataSchema.NewRecord(1000)
		locked.Lock = { ServerId = "srv", SessionId = "ses", Time = 50 }
		local _, lockedResult: any = Versioning.Migrate(locked)
		t.Equal("Migrate keeps the Lock", lockedResult.Lock, { ServerId = "srv", SessionId = "ses", Time = 50 })
	end

	do
		local newer = DataSchema.NewRecord(1000)
		newer.SchemaVersion = DataSchema.CURRENT_VERSION + 1
		local status, result = Versioning.Migrate(newer)
		t.Check("Migrate rejects a newer SchemaVersion", status == "TooNew" and result == nil)
		t.Check("Newer record is left untouched", newer.SchemaVersion == DataSchema.CURRENT_VERSION + 1)
		t.Check("IsTooNew: newer record", Versioning.IsTooNew(newer))
		t.Check("IsTooNew: current record", not Versioning.IsTooNew(DataSchema.NewRecord(1000)))
		t.Check("IsTooNew: non-table", not Versioning.IsTooNew(nil))

		local invalidCases: { any } = {
			"text",
			42,
			{},
			{ SchemaVersion = "1" },
			{ SchemaVersion = -1 },
			{ SchemaVersion = 1.5 },
			{ SchemaVersion = 0 / 0 },
		}
		for index, bad in invalidCases do
			local badStatus, badResult = Versioning.Migrate(bad)
			t.Check("Migrate rejects invalid record #" .. index, badStatus == "Invalid" and badResult == nil)
		end
	end

	do
		local migrations = {
			[1] = function(record: any)
				table.insert(record.Data.Flags.Log, "1to2")
			end,
			[2] = function(record: any)
				table.insert(record.Data.Flags.Log, "2to3")
			end,
		}
		local old: any = {
			SchemaVersion = 1,
			Data = { Flags = { Log = {} } },
			Meta = { CreatedAt = 1, LastSaved = 2 },
		}

		local status, result: any = Versioning.Migrate(old, 3, migrations)
		t.Check("Migrate runs a chain of migrations", status == "Ok" and result.SchemaVersion == 3)
		t.Equal("Migrations run in order", result.Data.Flags.Log, { "1to2", "2to3" })
		t.Check("Migrate works on a copy", old.SchemaVersion == 1 and #old.Data.Flags.Log == 0)

		t.Check("Migrate asserts on a bad targetVersion", not pcall(Versioning.Migrate, old, -1))
		local missingStatus, missingResult = Versioning.Migrate({ SchemaVersion = 1, Data = {} }, 2, {})
		t.Check("Migrate fails when a migration is missing", missingStatus == "MigrationFailed" and missingResult == nil)

		local throwing: Versioning.MigrationTable = {
			[1] = function(record: any)
				record.Data.Marker = true
				error("boom")
			end,
		}
		local victim: any = { SchemaVersion = 1, Data = {} }
		local throwStatus, throwResult = Versioning.Migrate(victim, 2, throwing)
		t.Check("Migrate fails when a migration throws", throwStatus == "MigrationFailed" and throwResult == nil)
		t.Check("A failed migration leaves the input untouched", victim.SchemaVersion == 1 and victim.Data.Marker == nil)
	end

	-- BaseUtil
	do
		local maxInt = DataSchema.Limits.MaxInt
		t.Check("SanitizeInt floors decimals", BaseUtil.SanitizeInt(5.9, 0) == 5)
		t.Check("SanitizeInt raises negatives to 0", BaseUtil.SanitizeInt(-3, 0) == 0)
		t.Check("SanitizeInt uses the default for non-numbers", BaseUtil.SanitizeInt("abc", 7) == 7)
		t.Check("SanitizeInt uses the default for NaN", BaseUtil.SanitizeInt(0 / 0, 7) == 7)
		t.Check("SanitizeInt uses the default for infinity", BaseUtil.SanitizeInt(math.huge, 7) == 7)
		t.Check("SanitizeInt clamps huge numbers to the IntValue range", BaseUtil.SanitizeInt(1e20, 0) == maxInt)
		t.Check("SanitizeInt respects a custom max", BaseUtil.SanitizeInt(50, 0, 1, 10) == 10)
		t.Check("SanitizeInt clamps the default too", BaseUtil.SanitizeInt(nil, 0, 1, 10) == 1)
		t.Check("SanitizeInt asserts when min is above max", not pcall(BaseUtil.SanitizeInt, 5, 0, 10, 1))
		t.Check("SanitizeInt asserts on a non-finite default", not pcall(BaseUtil.SanitizeInt, 5, 0 / 0))

		t.Check("SanitizeTimestamp keeps a past time", BaseUtil.SanitizeTimestamp(900, 1000) == 900)
		t.Check("SanitizeTimestamp allows a little clock skew", BaseUtil.SanitizeTimestamp(1200, 1000) == 1200)
		t.Check("SanitizeTimestamp resets the far future", BaseUtil.SanitizeTimestamp(5000, 1000) == 0)
		t.Check("SanitizeTimestamp resets negatives", BaseUtil.SanitizeTimestamp(-5, 1000) == 0)
		t.Check("SanitizeTimestamp resets garbage", BaseUtil.SanitizeTimestamp("x", 1000) == 0)

		t.Check("SanitizeString keeps a valid string", BaseUtil.SanitizeString("Goku", "Pain") == "Goku")
		t.Check("SanitizeString defaults non-strings", BaseUtil.SanitizeString(5, "Pain") == "Pain")
		t.Check("SanitizeString defaults over-long strings", BaseUtil.SanitizeString(string.rep("a", 100), "Pain") == "Pain")
		t.Check("SanitizeBool keeps booleans", BaseUtil.SanitizeBool(true, false) == true)
		t.Check("SanitizeBool defaults everything else", BaseUtil.SanitizeBool("yes", false) == false)

		t.Equal("SanitizeIdSet keeps a valid map", BaseUtil.SanitizeIdSet({ Pain = true, Goku = true }), { Pain = true, Goku = true })
		t.Equal("SanitizeIdSet converts the old array shape", BaseUtil.SanitizeIdSet({ "Pain", "Goku" }), { Pain = true, Goku = true })
		t.Equal(
			"SanitizeIdSet drops junk entries",
			BaseUtil.SanitizeIdSet((function(): any
				local junkSet: any = { Pain = true, Bad = false }
				junkSet[5] = 5
				junkSet[string.rep("a", 100)] = true
				return junkSet
			end)()),
			{ Pain = true }
		)
		t.Equal("SanitizeIdSet of a non-table is empty", BaseUtil.SanitizeIdSet(7), {})
		t.Equal("AsTable passes tables through", BaseUtil.AsTable({ A = 1 }), { A = 1 })
		t.Equal("AsTable turns non-tables into an empty table", BaseUtil.AsTable("x"), {})
	end

	return t.Summary()
end