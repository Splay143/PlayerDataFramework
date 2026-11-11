--!strict
--@Splay

export type Call = {
	UserId: number,
	Reason: string,
	DurationSeconds: number,
}

type Fields = {
	Calls: { Call },
	ShouldFail: boolean,
}

local MockBanHandler = {}
MockBanHandler.__index = MockBanHandler

export type MockBanHandler = typeof(setmetatable({} :: Fields, MockBanHandler))

function MockBanHandler.new(): MockBanHandler
	return setmetatable({ Calls = {} :: { Call }, ShouldFail = false }, MockBanHandler)
end

function MockBanHandler.Handle(self: MockBanHandler, userId: number, reason: string, durationSeconds: number)
	table.insert(self.Calls, { UserId = userId, Reason = reason, DurationSeconds = durationSeconds })
	if self.ShouldFail then
		error("MockBanHandler: ban failed on purpose")
	end
end

return MockBanHandler