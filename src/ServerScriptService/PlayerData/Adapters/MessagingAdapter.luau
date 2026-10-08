--!strict
--@Splay

local HttpService = game:GetService("HttpService")
local MessagingService = game:GetService("MessagingService")
local ServerScriptService = game:GetService("ServerScriptService")

local DataSchema = require(ServerScriptService.PlayerData.Config.DataSchema)

export type Adapter = {
	Publish: (self: Adapter, topic: string, payload: any) -> boolean,
	Subscribe: (self: Adapter, topic: string, callback: (payload: any) -> ()) -> (() -> ())?,
}

local MessagingAdapter = {}
MessagingAdapter.__index = MessagingAdapter

function MessagingAdapter.AssertValidTopic(topic: any, methodName: string)
	assert(type(topic) == "string" and topic ~= "", ("%s: topic must be a non-empty string"):format(methodName))
	assert(
		#topic <= DataSchema.Messaging.MaxTopicLength,
		("%s: topic must be at most %d characters"):format(methodName, DataSchema.Messaging.MaxTopicLength)
	)
end

function MessagingAdapter.Encode(payload: any): (string?, string?)
	local encodeOk, encoded = pcall(function(): any
		return HttpService:JSONEncode(payload)
	end)

	if not encodeOk then
		return nil, "the payload cannot be encoded as JSON"
	end

	local text = encoded :: string
	local limit = DataSchema.Messaging.MaxPayloadBytes
	if #text > limit then
		return nil, ("the payload is %d bytes and the limit is %d"):format(#text, limit)
	end

	return text, nil
end

function MessagingAdapter.new(): Adapter
	return (setmetatable({}, MessagingAdapter) :: any) :: Adapter
end

function MessagingAdapter.Publish(_self: any, topic: string, payload: any): boolean
	MessagingAdapter.AssertValidTopic(topic, "MessagingAdapter:Publish")

	local encoded, reason = MessagingAdapter.Encode(payload)
	if encoded == nil then
		warn(("MessagingAdapter: not publishing to %s: %s"):format(topic, tostring(reason)))
		return false
	end

	local ok, publishError = pcall(function(): any
		MessagingService:PublishAsync(topic, payload)
		return nil
	end)

	if not ok then
		warn(("MessagingAdapter: publish to %s failed: %s"):format(topic, tostring(publishError)))
		return false
	end

	return true
end

function MessagingAdapter.Subscribe(_self: any, topic: string, callback: (payload: any) -> ()): (() -> ())?
	MessagingAdapter.AssertValidTopic(topic, "MessagingAdapter:Subscribe")
	assert(type(callback) == "function", "MessagingAdapter:Subscribe: callback must be a function")

	local ok, connectionOrError = pcall(function(): any
		return MessagingService:SubscribeAsync(topic, function(message)
			-- MessagingService wraps what was sent; callers only want the payload.
			callback(message.Data)
		end)
	end)

	if not ok then
		warn(("MessagingAdapter: subscribe to %s failed: %s"):format(topic, tostring(connectionOrError)))
		return nil
	end

	local connection = connectionOrError :: RBXScriptConnection
	return function()
		connection:Disconnect()
	end
end

return MessagingAdapter
