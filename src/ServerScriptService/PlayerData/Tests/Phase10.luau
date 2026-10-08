--!strict
--@Splay

--[[
	Phase 10 tests: MessagingAdapter helpers and MockMessagingAdapter.

	Delivery is manual (Deliver), so nothing here uses real time.
	It returns true when every check passed.
]]

local ServerScriptService = game:GetService("ServerScriptService")

local PlayerData = ServerScriptService.PlayerData

local DataSchema = require(PlayerData.Config.DataSchema)
local Harness = require(PlayerData.Tests.Harness)
local MessagingAdapter = require(PlayerData.Adapters.MessagingAdapter)
local MockMessagingAdapter = require(PlayerData.Adapters.MockMessagingAdapter)
local ReleaseCoordinator = require(PlayerData.Utils.ReleaseCoordinator)

local TOPIC = "server-a"
local BLOCKER_SERVER_ID = "job-blocker"
local JOINER_SERVER_ID = "job-joiner"
local BLOCKER_TOPIC = "Release-" .. BLOCKER_SERVER_ID

local function newRecorder(): ({ any }, (payload: any) -> ())
	local received: { any } = {}

	return received, function(payload: any)
		table.insert(received, payload)
	end
end

local function newServer(
	network: MockMessagingAdapter.MockMessagingAdapter,
	serverId: string
): (ReleaseCoordinator.ReleaseCoordinator, { ReleaseCoordinator.ReleaseRequest })
	local received: { ReleaseCoordinator.ReleaseRequest } = {}
	local coordinator = ReleaseCoordinator.new(network, serverId, function(request)
		table.insert(received, request)
	end)
	return coordinator, received
end

