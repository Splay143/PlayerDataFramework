--!strict
--[[
	Phase 11 tests: DeltaUtil.Diff.
	It returns true when every check passed.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Shared = ReplicatedStorage.PlayerDataShared.Shared
local DeltaUtil = require(Shared.DeltaUtil)
local Harness = require(ServerScriptService.PlayerData.Tests.Harness)
local Protocol = require(Shared.Protocol)
local TableUtil = require(Shared.TableUtil)

local SET = Protocol.ChangeType.Set
local REMOVE = Protocol.ChangeType.Remove

return function(): boolean
	local t = Harness.new("Phase11")

	-- Basic changes
	do
		t.Equal("identical data gives no changes", DeltaUtil.Diff({ A = { B = 1 } }, { A = { B = 1 } }), {})

		t.Equal(
			"nested scalar change is a Set at its path",
			DeltaUtil.Diff({ Stats = { Level = 1, Coins = 5 } }, { Stats = { Level = 2, Coins = 5 } }),
			{ { Type = SET, Path = { "Stats", "Level" }, Value = 2 } }
		)

		t.Equal(
			"added key is a Set",
			DeltaUtil.Diff({ Stats = {} }, { Stats = { Level = 1 } }),
			{ { Type = SET, Path = { "Stats" }, Value = { Level = 1 } } }
		)

		t.Equal(
			"added key on a non-empty dictionary is a Set at that key",
			DeltaUtil.Diff({ Stats = { Coins = 5 } }, { Stats = { Coins = 5, Level = 1 } }),
			{ { Type = SET, Path = { "Stats", "Level" }, Value = 1 } }
		)

		t.Equal(
			"removed key is a Remove",
			DeltaUtil.Diff({ Stats = { Coins = 5, Level = 1 } }, { Stats = { Coins = 5 } }),
			{ { Type = REMOVE, Path = { "Stats", "Level" } } }
		)

		t.Equal(
			"first key into an empty root is a Set at that key, not a root replace",
			DeltaUtil.Diff({}, { Inventory = { "Sword" } }),
			{ { Type = SET, Path = { "Inventory" }, Value = { "Sword" } } }
		)
	end

	-- Arrays
	do
		t.Equal(
			"same-length array change is a Set at the index",
			DeltaUtil.Diff({ Inventory = { "Sword", "Potion" } }, { Inventory = { "Sword", "Bow" } }),
			{ { Type = SET, Path = { "Inventory", 2 } :: { DeltaUtil.PathKey }, Value = "Bow" } }
		)

		t.Equal(
			"array length change replaces the whole array",
			DeltaUtil.Diff({ Inventory = { "Sword" } }, { Inventory = { "Sword", "Bow" } }),
			{ { Type = SET, Path = { "Inventory" }, Value = { "Sword", "Bow" } } }
		)

		t.Equal(
			"array becoming a dictionary replaces the whole value",
			DeltaUtil.Diff({ Items = { "A" } }, { Items = { Slot = "A" } }),
			{ { Type = SET, Path = { "Items" }, Value = { Slot = "A" } } }
		)
	end

	-- Edge values
	do
		t.Equal(
			"true to false is a Set of false",
			DeltaUtil.Diff({ Flag = true }, { Flag = false }),
			{ { Type = SET, Path = { "Flag" }, Value = false } }
		)

		t.Equal(
			"a newly added false value is a Set",
			DeltaUtil.Diff({}, { Flag = false }),
			{ { Type = SET, Path = { "Flag" }, Value = false } }
		)

		t.Equal(
			"scalar replaced by a table is a Set",
			DeltaUtil.Diff({ Slot = 1 }, { Slot = { Id = 1 } }),
			{ { Type = SET, Path = { "Slot" }, Value = { Id = 1 } } }
		)
	end

	-- Ordering and isolation
	do
		t.Equal(
			"changes come out in sorted key order",
			DeltaUtil.Diff({ B = 1, A = 1, C = 1 }, { B = 2, A = 2, C = 2 }),
			{
				{ Type = SET, Path = { "A" }, Value = 2 },
				{ Type = SET, Path = { "B" }, Value = 2 },
				{ Type = SET, Path = { "C" }, Value = 2 },
			}
		)

		local oldData = { Stats = { Level = 1 } }
		local newData = { Stats = { Level = 2 } }
		local oldBefore = TableUtil.DeepCopy(oldData)
		local newBefore = TableUtil.DeepCopy(newData)
		DeltaUtil.Diff(oldData, newData)
		t.Equal("Diff does not mutate the old data", oldData, oldBefore)
		t.Equal("Diff does not mutate the new data", newData, newBefore)

		local source = { Inventory = { Items = { "Sword" } } }
		local changes = DeltaUtil.Diff({ Inventory = {} }, source)
		source.Inventory.Items[1] = "Changed afterwards"
		t.Equal("change values are copies, later mutation does not leak in", changes[1].Value, { Items = { "Sword" } })
	end

	-- Depth cap
	do
		local maxDepth = Protocol.Limits.MaxPathDepth

		local function buildNested(depth: number, leaf: number): { [string]: any }
			local node: { [string]: any } = { Value = leaf }
			for level = depth, 1, -1 do
				node = { ["L" .. tostring(level)] = node }
			end
			return node
		end

		-- 12 levels deep: far past the cap
		local changes = DeltaUtil.Diff(buildNested(12, 1), buildNested(12, 2))
		t.Check("deep change produces exactly one Set", #changes == 1 and changes[1].Type == SET)
		t.Check("deep change path is capped at MaxPathDepth", #changes[1].Path == maxDepth)

		local expectedPath: { string } = {}
		for level = 1, maxDepth do
			table.insert(expectedPath, "L" .. tostring(level))
		end
		t.Equal("capped path follows the nesting", changes[1].Path, expectedPath)

		local expectedSubtree: any = buildNested(12, 2)
		for _, key in expectedPath do
			expectedSubtree = expectedSubtree[key]
		end
		t.Equal("capped Set carries the whole remaining subtree", changes[1].Value, expectedSubtree)

		t.Equal("identical deep data gives no changes", DeltaUtil.Diff(buildNested(12, 1), buildNested(12, 1)), {})
	end

	-- Input validation
	do
		t.Check("Diff rejects a non-table old value", not pcall(DeltaUtil.Diff, nil :: any, {}))
		t.Check("Diff rejects a non-table new value", not pcall(DeltaUtil.Diff, {}, "x" :: any))
		t.Check("Diff rejects non string/number keys", not pcall(DeltaUtil.Diff, {}, { [true :: any] = 1 }))
	end

	-- Apply: round trip with Diff
	do
		local cases: { { Old: any, New: any } } = {
			{ Old = { Stats = { Level = 1, Coins = 5 } }, New = { Stats = { Level = 2, Coins = 5 } } },
			{ Old = { Stats = { Coins = 5 } }, New = { Stats = { Coins = 5, Level = 1 } } },
			{ Old = { Stats = { Coins = 5, Level = 1 } }, New = { Stats = { Coins = 5 } } },
			{ Old = {}, New = { Inventory = { "Sword" } } },
			{ Old = { Inventory = { "Sword", "Potion" } }, New = { Inventory = { "Sword", "Bow" } } },
			{ Old = { Inventory = { "Sword" } }, New = { Inventory = { "Sword", "Bow" } } },
			{ Old = { Items = { "A" } }, New = { Items = { Slot = "A" } } },
			{ Old = { Flag = true }, New = { Flag = false } },
			{ Old = { Slot = 1 }, New = { Slot = { Id = 1 } } },
			{ Old = { A = { B = { C = 1 } }, D = 1 }, New = { A = { B = { C = 2 } } } },
		}

		for index, case in cases do
			local working = TableUtil.DeepCopy(case.Old)
			local applied = DeltaUtil.Apply(working, DeltaUtil.Diff(case.Old, case.New))
			t.Check("round trip #" .. index .. " applies cleanly", applied)
			t.Equal("round trip #" .. index .. " reproduces the new data", working, case.New)
		end
	end

	-- Apply: individual changes
	do
		local data: any = { Stats = { Coins = 5 } }

		t.Check("an empty change list is fine", DeltaUtil.Apply(data, {}))
		t.Equal("an empty change list changes nothing", data, { Stats = { Coins = 5 } })

		DeltaUtil.Apply(data, { { Type = SET, Path = { "Stats", "Level" }, Value = 3 } })
		t.Equal("Set adds a new key", data.Stats.Level, 3)

		DeltaUtil.Apply(data, { { Type = REMOVE, Path = { "Stats", "Level" } } })
		t.Check("Remove deletes a key", data.Stats.Level == nil)

		DeltaUtil.Apply(data, {
			{ Type = SET, Path = { "Stats", "Temp" }, Value = 1 },
			{ Type = REMOVE, Path = { "Stats", "Temp" } },
		})
		t.Check("changes apply in order", data.Stats.Temp == nil)

		local value = { Level = 1 }
		DeltaUtil.Apply(data, { { Type = SET, Path = { "Stats", "Profile" }, Value = value } })
		value.Level = 99
		t.Equal("Set stores a copy of the value", data.Stats.Profile, { Level = 1 })
	end

	-- Apply: a change that does not fit means the state has drifted
	do
		local function appliesNothing(change: any): boolean
			local data: any = { Stats = { Coins = 5 } }
			return not DeltaUtil.Apply(data, { change })
		end

		t.Check(
			"Set under a missing parent fails",
			appliesNothing({ Type = SET, Path = { "Missing", "Key" }, Value = 1 })
		)
		t.Check(
			"Set under a non-table parent fails",
			appliesNothing({ Type = SET, Path = { "Stats", "Coins", "X" }, Value = 1 })
		)
		t.Check("Remove of a missing key fails", appliesNothing({ Type = REMOVE, Path = { "Stats", "Gone" } }))
		t.Check("an empty path fails", appliesNothing({ Type = SET, Path = {}, Value = 1 }))
		t.Check(
			"a path past the depth cap fails",
			appliesNothing({
				Type = SET,
				Path = { "A", "B", "C", "D", "E", "F", "G", "H", "I" },
				Value = 1,
			})
		)
		t.Check("an unknown change type fails", appliesNothing({ Type = "Explode", Path = { "Stats" }, Value = 1 }))
		t.Check("Set without a value fails", appliesNothing({ Type = SET, Path = { "Stats", "Coins" } }))
		t.Check("a non-table change fails", appliesNothing("nope"))
		t.Check("a boolean path key fails", appliesNothing({ Type = SET, Path = { true }, Value = 1 }))
		t.Check("a NaN path key fails", appliesNothing({ Type = SET, Path = { 0 / 0 }, Value = 1 }))

		t.Check("Apply asserts on non-table data", not pcall(DeltaUtil.Apply, "x" :: any, {}))
		t.Check("Apply asserts on non-table changes", not pcall(DeltaUtil.Apply, {}, "x" :: any))
	end

	-- Protocol messages
	do
		local snapshot = Protocol.NewSnapshot(0, { Inventory = {} })
		t.Check("NewSnapshot builds a valid message", Protocol.IsValidMessage(snapshot))
		t.Equal("NewSnapshot uses the Snapshot type", snapshot.Type, Protocol.MessageType.Snapshot)

		local delta = Protocol.NewDelta(7, {})
		t.Check("NewDelta builds a valid message", Protocol.IsValidMessage(delta))
		t.Equal("NewDelta keeps the sequence", delta.Sequence, 7)

		t.Check("NewSnapshot asserts on a negative sequence", not pcall(Protocol.NewSnapshot, -1, {}))
		t.Check("NewDelta asserts on a fractional sequence", not pcall(Protocol.NewDelta, 1.5, {}))
		t.Check("NewDelta asserts on non-table changes", not pcall(Protocol.NewDelta, 1, "x" :: any))

		t.Check("IsValidMessage rejects a non-table", not Protocol.IsValidMessage("x"))
		t.Check("IsValidMessage rejects an unknown type", not Protocol.IsValidMessage({ Type = "Boom", Sequence = 1 }))
		t.Check(
			"IsValidMessage rejects a missing sequence",
			not Protocol.IsValidMessage({ Type = "Delta", Changes = {} })
		)
		t.Check(
			"IsValidMessage rejects a NaN sequence",
			not Protocol.IsValidMessage({ Type = "Delta", Sequence = 0 / 0, Changes = {} })
		)
		t.Check(
			"IsValidMessage rejects a Snapshot without Data",
			not Protocol.IsValidMessage({ Type = "Snapshot", Sequence = 1 })
		)
		t.Check(
			"IsValidMessage rejects a Delta without Changes",
			not Protocol.IsValidMessage({ Type = "Delta", Sequence = 1 })
		)
	end
	return t.Summary()
end
