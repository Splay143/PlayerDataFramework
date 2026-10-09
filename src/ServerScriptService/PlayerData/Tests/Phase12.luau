--!strict
--@Splay

--[[
	Phase 12 tests: server-side network pieces (RateLimiter).
	It returns true when every check passed.
]]

local ServerScriptService = game:GetService("ServerScriptService")

local PlayerData = ServerScriptService.PlayerData

local Harness = require(PlayerData.Tests.Harness)
local RateLimiter = require(PlayerData.Utils.RateLimiter)

local function newLimiter(capacity: number, refillPerSecond: number): (RateLimiter.RateLimiter, (seconds: number) -> ())
	local currentTime = 0

	local limiter = RateLimiter.new({ Capacity = capacity, RefillPerSecond = refillPerSecond }, {
		Now = function()
			return currentTime
		end,
	})

	local function advance(seconds: number)
		currentTime += seconds
	end

	return limiter, advance
end

return function(): boolean
	local t = Harness.new("Phase12")

	-- RateLimiter argument checks
	do
		t.Check("new asserts on a non-table policy", not pcall(function()
			RateLimiter.new("nope" :: any)
		end))
		t.Check("new asserts on a Capacity below 1", not pcall(function()
			RateLimiter.new({ Capacity = 0, RefillPerSecond = 1 })
		end))
		t.Check("new asserts on a RefillPerSecond of 0", not pcall(function()
			RateLimiter.new({ Capacity = 1, RefillPerSecond = 0 })
		end))

		local limiter = newLimiter(1, 1)
		t.Check("TryConsume asserts on a nil key", not pcall(function()
			limiter:TryConsume(nil, "Route")
		end))
		t.Check("TryConsume asserts on an empty bucketName", not pcall(function()
			limiter:TryConsume("Alice", "")
		end))
	end

	-- A burst up to Capacity is allowed, then refused
	do
		local limiter = newLimiter(3, 1)

		t.Check("The first call is allowed", limiter:TryConsume("Alice", "Route"))
		t.Check("The second call is allowed", limiter:TryConsume("Alice", "Route"))
		t.Check("The third call is allowed", limiter:TryConsume("Alice", "Route"))
		t.Check("The call past Capacity is refused", not limiter:TryConsume("Alice", "Route"))
	end

	-- Tokens refill over time
	do
		local limiter, advance = newLimiter(2, 2)
		limiter:TryConsume("Alice", "Route")
		limiter:TryConsume("Alice", "Route")
		t.Check("An empty bucket refuses", not limiter:TryConsume("Alice", "Route"))

		advance(0.25)
		t.Check("Half a token is not enough", not limiter:TryConsume("Alice", "Route"))

		advance(0.25)
		t.Check("One full token has refilled after 0.5s at 2 per second", limiter:TryConsume("Alice", "Route"))
		t.Check("Only one token had refilled", not limiter:TryConsume("Alice", "Route"))
	end

	-- Idle time never banks more than Capacity
	do
		local limiter, advance = newLimiter(2, 1)
		limiter:TryConsume("Alice", "Route")

		advance(1000)
		t.Check("After a long idle the first call is allowed", limiter:TryConsume("Alice", "Route"))
		t.Check("After a long idle the second call is allowed", limiter:TryConsume("Alice", "Route"))
		t.Check("Idle time cannot bank more than Capacity", not limiter:TryConsume("Alice", "Route"))
	end

	-- Buckets are independent per key and per bucketName
	do
		local limiter = newLimiter(1, 1)

		t.Check("Alice spends her only token", limiter:TryConsume("Alice", "Route"))
		t.Check("Bob has his own bucket", limiter:TryConsume("Bob", "Route"))
		t.Check("Alice has a separate bucket per route name", limiter:TryConsume("Alice", "OtherRoute"))
		t.Check("Alice's first bucket is still empty", not limiter:TryConsume("Alice", "Route"))
	end

	-- Remove frees a key
	do
		local limiter = newLimiter(1, 1)
		limiter:TryConsume("Alice", "Route")
		t.Check("The bucket is empty before Remove", not limiter:TryConsume("Alice", "Route"))

		limiter:Remove("Alice")
		t.Check("A removed key starts again with a full bucket", limiter:TryConsume("Alice", "Route"))
		t.Check(
			"Removing an unknown key is safe",
			pcall(function()
				limiter:Remove("Nobody")
			end)
		)
	end

	-- A clock that steps backwards cannot create or destroy tokens
	do
		local currentTime = 100
		local limiter = RateLimiter.new({ Capacity = 1, RefillPerSecond = 1 }, {
			Now = function()
				return currentTime
			end,
		})

		limiter:TryConsume("Alice", "Route")
		currentTime = 50
		t.Check("A backwards clock does not refill the bucket", not limiter:TryConsume("Alice", "Route"))
	end

	return t.Summary()
end
