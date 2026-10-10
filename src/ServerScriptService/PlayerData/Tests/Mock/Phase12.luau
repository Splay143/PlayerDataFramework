--!strict
--@Splay

--[[
	Phase 12 tests: server-side network pieces (RateLimiter).
	It returns true when every check passed.
]]

local ServerScriptService = game:GetService("ServerScriptService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local PlayerData = ServerScriptService.PlayerData

local Harness = require(PlayerData.Tests.Harness)
local RateLimiter = require(PlayerData.Utils.RateLimiter)
local MockRemoteAdapter = require(PlayerData.Adapters.MockRemoteAdapter)
local PayloadValidator = require(PlayerData.Utils.PayloadValidator)
local Protocol = require(ReplicatedStorage.PlayerDataShared.Shared.Protocol)
local RemoteAdapter = require(PlayerData.Adapters.RemoteAdapter)

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

		-- PayloadValidator
	do
		local limits = Protocol.Limits

		local function reasonFor(payload: any): string?
			local _, reason = PayloadValidator.Validate(payload)
			return reason
		end

		local function isValid(payload: any): boolean
			local valid = PayloadValidator.Validate(payload)
			return valid
		end

		local function nested(levels: number): { [string]: any }
			local node: { [string]: any } = {}
			for _ = 2, levels do
				node = { Child = node }
			end
			return node
		end

		local function wide(entries: number): { number }
			local list: { number } = {}
			for index = 1, entries do
				list[index] = index
			end
			return list
		end

		t.Check("an empty table is valid", isValid({}))
		t.Check(
			"plain nested data is valid",
			isValid({ ItemId = "AK47", Count = 2, Equipped = true, Tags = { "a", "b" } })
		)
		t.Check("the same table used twice side by side is valid", (function(): boolean
			local shared = { 1 }
			return PayloadValidator.Validate({ A = shared, B = shared })
		end)())

		t.Equal("nil is refused", reasonFor(nil), "NotATable")
		t.Equal("a string is refused", reasonFor("x"), "NotATable")
		t.Equal("a function value is refused", reasonFor({ Callback = function() end }), "BadValueType")

		local part = Instance.new("Folder")
		t.Equal("an Instance value is refused", reasonFor({ Thing = part }), "BadValueType")
		part:Destroy()

		t.Equal("NaN is refused", reasonFor({ Value = 0 / 0 }), "BadNumber")
		t.Equal("infinity is refused", reasonFor({ Value = math.huge }), "BadNumber")
		t.Equal("a boolean key is refused", reasonFor({ [true :: any] = 1 }), "BadKeyType")

		t.Check("a string at the length limit is valid", isValid({ Text = string.rep("a", limits.MaxStringLength) }))
		t.Equal("a string over the limit is refused", reasonFor({ Text = string.rep("a", limits.MaxStringLength + 1) }), "StringTooLong")
		t.Equal("a key over the limit is refused", reasonFor({ [string.rep("a", limits.MaxStringLength + 1)] = 1 }), "StringTooLong")

		t.Check("nesting at the depth limit is valid", isValid(nested(limits.MaxPayloadDepth)))
		t.Equal("nesting past the depth limit is refused", reasonFor(nested(limits.MaxPayloadDepth + 1)), "TooDeep")

		-- The root table counts as one node, so this is exactly the limit.
		t.Check("a payload at the node limit is valid", isValid(wide(limits.MaxPayloadNodes - 1)))
		t.Equal("a payload over the node limit is refused", reasonFor(wide(limits.MaxPayloadNodes)), "TooLarge")

		local cyclic: any = {}
		cyclic.Self = cyclic
		t.Equal("a table containing itself is refused", reasonFor(cyclic), "Cycle")
	end

	-- RemoteAdapter (creates the real remotes, so it destroys them again)
	do
		local function classOf(name: string): string?
			local folder = ReplicatedStorage:FindFirstChild(Protocol.RemoteFolderName)
			local remote = if folder then folder:FindFirstChild(name) else nil
			return if remote then remote.ClassName else nil
		end

		local adapter = RemoteAdapter.new()

		t.Equal("Replication is a RemoteEvent", classOf(Protocol.RemoteNames.Replication), "RemoteEvent")
		t.Equal("Send is a RemoteEvent", classOf(Protocol.RemoteNames.Send), "RemoteEvent")
		t.Equal("Request is a RemoteFunction", classOf(Protocol.RemoteNames.Request), "RemoteFunction")

		t.Check("a second adapter is refused while the first exists", not pcall(RemoteAdapter.new))
		t.Check("SendReplication rejects a non-Player", not pcall(function()
			adapter:SendReplication({} :: any, Protocol.NewSnapshot(0, {}))
		end))
		t.Check("OnSend rejects a non-function", not pcall(function()
			adapter:OnSend("nope" :: any)
		end))

		adapter:SetRequestHandler(function()
			return nil
		end)
		t.Check("a second request handler is refused", not pcall(function()
			adapter:SetRequestHandler(function()
				return nil
			end)
		end))

		adapter:Destroy()
		t.Check("Destroy removes the remotes", ReplicatedStorage:FindFirstChild(Protocol.RemoteFolderName) == nil)

		local replacement = RemoteAdapter.new()
		t.Check("a new adapter can be made after Destroy", ReplicatedStorage:FindFirstChild(Protocol.RemoteFolderName) ~= nil)
		replacement:Destroy()
	end

	-- MockRemoteAdapter
	do
		local alice = ({ Name = "Alice" } :: any) :: Player
		local bob = ({ Name = "Bob" } :: any) :: Player

		-- Server -> client
		do
			local adapter = MockRemoteAdapter.new()
			local snapshot = Protocol.NewSnapshot(0, { Coins = 5 })

			t.Equal("a player with nothing sent has an empty list", adapter:ReplicatedTo(alice), {})

			adapter:SendReplication(alice, snapshot)
			snapshot.Data.Coins = 999
			t.Equal("a sent message is recorded as a copy", adapter:ReplicatedTo(alice), { { Type = "Snapshot", Sequence = 0, Data = { Coins = 5 } } })
			t.Equal("another player received nothing", adapter:ReplicatedTo(bob), {})

			t.Check("SendReplication rejects an invalid message", not pcall(function()
				adapter:SendReplication(alice, { Type = "Boom" } :: any)
			end))
		end

		-- Client -> server events
		do
			local adapter = MockRemoteAdapter.new()
			local received: { { Player: Player, Route: any, Payload: any } } = {}
			local sentPayload = { ItemId = "AK47" }

			local disconnect = adapter:OnSend(function(player, route, payload)
				table.insert(received, { Player = player, Route = route, Payload = payload })
			end)

			adapter:SimulateSend(alice, "Reload", sentPayload)
			t.Equal("a send reaches the handler", #received, 1)
			t.Check("the handler sees the player", received[1].Player == alice)
			t.Equal("the handler sees the route", received[1].Route, "Reload")
			t.Equal("the handler sees the payload", received[1].Payload, { ItemId = "AK47" })
			t.Check("the payload is a copy", received[1].Payload ~= sentPayload)

			disconnect()
			adapter:SimulateSend(alice, "Reload", {})
			t.Equal("a disconnected handler receives nothing", #received, 1)
		end

		-- A throwing handler must not stop the others
		do
			local adapter = MockRemoteAdapter.new()
			local calls = 0
			adapter:OnSend(function()
				error("simulated handler failure")
			end)
			adapter:OnSend(function()
				calls += 1
			end)

			adapter:SimulateSend(alice, "Reload", {})
			t.Equal("a throwing send handler does not stop the others", calls, 1)
		end

		-- Snapshot requests
		do
			local adapter = MockRemoteAdapter.new()
			local requesters: { Player } = {}
			adapter:OnSnapshotRequested(function(player)
				table.insert(requesters, player)
			end)

			adapter:SimulateSnapshotRequest(bob)
			t.Check("a snapshot request names the player", requesters[1] == bob and #requesters == 1)
		end

		-- Requests
		do
			local adapter = MockRemoteAdapter.new()

			t.Check("a request with no handler asserts", not pcall(function()
				adapter:SimulateRequest(alice, "EquipItem", {})
			end))

			adapter:SetRequestHandler(function(player, route, payload)
				return { Success = true, Route = route, ItemId = payload.ItemId, Player = player }
			end)

			local result = adapter:SimulateRequest(alice, "EquipItem", { ItemId = "AK47" })
			t.Check("a request returns the handler's result", result.Success == true and result.ItemId == "AK47")
			t.Check("the handler sees the player", result.Player == alice)

			t.Check("a second request handler is refused", not pcall(function()
				adapter:SetRequestHandler(function()
					return nil
				end)
			end))
		end
	end
	
	return t.Summary()
end
