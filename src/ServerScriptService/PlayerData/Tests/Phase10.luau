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

local TOPIC = "server-a"

local function newRecorder(): ({ any }, (payload: any) -> ())
	local received: { any } = {}

	return received, function(payload: any)
		table.insert(received, payload)
	end
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

	return t.Summary()
end
