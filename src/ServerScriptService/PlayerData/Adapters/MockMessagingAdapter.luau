--!strict
--@Splay

--[[
	MockMessagingAdapter

	An in-memory network for tests. Several "servers" can share one instance, the way they
	share one MockAdapter datastore.

	Nothing is delivered until the test calls Deliver(). Real messaging is asynchronous, and
	delivering on demand keeps tests deterministic: no real time, no flakiness.

	Failure injection covers what MessagingService can really do to us: refuse a publish,
	lose a message after accepting it, deliver one twice, or be unavailable altogether.
]]

local HttpService = game:GetService("HttpService")
local ServerScriptService = game:GetService("ServerScriptService")

local MessagingAdapter = require(ServerScriptService.PlayerData.Adapters.MessagingAdapter)

export type MockMessagingAdapter = MessagingAdapter.Adapter & {
	SetAvailable: (self: MockMessagingAdapter, available: boolean) -> (),
	FailNextPublish: (self: MockMessagingAdapter, count: number) -> (),
	DropNext: (self: MockMessagingAdapter, count: number) -> (),
	DuplicateNext: (self: MockMessagingAdapter, count: number) -> (),
	Deliver: (self: MockMessagingAdapter) -> number,
	PendingCount: (self: MockMessagingAdapter) -> number,
	PublishedCount: (self: MockMessagingAdapter) -> number,
}

type Subscriber = {
	Topic: string,
	Callback: (payload: any) -> (),
	Active: boolean,
}

type QueuedMessage = {
	Topic: string,
	Encoded: string,
}

local MockMessagingAdapter = {}
MockMessagingAdapter.__index = MockMessagingAdapter

local function assertCount(count: any, methodName: string)
	assert(
		type(count) == "number" and count >= 0 and count == math.floor(count),
		("MockMessagingAdapter:%s: count must be a whole number of at least 0"):format(methodName)
	)
end

function MockMessagingAdapter.new(): MockMessagingAdapter
	local self = setmetatable({
		_available = true,
		_publishFailures = 0,
		_drops = 0,
		_duplicates = 0,
		_publishedCount = 0,
		_subscribers = {} :: { Subscriber },
		_queue = {} :: { QueuedMessage },
	}, MockMessagingAdapter)

	return (self :: any) :: MockMessagingAdapter
end

function MockMessagingAdapter.SetAvailable(self: any, available: boolean)
	assert(type(available) == "boolean", "MockMessagingAdapter:SetAvailable: available must be a boolean")
	self._available = available
end

function MockMessagingAdapter.FailNextPublish(self: any, count: number)
	assertCount(count, "FailNextPublish")
	self._publishFailures = count
end

function MockMessagingAdapter.DropNext(self: any, count: number)
	assertCount(count, "DropNext")
	self._drops = count
end

function MockMessagingAdapter.DuplicateNext(self: any, count: number)
	assertCount(count, "DuplicateNext")
	self._duplicates = count
end

function MockMessagingAdapter.PendingCount(self: any): number
	return #self._queue
end

function MockMessagingAdapter.PublishedCount(self: any): number
	return self._publishedCount
end

function MockMessagingAdapter.Publish(self: any, topic: string, payload: any): boolean
	MessagingAdapter.AssertValidTopic(topic, "MockMessagingAdapter:Publish")

	if not self._available then
		return false
	end

	if self._publishFailures > 0 then
		self._publishFailures -= 1
		return false
	end

	local encoded = MessagingAdapter.Encode(payload)
	if encoded == nil then
		return false
	end

	self._publishedCount += 1

	if self._drops > 0 then
		self._drops -= 1
		return true
	end

	table.insert(self._queue, { Topic = topic, Encoded = encoded })

	if self._duplicates > 0 then
		self._duplicates -= 1
		table.insert(self._queue, { Topic = topic, Encoded = encoded })
	end

	return true
end

function MockMessagingAdapter.Subscribe(self: any, topic: string, callback: (payload: any) -> ()): (() -> ())?
	MessagingAdapter.AssertValidTopic(topic, "MockMessagingAdapter:Subscribe")
	assert(type(callback) == "function", "MockMessagingAdapter:Subscribe: callback must be a function")

	if not self._available then
		return nil
	end

	local subscriber: Subscriber = { Topic = topic, Callback = callback, Active = true }
	table.insert(self._subscribers, subscriber)

	return function()
		subscriber.Active = false
	end
end

function MockMessagingAdapter.Deliver(self: any): number
	local messages: { QueuedMessage } = self._queue
	self._queue = {}

	local subscribers: { Subscriber } = table.clone(self._subscribers)

	for _, message in messages do
		for _, subscriber in subscribers do
			if subscriber.Active and subscriber.Topic == message.Topic then
				local payload = HttpService:JSONDecode(message.Encoded)

				task.spawn(function()
					xpcall(subscriber.Callback, function(callbackError: any)
						warn(("MockMessagingAdapter: a subscriber errored: %s"):format(tostring(callbackError)))
					end, payload)
				end)
			end
		end
	end

	return #messages
end

return MockMessagingAdapter