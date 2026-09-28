--!strict
--@Splay

--[[
	Phase 6 tests: v2 reliability fixes.

	Currently covers ReleaseTracker,the Locked retry on
	Acquire, SessionLost handling.

	Nothing here uses real time: a fake clock advances only when the code
	under test calls Wait, so the tests run instantly and deterministically.

	It returns true when every check passed.
]]

local ServerScriptService = game:GetService("ServerScriptService")

local PlayerData = ServerScriptService.PlayerData

local ReleaseTracker = require(PlayerData.Utils.ReleaseTracker)

local Harness = require(PlayerData.Tests.Harness)

type FakeTime = {
	Now: () -> number,
	Wait: (seconds: number) -> (),
	WaitCount: () -> number,
	-- Runs after every Wait, so a test can make something happen "while waiting".
	OnWait: (callback: (waitCount: number) -> ()) -> (),
}

local function newFakeTime(): FakeTime
	local currentTime = 0
	local waitCount = 0
	local onWait: ((waitCount: number) -> ())? = nil

	return {
		Now = function()
			return currentTime
		end,
		Wait = function(seconds: number)
			currentTime += seconds
			waitCount += 1
			if onWait then
				onWait(waitCount)
			end
		end,
		WaitCount = function()
			return waitCount
		end,
		OnWait = function(callback: (waitCount: number) -> ())
			onWait = callback
		end,
	}
end

-- 0.25 is exactly representable in binary, so four polls land on exactly 1.0
-- with no floating-point drift in the timeout checks.
local TEST_POLL_INTERVAL_SECONDS = 0.25

local function newTracker(fakeTime: FakeTime): ReleaseTracker.ReleaseTracker
	return ReleaseTracker.new({
		Now = fakeTime.Now,
		Wait = fakeTime.Wait,
		PollIntervalSeconds = TEST_POLL_INTERVAL_SECONDS,
	})
end

return function(): boolean
	local t = Harness.new("Phase6")

	-- ReleaseTracker.new argument checks
	do
		t.Check(
			"new asserts when PollIntervalSeconds is 0",
			not pcall(function()
				ReleaseTracker.new({ PollIntervalSeconds = 0 })
			end)
		)

		t.Check(
			"new asserts when PollIntervalSeconds is negative",
			not pcall(function()
				ReleaseTracker.new({ PollIntervalSeconds = -1 })
			end)
		)
	end

	-- Begin argument checks
	do
		local tracker = newTracker(newFakeTime())

		t.Check(
			"Begin asserts on a non-number userId",
			not pcall(function()
				tracker:Begin("123" :: any)
			end)
		)

		t.Check(
			"Begin asserts on a fractional userId",
			not pcall(function()
				tracker:Begin(1.5)
			end)
		)

		t.Check(
			"Begin asserts on a NaN userId",
			not pcall(function()
				tracker:Begin(0 / 0)
			end)
		)
	end

	-- Pending state
	do
		local tracker = newTracker(newFakeTime())

		t.Check("Nothing is pending before Begin", not tracker:IsPending(1))

		local finish = tracker:Begin(1)
		t.Check("A user is pending after Begin", tracker:IsPending(1))
		t.Check("Other users are not affected by Begin", not tracker:IsPending(2))

		finish()
		t.Check("A user is not pending after finish", not tracker:IsPending(1))
	end

	-- finish is safe to call twice, and overlapping releases do not clear each other
	do
		local tracker = newTracker(newFakeTime())

		local finishFirst = tracker:Begin(1)
		local finishSecond = tracker:Begin(1)

		finishFirst()
		finishFirst() -- second call must not consume the other release's pending state
		t.Check("Calling finish twice does not clear an overlapping release", tracker:IsPending(1))

		finishSecond()
		t.Check("The user is clear once every overlapping release has finished", not tracker:IsPending(1))
	end

	-- WaitUntilClear argument checks
	do
		local tracker = newTracker(newFakeTime())

		t.Check(
			"WaitUntilClear asserts on a non-number userId",
			not pcall(function()
				tracker:WaitUntilClear("123" :: any, 1)
			end)
		)

		t.Check(
			"WaitUntilClear asserts on a negative timeout",
			not pcall(function()
				tracker:WaitUntilClear(1, -1)
			end)
		)
	end

	-- WaitUntilClear returns immediately when nothing is pending
	do
		local fakeTime = newFakeTime()
		local tracker = newTracker(fakeTime)

		t.Check("WaitUntilClear returns true when nothing is pending", tracker:WaitUntilClear(1, 10))
		t.Equal("WaitUntilClear does not wait when nothing is pending", fakeTime.WaitCount(), 0)
	end

	-- A pending release for one user does not block another user
	do
		local fakeTime = newFakeTime()
		local tracker = newTracker(fakeTime)

		tracker:Begin(1)

		t.Check("WaitUntilClear ignores other users' pending releases", tracker:WaitUntilClear(2, 10))
		t.Equal("No waiting happens for an unaffected user", fakeTime.WaitCount(), 0)
	end

	-- WaitUntilClear returns true once the release finishes mid-wait
	do
		local fakeTime = newFakeTime()
		local tracker = newTracker(fakeTime)

		local finish = tracker:Begin(1)
		fakeTime.OnWait(function(waitCount: number)
			if waitCount == 3 then
				finish()
			end
		end)

		t.Check("WaitUntilClear returns true when the release finishes in time", tracker:WaitUntilClear(1, 10))
		t.Equal("WaitUntilClear stops polling as soon as the release finishes", fakeTime.WaitCount(), 3)
		t.Check("The user is clear afterwards", not tracker:IsPending(1))
	end

	-- WaitUntilClear times out when the release never finishes
	do
		local fakeTime = newFakeTime()
		local tracker = newTracker(fakeTime)

		tracker:Begin(1)

		t.Check("WaitUntilClear returns false on timeout", not tracker:WaitUntilClear(1, 1))
		t.Equal("WaitUntilClear polls until the deadline", fakeTime.WaitCount(), 4)
		t.Equal("WaitUntilClear waits exactly the timeout, not longer", fakeTime.Now(), 1)
		t.Check("The user is still pending after a timeout", tracker:IsPending(1))
	end

	-- WaitUntilClear never sleeps past the deadline
	do
		local fakeTime = newFakeTime()
		local tracker = newTracker(fakeTime)

		tracker:Begin(1)

		-- 0.6s is not a multiple of the 0.25s poll, so the last sleep must be shortened to 0.1s.
		t.Check("WaitUntilClear times out on a non-multiple timeout", not tracker:WaitUntilClear(1, 0.6))
		t.Check("WaitUntilClear does not overshoot the deadline", math.abs(fakeTime.Now() - 0.6) < 1e-9)
	end

	-- A zero timeout checks once and does not wait
	do
		local fakeTime = newFakeTime()
		local tracker = newTracker(fakeTime)

		tracker:Begin(1)

		t.Check("WaitUntilClear with a 0 timeout returns false when pending", not tracker:WaitUntilClear(1, 0))
		t.Equal("WaitUntilClear with a 0 timeout does not wait", fakeTime.WaitCount(), 0)
	end

	return t.Summary()
end