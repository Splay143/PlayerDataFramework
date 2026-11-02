--!strict
--@Splay

export type Connection = {
	Connected: boolean,
	Disconnect: (self: Connection) -> (),
}

-- The read-only view handed to game code. It has no Fire.
export type Event<T...> = {
	Connect: (self: Event<T...>, callback: (T...) -> ()) -> Connection,
	Once: (self: Event<T...>, callback: (T...) -> ()) -> Connection,
	Wait: (self: Event<T...>) -> T...,
}

export type Signal<T...> = {
	Event: Event<T...>,
	Connect: (self: Signal<T...>, callback: (T...) -> ()) -> Connection,
	Once: (self: Signal<T...>, callback: (T...) -> ()) -> Connection,
	Wait: (self: Signal<T...>) -> T...,
	Fire: (self: Signal<T...>, T...) -> (),
	DisconnectAll: (self: Signal<T...>) -> (),
	Destroy: (self: Signal<T...>) -> (),
}

-- What a signal holds privately, on top of its public methods.
type Private<T...> = Signal<T...> & {
	_listeners: { Listener<T...> },
	_destroyed: boolean,
}

-- A listener is also the Connection handed back to the caller.
type Listener<T...> = {
	Connected: boolean,
	Callback: (T...) -> (),
	Owner: Private<T...>,
}

type EventState<T...> = {
	_signal: Private<T...>,
}

local ConnectionClass = {}
ConnectionClass.__index = ConnectionClass

local EventView = {}
EventView.__index = EventView

local Signal = {}
Signal.__index = Signal

function ConnectionClass.Disconnect<T...>(self: Listener<T...>)
	if not self.Connected then
		return
	end
	self.Connected = false

	local listeners = self.Owner._listeners
	local index = table.find(listeners, self)
	if index ~= nil then
		table.remove(listeners, index)
	end
end

function Signal.new<T...>(): Signal<T...>
	local signal = setmetatable({ _listeners = {}, _destroyed = false }, Signal) :: any
	signal.Event = setmetatable({ _signal = signal }, EventView)
	return signal :: Signal<T...>
end

function Signal.Connect<T...>(self: Private<T...>, callback: (T...) -> ()): Connection
	assert(not self._destroyed, "Signal:Connect: the signal has been destroyed")
	assert(type(callback) == "function", "Signal:Connect: callback must be a function")

	local listener = setmetatable({ Connected = true, Callback = callback, Owner = self }, ConnectionClass)
	table.insert(self._listeners, listener :: any)
	return listener :: any
end

function Signal.Once<T...>(self: Private<T...>, callback: (T...) -> ()): Connection
	assert(type(callback) == "function", "Signal:Once: callback must be a function")

	local connection: Connection
	connection = Signal.Connect(self, function(...: T...)
		-- Disconnect first so the callback can never run twice.
		connection:Disconnect()
		callback(...)
	end)
	return connection
end

function Signal.Wait<T...>(self: Private<T...>): T...
	local thread = coroutine.running()
	Signal.Once(self, function(...: T...)
		task.spawn(thread, ...)
	end)
	return coroutine.yield()
end

function Signal.Fire<T...>(self: Private<T...>, ...: T...)
	if self._destroyed then
		return
	end

	-- Copied so a listener that disconnects (or connects) mid-fire cannot disturb this loop.
	for _, listener in table.clone(self._listeners) do
		if listener.Connected then
			task.spawn(listener.Callback, ...)
		end
	end
end

function Signal.DisconnectAll<T...>(self: Private<T...>)
	for _, listener in self._listeners do
		listener.Connected = false
	end
	table.clear(self._listeners)
end

function Signal.Destroy<T...>(self: Private<T...>)
	if self._destroyed then
		return
	end
	self._destroyed = true
	Signal.DisconnectAll(self)
end

function EventView.Connect<T...>(self: EventState<T...>, callback: (T...) -> ()): Connection
	return Signal.Connect(self._signal, callback)
end

function EventView.Once<T...>(self: EventState<T...>, callback: (T...) -> ()): Connection
	return Signal.Once(self._signal, callback)
end

function EventView.Wait<T...>(self: EventState<T...>): T...
	return Signal.Wait(self._signal)
end

return Signal