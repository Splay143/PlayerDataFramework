--!strict
--@Splay
--[[
	Harness
	Minimal test helper used by the step test modules in this folder.

		local t = Harness.new("Step1")
		t.Check("something is true", 1 + 1 == 2)
		t.Equal("tables match", { A = 1 }, { A = 1 })
		return t.Summary()   -- prints the totals, true when nothing failed
]]

local ServerScriptService = game:GetService("ServerScriptService")
local TableUtil = require(ServerScriptService.PlayerData.Utils.TableUtil)

export type Suite = {
	Check: (name: string, condition: boolean) -> (),
	Equal: (name: string, actual: any, expected: any) -> (),
	Summary: () -> boolean,
}

local Harness = {}

function Harness.new(suiteName: string): Suite
	local passed = 0
	local failed = 0

	local function check(name: string, condition: boolean)
		if condition then
			passed += 1
		else
			failed += 1
			print(string.format("[FAIL] %s: %s", suiteName, name))
		end
	end

	local function equal(name: string, actual: any, expected: any)
		check(name, TableUtil.DeepEqual(actual, expected))
	end

	local function summary(): boolean
		print(string.format("[%s] %d passed, %d failed", suiteName, passed, failed))
		return failed == 0
	end

	return {
		Check = check,
		Equal = equal,
		Summary = summary,
	}
end

return Harness