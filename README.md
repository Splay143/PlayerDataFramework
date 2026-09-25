# PlayerDataFramework

A modular, strictly typed Roblox player-data persistence framework designed for reliable and maintainable player data systems.

## Features

* Strictly typed Luau
* Session locking
* Schema versioning and migrations
* Data validation and sanitisation
* Retry and exponential backoff
* Pluggable storage adapters
* In-memory mock adapter for testing
* Leaderstats integration
* Handler-based data architecture
* Atomic `UpdateAsync` persistence
* Fail-closed handling for invalid or incompatible data

## Getting Started

Register your data handlers before starting `DataService`:

```lua
local ExampleHandler = require(PlayerData.Handlers.ExampleHandler)

DataService.RegisterHandler(ExampleHandler)
DataService.Start()
```

Handlers define the game's data structure and are responsible for loading and saving their own data.

See `ExampleHandler` for a reference implementation.

---

## Handler API

Each data handler must provide:

handler.Namespace
handler.Key

handler.Default()
handler.Sanitize(raw)
handler.Load(player, ctx, value)
handler.Save(player, ctx)

# API

## DataService

### `DataService.RegisterHandler(handler)`

Registers a data handler.

```lua
DataService.RegisterHandler(handler)
```

Must be called before `DataService.Start()`.

### `DataService.Start()`

Starts the player-data system.

```lua
DataService.Start()
```

### `DataService.SaveNow(player)`

Immediately saves a player's current data.

```lua
local success = DataService.SaveNow(player)
```

Returns `boolean`.

### `DataService.IsLoaded(player)`

Checks whether a player's data has finished loading.

```lua
local loaded = DataService.IsLoaded(player)
```

Returns `boolean`.

### `DataService.WaitForLoad(player)`

Waits for a player's data to finish loading.

```lua
local loaded = DataService.WaitForLoad(player)
```

Returns `boolean`.

### `DataService.Get(player, namespace)`

Gets a deep copy of a player's data for a registered namespace.

```lua
local data = DataService.Get(player, "Example")
```

Returns the namespace data or `nil`.

---

## DataSchema

### `DataSchema.KeyFor(userId)`

Generates the DataStore key for a user.

```lua
local key = DataSchema.KeyFor(player.UserId)
```

### `DataSchema.NewData()`

Creates a new copy of the configured default data.

```lua
local data = DataSchema.NewData()
```

### `DataSchema.NewSection(key)`

Creates a new copy of a configured data section.

```lua
local section = DataSchema.NewSection("Inventory")
```

### `DataSchema.NewRecord(now)`

Creates a new player data record.

```lua
local record = DataSchema.NewRecord(os.time())
```

---

## Versioning

### `Versioning.IsTooNew(record)`

Checks whether a record uses a schema version newer than the current framework version.

```lua
local tooNew = Versioning.IsTooNew(record)
```

### `Versioning.Migrate(record, targetVersion?, migrations?)`

Validates and migrates a data record.

```lua
local status, migrated = Versioning.Migrate(record)
```

Returns one of:

```text
Ok
TooNew
Invalid
MigrationFailed
```

### `Versioning.Migrations`

Migration functions are registered by their source schema version.

```lua
Versioning.Migrations[1] = function(record)
    -- Migrate version 1 → 2
end
```

---

## LeaderstatsAdapter

### `LeaderstatsAdapter.new(folder)`

Creates a leaderstats adapter.

```lua
local adapter = LeaderstatsAdapter.new(leaderstatsFolder)
```

### `adapter:ShowInLeaderStats(name, initialValue, valueType?)`

Creates or updates a leaderstat.

```lua
adapter:ShowInLeaderStats("Coins", 100)
```

Supported value types:

```text
IntValue
NumberValue
StringValue
BoolValue
```

### `adapter:Get(name)`

Gets a leaderstat's current value.

```lua
local value = adapter:Get("Coins")
```

### `adapter:Set(name, value)`

Sets an existing leaderstat's value.

```lua
adapter:Set("Coins", 100)
```

---

## StoreHandler

### `StoreHandler.new(storeName, adapter?, options?)`

Creates a storage handler.

```lua
local store = StoreHandler.new("PlayerData")
```

### `store:Get(key)`

Gets a value with retry and backoff handling.

```lua
local status, value = store:Get(key)
```

### `store:Update(key, transform)`

Updates a value using an `UpdateAsync` transform.

```lua
local status, value = store:Update(key, function(current)
    return current
end)
```

### `StoreHandler.ExponentialBackoff(attempt, baseSeconds, maxSeconds)`

Calculates an exponential backoff duration.

```lua
local delay = StoreHandler.ExponentialBackoff(3, 1, 8)
```

---

## SessionManager

### `SessionManager.new(store, serverId, options?)`

Creates a session manager.

```lua
local session = SessionManager.new(store, serverId)
```

### `session:Acquire(userId)`

Attempts to acquire a player's session.

```lua
local status, record, sessionId = session:Acquire(userId)
```

Returns:

```text
Acquired
Locked
TooNew
Failed
```

### `session:Save(userId, sessionId, data)`

Saves data while maintaining the current session lock.

```lua
local status = session:Save(userId, sessionId, data)
```

Returns:

```text
Saved
Lost
Failed
```

### `session:Release(userId, sessionId, data)`

Releases the current session lock.

```lua
local status = session:Release(userId, sessionId, data)
```

Returns:

```text
Released
Lost
Failed
```

---

## DataStoreAdapter

### `DataStoreAdapter.new(storeName)`

Creates a Roblox DataStore adapter.

```lua
local adapter = DataStoreAdapter.new("PlayerData")
```

### `adapter:GetAsync(key)`

Reads a value from the DataStore.

```lua
local value = adapter:GetAsync(key)
```

### `adapter:UpdateAsync(key, transform)`

Updates a value through Roblox `UpdateAsync`.

```lua
local value = adapter:UpdateAsync(key, function(current)
    return current
end)
```

---

## MockAdapter

### `MockAdapter.new(wait?)`

Creates an in-memory storage adapter for testing.

```lua
local adapter = MockAdapter.new()
```

### `adapter:FailNext(count)`

Makes the next number of storage operations fail.

```lua
adapter:FailNext(2)
```

### `adapter:SetLatency(seconds)`

Adds simulated latency to storage operations.

```lua
adapter:SetLatency(0.5)
```

### `adapter:CallCount()`

Returns the number of storage operations performed.

```lua
local calls = adapter:CallCount()
```

### `adapter:Peek(key)`

Returns the stored value without performing a storage operation.

```lua
local value = adapter:Peek(key)
```

---

## BaseUtil

Common sanitisation helpers:

```lua
BaseUtil.SanitizeInt(value, default, min?, max?)
BaseUtil.SanitizeTimestamp(value, now)
BaseUtil.SanitizeString(value, default, maxLength?)
BaseUtil.SanitizeBool(value, default)
BaseUtil.SanitizeIdSet(value)
BaseUtil.AsTable(value)
```

---

## TableUtil

General table utilities:

```lua
TableUtil.DeepCopy(value)
TableUtil.Count(value)
TableUtil.IsArray(value)
TableUtil.DeepEqual(a, b)
TableUtil.Reconcile(target, defaults)
TableUtil.ToSet(list)
TableUtil.ToArray(set)
```

---

# Testing

The framework includes a phased test suite covering its core systems.

The tests use `MockAdapter` where storage behaviour needs to be simulated without using live Roblox DataStores.

---

# License

PlayerDataFramework is released under the MIT License.

See [`LICENSE`](LICENSE) for the full license text.