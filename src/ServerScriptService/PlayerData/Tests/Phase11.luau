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

	return t.Summary()
end
