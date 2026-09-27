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

### 1. Create a handler

Game-specific player data is defined through handlers.

Each handler owns one namespace of player data:

```lua
local Handler = {
    Namespace = "Example",

    Default = function()
        return {
            Coins = 0,
        }
    end,

    Sanitize = function(value)
        return {
            Coins = BaseUtil.SanitizeInt(
                value and value.Coins,
                0,
                0
            ),
        }
    end,

    Load = function(player, ctx, data)
        ctx.LeaderstatsAdapter:ShowInLeaderStats("Coins", data.Coins)
    end,

    Save = function(player, ctx)
        return {
            Coins = ctx.LeaderstatsAdapter:Get("Coins") or 0,
        }
    end,
}

return Handler
```

See `ExampleHandler` for a complete reference implementation.

### 2. Register handlers

Register every handler before starting `DataService`:

```lua
local DataService = require(...)

local ExampleHandler = require(...)

DataService.RegisterHandler(ExampleHandler)
DataService.Start()
```

Handlers cannot be registered after `DataService.Start()`.

### 3. Wait for player data

Player data loads asynchronously when a player joins.

Use `WaitForLoad()` when another system needs to wait for the player's data:

```lua
if not DataService.WaitForLoad(player) then
    return
end
```

You can also check the current state without yielding:

```lua
if DataService.IsLoaded(player) then
    -- Player data is ready.
end
```

### 4. Read player data

Use `DataService.Get()` to retrieve a deep copy of a registered namespace:

```lua
local data = DataService.Get(player, "Example")

if data then
    print(data.Coins)
end
```

The returned value should not be modified directly. Game systems should modify their own live state and allow the handler to collect that state when saving.

### 5. Request a save

For normal gameplay systems, request a save through the save queue:

```lua
DataService.RequestSave(player)
```

Repeated requests for the same player are deduplicated by the save queue.

Use `SaveNow()` when an immediate save is specifically required:

```lua
local success = DataService.SaveNow(player)
```

`SaveNow()` is still subject to the framework's save-gap protection.

## Handler API

Each data handler must provide:

```text
handler.Namespace
handler.Default()
handler.Sanitize(raw)
handler.Load(player, ctx, value)
handler.Save(player, ctx)
```

### `handler.Namespace`

Unique name identifying the handler's section of player data.

```lua
Namespace = "Example"
```

### `handler.Default()`

Returns the default value for the handler's namespace.

```lua
Default = function()
    return {
        Coins = 0,
    }
end
```

### `handler.Sanitize(raw)`

Validates and sanitizes loaded or saved data.

During loading, if sanitization errors or returns `nil`, the framework falls back to `Default()`.

```lua
Sanitize = function(value)
    return {
        Coins = BaseUtil.SanitizeInt(
            value and value.Coins,
            0,
            0
        ),
    }
end
```

### `handler.Load(player, ctx, value)`

Applies loaded data to the live game state.

### `handler.Save(player, ctx)`

Reads the current live game state and returns the value that should be persisted.

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

### `DataService.RequestSave(player)`

Requests that a player's current data be saved through the framework's save queue.

```lua
DataService.RequestSave(player)
```

Use `RequestSave()` for **normal gameplay events that should cause player data to be persisted**.

For example, after a player completes an important action:

```lua
DataService.RequestSave(player)
```

The request is added to the save queue rather than performing a DataStore operation immediately. The queue controls when the save is processed, takes DataStore request budget into account, and deduplicates repeated requests for the same player.

**Use `RequestSave()` by default when you need to save player data.**

---

### `DataService.SaveNow(player)`

Attempts to save a player's current data immediately instead of adding the player to the save queue.

```lua
local success = DataService.SaveNow(player)
```

Returns `boolean`.

Use `SaveNow()` when the save needs to be attempted **immediately**, rather than waiting for the normal save queue.

For example, a system may use it when it has a specific reason to complete a save before continuing:

```lua
local success = DataService.SaveNow(player)

if not success then
    warn("Player data could not be saved immediately")
end
```

`SaveNow()` is intended for situations where immediate persistence is important. It should **not** normally be used for frequent gameplay saves, as repeatedly forcing immediate saves can increase DataStore usage and contention.

`SaveNow()` is still subject to the framework's save-gap protection. If the player was saved too recently, the save may be skipped and `false` will be returned.

**Rule of thumb:**

* Use `RequestSave()` for normal gameplay saves.
* Use `SaveNow()` when you specifically need the framework to attempt the save immediately.

### Example

```lua
-- Player completes a race
playerData.Coins += 100
DataService.RequestSave(player)

-- Player purchases a permanent item
playerData.OwnedItems["SpeedCoil"] = true
DataService.SaveNow(player)
```

Use `RequestSave()` for normal gameplay changes. Use `SaveNow()` when the change is important enough that you specifically want to attempt saving it immediately.

---

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

Returns `true` when loading succeeds and `false` when loading fails.

### `DataService.Get(player, namespace)`

Gets a deep copy of a player's data for a registered namespace.

```lua
local data = DataService.Get(player, "Example")
```

Returns the namespace data or `nil`.

### `DataService.Replicate(player, key, value, private?)`

Replicates a value to the client using the framework's value replication system.

```lua
DataService.Replicate(player, "Wins", 10)
```

By default, the value is replicated through the player's `leaderstats` folder.

Set `private` to `true` when the value is intended for the game's own UI or other client-side systems rather than the standard Roblox leaderboard:

```lua
DataService.Replicate(player, "Coins", 500, true)
```

Private values are placed in the player's `PrivateData` folder under `PlayerGui`.

The `PrivateData` folder is still replicated to the client. `private = true` does **not** mean the value is secret from the client. It means the value is separated from `leaderstats` so developers can expose values specifically for their own UI and client systems.

#### Examples

Standard Roblox leaderboard value:

```lua
DataService.Replicate(player, "Wins", 10)
```

Value intended for a custom UI:

```lua
DataService.Replicate(player, "Coins", 500, true)
```

The value type can be inferred from the Lua value. Supported types are:

```text
number → IntValue or NumberValue
string → StringValue
boolean → BoolValue
```

An integer number creates an `IntValue`, while a fractional number creates a `NumberValue`.

`DataService.Replicate()` only updates the replicated live value. It does **not** save the value to the player's persistent data.

For persistent data, the value must still be returned by the appropriate handler's `Save()` function.


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

Gets a value with retry and exponential backoff handling.

```lua
local status, value = store:Get(key)
```

Returns:

```text
Ok
Failed
```

### `store:Update(key, transform)`

Updates a value using an `UpdateAsync` transform.

```lua
local status, value = store:Update(key, function(current)
    return current
end)
```

Returns:

```text
Ok
Cancelled
Failed
```

`Cancelled` is returned when the transform returns `nil`.

### `store:GetBudget()`

Returns the currently available storage request budget.

```lua
local budget = store:GetBudget()
```

Adapters that do not expose request-budget information return `math.huge`.

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
local status, record = session:Acquire(userId)
```

Returns:

```text
Acquired
Locked
TooNew
Failed
```

When `status` is `Acquired`, the returned record contains the active session lock:

```lua
local sessionId = record.Lock.SessionId
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

### `adapter:GetBudget()`

Returns the current Roblox DataStore request budget for `UpdateAsync` operations.

```lua
local budget = adapter:GetBudget()
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

### `adapter:SetBudget(budget)`

Sets the simulated storage request budget.

```lua
adapter:SetBudget(10)
```

Useful for testing budget-aware systems such as the save queue.

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