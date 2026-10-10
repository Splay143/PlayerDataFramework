--!strict
--@Splay

--[[
	Phase 12 tests: server-side network pieces
	It returns true when every check passed.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local PlayerData = ServerScriptService.PlayerData

local DataSchema = require(PlayerData.Config.DataSchema)
local DeltaUtil = require(ReplicatedStorage.PlayerDataShared.Shared.DeltaUtil)
local Harness = require(PlayerData.Tests.Harness)
local MockRemoteAdapter = require(PlayerData.Adapters.MockRemoteAdapter)
local PayloadValidator = require(PlayerData.Utils.PayloadValidator)
local Protocol = require(ReplicatedStorage.PlayerDataShared.Shared.Protocol)
local RateLimiter = require(PlayerData.Utils.RateLimiter)
local RemoteAdapter = require(PlayerData.Adapters.RemoteAdapter)
local ReplicationService = require(PlayerData.Networking.ReplicationService)
local ReplicationState = require(PlayerData.Networking.ReplicationState)

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
		t.Check(
			"the same table used twice side by side is valid",
			(function(): boolean
				local shared = { 1 }
				return PayloadValidator.Validate({ A = shared, B = shared })
			end)()
		)

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
		t.Equal(
			"a string over the limit is refused",
			reasonFor({ Text = string.rep("a", limits.MaxStringLength + 1) }),
			"StringTooLong"
		)
		t.Equal(
			"a key over the limit is refused",
			reasonFor({ [string.rep("a", limits.MaxStringLength + 1)] = 1 }),
			"StringTooLong"
		)

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
		t.Check(
			"a new adapter can be made after Destroy",
			ReplicatedStorage:FindFirstChild(Protocol.RemoteFolderName) ~= nil
		)
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
			t.Equal(
				"a sent message is recorded as a copy",
				adapter:ReplicatedTo(alice),
				{ { Type = "Snapshot", Sequence = 0, Data = { Coins = 5 } } }
			)
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

	-- ReplicationState
	do
		local SET = Protocol.ChangeType.Set

		local function setChange(path: { DeltaUtil.PathKey }, value: any): any
			return { Type = SET, Path = path, Value = value }
		end

		-- Nothing is sent before the client has a baseline
		do
			local state = ReplicationState.new()
			state:MarkDirty("Inventory", { "Sword" })

			t.Check("dirty data waits for the first snapshot request", not state:HasPending())
			t.Check("no message is built before the first snapshot request", state:BuildMessage() == nil)
		end

		-- A snapshot carries everything marked so far
		do
			local state = ReplicationState.new()
			state:MarkDirty("Inventory", { "Sword" })
			state:MarkDirty("Equipment", { Slot = "Sword" })
			state:RequestSnapshot()

			t.Check("a snapshot request is pending", state:HasPending())

			local snapshot: any = state:BuildMessage()
			t.Equal("the snapshot carries every marked key", snapshot, {
				Type = "Snapshot",
				Sequence = 1,
				Data = { Inventory = { "Sword" }, Equipment = { Slot = "Sword" } },
			})
			t.Check("nothing is pending after the snapshot", not state:HasPending())
			t.Check("a snapshot is only built once", state:BuildMessage() == nil)
		end

		-- A snapshot with nothing marked is still sent: the client asked for its baseline
		do
			local state = ReplicationState.new()
			state:RequestSnapshot()

			local snapshot: any = state:BuildMessage()
			t.Equal("an empty snapshot is still answered", snapshot, { Type = "Snapshot", Sequence = 1, Data = {} })
		end

		-- Deltas, coalescing, and in-place changes
		do
			local state = ReplicationState.new()
			local inventory = { "Sword", "Potion" }
			state:MarkDirty("Inventory", inventory)
			state:RequestSnapshot()
			state:BuildMessage()

			-- An in-place change is found by diffing against the private mirror.
			inventory[2] = "Bow"
			state:MarkDirty("Inventory", inventory)
			t.Check("a marked key is pending once the client is ready", state:HasPending())

			local delta: any = state:BuildMessage()
			t.Equal("an in-place change becomes one small Set", delta, {
				Type = "Delta",
				Sequence = 2,
				Changes = { setChange({ "Inventory", 2 }, "Bow") },
			})
			t.Check("nothing is pending after the delta", not state:HasPending())

			-- Several changes in one interval collapse into one message, latest value wins.
			inventory[1] = "Intermediate"
			state:MarkDirty("Inventory", inventory)
			inventory[1] = "Axe"
			state:MarkDirty("Inventory", inventory)
			state:MarkDirty("Stats", { Level = 2 })

			local coalesced: any = state:BuildMessage()
			t.Equal("changes in one interval become one message with the latest values", coalesced, {
				Type = "Delta",
				Sequence = 3,
				Changes = {
					setChange({ "Inventory", 1 }, "Axe"),
					setChange({ "Stats" }, { Level = 2 }),
				},
			})

			-- Marked but unchanged: nothing is sent and no sequence number is used.
			state:MarkDirty("Inventory", inventory)
			t.Check("a marked but unchanged value sends nothing", state:BuildMessage() == nil)

			inventory[1] = "Spear"
			state:MarkDirty("Inventory", inventory)
			local next: any = state:BuildMessage()
			t.Equal("a skipped no-change leaves no sequence gap", next.Sequence, 4)

			-- Changing without marking is the developer's contract: nothing is sent.
			inventory[1] = "Unmarked"
			t.Check("an unmarked change is not detected", not state:HasPending())
			t.Check("an unmarked change builds no message", state:BuildMessage() == nil)
		end

		-- A later snapshot replaces the baseline
		do
			local state = ReplicationState.new()
			local inventory = { "Sword" }
			state:MarkDirty("Inventory", inventory)
			state:RequestSnapshot()
			state:BuildMessage()

			inventory[1] = "Bow"
			state:MarkDirty("Inventory", inventory)
			state:RequestSnapshot()

			local resync: any = state:BuildMessage()
			t.Equal("a resync carries the latest values", resync.Data, { Inventory = { "Bow" } })
			t.Equal("a resync continues the sequence", resync.Sequence, 2)
			t.Check("a resync consumes the dirty flags", not state:HasPending())

			resync.Data.Inventory[1] = "Hacked"
			t.Equal("a snapshot is a copy of the live data", inventory[1], "Bow")
		end

		-- A table the diff cannot read is dropped, and the state recovers
		do
			local state = ReplicationState.new()
			state:RequestSnapshot()
			state:BuildMessage()

			state:MarkDirty("Broken", { [true :: any] = 1 })
			t.Check("BuildMessage throws for a table with a boolean key", not pcall(function()
				state:BuildMessage()
			end))
			t.Check("the bad value is not retried every tick", not state:HasPending())

			state:MarkDirty("Broken", { Fine = 1 })
			local recovered: any = state:BuildMessage()
			t.Equal("the state recovers once valid data is marked", recovered, {
				Type = "Delta",
				Sequence = 2,
				Changes = { { Type = SET, Path = { "Broken" }, Value = { Fine = 1 } } },
			})
		end

		-- Argument checks
		do
			local state = ReplicationState.new()
			t.Check("MarkDirty asserts on an empty key", not pcall(function()
				state:MarkDirty("", {})
			end))
			t.Check("MarkDirty asserts on a non-table value", not pcall(function()
				state:MarkDirty("Inventory", 5 :: any)
			end))
		end

		-- Other values that cannot be replicated, and a bad key must not hold back good ones
		do
			local cyclic: any = {}
			cyclic.Self = cyclic

			local cases: { { Name: string, Value: { [any]: any } } } = {
				{ Name = "a function", Value = { Callback = function() end } },
				{ Name = "NaN", Value = { Number = 0 / 0 } },
				{ Name = "infinity", Value = { Number = math.huge } },
				{ Name = "a cycle", Value = cyclic },
				{ Name = "a sparse array", Value = { [1] = "a", [3] = "c" } :: any },
				{ Name = "a zero-based array", Value = { [0] = "a" } :: any },
				{ Name = "mixed number and string keys", Value = { "a", Name = "b" } :: any },
			}

			for _, case in cases do
				local caseState = ReplicationState.new()
				caseState:RequestSnapshot()
				caseState:BuildMessage()

				caseState:MarkDirty("Bad", case.Value)
				t.Check("a table containing " .. case.Name .. " is refused", not pcall(function()
					caseState:BuildMessage()
				end))
			end

			local state = ReplicationState.new()
			state:RequestSnapshot()
			state:BuildMessage()

			state:MarkDirty("Broken", { [true :: any] = 1 })
			state:MarkDirty("Good", { Level = 2 })

			t.Check("a bad key makes BuildMessage throw", not pcall(function()
				state:BuildMessage()
			end))
			t.Check("a good key marked alongside it is still pending", state:HasPending())

			local goodDelta: any = state:BuildMessage()
			t.Equal("the good key goes out on the next tick", goodDelta, {
				Type = "Delta",
				Sequence = 2,
				Changes = { setChange({ "Good" }, { Level = 2 }) },
			})
		end

		-- Legitimate shapes still replicate
		do
			local state = ReplicationState.new()
			state:MarkDirty("Inventory", {
				Slots = { { Id = "Sword", Count = 1 }, { Id = "Potion", Count = 3 } },
				Owned = { ["12345"] = true, ["67890"] = true },
				Empty = {},
			})
			state:RequestSnapshot()

			t.Check(
				"arrays of dictionaries and string-keyed ids are accepted",
				pcall(function()
					state:BuildMessage()
				end)
			)
		end

		-- A snapshot leaves out data that cannot be replicated
		do
			local state = ReplicationState.new()
			state:MarkDirty("Broken", { [true :: any] = 1 })
			state:MarkDirty("Good", { Level = 1 })
			state:RequestSnapshot()

			t.Check("a snapshot containing a bad key throws", not pcall(function()
				state:BuildMessage()
			end))
			t.Check("the snapshot request is still pending", state:HasPending())

			local snapshot: any = state:BuildMessage()
			t.Equal("the retried snapshot leaves the bad key out", snapshot, {
				Type = "Snapshot",
				Sequence = 1,
				Data = { Good = { Level = 1 } },
			})
		end
	end

	-- ReplicationService
	do
		local alice = ({ Name = "Alice" } :: any) :: Player
		local bob = ({ Name = "Bob" } :: any) :: Player

		-- A huge interval keeps the background loop quiet: tests call Flush themselves.
		local function newFixture(options: ReplicationService.Options?)
			local adapter = MockRemoteAdapter.new()
			local resolved: ReplicationService.Options = options or {}
			resolved.IntervalSeconds = 1_000_000

			local service = ReplicationService.new(adapter, resolved)
			service:Start()
			return service, adapter
		end

		local function addLoaded(service: ReplicationService.ReplicationService, player: Player)
			service:AddPlayer(player)
			service:SetLoaded(player)
		end
		-- Argument checks
		do
			t.Check("new asserts on a non-table adapter", not pcall(function()
				ReplicationService.new("nope" :: any)
			end))
			t.Check("new asserts on a non-positive interval", not pcall(function()
				ReplicationService.new(MockRemoteAdapter.new(), { IntervalSeconds = 0 })
			end))
			t.Check("new asserts on a non-function OnRejected", not pcall(function()
				ReplicationService.new(MockRemoteAdapter.new(), { OnRejected = "nope" :: any })
			end))

			local service = newFixture()
			addLoaded(service, alice)

			t.Check("Start twice asserts", not pcall(function()
				service:Start()
			end))
			t.Check("AddPlayer asserts on nil", not pcall(function()
				service:AddPlayer(nil :: any)
			end))
			t.Check("Replicate asserts on an empty key", not pcall(function()
				service:Replicate(alice, "", {})
			end))
			service:Stop()
		end

		-- The basic flow: baseline first, then deltas, then silence
		do
			local service, adapter = newFixture()
			addLoaded(service, alice)
			service:Replicate(alice, "Inventory", { "Sword" })

			service:Flush()
			t.Equal("nothing is sent before the client asks for a snapshot", #adapter:ReplicatedTo(alice), 0)

			adapter:SimulateSnapshotRequest(alice)
			service:Flush()
			t.Equal("a requested snapshot is sent on the next flush", adapter:ReplicatedTo(alice), {
				{ Type = "Snapshot", Sequence = 1, Data = { Inventory = { "Sword" } } },
			})

			service:Replicate(alice, "Inventory", { "Sword", "Bow" })
			service:Flush()

			local sent = adapter:ReplicatedTo(alice)
			t.Equal("a change is sent as a second message", #sent, 2)
			t.Equal("the second message is a delta", sent[2].Type, "Delta")
			t.Equal("the delta carries the next sequence", sent[2].Sequence, 2)

			service:Flush()
			service:Flush()
			t.Equal("flushing with nothing dirty sends nothing", #adapter:ReplicatedTo(alice), 2)

			service:Stop()
		end

		-- Players never see each other's data
		do
			local service, adapter = newFixture()
			addLoaded(service, alice)
			addLoaded(service, bob)
			service:Replicate(alice, "Inventory", { "Sword" })
			service:Replicate(bob, "Inventory", { "Axe" })
			adapter:SimulateSnapshotRequest(alice)
			adapter:SimulateSnapshotRequest(bob)
			service:Flush()

			t.Equal("the first player gets only their own data", adapter:ReplicatedTo(alice), {
				{ Type = "Snapshot", Sequence = 1, Data = { Inventory = { "Sword" } } },
			})
			t.Equal("the second player gets only their own data", adapter:ReplicatedTo(bob), {
				{ Type = "Snapshot", Sequence = 1, Data = { Inventory = { "Axe" } } },
			})
			service:Stop()
		end

		-- Unknown players are ignored and reported
		do
			local rejections: { string } = {}
			local service, adapter = newFixture({
				OnRejected = function(_player: Player, reason: ReplicationService.RejectionReason)
					table.insert(rejections, reason)
				end,
			})

			adapter:SimulateSnapshotRequest(alice)
			t.Equal("a snapshot request from an unknown player is rejected", rejections, { "UnknownPlayer" })

			service:Replicate(alice, "Inventory", { "Sword" })
			addLoaded(service, alice)
			service:Flush()
			t.Equal("Replicate for an unknown player was ignored", #adapter:ReplicatedTo(alice), 0)
			service:Stop()
		end

		-- Snapshot requests are rate-limited
		do
			local clock = 0
			local rejections: { string } = {}
			local service, adapter = newFixture({
				Now = function()
					return clock
				end,
				OnRejected = function(_player: Player, reason: ReplicationService.RejectionReason)
					table.insert(rejections, reason)
				end,
			})
			addLoaded(service, alice)

			for _ = 1, DataSchema.Replication.SnapshotRequestCapacity + 2 do
				adapter:SimulateSnapshotRequest(alice)
			end
			t.Equal(
				"requests past the capacity are rejected",
				rejections,
				{ "SnapshotRateLimited", "SnapshotRateLimited" }
			)

			clock += 1 / DataSchema.Replication.SnapshotRequestRefillPerSecond
			adapter:SimulateSnapshotRequest(alice)
			t.Equal("a request is accepted again once a token has refilled", #rejections, 2)
			service:Stop()
		end

		-- Removing a player forgets them
		do
			local rejections: { string } = {}
			local service, adapter = newFixture({
				OnRejected = function(_player: Player, reason: ReplicationService.RejectionReason)
					table.insert(rejections, reason)
				end,
			})
			addLoaded(service, alice)
			service:Replicate(alice, "Inventory", { "Sword" })
			adapter:SimulateSnapshotRequest(alice)
			service:Flush()

			service:RemovePlayer(alice)
			service:Replicate(alice, "Inventory", { "Sword", "Bow" })
			service:Flush()
			t.Equal("a removed player is sent nothing more", #adapter:ReplicatedTo(alice), 1)

			adapter:SimulateSnapshotRequest(alice)
			t.Equal("a removed player's snapshot request is rejected", rejections, { "UnknownPlayer" })

			addLoaded(service, alice)
			service:Flush()
			t.Equal("a re-added player starts with no baseline", #adapter:ReplicatedTo(alice), 1)
			service:Stop()
		end

		-- Unreplicable data never stops Flush
		do
			local service, adapter = newFixture()
			addLoaded(service, alice)
			service:Replicate(alice, "Broken", { [true :: any] = 1 })
			service:Replicate(alice, "Good", { Level = 1 })
			adapter:SimulateSnapshotRequest(alice)

			t.Check(
				"Flush survives unreplicable data",
				pcall(function()
					service:Flush()
				end)
			)
			t.Equal("nothing is sent while the snapshot is being rejected", #adapter:ReplicatedTo(alice), 0)

			service:Flush()
			t.Equal("the retried snapshot leaves the bad key out", adapter:ReplicatedTo(alice), {
				{ Type = "Snapshot", Sequence = 1, Data = { Good = { Level = 1 } } },
			})
			service:Stop()
		end

		-- A failed send is followed by a fresh baseline
		do
			local service, adapter = newFixture()
			addLoaded(service, alice)
			service:Replicate(alice, "Inventory", { "Sword" })
			adapter:SimulateSnapshotRequest(alice)
			service:Flush()

			-- Instance field shadows the class method, so clearing it restores the real one.
			local loose: any = adapter
			loose.SendReplication = function()
				error("simulated send failure")
			end

			service:Replicate(alice, "Inventory", { "Sword", "Bow" })
			t.Check(
				"a failed send does not throw out of Flush",
				pcall(function()
					service:Flush()
				end)
			)

			loose.SendReplication = nil
			service:Flush()

			local sent = adapter:ReplicatedTo(alice)
			t.Equal("the lost delta is replaced by a fresh snapshot", sent[2], {
				Type = "Snapshot",
				Sequence = 3,
				Data = { Inventory = { "Sword", "Bow" } },
			})
			service:Stop()
		end

				-- Nothing is sent until the player has finished loading
		do
			local service, adapter = newFixture()
			service:AddPlayer(alice)
			service:Replicate(alice, "Inventory", { "Sword" })
			adapter:SimulateSnapshotRequest(alice)

			service:Flush()
			t.Equal("nothing is sent while the player is still loading", #adapter:ReplicatedTo(alice), 0)

			-- Changes made while loading are coalesced into the first snapshot.
			service:Replicate(alice, "Inventory", { "Sword", "Bow" })
			service:SetLoaded(alice)
			service:Flush()
			t.Equal("the first snapshot is the complete one", adapter:ReplicatedTo(alice), {
				{ Type = "Snapshot", Sequence = 1, Data = { Inventory = { "Sword", "Bow" } } },
			})

			t.Check("SetLoaded ignores a player who is not registered", pcall(function()
				service:SetLoaded(bob)
			end))
			t.Check("SetLoaded asserts on nil", not pcall(function()
				service:SetLoaded(nil :: any)
			end))
			service:Stop()
		end

		-- A removed and re-added player is held again
		do
			local service, adapter = newFixture()
			addLoaded(service, alice)
			service:RemovePlayer(alice)

			service:AddPlayer(alice)
			service:Replicate(alice, "Inventory", { "Sword" })
			adapter:SimulateSnapshotRequest(alice)
			service:Flush()

			t.Equal("a re-added player is held until loaded again", #adapter:ReplicatedTo(alice), 0)
			service:Stop()
		end
	end

	return t.Summary()
end
