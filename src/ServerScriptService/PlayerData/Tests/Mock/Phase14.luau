--!strict
--@Splay

--[[
	Phase 14 tests: Signal.
	The `:: any` on bad-input checks is deliberate: it passes a wrong type on purpose.
]]
local ServerScriptService = game:GetService("ServerScriptService")

local PlayerData = ServerScriptService.PlayerData

local Harness = require(PlayerData.Tests.Harness)
local Signal = require(PlayerData.Utils.Signal)

return function(): boolean
	local t = Harness.new("Phase14")

	-- Order and arguments
	do
		local signal: Signal.Signal<string, number> = Signal.new()
		local calls: { string } = {}
		signal:Connect(function(name, amount)
			table.insert(calls, "A:" .. name .. amount)
		end)
		signal:Connect(function(name, amount)
			table.insert(calls, "B:" .. name .. amount)
		end)

		signal:Fire("coins", 5)
		t.Equal("listeners run in connection order with the arguments", calls, { "A:coins5", "B:coins5" })
		signal:Destroy()
	end

	-- Once
	do
		local signal: Signal.Signal<> = Signal.new()
		local count = 0
		signal:Once(function()
			count += 1
		end)

		signal:Fire()
		signal:Fire()
		t.Equal("Once runs a single time", count, 1)
		signal:Destroy()
	end

	-- Wait
	do
		local signal: Signal.Signal<string> = Signal.new()
		local received: string? = nil
		task.spawn(function()
			received = signal:Wait()
		end)

		signal:Fire("done")
		t.Equal("Wait returns the fired value", received, "done")
		signal:Destroy()
	end

	-- Disconnect
	do
		local signal: Signal.Signal<> = Signal.new()
		local count = 0
		local connection = signal:Connect(function()
			count += 1
		end)

		t.Check("a new connection is connected", connection.Connected)
		connection:Disconnect()
		t.Check("a disconnected connection reports it", not connection.Connected)

		signal:Fire()
		t.Equal("a disconnected listener is not called", count, 0)
		t.Check(
			"Disconnect twice is safe",
			pcall(function()
				connection:Disconnect()
			end)
		)
		signal:Destroy()
	end

	-- Disconnecting another listener during a fire
	do
		local signal: Signal.Signal<> = Signal.new()
		local secondCalled = false
		local second: Signal.Connection
		signal:Connect(function()
			second:Disconnect()
		end)
		second = signal:Connect(function()
			secondCalled = true
		end)

		signal:Fire()
		t.Check("a listener disconnected mid-fire is skipped", not secondCalled)
		signal:Destroy()
	end

	-- One throwing listener does not stop the others
	do
		local signal: Signal.Signal<> = Signal.new()
		local count = 0
		signal:Connect(function()
			error("simulated listener failure")
		end)
		signal:Connect(function()
			count += 1
		end)

		signal:Fire()
		t.Equal("a throwing listener does not stop the others", count, 1)
		signal:Destroy()
	end

	-- Arguments are not copied
	do
		local signal: Signal.Signal<{ Value: number }> = Signal.new()
		local sent = { Value = 1 }
		local received: { Value: number }? = nil
		signal:Connect(function(payload)
			received = payload
		end)

		signal:Fire(sent)
		t.Check("a table argument is the same table, not a copy", received == sent)
		signal:Destroy()
	end

	-- DisconnectAll and Destroy
	do
		local signal: Signal.Signal<> = Signal.new()
		local count = 0
		signal:Connect(function()
			count += 1
		end)

		signal:DisconnectAll()
		signal:Fire()
		t.Equal("DisconnectAll removes every listener", count, 0)

		signal:Connect(function()
			count += 1
		end)
		signal:Destroy()
		signal:Fire()
		t.Equal("Fire after Destroy does nothing", count, 0)
		t.Check("Connect after Destroy asserts", not pcall(function()
			signal:Connect(function() end)
		end))
		t.Check(
			"Destroy twice is safe",
			pcall(function()
				signal:Destroy()
			end)
		)
	end

	-- The public view cannot fire
	do
		local signal: Signal.Signal<> = Signal.new()
		local count = 0
		signal.Event:Connect(function()
			count += 1
		end)

		t.Check("Event has no Fire", rawget(signal.Event, "Fire") == nil)
		signal:Fire()
		t.Equal("a listener connected through Event is called", count, 1)
		signal:Destroy()
	end

	-- Argument checks
	do
		local signal: Signal.Signal<> = Signal.new()
		t.Check("Connect asserts on a non-function", not pcall(function()
			signal:Connect("nope" :: any)
		end))
		t.Check("Once asserts on a non-function", not pcall(function()
			signal:Once("nope" :: any)
		end))
		signal:Destroy()
	end

	return t.Summary()
end