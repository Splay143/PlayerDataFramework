# PlayerDataFramework

PlayerDataFramework is a reusable Roblox data framework for managing persistent player data, handler-based data sections, session locking, saving, and server-to-client replication.

V2 uses an instance-based `DataService` API and includes a networking layer for client requests, server-to-client messages, and structured data replication.

> **Version note:** This README documents the V2 API. V1 uses a different, static service API. Do not mix V1 examples with V2 code.

## Features

- Handler-based data sections with typed defaults and sanitisation.
- Session locking to prevent concurrent servers from owning the same player record.
- Budget-aware persistence, retries, and queued save requests.
- Schema versioning and data migration support.
- Optional secondary data namespaces.
- Scalar and structured data replication.
- Validated client-to-server requests and server-to-client messages.
- Mock-based tests and separate live DataStore tests.

## Installation

Choose the workflow you use for your Roblox project.

### Option 1: Non-Rojo workflow

1. Download the framework's `.rbxm` release from the [GitHub Releases page](https://github.com/Splay143/PlayerDataFramework/releases).
2. Open your Roblox Studio project and insert the model into the appropriate services.
3. Read the included module script README for setup instructions.

### Option 2: Rojo workflow

1. Clone the repository:

   ```bash
   git clone https://github.com/Splay143/PlayerDataFramework.git
   cd PlayerDataFramework
   ```

2. Open the cloned folder in VS Code:

   ```bash
   code .
   ```

3. From the repository root, start the Rojo server:

   ```bash
   rojo serve default.project.json
   ```

4. Connect Roblox Studio to the running server using the Rojo Studio plugin.

The repository's `default.project.json` defines how the source maps into Roblox Studio. Keep Rojo running while you work so supported source changes can sync into Studio.

## Quick start

The examples below show the V2 API. Replace module paths with the paths used by your project.

### 1. Create a handler

A handler defines one data section and how that section is created, sanitised, loaded into runtime systems, and saved back.

```lua
--!strict

local ServerScriptService = game:GetService("ServerScriptService")
local BaseUtil = require(ServerScriptService.PlayerData.Utils.BaseUtil)

export type CurrencyData = {
    Coins: number,
}

local CurrencyHandler = {}
CurrencyHandler.Namespace = "Currency"

function CurrencyHandler.Default(): CurrencyData
    return {
        Coins = 0,
    }
end

function CurrencyHandler.Sanitize(raw: any?): CurrencyData
    local data = BaseUtil.AsTable(raw)

    return {
        Coins = BaseUtil.SanitizeInt(data.Coins, 0, 0, 1_000_000_000),
    }
end

function CurrencyHandler.Load(player: Player, ctx: BaseUtil.Context, value: CurrencyData)
    ctx.LeaderstatsAdapter:ShowInLeaderStats("Coins", value.Coins)
end

function CurrencyHandler.Save(player: Player, ctx: BaseUtil.Context): CurrencyData
    return {
        Coins = ctx.LeaderstatsAdapter:Get("Coins") or 0,
    }
end

local handler: BaseUtil.Handler<CurrencyData> = CurrencyHandler

return handler
```

Sanitisation must treat stored data as untrusted input. Apply the framework's expected handler contract and validate any game-specific constraints before relying on loaded values.

### 2. Register handlers and start the service

```lua
--!strict

local dataService = DataService.new()

dataService:RegisterHandler(CurrencyHandler)
dataService:RegisterHandler(InventoryHandler)

dataService:Start()
```

Register all required handlers before starting the service.

### 3. Read player data and request a save

```lua
dataService:OnPlayerLoaded(function(player)
    local currency = dataService:Get(player, CurrencyHandler)

    if currency then
        print(currency.Coins)
    end
end)

dataService:RequestSave(player)
```

Use the loaded-data lifecycle rather than assuming a player's data is ready immediately after joining. A save request asks the framework to save through its save pipeline; it should not be treated as a synchronous confirmation that the data has reached the DataStore.

