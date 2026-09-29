--!strict
--@Splay

export type Options = {
    Now: (() -> number)?,
    Wait: ((seconds: number) -> ())?,
    PollIntervalSeconds: number?,
}

export type ReleaseTracker = {
    Begin: (self: ReleaseTracker, userId: number)-> () -> (),
    IsPending: (self: ReleaseTracker, userId: number) -> boolean,
    WaitUntilClear: (Self: ReleaseTracker, userId: number, timeoutSeconds: number) -> boolean,
}

local DEFAULT_POLL_INTERVAL_SECONDS = 0.1

local ReleaseTracker = {}
ReleaseTracker.__index = ReleaseTracker

local function isWholeNumber(value: any): boolean
    return type(value) == "number" and value == math.floor(value) and value > -math.huge and value < math.huge
end

function ReleaseTracker.new(options: Options?): ReleaseTracker
    local now: () -> number = (options and options.Now) or os.clock

    local wait: (seconds: number) -> () = (options and options.Wait)
	    or function(seconds: number)
		    task.wait(seconds)
        end

    local pollInterval: number = (options and options.PollIntervalSeconds) or DEFAULT_POLL_INTERVAL_SECONDS
    assert(pollInterval >0, "ReleaseTracler.new: PollIntervalSeconds must be greater than 0")

    local self = setmetatable({
        _now = now,
        _wait = wait,
        _pollInterval = pollInterval,
        _pendingCounts = {} :: { [number]: number },
    }, ReleaseTracker)

    return (self :: any) :: ReleaseTracker
end

function ReleaseTracker.Begin(self: any, userId: number): () -> ()
    assert(isWholeNumber(userId), "ReleaseTracker:Begin: userId must be a whole number")

    self ._pendingCounts[userId] = (self._pendingCounts[userId] or 0) + 1

    local finished = false
    return function()
        if finished then
            return
        end
        finished = true

        local remaining = self._pendingCounts[userId] - 1
        if remaining <= 0 then
            self._pendingCounts[userId] = nil
        else
            self._pendingCounts[userId] = remaining
        end
    end
end

function ReleaseTracker.IsPending(self: any, userId: number): boolean
    return self._pendingCounts[userId] ~= nil
end

function ReleaseTracker.WaitUntilClear(self: any, userId: number, timeoutSeconds: number): boolean
    assert(isWholeNumber(userId), "ReleaseTracker:WaitUntilClear: userId must be a whole number")
	assert(
		type(timeoutSeconds) == "number" and timeoutSeconds >= 0,
		"ReleaseTracker:WaitUntilClear: timeoutSeconds must be at least 0"
	)

    local deadline = self._now() + timeoutSeconds

    while self._pendingCounts[userId] ~= nil do
        local remaining = deadline - self._now()
        if remaining <= 0 then
            return false
        end

        self._wait(math.min(self._pollInterval, remaining))
    end

    return true
end

return ReleaseTracker