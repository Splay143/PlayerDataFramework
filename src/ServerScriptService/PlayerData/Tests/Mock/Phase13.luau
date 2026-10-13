--!strict
--@Splay

--[[
	Phase 13 tests: RequestService.

	Uses MockRemoteAdapter and fake players, with a fake clock for the rate limiter.
	A few handlers throw on purpose, so "errored" warnings in the output are expected.

	It returns true when every check passed.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local PlayerData = ServerScriptService.PlayerData

local DataSchema = require(PlayerData.Config.DataSchema)
local Harness = require(PlayerData.Tests.Harness)
local MockRemoteAdapter = require(PlayerData.Adapters.MockRemoteAdapter)
local Protocol = require(ReplicatedStorage.PlayerDataShared.Shared.Protocol)
local RequestService = require(PlayerData.Networking.RequestService)

local alice = ({ Name = "Alice" } :: any) :: Player
local bob = ({ Name = "Bob" } :: any) :: Player

local function okHandler(): RequestService.RequestHandler
	return function(_player: Player, _payload: { [any]: any }): RequestService.Result
		return { Success = true }
	end
end

local function newFixture()
	local adapter = MockRemoteAdapter.new()
	local loaded: { [Player]: boolean } = { [alice] = true, [bob] = true }
	local rejections: { { Route: any, Reason: RequestService.FailureReason } } = {}
	local clock = 0

	local service = RequestService.new(adapter, {
		IsLoaded = function(player: Player): boolean
			return loaded[player] == true
		end,
		Now = function(): number
			return clock
		end,
		OnRejected = function(_player: Player, route: any, reason: RequestService.FailureReason)
			table.insert(rejections, { Route = route, Reason = reason })
		end,
	})
	service:Start()

	return {
		Service = service,
		Adapter = adapter,
		Loaded = loaded,
		Rejections = rejections,
		Advance = function(seconds: number)
			clock += seconds
		end,
	}
end

local function lastReason(
	rejections: { { Route: any, Reason: RequestService.FailureReason } }
): RequestService.FailureReason?
	local last = rejections[#rejections]
	return if last then last.Reason else nil
end

return function(): boolean
	local t = Harness.new("Phase13")

	local maxRoute = Protocol.Limits.MaxRouteNameLength
	local maxString = Protocol.Limits.MaxStringLength

	-- Argument checks
	do
		local adapter = MockRemoteAdapter.new()
		local function isLoaded(_player: Player): boolean
			return true
		end

		t.Check("new asserts on a non-table adapter", not pcall(function()
			RequestService.new("nope" :: any, { IsLoaded = isLoaded })
		end))
		t.Check("new asserts on missing options", not pcall(function()
			RequestService.new(adapter, nil :: any)
		end))
		t.Check("new asserts when IsLoaded is missing", not pcall(function()
			RequestService.new(adapter, {} :: any)
		end))
		t.Check("new asserts on a non-function OnRejected", not pcall(function()
			RequestService.new(adapter, { IsLoaded = isLoaded, OnRejected = "nope" :: any })
		end))

		local fixture = newFixture()
		t.Check("Start twice asserts", not pcall(function()
			fixture.Service:Start()
		end))
		t.Check("RegisterRequest asserts on an empty route", not pcall(function()
			fixture.Service:RegisterRequest("", okHandler())
		end))
		t.Check("RegisterRequest asserts on a non-function handler", not pcall(function()
			fixture.Service:RegisterRequest("Ping", "nope" :: any)
		end))
		t.Check("RegisterSend asserts on an over-long route", not pcall(function()
			fixture.Service:RegisterSend(string.rep("a", maxRoute + 1), function() end)
		end))

		fixture.Service:RegisterRequest("Ping", okHandler())
		t.Check("RegisterRequest asserts on a duplicate route", not pcall(function()
			fixture.Service:RegisterRequest("Ping", okHandler())
		end))
		t.Check(
			"the same route name may also be registered for Send",
			pcall(function()
				fixture.Service:RegisterSend("Ping", function() end)
			end)
		)
		t.Check("RemovePlayer asserts on nil", not pcall(function()
			fixture.Service:RemovePlayer(nil :: any)
		end))
		fixture.Service:Stop()
	end

	-- A valid request
	do
		local fixture = newFixture()
		local seenPlayer: any = nil
		local seenPayload: any = nil

		fixture.Service:RegisterRequest(
			"EquipItem",
			function(player: Player, payload: { [any]: any }): RequestService.Result
				seenPlayer = player
				seenPayload = payload
				return { Success = true, Data = { ItemId = payload.ItemId } }
			end
		)

		local result = fixture.Adapter:SimulateRequest(alice, "EquipItem", { ItemId = "AK47" })
		t.Equal("a valid request returns the handler's result", result, { Success = true, Data = { ItemId = "AK47" } })
		t.Check("the handler sees the player", seenPlayer == alice)
		t.Equal("the handler sees the payload", seenPayload, { ItemId = "AK47" })

		fixture.Adapter:SimulateRequest(alice, "EquipItem", nil)
		t.Equal("a missing payload becomes an empty table", seenPayload, {})
		t.Equal("nothing was rejected", #fixture.Rejections, 0)
		fixture.Service:Stop()
	end

	-- Refused before the handler: loaded check and route check
	do
		local fixture = newFixture()
		local calls = 0
		fixture.Service:RegisterRequest("Ping", function(): RequestService.Result
			calls += 1
			return { Success = true }
		end)

		fixture.Loaded[alice] = false
		t.Equal(
			"a player whose data is not loaded is refused",
			fixture.Adapter:SimulateRequest(alice, "Ping", {}),
			{ Success = false, Reason = "NotLoaded" }
		)
		t.Equal("the refusal is reported", lastReason(fixture.Rejections), "NotLoaded")
		fixture.Loaded[alice] = true

		local badRoutes: { any } = { "Missing", "", string.rep("a", maxRoute + 1), 5, true }
		for _, badRoute in badRoutes do
			t.Equal(
				"an unknown or malformed route is refused",
				fixture.Adapter:SimulateRequest(alice, badRoute, {}),
				{ Success = false, Reason = "NoHandler" }
			)
		end
		t.Equal(
			"a nil route is refused",
			fixture.Adapter:SimulateRequest(alice, nil, {}),
			{ Success = false, Reason = "NoHandler" }
		)

		t.Equal("the handler never ran for refused requests", calls, 0)
		t.Equal("every refusal was reported", #fixture.Rejections, 1 + #badRoutes + 1)
		fixture.Service:Stop()
	end

	-- Payload validation
	do
		local fixture = newFixture()
		local calls = 0
		fixture.Service:RegisterRequest("Ping", function(): RequestService.Result
			calls += 1
			return { Success = true }
		end)

		local badPayloads: { any } = {
			"text",
			5,
			true,
			{ Callback = function() end },
			{ Value = 0 / 0 },
			{ Text = string.rep("a", maxString + 1) },
		}
		for _, badPayload in badPayloads do
			-- Time passes so the rate limit never interferes with this check.
			fixture.Advance(1000)
			t.Equal(
				"an invalid payload is refused",
				fixture.Adapter:SimulateRequest(alice, "Ping", badPayload),
				{ Success = false, Reason = "InvalidPayload" }
			)
		end

		t.Equal("the handler never ran for invalid payloads", calls, 0)
		fixture.Service:Stop()
	end

	-- Rate limiting
	do
		local fixture = newFixture()
		fixture.Service:RegisterRequest("Ping", okHandler())
		fixture.Service:RegisterRequest("Other", okHandler())
		fixture.Service:RegisterSend("Ping", function() end)

		local capacity = DataSchema.Requests.RequestCapacity
		local successes = 0
		for _ = 1, capacity do
			if fixture.Adapter:SimulateRequest(alice, "Ping", {}).Success then
				successes += 1
			end
		end

		t.Equal("every request within capacity succeeds", successes, capacity)
		t.Equal(
			"the request past capacity is rate limited",
			fixture.Adapter:SimulateRequest(alice, "Ping", {}),
			{ Success = false, Reason = "RateLimited" }
		)
		t.Equal("the rate limit is reported", lastReason(fixture.Rejections), "RateLimited")

		t.Check("another player has their own bucket", fixture.Adapter:SimulateRequest(bob, "Ping", {}).Success)
		t.Check("another route has its own bucket", fixture.Adapter:SimulateRequest(alice, "Other", {}).Success)

		fixture.Adapter:SimulateSend(alice, "Ping", {})
		t.Equal("sends do not use the request bucket", #fixture.Rejections, 1)

		fixture.Advance(1 / DataSchema.Requests.RequestRefillPerSecond)
		t.Check(
			"a request succeeds again once a token has refilled",
			fixture.Adapter:SimulateRequest(alice, "Ping", {}).Success
		)

		fixture.Service:RemovePlayer(alice)
		local refilled = 0
		for _ = 1, capacity do
			if fixture.Adapter:SimulateRequest(alice, "Ping", {}).Success then
				refilled += 1
			end
		end
		t.Equal("RemovePlayer gives a full bucket back", refilled, capacity)
		fixture.Service:Stop()
	end

	-- Handler failures never leak details
	do
		local fixture = newFixture()
		fixture.Service:RegisterRequest("Throws", function(): RequestService.Result
			error("secret internal detail")
		end)

		local result = fixture.Adapter:SimulateRequest(alice, "Throws", {})
		t.Equal("a throwing handler gives a generic failure", result, { Success = false, Reason = "HandlerError" })
		t.Equal("the failure is reported", lastReason(fixture.Rejections), "HandlerError")

		local badReturns: { any } = {
			"text",
			{},
			{ Success = "yes" },
			{ Success = true, Reason = 5 },
			{ Success = true, Reason = string.rep("a", maxString + 1) },
			{ Success = true, Data = { Callback = function() end } },
			{ Success = true, Data = "text" },
		}
		for index, badReturn in badReturns do
			local route = "Bad" .. tostring(index)
			fixture.Service:RegisterRequest(route, function(): RequestService.Result
				return badReturn :: any
			end)
			t.Equal(
				"a malformed handler result becomes HandlerError #" .. tostring(index),
				fixture.Adapter:SimulateRequest(alice, route, {}),
				{ Success = false, Reason = "HandlerError" }
			)
		end

		fixture.Service:RegisterRequest("ReturnsNil", function(): RequestService.Result
			return nil :: any
		end)
		t.Equal(
			"a handler that returns nothing becomes HandlerError",
			fixture.Adapter:SimulateRequest(alice, "ReturnsNil", {}),
			{ Success = false, Reason = "HandlerError" }
		)

		fixture.Service:RegisterRequest("Leaky", function(): RequestService.Result
			return { Success = false, Reason = "OutOfStock", Secret = "x" } :: any
		end)
		t.Equal(
			"extra fields are stripped from a handler result",
			fixture.Adapter:SimulateRequest(alice, "Leaky", {}),
			{ Success = false, Reason = "OutOfStock" }
		)
		fixture.Service:Stop()
	end

	-- Sends
	do
		local fixture = newFixture()
		local received: { { Player: Player, Payload: { [any]: any } } } = {}

		fixture.Service:RegisterSend("Reload", function(player: Player, payload: { [any]: any })
			table.insert(received, { Player = player, Payload = payload })
		end)
		fixture.Service:RegisterRequest("RequestOnly", okHandler())
		fixture.Service:RegisterSend("Throws", function()
			error("simulated send failure")
		end)

		fixture.Adapter:SimulateSend(alice, "Reload", { Action = "Reload" })
		t.Equal("a valid send reaches the handler", #received, 1)
		t.Check("the send handler sees the player", received[1].Player == alice)
		t.Equal("the send handler sees the payload", received[1].Payload, { Action = "Reload" })

		fixture.Loaded[alice] = false
		fixture.Adapter:SimulateSend(alice, "Reload", {})
		t.Equal("a send from an unloaded player is reported", lastReason(fixture.Rejections), "NotLoaded")
		fixture.Loaded[alice] = true

		fixture.Adapter:SimulateSend(alice, "Missing", {})
		t.Equal("a send to an unknown route is reported", lastReason(fixture.Rejections), "NoHandler")

		fixture.Adapter:SimulateSend(alice, "RequestOnly", {})
		t.Equal("a request-only route cannot be reached by Send", lastReason(fixture.Rejections), "NoHandler")

		fixture.Adapter:SimulateSend(alice, "Reload", "text")
		t.Equal("an invalid send payload is reported", lastReason(fixture.Rejections), "InvalidPayload")

		fixture.Adapter:SimulateSend(alice, "Throws", {})
		t.Equal("a throwing send handler is reported", lastReason(fixture.Rejections), "HandlerError")

		t.Equal("only the valid send ran the handler", #received, 1)

		fixture.Advance(1000)
		local sendCapacity = DataSchema.Requests.SendCapacity
		for _ = 1, sendCapacity do
			fixture.Adapter:SimulateSend(bob, "Reload", {})
		end
		t.Equal("sends within capacity all run", #received, 1 + sendCapacity)

		fixture.Adapter:SimulateSend(bob, "Reload", {})
		t.Equal("a send past capacity is dropped", #received, 1 + sendCapacity)
		t.Equal("the dropped send is reported", lastReason(fixture.Rejections), "RateLimited")
		fixture.Service:Stop()
	end

	-- Stop
	do
		local fixture = newFixture()
		local sends = 0
		fixture.Service:RegisterRequest("Ping", okHandler())
		fixture.Service:RegisterSend("Ping", function()
			sends += 1
		end)

		fixture.Service:Stop()

		t.Equal(
			"a request after Stop is Unavailable",
			fixture.Adapter:SimulateRequest(alice, "Ping", {}),
			{ Success = false, Reason = "Unavailable" }
		)
		fixture.Adapter:SimulateSend(alice, "Ping", {})
		t.Equal("a send after Stop never reaches the handler", sends, 0)
		t.Check(
			"Stop twice is safe",
			pcall(function()
				fixture.Service:Stop()
			end)
		)
	end

	return t.Summary()
end
