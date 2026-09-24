# PlayerDataFramework

A modular Roblox player-data persistence framework built for reliable, secure, and maintainable data systems.

PlayerDataFramework provides the persistence infrastructure needed to build a game-specific player data system while allowing developers to define their own data structure and game-specific logic.

## Features

* Strictly typed Luau architecture
* Session locking
* Schema versioning and migrations
* Retry and backoff handling
* Data validation and sanitisation
* Pluggable storage adapters
* In-memory mock adapter for testing
* Deterministic testing utilities
* Atomic session ownership through `UpdateAsync`
* Separation between persistence infrastructure and game-specific logic
* Fail-closed handling for invalid or incompatible data

## Getting Started

PlayerDataFramework is designed to be customised for your own game.

The repository includes the required Rojo and Luau configuration, allowing you to use the same development setup as the project.

Define your player data in `DataSchema`, then build your game-specific data handling around the framework.

**You will need to develop the DataService, data handlers, and server initialization/integration logic yourself.**

A future version will include a `DataService` foundation requiring primarily integration work, along with an example data handler to demonstrate how the framework can be used.

## Testing

The framework includes testing utilities and tests for its core systems.

The included `MockAdapter` provides an in-memory implementation of the storage interface, allowing storage behaviour and failure conditions to be tested without using live Roblox DataStores.

The existing tests can also be used as examples when creating tests for your own extensions.

## Development

PlayerDataFramework is maintained by its author.

The repository is publicly available so developers can inspect, use, and adapt the framework for their own projects. The official repository is not intended to be community-maintained.

## Contact

For questions, issues, or other enquiries, you can contact me on Discord:

**Discord:** `@vfa6`

## License

PlayerDataFramework is released under the MIT License.

See [`LICENSE`](LICENSE) for the full license text.