return function(): boolean
	local t = Harness.new("Phase10")

	-- Basic delivery

	do
		local network = MockMessagingAdapter.new()
		local received, record = newRecorder()
		network:Subscribe(TOPIC, record)

		t.Check("Publish succeeds", network:Publish(TOPIC, { UserId = 1 }))
		t.Equal("Nothing arrives before Deliver", #received, 0)
		t.Equal("The message is pending", network:PendingCount(), 1)

		t.Equal("Deliver reports how many messages it delivered", network:Deliver(), 1)
		t.Equal("The subscriber receives the payload", received, { { UserId = 1 } })
		t.Equal("Nothing is pending after delivery", network:PendingCount(), 0)
		t.Equal("PublishedCount counts the publish", network:PublishedCount(), 1)
	end

	-- Topics and subscribers

	do
		local network = MockMessagingAdapter.new()
		local receivedA, recordA = newRecorder()
		local receivedB, recordB = newRecorder()
		local receivedAgain, recordAgain = newRecorder()
		network:Subscribe("topic-a", recordA)
		network:Subscribe("topic-b", recordB)
		network:Subscribe("topic-a", recordAgain)

		network:Publish("topic-a", { Value = 1 })
		network:Deliver()

		t.Equal("A subscriber receives its own topic", receivedA, { { Value = 1 } })
		t.Equal("Another topic receives nothing", #receivedB, 0)
		t.Equal("Every subscriber on a topic receives the message", receivedAgain, { { Value = 1 } })
	end

	-- Unsubscribing

	do
		local network = MockMessagingAdapter.new()
		local received, record = newRecorder()
		local unsubscribe = network:Subscribe(TOPIC, record)

		t.Check("Subscribe returns an unsubscribe function", unsubscribe ~= nil)
		if unsubscribe then
			unsubscribe()
		end

		network:Publish(TOPIC, { Value = 1 })
		network:Deliver()
		t.Equal("An unsubscribed callback receives nothing", #received, 0)
	end

	-- Payloads are copies

	do
		local network = MockMessagingAdapter.new()
		local received, record = newRecorder()
		network:Subscribe(TOPIC, record)

		local payload = { UserId = 1 }
		network:Publish(TOPIC, payload)
		payload.UserId = 999
		network:Deliver()

		t.Equal("The payload is captured when published", received[1] and received[1].UserId, 1)
		t.Check("The receiver gets a different table from the sender", received[1] ~= payload)
	end

	-- Limits

	do
		local network = MockMessagingAdapter.new()
		local received, record = newRecorder()
		network:Subscribe(TOPIC, record)

		local tooBig = { Text = string.rep("x", DataSchema.Messaging.MaxPayloadBytes) }
		t.Check("A payload over the size limit is refused", not network:Publish(TOPIC, tooBig))
		t.Equal("A refused payload is not queued", network:PendingCount(), 0)

		local cyclic: any = {}
		cyclic.Self = cyclic
		t.Check("A payload that cannot be encoded is refused", not network:Publish(TOPIC, cyclic))

		network:Deliver()
		t.Equal("Nothing refused is ever delivered", #received, 0)
	end

	-- Shared helpers

	do
		local encoded = MessagingAdapter.Encode({ UserId = 1 })
		t.Check("Encode returns JSON text for a valid payload", type(encoded) == "string")

		local failedText, reason =
			MessagingAdapter.Encode({ Text = string.rep("x", DataSchema.Messaging.MaxPayloadBytes) })
		t.Check("Encode returns nil for an oversized payload", failedText == nil)
		t.Check("Encode explains why", type(reason) == "string")
	end

	-- Failure injection

	do
		local network = MockMessagingAdapter.new()
		local received, record = newRecorder()
		network:Subscribe(TOPIC, record)

		network:FailNextPublish(1)
		t.Check("FailNextPublish refuses the next publish", not network:Publish(TOPIC, { Value = 1 }))
		t.Check("Later publishes work again", network:Publish(TOPIC, { Value = 2 }))
		network:Deliver()
		t.Equal("Only the message that was accepted arrives", received, { { Value = 2 } })
	end

	do
		local network = MockMessagingAdapter.new()
		local received, record = newRecorder()
		network:Subscribe(TOPIC, record)

		network:DropNext(1)
		t.Check("A dropped message still looks published to the sender", network:Publish(TOPIC, { Value = 1 }))
		network:Deliver()
		t.Equal("A dropped message never arrives", #received, 0)
		t.Equal("A dropped message still counts as published", network:PublishedCount(), 1)

		network:Publish(TOPIC, { Value = 2 })
		network:Deliver()
		t.Equal("Messages after the drop arrive normally", received, { { Value = 2 } })
	end

	do
		local network = MockMessagingAdapter.new()
		local received, record = newRecorder()
		network:Subscribe(TOPIC, record)

		network:DuplicateNext(1)
		network:Publish(TOPIC, { Value = 1 })
		network:Deliver()
		t.Equal("DuplicateNext delivers the message twice", #received, 2)
	end

	-- Unavailable messaging

	do
		local network = MockMessagingAdapter.new()
		local _, record = newRecorder()

		network:SetAvailable(false)
		t.Check("Publish returns false when messaging is unavailable", not network:Publish(TOPIC, { Value = 1 }))
		t.Check("Subscribe returns nil when messaging is unavailable", network:Subscribe(TOPIC, record) == nil)

		network:SetAvailable(true)
		t.Check("Publish works again once messaging is back", network:Publish(TOPIC, { Value = 1 }))
		t.Check("Subscribe works again once messaging is back", network:Subscribe(TOPIC, record) ~= nil)
	end

	-- One failing subscriber does not stop the others

	do
		local network = MockMessagingAdapter.new()
		local received, record = newRecorder()
		network:Subscribe(TOPIC, function()
			error("simulated subscriber failure")
		end)
		network:Subscribe(TOPIC, record)

		network:Publish(TOPIC, { Value = 1 })
		network:Deliver()
		t.Equal("A throwing subscriber does not stop the others", #received, 1)
	end

	-- Argument validation

	do
		local network = MockMessagingAdapter.new()
		local _, record = newRecorder()

		t.Check("Publish asserts on an empty topic", not pcall(function()
			network:Publish("", {})
		end))
		t.Check("Publish asserts on a non-string topic", not pcall(function()
			network:Publish(1 :: any, {})
		end))
		t.Check("Publish asserts on a topic that is too long", not pcall(function()
			network:Publish(string.rep("t", DataSchema.Messaging.MaxTopicLength + 1), {})
		end))
		t.Check("Subscribe asserts on a non-function callback", not pcall(function()
			network:Subscribe(TOPIC, "nope" :: any)
		end))
		t.Check("Subscribe asserts on an empty topic", not pcall(function()
			network:Subscribe("", record)
		end))
		t.Check("FailNextPublish asserts on a negative count", not pcall(function()
			network:FailNextPublish(-1)
		end))
		t.Check("SetAvailable asserts on a non-boolean", not pcall(function()
			network:SetAvailable("yes" :: any)
		end))
	end


		-- ReleaseCoordinator: a request reaches the target server

	do
		local network = MockMessagingAdapter.new()
		local blocker, blockerReceived = newServer(network, BLOCKER_SERVER_ID)
		local joiner, joinerReceived = newServer(network, JOINER_SERVER_ID)

		t.Check("The blocking server starts", blocker:Start())
		t.Check("The joining server starts", joiner:Start())

		t.Check("A release request is accepted", joiner:RequestRelease(BLOCKER_SERVER_ID, { UserId = 1, SessionId = "session-A" }))
		t.Equal("Nothing arrives before Deliver", #blockerReceived, 0)

		network:Deliver()
		t.Equal("The blocking server receives the request", blockerReceived, { { UserId = 1, SessionId = "session-A" } })
		t.Equal("The requesting server receives nothing", #joinerReceived, 0)
	end

	-- ReleaseCoordinator: requests are best-effort

	do
		local network = MockMessagingAdapter.new()
		local blocker, blockerReceived = newServer(network, BLOCKER_SERVER_ID)
		local joiner = newServer(network, JOINER_SERVER_ID)
		blocker:Start()

		network:DropNext(1)
		t.Check("A dropped request still looks sent", joiner:RequestRelease(BLOCKER_SERVER_ID, { UserId = 1, SessionId = "session-A" }))
		network:Deliver()
		t.Equal("A dropped request never arrives", #blockerReceived, 0)

		network:FailNextPublish(1)
		t.Check("A refused publish returns false", not joiner:RequestRelease(BLOCKER_SERVER_ID, { UserId = 1, SessionId = "session-A" }))
		t.Equal("A refused publish queues nothing", network:PendingCount(), 0)

		joiner:RequestRelease(BLOCKER_SERVER_ID, { UserId = 1, SessionId = "session-A" })
		network:Deliver()
		t.Equal("A later request arrives normally", #blockerReceived, 1)
	end

	-- ReleaseCoordinator: duplicates are passed on, so the callback must be idempotent

	do
		local network = MockMessagingAdapter.new()
		local blocker, blockerReceived = newServer(network, BLOCKER_SERVER_ID)
		local joiner = newServer(network, JOINER_SERVER_ID)
		blocker:Start()

		network:DuplicateNext(1)
		joiner:RequestRelease(BLOCKER_SERVER_ID, { UserId = 1, SessionId = "session-A" })
		network:Deliver()
		t.Equal("A duplicated message reaches the callback twice", #blockerReceived, 2)
	end

	-- ReleaseCoordinator: malformed payloads are ignored

	do
		local network = MockMessagingAdapter.new()
		local blocker, blockerReceived = newServer(network, BLOCKER_SERVER_ID)
		blocker:Start()

		network:Publish(BLOCKER_TOPIC, "just text")
		network:Publish(BLOCKER_TOPIC, { SessionId = "session-A" })
		network:Publish(BLOCKER_TOPIC, { UserId = "1", SessionId = "session-A" })
		network:Publish(BLOCKER_TOPIC, { UserId = 1 })
		network:Publish(BLOCKER_TOPIC, { UserId = 1, SessionId = "" })
		network:Deliver()
		t.Equal("Malformed payloads never reach the callback", #blockerReceived, 0)

		network:Publish(BLOCKER_TOPIC, { UserId = 1, SessionId = "session-A", Extra = "ignored" })
		network:Deliver()
		t.Equal(
			"Extra fields are stripped before the callback",
			blockerReceived,
			{ { UserId = 1, SessionId = "session-A" } }
		)
	end

	-- ReleaseCoordinator: start and stop

	do
		local network = MockMessagingAdapter.new()
		local blocker, blockerReceived = newServer(network, BLOCKER_SERVER_ID)
		local joiner = newServer(network, JOINER_SERVER_ID)

		network:SetAvailable(false)
		t.Check("Start returns false when messaging is unavailable", not blocker:Start())
		network:SetAvailable(true)
		t.Check("Start can be retried after a failed subscribe", blocker:Start())
		t.Check("Starting twice asserts", not pcall(function()
			blocker:Start()
		end))

		blocker:Stop()
		joiner:RequestRelease(BLOCKER_SERVER_ID, { UserId = 1, SessionId = "session-A" })
		network:Deliver()
		t.Equal("A stopped server receives nothing", #blockerReceived, 0)

		t.Check("Stop twice is safe", pcall(function()
			blocker:Stop()
		end))
		t.Check("Stop before Start is safe", pcall(function()
			joiner:Stop()
		end))
	end

	-- ReleaseCoordinator: argument validation
	do
		local network = MockMessagingAdapter.new()
		local joiner = newServer(network, JOINER_SERVER_ID)
		local validRequest = { UserId = 1, SessionId = "session-A" }

		t.Check("new asserts on a missing messaging adapter", not pcall(function()
			ReleaseCoordinator.new(nil :: any, JOINER_SERVER_ID, function() end)
		end))
		t.Check("new asserts on an empty serverId", not pcall(function()
			ReleaseCoordinator.new(network, "", function() end)
		end))
		t.Check("new asserts on a non-function callback", not pcall(function()
			ReleaseCoordinator.new(network, JOINER_SERVER_ID, "nope" :: any)
		end))
		t.Check("RequestRelease asserts on an empty blocker id", not pcall(function()
			joiner:RequestRelease("", validRequest)
		end))
		t.Check("RequestRelease asserts when a server asks itself", not pcall(function()
			joiner:RequestRelease(JOINER_SERVER_ID, validRequest)
		end))
		t.Check("RequestRelease asserts on a non-numeric UserId", not pcall(function()
			joiner:RequestRelease(BLOCKER_SERVER_ID, { UserId = "1" :: any, SessionId = "session-A" })
		end))
		t.Check("RequestRelease asserts on an empty SessionId", not pcall(function()
			joiner:RequestRelease(BLOCKER_SERVER_ID, { UserId = 1, SessionId = "" })
		end))
	end

	return t.Summary()
end