### 4. Replicate values to a client

```lua
dataService:Replicate(player, "Wins", 10)
dataService:Replicate(player, "Coins", 500, true)
dataService:Replicate(player, "Inventory", {
    Items = { "Sword", "Bow" },
})
```

Use replication for data the client needs to display. The server remains authoritative: replicated client-visible values must not be used as proof that a player owns an item, has enough currency, or is allowed to perform an action.

### 5. Register a server request

```lua
dataService:RegisterRequest("EquipItem", function(player, payload)
    local itemId = payload.ItemId

    if type(itemId) ~= "string" then
        return {
            Success = false,
            Reason = "InvalidItem",
        }
    end

    -- Validate ownership and gameplay requirements here.
    -- Update authoritative server state only after validation.

    return {
        Success = true,
    }
end)
```

A request handler must validate payload types, ownership, permissions, cooldowns, and other gameplay rules on the server. Never trust the client to decide the result of an action.

## API reference

The following is a quick reference to the V2 public API. Check the source for exact parameter and return types for the version you have installed.

### DataService

| Method | Purpose |
|---|---|
| `DataService.new()` | Creates a service instance. |
| `RegisterHandler(handler)` | Registers a data handler before startup. |
| `Start()` | Starts the service lifecycle. |
| `Get(player, handler)` | Gets the loaded data for a registered handler. |
| `IsLoaded(player)` | Checks whether the player's data has finished loading. |
| `WaitForLoad(player)` | Waits for the player's data-loading lifecycle. |
| `OnPlayerLoaded(callback)` | Registers a callback for successfully loaded player data. |
| `RequestSave(player)` | Requests a save through the framework's save pipeline. |
| `SaveNow(player)` | Requests an immediate save operation where supported. |
| `GetLastSaved(player)` | Gets the last saved snapshot where available. |
| `Replicate(player, key, value, private?)` | Replicates a supported value to the client. |
| `RegisterRequest(name, callback)` | Registers a client request that expects a response. |
| `RegisterSend(name, callback)` | Registers a client message that does not expect a response. |
| `Destroy()` | Shuts down the service instance and its owned resources. |

### Signals

V2 exposes lifecycle and persistence signals, including:

- `PlayerLoaded` — player data has loaded successfully.
- `SaveFailed` — a save operation failed.

Check the source for the exact callback arguments and whether a signal is available directly or through a service instance.

### Handler contract

A handler represents one data section. The V2 handler contract includes the following core members:

| Member | Purpose |
|---|---|
| `Namespace` | Identifies the data namespace. |
| `Default()` | Creates the default data value. |
| `Sanitize(raw)` | Converts stored input into valid data. |
| `Load(player, ctx, value)` | Applies loaded data to runtime systems. |
| `Save(player, ctx)` | Builds the data value to persist. |

Some handler or storage configurations may expose additional options. Match the exact type definition in the version you are using rather than adding optional members based on examples from another version.

### Client API

The shared client API provides access to replicated values and registered server routes. Common operations include:

| Method | Purpose |
|---|---|
| `Get(key)` | Reads a replicated value. |
| `Changed(key, callback)` | Subscribes to changes for a replicated value. |
| `IsReady()` | Checks whether client replication is ready. |
| `WaitUntilReady()` | Waits until the client API is ready. |
| `Request(name, payload)` | Sends a request and receives its response. |
| `Send(name, payload)` | Sends a message without waiting for a response. |

Example:

```lua
--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local PlayerData = require(ReplicatedStorage.PlayerDataShared.Client.PlayerData)

PlayerData.WaitUntilReady()

local inventory = PlayerData.Get("Inventory")

local disconnect = PlayerData.Changed("Inventory", function(value)
    -- Refresh the UI using the new value.
end)
```

Example request:

```lua
local result = PlayerData.Request("EquipItem", {
    ItemId = "AK47",
})

if not result.Success then
    warn(result.Reason)
end
```

Use the exact client module path and callback types from your installed version. Disconnect change listeners when the UI or controller that owns them is destroyed.

## Important behaviour

### Error codes

When the framework kicks a player because of a data problem, the kick message ends with an
`Error Code`. Give it to the player's support request; the matching server log line starts
with `[Error <code>]` and names the affected namespaces. Player-facing messages never
contain handler names, stack traces or schema details.

Codes are stable. A number is never reused and never changes meaning between releases.

| Code | Name | Meaning | Likely cause |
|---|---|---|---|
| 201 | HandlerSanitizeFailure | A handler's `Sanitize` threw or returned nil while loading. | Handler bug. Check that `Sanitize(nil)` returns the default. |
| 202 | HandlerLoadFailure | A handler's `Load` threw while loading. | Handler bug. Check the handler's `Load` and its adapters. |
| 301 | RecordTooNew | The stored record was written by a newer version of the game. | A rollback or a rolling update where servers run different versions. |
| 401 | SessionLocked | Another server held the player's session for too long. | The other server is stuck or shutting down. Usually clears by itself; the lock expires after `StaleLockSeconds`. |
| 402 | LoadFailed | The DataStore failed, or the record could not be migrated. | DataStore outage, or a migration error. Check the server log. |
| 403 | NamespaceUnavailable | A secondary namespace could not be claimed. | DataStore outage, or a corrupt secondary record. |
| 404 | SessionLost | Another server took over the player's session during a save. | The player joined elsewhere while this server still held them. |

The player's stored data is not overwritten when they are kicked for 201, 202, 301, 401, 402 or 403.

### Persistence and session locking

- Player data should be accessed through the framework's lifecycle.
- Session locking is intended to prevent two servers from simultaneously owning the same player record.
- Saves may be delayed by queueing, cooldowns, or DataStore request budgets.
- A requested save is not necessarily an immediate successful write.
- Handle load and save failures deliberately; do not silently replace valid player data with defaults after a failed load.

### Secondary namespaces

Secondary namespaces allow data to be stored separately from the primary player record where configured. Use them only when separate storage is useful for the data's lifecycle or size. Each additional namespace introduces its own failure and consistency considerations.

### Replication and security

- Replicate only information the client needs.
- Treat all client-supplied request payloads as untrusted.
- Validate requests on the server before changing persistent or gameplay state.
- Do not expose server-only modules, DataStore keys, session-lock internals, or sensitive data to clients.
- Do not use a replicated value as the authoritative source for purchases, inventory ownership, or permissions.

## Configuration and migrations

Use the framework's schema and configuration modules to manage store names, key prefixes, versioning, save behaviour, and sanitisation. Review the defaults in the source before changing production settings.

When changing the shape of stored data:

1. Update the relevant handler's data type and default.
2. Ensure sanitisation can safely handle older or malformed records.
3. Add a migration when old data needs a deliberate transformation.
4. Test both valid legacy data and malformed input.
5. Test migrations against a disposable test store before using them with production data.

Never test destructive migrations against live player data.

## Testing

PlayerDataFramework includes mock-based tests for repeatable unit and integration coverage. Use these for normal development and regression testing.

Live DataStore tests should be separate and explicitly enabled. Run them only in a dedicated test experience and with a disposable DataStore name. A throwaway place is not sufficient protection if it points at the same production store or keys as a live game.

Before enabling live tests:

- Verify the experience and DataStore name.
- Keep production keys and test keys separate.
- Test session-lock acquisition, contention, release, and recovery.
- Avoid running multiple destructive test sessions against the same test key.
- Confirm that test cleanup cannot delete or overwrite production records.


## License

See the repository's [LICENSE](https://github.com/Splay143/PlayerDataFramework) file for the terms that apply to using and distributing PlayerDataFramework.