--!strict
--@Splay

--[[
	Phase 15 tests: Logger core and OutputSink.
	Wrong types are passed on purpose by casting through `unknown`.
	A throwing sink prints one expected warning.
	It returns true when every check passed.
]]

local ServerScriptService = game:GetService("ServerScriptService")
local HttpService = game:GetService("HttpService")
local PlayerData = ServerScriptService.PlayerData

local ErrorCodes = require(PlayerData.Config.ErrorCodes)
local ErrorLogConfig = require(PlayerData.Config.ErrorLogConfig)
local Harness = require(PlayerData.Tests.Harness)
local Logger = require(PlayerData.Utils.Logger)
local OutputSink = require(PlayerData.Adapters.LogSinks.OutputSink)
local DataSchema = require(PlayerData.Config.DataSchema)
local DataStoreSink = require(PlayerData.Adapters.LogSinks.DataStoreSink)
local MockAdapter = require(PlayerData.Adapters.MockAdapter)
local EmbedFormatter = require(PlayerData.Integration.Discord.EmbedFormatter)
local WebhookSink = require(PlayerData.Adapters.LogSinks.WebhookSink)
local GameNameResolver = require(PlayerData.Integration.GameNameResolver)

local LOAD_FAILURE = ErrorCodes.Codes.HandlerLoadFailure

local function validInput(message: string?): Logger.EventInput
	return {
		Code = LOAD_FAILURE,
		Severity = "Error",
		Fault = "Developer",
		Stage = "Load",
		Message = message or "handler Load threw",
	}
end

-- A valid input with one field replaced by a value of the wrong type.
local function inputWith(field: string, value: unknown): Logger.EventInput
	local copy = (table.clone(validInput()) :: unknown) :: { [string]: unknown }
	copy[field] = value
	return (copy :: unknown) :: Logger.EventInput
end

local function newFixture(bufferSize: number?, settings: ErrorLogConfig.Settings?, random: (() -> number)?)
	local currentTime = 1000
	local idCount = 0

	local logger = Logger.new({
		Now = function(): number
			return currentTime
		end,
		GenerateId = function(): string
			idCount += 1
			return "incident-" .. tostring(idCount)
		end,
		Random = random,
		BufferSize = bufferSize,
		Context = { JobId = "job-1", PlaceId = 42, FrameworkVersion = "test" },
		Config = ErrorLogConfig.Resolve(settings),
	})

	local received: { Logger.Event } = {}
	logger:AddSink(function(event: Logger.Event)
		table.insert(received, event)
	end)

	local function advance(seconds: number)
		currentTime += seconds
	end

	return logger, received, advance
end

local function inputOf(code: number, severity: Logger.Severity, kicked: boolean?): Logger.EventInput
	return {
		Code = code,
		Severity = severity,
		Fault = "Unknown",
		Stage = "Join",
		Message = "test " .. tostring(code),
		Kicked = kicked,
	}
end

local function codesOf(events: { Logger.Event }): { number }
	local codes: { number } = {}
	for _, event in events do
		table.insert(codes, event.Code)
	end
	return codes
end

-- True when Resolve refuses these settings. Settings are passed as unknown so bad shapes compile.
local function rejects(settings: unknown): boolean
	return not pcall(ErrorLogConfig.Resolve, settings :: ErrorLogConfig.Settings)
end

local function messagesOf(events: { Logger.Event }): { string }
	local messages: { string } = {}
	for _, event in events do
		table.insert(messages, event.Message)
	end
	return messages
end

return function(): boolean
	local t = Harness.new("Phase15")

	-- Default incident IDs are compact, recognizable, and retain a random suffix for uniqueness.
	do
		local logger = Logger.new()
		local event = logger:Log(validInput())
		t.Check(
			"a default incident ID is structured and shorter than a GUID",
			#event.Id <= 32 and string.match(event.Id, "^INC%-%d+%-%x+$") ~= nil
		)
	end

	-- The event
	do
		local logger, received, advance = newFixture()

		local event = logger:Log({
			Code = LOAD_FAILURE,
			Severity = "Error",
			Fault = "Developer",
			Stage = "Load",
			Message = "handler Load threw",
			UserId = 7,
			SessionId = "s1",
			Namespace = "Currency",
			Detail = "boom",
		})

		t.Equal("an event carries the input, the context and the stamps", event, {
			Id = "incident-1",
			Code = LOAD_FAILURE,
			Name = "HandlerLoadFailure",
			Severity = "Error",
			Fault = "Developer",
			UserId = 7,
			SessionId = "s1",
			JobId = "job-1",
			PlaceId = 42,
			FrameworkVersion = "test",
			Timestamp = 1000,
			Stage = "Load",
			Namespace = "Currency",
			Kicked = false,
			DataLossLikely = false,
			Message = "handler Load threw",
			Detail = "boom",
		})
		t.Check("an event is frozen", table.isfrozen(event))
		t.Check("Log returns the same event the sink received", received[1] == event)

		advance(5)
		local later = logger:Log(validInput())
		t.Equal("the timestamp follows the clock", later.Timestamp, 1005)
		t.Equal("every event gets its own id", later.Id, "incident-2")

		local flagged = logger:Log({
			Code = LOAD_FAILURE,
			Severity = "DataLoss",
			Fault = "Framework",
			Stage = "Release",
			Message = "release lost",
			Kicked = true,
			DataLossLikely = true,
		})
		t.Check("Kicked and DataLossLikely are kept when set", flagged.Kicked and flagged.DataLossLikely)

		local long = logger:Log({
			Code = LOAD_FAILURE,
			Severity = "Error",
			Fault = "Developer",
			Stage = "Load",
			Message = "long detail",
			Detail = string.rep("x", Logger.MaxDetailLength + 100),
		})
		t.Equal("Detail is truncated", #(long.Detail or ""), Logger.MaxDetailLength)
	end

	-- Ring buffer
	do
		local logger = newFixture(3)
		logger:Log(validInput("m1"))
		logger:Log(validInput("m2"))
		t.Equal("Recent lists events oldest first before the buffer is full", messagesOf(logger:Recent()), { "m1", "m2" })

		logger:Log(validInput("m3"))
		logger:Log(validInput("m4"))
		logger:Log(validInput("m5"))
		t.Equal("a full buffer keeps only the newest events", messagesOf(logger:Recent()), { "m3", "m4", "m5" })

		local emptyLogger = newFixture(3)
		t.Equal("Recent is empty for a new logger", #emptyLogger:Recent(), 0)
	end

	-- Sinks
	do
		local logger, received = newFixture()
		local afterFailing = 0
		logger:AddSink(function()
			error("simulated sink failure")
		end)
		logger:AddSink(function()
			afterFailing += 1
		end)

		logger:Log(validInput("a"))
		logger:Log(validInput("b"))

		t.Equal("a throwing sink does not stop earlier sinks", #received, 2)
		t.Equal("a throwing sink does not stop later sinks", afterFailing, 2)
		t.Equal("a throwing sink does not stop the buffer", #logger:Recent(), 2)
	end

	-- Argument checks
	do
		local logger = newFixture()

		t.Check("Log asserts on an unknown code", not pcall(function()
			logger:Log(inputWith("Code", 999))
		end))
		t.Check("Log asserts on an unknown severity", not pcall(function()
			logger:Log(inputWith("Severity", "Loud"))
		end))
		t.Check("Log asserts on an unknown fault", not pcall(function()
			logger:Log(inputWith("Fault", "Nobody"))
		end))
		t.Check("Log asserts on an unknown stage", not pcall(function()
			logger:Log(inputWith("Stage", "Never"))
		end))
		t.Check("Log asserts on an empty message", not pcall(function()
			logger:Log(inputWith("Message", ""))
		end))
		t.Check("AddSink asserts on a non-function", not pcall(function()
			logger:AddSink(("nope" :: unknown) :: Logger.Sink)
		end))
		t.Check("new asserts on a BufferSize of 0", not pcall(function()
			Logger.new({ BufferSize = 0 })
		end))
		t.Check("new asserts on a fractional BufferSize", not pcall(function()
			Logger.new({ BufferSize = 1.5 })
		end))
		t.Check("new asserts on a non-function Now", not pcall(function()
			Logger.new({ Now = ("nope" :: unknown) :: () -> number })
		end))
	end

	-- OutputSink.Format
	do
		local logger = newFixture()

		local full = logger:Log({
			Code = LOAD_FAILURE,
			Severity = "Error",
			Fault = "Developer",
			Stage = "Load",
			Message = "handler Load threw",
			UserId = 7,
			Namespace = "Currency",
			Detail = "boom",
		})
		t.Equal(
			"a full event formats on one line",
			OutputSink.Format(full),
			"[Error 202] HandlerLoadFailure (Error): handler Load threw (user 7, namespace Currency, incident incident-1) | boom"
		)

		local minimal = logger:Log(validInput())
		t.Equal(
			"a minimal event leaves out the missing parts",
			OutputSink.Format(minimal),
			"[Error 202] HandlerLoadFailure (Error): handler Load threw (incident incident-2)"
		)
	end

	-- ErrorLogConfig: presets and overrides
	do
		local standard = ErrorLogConfig.Resolve(nil)
		t.Equal("no settings means the Standard preset", standard.MinSeverity, "Warning")
		t.Equal(
			"Standard sink floors",
			standard.Sinks,
			{ Output = "Warning", DataStore = "Error", Webhook = "DataLoss" }
		)
		t.Check("Standard logs kicks and warnings one by one", not standard.SummariseKicks and not standard.SummariseWarnings)
		t.Equal("Diagnostic records everything", ErrorLogConfig.Resolve({ Preset = "Diagnostic" }).MinSeverity, "Info")
		t.Equal("DataLossOnly records only DataLoss", ErrorLogConfig.Resolve({ Preset = "DataLossOnly" }).MinSeverity, "DataLoss")
	
		local production = ErrorLogConfig.Resolve({ Preset = "Production" })
		t.Check("Production summarises warnings and kicks", production.SummariseWarnings and production.SummariseKicks)
	
		t.Equal(
			"a sink override replaces only that sink",
			ErrorLogConfig.Resolve({ Preset = "Production", Sinks = { Webhook = "Error" } }).Sinks,
			{ Output = "Warning", DataStore = "Error", Webhook = "Error" }
		)
		t.Equal(
			"a code rule is kept",
			ErrorLogConfig.Resolve({ Codes = { [401] = { Sample = 0.5 } } }).Codes,
			{ [401] = { Sample = 0.5 } }
		)
	end
	
	-- ErrorLogConfig: bad settings assert
	do
		t.Check("a non-table asserts", rejects("text"))
		t.Check("an unknown preset asserts", rejects({ Preset = "Loud" }))
		t.Check("a misspelt settings field asserts", rejects({ Presett = "Standard" }))
		t.Check("an unknown sink asserts", rejects({ Sinks = { Disk = "Error" } }))
		t.Check("a bad sink floor asserts", rejects({ Sinks = { Output = "Loud" } }))
		t.Check("an unknown code asserts", rejects({ Codes = { [999] = { Enabled = false } } }))
		t.Check("a misspelt rule field asserts", rejects({ Codes = { [401] = { Enabeld = false } } }))
		t.Check("a Sample above 1 asserts", rejects({ Codes = { [401] = { Sample = 2 } } }))
		t.Check("Sample with Summarise asserts", rejects({ Codes = { [401] = { Sample = 0.5, Summarise = true } } }))
		t.Check("a DataLoss severity override asserts", rejects({ Codes = { [401] = { Severity = "DataLoss" } } }))
		t.Check("a zero summary interval asserts", rejects({ Codes = { [401] = { SummaryIntervalSeconds = 0 } } }))
		t.Check("a category above 7 asserts", rejects({ Categories = { [8] = false } }))
		t.Check("a non-boolean category asserts", rejects({ Categories = { [6] = "no" } }))
	end
	
	-- Severity floor, counters, sink floors
	do
		local logger, received = newFixture()
		logger:Log(inputOf(401, "Info"))
		t.Equal("an event below the floor reaches no sink", #received, 0)
		t.Equal("an event below the floor is not buffered", #logger:Recent(), 0)
	
		logger:Log(inputOf(401, "Warning"))
		t.Equal("an event at the floor is delivered", #received, 1)
		t.Equal("every event is counted, filtered or not", logger:Counts()[401], 2)
	
		local counts = logger:Counts()
		counts[401] = 99
		t.Equal("Counts returns a copy", logger:Counts()[401], 2)
	
		local diagnostic, diagnosticReceived = newFixture(nil, { Preset = "Diagnostic" })
		diagnostic:Log(inputOf(401, "Info"))
		t.Equal("Diagnostic delivers Info", #diagnosticReceived, 1)
	
		local lossOnly, lossOnlyReceived = newFixture(nil, { Preset = "DataLossOnly" })
		lossOnly:Log(inputOf(401, "Error"))
		lossOnly:Log(inputOf(401, "DataLoss"))
		t.Equal("DataLossOnly delivers only DataLoss", #lossOnlyReceived, 1)
	
		local floored, _ = newFixture()
		local errorsOnly: { Logger.Event } = {}
		floored:AddSink(function(event: Logger.Event)
			table.insert(errorsOnly, event)
		end, "Error")
		floored:Log(inputOf(401, "Warning"))
		floored:Log(inputOf(401, "Error"))
		t.Equal("a sink floor skips lower severities", #errorsOnly, 1)
		t.Equal("the buffer still holds both", #floored:Recent(), 2)
	end
	
	-- Categories and code rules
	do
		local off, offReceived = newFixture(nil, { Categories = { [4] = false } })
		off:Log(inputOf(401, "Error"))
		off:Log(inputOf(202, "Error"))
		t.Equal("a disabled category drops its codes", codesOf(offReceived), { 202 })
		t.Equal("a dropped event is still counted", off:Counts()[401], 1)
	
		local back, backReceived = newFixture(nil, {
			Categories = { [4] = false },
			Codes = { [401] = { Enabled = true } },
		})
		back:Log(inputOf(401, "Error"))
		t.Equal("a code rule wins over its category", #backReceived, 1)
	
		local disabled, disabledReceived = newFixture(nil, { Codes = { [202] = { Enabled = false } } })
		disabled:Log(inputOf(202, "Error"))
		t.Equal("a disabled code is dropped", #disabledReceived, 0)
	
		local loweredSettings: ErrorLogConfig.Settings = {
			Codes = { [401] = { Severity = "Info" :: ErrorLogConfig.Severity } },
		}
		local lowered, loweredReceived = newFixture(nil, loweredSettings)
		lowered:Log(inputOf(401, "Error"))
		t.Equal("a severity override can push an event under the floor", #loweredReceived, 0)
	
		local raisedSettings: ErrorLogConfig.Settings = {
			Codes = { [401] = { Severity = "Error" :: ErrorLogConfig.Severity } },
		}
		local raised, raisedReceived = newFixture(nil, raisedSettings)
		local raisedEvent = raised:Log(inputOf(401, "Info"))
		t.Equal("a severity override re-rates the event", raisedEvent.Severity, "Error")
		t.Equal("a raised event is delivered", #raisedReceived, 1)
	end
	
	-- DataLoss is never filtered
	do
		local harshSettings: ErrorLogConfig.Settings = {
			Preset = "Production",
			Categories = { [2] = false },
			Codes = {
				[202] = { Enabled = false, Severity = "Info" :: ErrorLogConfig.Severity, Summarise = true },
			},
		}
		local harsh, harshReceived = newFixture(nil, harshSettings)
		harsh:Log(inputOf(202, "Error"))
		t.Equal("the same code is dropped when it is not DataLoss", #harshReceived, 0)
	
		local loss = harsh:Log(inputOf(202, "DataLoss"))
		t.Equal("DataLoss ignores disabling and summarising", #harshReceived, 1)
		t.Equal("DataLoss keeps its severity", loss.Severity, "DataLoss")
	
		local sampled, sampledReceived = newFixture(nil, { Codes = { [202] = { Sample = 0 } } }, function(): number
			return 0.99
		end)
		sampled:Log(inputOf(202, "DataLoss"))
		t.Equal("DataLoss ignores sampling", #sampledReceived, 1)
	
		local floor, floorReceived = newFixture(nil, { Preset = "DataLossOnly" })
		floor:Log(inputOf(202, "DataLoss"))
		t.Equal("DataLoss passes the strictest floor", #floorReceived, 1)
	end
	
	-- Sampling
	do
		local nextRandom = 0.4
		local logger, received = newFixture(nil, { Codes = { [401] = { Sample = 0.5 } } }, function(): number
			return nextRandom
		end)
	
		logger:Log(inputOf(401, "Error"))
		t.Equal("an event under the sample rate is kept", #received, 1)
	
		nextRandom = 0.5
		logger:Log(inputOf(401, "Error"))
		t.Equal("an event at or over the sample rate is dropped", #received, 1)
		t.Equal("sampled-out events are still counted", logger:Counts()[401], 2)
	end
	
	-- Summaries
	do
		local logger, received, advance = newFixture(nil, { Preset = "Production" })
		logger:Log(inputOf(401, "Warning"))
		advance(10)
		logger:Log(inputOf(401, "Warning"))
		advance(10)
		logger:Log(inputOf(401, "Warning"))
		t.Equal("warnings are held back by a summarising preset", #received, 0)
	
		advance(280)
		logger:FlushSummaries(false)
		local summary = received[1]
		t.Equal("a due summary is delivered", #received, 1)
		t.Equal("the summary counts the events", summary and summary.Count, 3)
		t.Equal("the summary has the first time", summary and summary.FirstTimestamp, 1000)
		t.Equal("the summary has the last time", summary and summary.LastTimestamp, 1020)
		t.Equal("the summary is stamped at flush time", summary and summary.Timestamp, 1300)
		t.Equal("the summary keeps the code", summary and summary.Code, 401)
	
		logger:FlushSummaries(false)
		t.Equal("a delivered summary is not delivered again", #received, 1)
		t.Equal("every held event was counted", logger:Counts()[401], 3)
	
		-- A later Log delivers a due summary first
		local second, secondReceived, secondAdvance = newFixture(nil, { Preset = "Production" })
		second:Log(inputOf(401, "Warning"))
		secondAdvance(300)
		second:Log(inputOf(202, "Error"))
		t.Equal("the next Log delivers a due summary first", codesOf(secondReceived), { 401, 202 })
	
		-- Production: Error is one by one, a kick is summarised, Force delivers at once
		local kicks, kickReceived = newFixture(nil, { Preset = "Production" })
		kicks:Log(inputOf(202, "Error"))
		t.Equal("Production logs an Error one by one", #kickReceived, 1)
		kicks:Log(inputOf(401, "Error", true))
		t.Equal("Production holds back a kick", #kickReceived, 1)
		kicks:FlushSummaries(true)
		t.Equal("force delivers held summaries without waiting", codesOf(kickReceived), { 202, 401 })
	
		local standardKick, standardKickReceived = newFixture()
		standardKick:Log(inputOf(401, "Warning", true))
		t.Equal("Standard logs a kick one by one", #standardKickReceived, 1)
	end
	
	-- Per-code summary rules
	do
		local logger, received, advance = newFixture(nil, {
			Codes = { [401] = { Summarise = true, SummaryIntervalSeconds = 60 } },
		})
		logger:Log(inputOf(401, "Error"))
		t.Equal("a code rule can summarise under Standard", #received, 0)
	
		advance(59)
		logger:FlushSummaries(false)
		t.Equal("a custom interval is not due early", #received, 0)
	
		advance(1)
		logger:FlushSummaries(false)
		t.Equal("a custom interval is due on time", #received, 1)
	
		local optOut, optOutReceived = newFixture(nil, {
			Preset = "Production",
			Codes = { [401] = { Summarise = false } },
		})
		optOut:Log(inputOf(401, "Warning"))
		t.Equal("Summarise = false opts a code out of the preset", #optOutReceived, 1)
	end
	
	-- Spam caps: an over-cap event is merged into a summary instead of being delivered one by one
	do
		local function forUser(code: number, severity: Logger.Severity, userId: number?): Logger.EventInput
			local input = inputOf(code, severity)
			input.UserId = userId
			return input
		end
	
		-- The defaults come from the roadmap
		local defaults = ErrorLogConfig.Resolve(nil)
		t.Equal("the default player cap is 20 a minute", defaults.MaxEventsPerPlayerPerMinute, 20)
		t.Equal("the default server cap is 200 a minute", defaults.MaxEventsPerServerPerMinute, 200)
	
		-- Per-player cap
		local logger, received, advance = newFixture(nil, { MaxEventsPerPlayerPerMinute = 3 })
		for _ = 1, 5 do
			logger:Log(forUser(LOAD_FAILURE, "Error", 1))
		end
		t.Equal("a player is delivered up to the cap", #received, 3)
		t.Equal("every capped event is still counted", logger:Counts()[LOAD_FAILURE], 5)
	
		logger:FlushSummaries(true)
		local summary = received[4]
		t.Equal("the events over the cap become one summary", #received, 4)
		t.Equal("the summary counts the events over the cap", summary and summary.Count, 2)
	
		logger:Log(forUser(LOAD_FAILURE, "Error", 2))
		t.Equal("another player has their own cap", #received, 5)
	
		advance(60)
		logger:Log(forUser(LOAD_FAILURE, "Error", 1))
		t.Equal("a player's cap resets after a minute", #received, 6)
	
		-- Server cap, shared by every player
		local serverLogger, serverReceived = newFixture(nil, { MaxEventsPerServerPerMinute = 2 })
		for userId = 1, 3 do
			serverLogger:Log(forUser(LOAD_FAILURE, "Error", userId))
		end
		t.Equal("the server cap limits events across players", #serverReceived, 2)
	
		-- An event with no player only counts against the server cap
		local anonymous, anonymousReceived = newFixture(nil, { MaxEventsPerPlayerPerMinute = 1 })
		for _ = 1, 3 do
			anonymous:Log(forUser(LOAD_FAILURE, "Error", nil))
		end
		t.Equal("an event with no player ignores the player cap", #anonymousReceived, 3)
	
		-- A player over their cap must not use up the server's capacity
		local shared, sharedReceived = newFixture(nil, {
			MaxEventsPerPlayerPerMinute = 1,
			MaxEventsPerServerPerMinute = 2,
		})
		shared:Log(forUser(LOAD_FAILURE, "Error", 1))
		shared:Log(forUser(LOAD_FAILURE, "Error", 1))
		shared:Log(forUser(LOAD_FAILURE, "Error", 2))
		t.Equal("a refused event does not use up server capacity", #sharedReceived, 2)
	
		-- DataLoss is never capped and never uses capacity
		local lossLogger, lossReceived = newFixture(nil, {
			MaxEventsPerPlayerPerMinute = 1,
			MaxEventsPerServerPerMinute = 1,
		})
		for _ = 1, 3 do
			lossLogger:Log(forUser(LOAD_FAILURE, "DataLoss", 1))
		end
		t.Equal("DataLoss events are never capped", #lossReceived, 3)
		lossLogger:Log(forUser(LOAD_FAILURE, "Error", 1))
		t.Equal("DataLoss events do not use up the cap", #lossReceived, 4)
	
		-- Events the preset already summarises do not use capacity either
		local held, heldReceived = newFixture(nil, {
			Preset = "Production",
			MaxEventsPerPlayerPerMinute = 1,
		})
		for _ = 1, 3 do
			held:Log(forUser(401, "Warning", 1))
		end
		held:Log(forUser(LOAD_FAILURE, "Error", 1))
		t.Equal("held back events do not use up the cap", codesOf(heldReceived), { LOAD_FAILURE })
	
		-- Bad caps assert
		t.Check("a cap of 0 is rejected", rejects({ MaxEventsPerPlayerPerMinute = 0 }))
		t.Check("a fractional cap is rejected", rejects({ MaxEventsPerServerPerMinute = 1.5 }))
		t.Check("an infinite cap is rejected", rejects({ MaxEventsPerServerPerMinute = math.huge }))
		t.Check("a non-number cap is rejected", rejects({ MaxEventsPerPlayerPerMinute = "many" }))
	end
	
	-- Argument checks for the new options
	do
		t.Check("AddSink asserts on an unknown severity", not pcall(function()
			local logger = newFixture()
			logger:AddSink(function() end, ("Loud" :: unknown) :: Logger.Severity)
		end))
		t.Check("new asserts on a non-function Random", not pcall(function()
			Logger.new({ Random = ("nope" :: unknown) :: () -> number })
		end))
		t.Check("new asserts on a non-table Config", not pcall(function()
			Logger.new({ Config = ("nope" :: unknown) :: ErrorLogConfig.Resolved })
		end))
	end
	
	-- DataStoreSink
	do
		local logger = newFixture()
		local clock = 1000
	
		local function newEvent(severity: string?): Logger.Event
			return logger:Log(inputWith("Severity", severity or "Error"))
		end
	
		local function keyOf(event: Logger.Event): string
			return DataSchema.IncidentStore.KeyPrefix .. event.Id
		end
	
		local function newSink(adapter: any, options: DataStoreSink.Options?): DataStoreSink.DataStoreSink
			local merged: DataStoreSink.Options = if options then table.clone(options) else {}
			merged.Now = function(): number
				return clock
			end
			return DataStoreSink.new(adapter, merged)
		end
	
		-- An event is stored under its incident id.
		do
			local adapter = MockAdapter.new()
			local sink = newSink(adapter)
			local event = newEvent()
	
			sink:Write(event)
			t.Equal("Write only queues, nothing is stored yet", adapter:Peek(keyOf(event)), nil)
			t.Equal("a queued event is pending", sink:PendingCount(), 1)
	
			t.Equal("Step stores the event", sink:Step(), 1)
			t.Equal("the stored event keeps its code", adapter:Peek(keyOf(event)).Code, event.Code)
			t.Equal("the stored event keeps its id", adapter:Peek(keyOf(event)).Id, event.Id)
			t.Equal("nothing is pending after a write", sink:PendingCount(), 0)
		end
	
		-- An existing key is never overwritten.
		do
			local adapter = MockAdapter.new()
			local sink = newSink(adapter)
			local event = newEvent()
	
			adapter:UpdateAsync(keyOf(event), function()
				return { Code = 1 }
			end)
			sink:Write(event)
	
			t.Equal("an already stored incident counts as written", sink:Step(), 1)
			t.Equal("the existing record is untouched", adapter:Peek(keyOf(event)).Code, 1)
		end
	
		-- The per-minute cap
		do
			local adapter = MockAdapter.new()
			local sink = newSink(adapter, { MaxWritesPerMinute = 2 })
			sink:Write(newEvent())
			sink:Write(newEvent())
			sink:Write(newEvent())
	
			t.Equal("only the capped number is written", sink:Step(), 2)
			t.Equal("the rest waits", sink:PendingCount(), 1)
			t.Equal("nothing more is written inside the same minute", sink:Step(), 0)
	
			clock += 60
			t.Equal("the next minute writes the rest", sink:Step(), 1)
			clock = 1000
		end
	
		-- The budget reserve
		do
			local adapter = MockAdapter.new()
			adapter:SetBudget(10)
			local sink = newSink(adapter, { BudgetReserve = 50 })
			sink:Write(newEvent())
	
			t.Equal("nothing is written while the budget is below the reserve", sink:Step(), 0)
			t.Equal("the event keeps waiting", sink:PendingCount(), 1)
	
			adapter:SetBudget(100)
			t.Equal("it is written once the budget recovers", sink:Step(), 1)
		end
		
		-- A final step (shutdown) ignores the rate cap and the reserve, but not its own limit.
		do
			local adapter = MockAdapter.new()
			adapter:SetBudget(0)
			local sink = newSink(adapter, { MaxWritesPerMinute = 1, FinalFlushMaxWrites = 2 })
			sink:Write(newEvent())
			sink:Write(newEvent())
			sink:Write(newEvent())
		
			t.Equal("a normal step writes nothing with no budget", sink:Step(), 0)
			t.Equal("a final step writes up to its limit", sink:Step(true), 2)
			t.Equal("the rest is left behind", sink:PendingCount(), 1)
		end
		
		-- Failures
		do
			local adapter = MockAdapter.new()
			local sink = newSink(adapter, { MaxAttempts = 2 })
			sink:Write(newEvent())
	
			adapter:FailNext(1)
			t.Equal("a failed write stores nothing", sink:Step(), 0)
			t.Equal("a failed write is kept for another try", sink:PendingCount(), 1)
			t.Equal("the retry succeeds", sink:Step(), 1)
	
			sink:Write(newEvent())
			adapter:FailNext(2)
			sink:Step()
			sink:Step()
			t.Equal("an event is dropped after MaxAttempts", sink:PendingCount(), 0)
			t.Equal("the drop is counted", sink:DroppedCount(), 1)
		end
	
		-- Overflow
		do
			local sink = newSink(MockAdapter.new(), { QueueCapacity = 2 })
			sink:Write(newEvent())
			sink:Write(newEvent())
			sink:Write(newEvent())
			t.Equal("a full queue stays at capacity", sink:PendingCount(), 2)
			t.Equal("an overflow is counted", sink:DroppedCount(), 1)
		end
	
		do
			local adapter = MockAdapter.new()
			local sink = newSink(adapter, { QueueCapacity = 2 })
			local firstLoss = newEvent("DataLoss")
			local error = newEvent("Error")
			local secondLoss = newEvent("DataLoss")
			sink:Write(firstLoss)
			sink:Write(error)
			sink:Write(secondLoss)
			sink:Step()
	
			t.Check("DataLoss events are kept over an Error", adapter:Peek(keyOf(firstLoss)) ~= nil and adapter:Peek(keyOf(secondLoss)) ~= nil)
			t.Equal("the Error was the one dropped", adapter:Peek(keyOf(error)), nil)
		end
	
		do
			local adapter = MockAdapter.new()
			local sink = newSink(adapter, { QueueCapacity = 1 })
			local loss = newEvent("DataLoss")
			local error = newEvent("Error")
			sink:Write(loss)
			sink:Write(error)
			sink:Step()
	
			t.Check("an Error never pushes out a queued DataLoss", adapter:Peek(keyOf(loss)) ~= nil and adapter:Peek(keyOf(error)) == nil)
		end
	
		do
			local adapter = MockAdapter.new()
			local sink = newSink(adapter, { QueueCapacity = 1 })
			local older = newEvent("DataLoss")
			local newer = newEvent("DataLoss")
			sink:Write(older)
			sink:Write(newer)
			sink:Step()
	
			t.Check("a new DataLoss replaces the oldest when all are DataLoss", adapter:Peek(keyOf(newer)) ~= nil and adapter:Peek(keyOf(older)) == nil)
		end
		
		-- A second Step while one is in flight does nothing, so an entry cannot be removed unwritten.
		do
			local realAdapter = MockAdapter.new()
			local sink: DataStoreSink.DataStoreSink
			local innerStepResult = -1
		
			-- Calls Step from inside the write, which is what an overlapping Step would do.
			local overlappingAdapter = {
				UpdateAsync = function(_, key: string, transform: any)
					innerStepResult = sink:Step()
					return realAdapter:UpdateAsync(key, transform)
				end,
			}
			sink = newSink(overlappingAdapter)
		
			local first = newEvent()
			local second = newEvent()
			sink:Write(first)
			sink:Write(second)
		
			t.Equal("both events are written by the outer step", sink:Step(), 2)
			t.Equal("a step inside a step does nothing", innerStepResult, 0)
			t.Check("neither event was lost", realAdapter:Peek(keyOf(first)) ~= nil and realAdapter:Peek(keyOf(second)) ~= nil)
			t.Equal("the queue is empty", sink:PendingCount(), 0)
		end

		-- Argument checks
		t.Check("new asserts on a bad adapter", not pcall(function()
			DataStoreSink.new(("nope" :: unknown) :: any)
		end))
		t.Check("new asserts on a zero queue capacity", not pcall(function()
			DataStoreSink.new(MockAdapter.new(), { QueueCapacity = 0 })
		end))
		t.Check("new asserts on a fractional write cap", not pcall(function()
			DataStoreSink.new(MockAdapter.new(), { MaxWritesPerMinute = 1.5 })
		end))
		t.Check("Write asserts on a non-table event", not pcall(function()
			newSink(MockAdapter.new()):Write(("nope" :: unknown) :: Logger.Event)
		end))
	end


	-- EmbedFormatter
	do
		local logger = newFixture()
		local base = logger:Log(inputWith("Severity", "Error"))
	
		local function embedOf(event: Logger.Event): any
			return (EmbedFormatter.Format(event) :: any).embeds[1]
		end

		local function footerTextOf(event: Logger.Event, options: EmbedFormatter.Options?): string
			local embeds = EmbedFormatter.Format(event, options).embeds :: { { footer: { text: string } } }
			return embeds[1].footer.text
		end

		local function fieldValue(embed: any, name: string): string?
			for _, field in embed.fields do
				if field.name == name then
					return field.value
				end
			end
			return nil
		end
	
		-- A copy of an event with one field replaced, for cases the Logger would never produce.
		local function eventWith(event: Logger.Event, field: string, value: unknown): Logger.Event
			local copy = (table.clone(event) :: unknown) :: { [string]: unknown }
			copy[field] = value
			return (copy :: unknown) :: Logger.Event
		end
	
		local embed = embedOf(base)
		t.Check(
			"the title starts with the error code",
			string.find(embed.title, "[Error " .. tostring(base.Code) .. "]", 1, true) == 1
		)
		t.Equal("the description is the message", embed.description, base.Message)
		t.Equal("the incident id is shown", fieldValue(embed, "Incident ID"), "`" .. base.Id .. "`")
		t.Equal("no player field without a user", fieldValue(embed, "User"), nil)
		t.Equal("no window field on a normal event", fieldValue(embed, "Window"), nil)
		t.Equal("a message can never ping anyone", (EmbedFormatter.Format(base) :: any).allowed_mentions.parse, {})
	
		t.Equal("Error colour", embed.color, 0xE74C3C)
		t.Equal("DataLoss colour", embedOf(eventWith(base, "Severity", "DataLoss")).color, 0x992D22)
	
		t.Equal("a user id is shown", fieldValue(embedOf(eventWith(base, "UserId", 7)), "User"), "7")
		t.Check(
			"an empty JobId reads as Studio",
			string.find(embedOf(eventWith(base, "JobId", "")).footer.text, "server Studio", 1, true) ~= nil
		)
		t.Check(
			"the footer shows the game name when one is given",
			string.find(footerTextOf(base, { GameName = "Space Game" }), "Space Game", 1, true) ~= nil
		)
		t.Check(
			"the footer falls back to the place id without a name",
			string.find(footerTextOf(base), "Place " .. tostring(base.PlaceId), 1, true) ~= nil
		)
		t.Check("Format asserts on non-table options", not pcall(function()
			EmbedFormatter.Format(base, ("nope" :: unknown) :: EmbedFormatter.Options)
		end))

		-- A backtick would end the code block early.
		t.Equal(
			"backticks in Detail are replaced",
			fieldValue(embedOf(eventWith(base, "Detail", "a`b")), "Detail"),
			"```a'b```"
		)
		
		local summary = eventWith(eventWith(eventWith(base, "Count", 3), "FirstTimestamp", 1000), "LastTimestamp", 1060)
		t.Equal("a summary shows its count", fieldValue(embedOf(summary), "Occurrences"), "3")
		t.Check("a summary shows its window", fieldValue(embedOf(summary), "Window") ~= nil)
		
		-- Discord rejects the whole message for an over-long or empty value.
		local oversized = embedOf(eventWith(eventWith(base, "Detail", string.rep("x", 5000)), "Message", string.rep("é", 3000)))
		local fieldsValid = true
		for _, field in oversized.fields do
			if field.value == "" or #field.value > 1024 then
				fieldsValid = false
			end
		end
		t.Check("every field is non-empty and within 1024 bytes", fieldsValid)
		t.Check("the description is within 2000 bytes", #oversized.description <= 2000)
		t.Check("a cut description is still valid UTF-8", utf8.len(oversized.description) ~= nil)
	
		t.Check("Format asserts on a non-table event", not pcall(function()
			EmbedFormatter.Format(("nope" :: unknown) :: Logger.Event)
		end))
	end
	
	-- WebhookSink
	do
		local TEST_URL = "https://relay.example/hook"
		local logger = newFixture()
		local clock = 1000
		local posts: { { Url: string, Body: string } } = {}
	
		local function newEvent(severity: string?): Logger.Event
			return logger:Log(inputWith("Severity", severity or "Error"))
		end
	
		local function recordingPoster(url: string, body: string): boolean
			table.insert(posts, { Url = url, Body = body })
			return true
		end
	
		local function newSink(options: WebhookSink.Options?): WebhookSink.WebhookSink
			local merged: WebhookSink.Options = if options then table.clone(options) else {}
			merged.Now = function(): number
				return clock
			end
			merged.Poster = merged.Poster or recordingPoster
			return WebhookSink.new(TEST_URL, merged)
		end
	
		-- An event is queued, then posted by Step.
		do
			table.clear(posts)
			local sink = newSink()
			sink:Write(newEvent())
	
			t.Equal("Write only queues, nothing is posted yet", #posts, 0)
			t.Equal("a queued event is pending", sink:PendingCount(), 1)
			t.Equal("Step posts the event", sink:Step(), 1)
			t.Equal("nothing is pending after a post", sink:PendingCount(), 0)
			t.Equal("the post goes to the given url", posts[1].Url, TEST_URL)
	
			local decoded = HttpService:JSONDecode(posts[1].Body)
			t.Equal("the body is a Discord embed", decoded.embeds[1].color, 0xE74C3C)
		end
	
		-- The per-minute cap
		do
			table.clear(posts)
			local sink = newSink({ MaxPostsPerMinute = 2 })
			sink:Write(newEvent())
			sink:Write(newEvent())
			sink:Write(newEvent())
	
			t.Equal("only the capped number is posted", sink:Step(), 2)
			t.Equal("the rest waits", sink:PendingCount(), 1)
			t.Equal("nothing more is posted inside the same minute", sink:Step(), 0)
	
			clock += 60
			t.Equal("the next minute posts the rest", sink:Step(), 1)
			clock = 1000
		end
	
		-- A final step (shutdown) ignores the rate cap, but not its own limit.
		do
			table.clear(posts)
			local sink = newSink({ MaxPostsPerMinute = 1, FinalFlushMaxPosts = 2 })
			for _ = 1, 4 do
				sink:Write(newEvent())
			end
	
			t.Equal("a final step posts up to its limit", sink:Step(true), 2)
			t.Equal("the rest is left behind", sink:PendingCount(), 2)
		end
	
		-- Failures
		do
			local sink = newSink({
				MaxAttempts = 2,
				Poster = function(): boolean
					return false
				end,
			})
			sink:Write(newEvent())
	
			t.Equal("a failed post sends nothing", sink:Step(), 0)
			t.Equal("a failed post is kept for another try", sink:PendingCount(), 1)
			sink:Step()
			t.Equal("an event is dropped after MaxAttempts", sink:PendingCount(), 0)
			t.Equal("the drop is counted", sink:DroppedCount(), 1)
		end
	
		-- A poster that throws must not break Step or leave the sink stuck.
		do
			local sink = newSink({
				MaxAttempts = 1,
				Poster = function(): boolean
					error("poster failed on purpose")
				end,
			})
			sink:Write(newEvent())
	
			t.Check("a throwing poster does not break Step", pcall(function()
				sink:Step()
			end))
			t.Equal("the event is dropped", sink:PendingCount(), 0)
			t.Check("the sink can step again afterwards", pcall(function()
				sink:Step()
			end))
		end
	
		-- An event that cannot be turned into JSON is dropped, because no retry would fix it.
		do
			local sink = newSink({
				Format = function(): { [string]: unknown }
					error("format failed on purpose")
				end,
			})
			sink:Write(newEvent())
		
			t.Check("an unformattable event does not break Step", pcall(function()
				sink:Step()
			end))
			t.Equal("it is dropped, not retried", sink:PendingCount(), 0)
			t.Equal("the unformattable drop is counted", sink:DroppedCount(), 1)
		end
	
		-- Overflow keeps DataLoss.
		do
			local sink = newSink({ QueueCapacity = 2 })
			sink:Write(newEvent("Error"))
			sink:Write(newEvent("DataLoss"))
			sink:Write(newEvent("DataLoss"))
			t.Equal("a full queue stays at capacity", sink:PendingCount(), 2)
			t.Equal("an Error was pushed out for a DataLoss", sink:DroppedCount(), 1)
	
			sink:Write(newEvent("Error"))
			t.Equal("an Error never pushes out a DataLoss", sink:PendingCount(), 2)
			t.Equal("the refused Error is counted", sink:DroppedCount(), 2)
	
			sink:Write(newEvent("DataLoss"))
			t.Equal("a new DataLoss replaces the oldest DataLoss", sink:DroppedCount(), 3)
		end
	
		-- A second Step while one is in flight does nothing.
		do
			local sink: WebhookSink.WebhookSink
			local innerStepResult = -1
			sink = newSink({
				Poster = function(): boolean
					innerStepResult = sink:Step()
					return true
				end,
			})
			sink:Write(newEvent())
			sink:Write(newEvent())
	
			t.Equal("both events are posted by the outer step", sink:Step(), 2)
			t.Equal("a step inside a step does nothing", innerStepResult, 0)
		end
	
		-- Argument checks
		t.Check("new asserts on a non-https url", not pcall(function()
			WebhookSink.new("http://relay.example/hook")
		end))
		t.Check("new asserts on an empty url", not pcall(function()
			WebhookSink.new("")
		end))
		t.Check("new asserts on a zero queue capacity", not pcall(function()
			WebhookSink.new(TEST_URL, { QueueCapacity = 0 })
		end))
		t.Check("Write asserts on a non-table event", not pcall(function()
			newSink():Write(("nope" :: unknown) :: Logger.Event)
		end))
	end

	-- GameNameResolver
	do
		local function newResolver(
			fetch: GameNameResolver.Fetcher,
			placeId: number?
		): (GameNameResolver.GameNameResolver, { number })
			local waits: { number } = {}
			local resolver = GameNameResolver.new(placeId or 123, {
				Fetch = fetch,
				Wait = function(seconds: number)
					table.insert(waits, seconds)
				end,
				MaxAttempts = 3,
				RetrySeconds = 5,
			})
			return resolver, waits
		end
	
		local resolver = newResolver(function(): string?
			return "Space Game"
		end)
		t.Check("no name is known before Start", resolver:Get() == nil)
		resolver:Start()
		t.Equal("the fetched name is kept", resolver:Get(), "Space Game")
		t.Check("Start twice asserts", not pcall(function()
			resolver:Start()
		end))
	
		-- A failed lookup is retried after a pause.
		local flakyCalls = 0
		local flaky, flakyWaits = newResolver(function(): string?
			flakyCalls += 1
			if flakyCalls == 1 then
				error("simulated lookup failure")
			end
			return "Space Game"
		end)
		flaky:Start()
		t.Equal("a retry finds the name", flaky:Get(), "Space Game")
		t.Equal("one pause between the two attempts", flakyWaits, { 5 })
	
		-- A name that never arrives is abandoned.
		local hopelessCalls = 0
		local hopeless, hopelessWaits = newResolver(function(): string?
			hopelessCalls += 1
			return nil
		end)
		hopeless:Start()
		t.Check("a name that never arrives stays nil", hopeless:Get() == nil)
		t.Equal("it stops after MaxAttempts", hopelessCalls, 3)
		t.Equal("it does not pause after the last attempt", #hopelessWaits, 2)
	
		-- An empty name is treated as a failed lookup.
		local blank = newResolver(function(): string?
			return ""
		end)
		blank:Start()
		t.Check("an empty name is rejected", blank:Get() == nil)
	
		-- Id 0 is an unpublished place.
		local fetchedForStudio = false
		local studio = newResolver(function(): string?
			fetchedForStudio = true
			return "Never used"
		end, 0)
		studio:Start()
		t.Check("an unpublished place is never looked up", not fetchedForStudio and studio:Get() == nil)
	
		t.Check("new asserts on a negative placeId", not pcall(function()
			GameNameResolver.new(-1)
		end))
		t.Check("new asserts on MaxAttempts below 1", not pcall(function()
			GameNameResolver.new(1, { MaxAttempts = 0 })
		end))
	end
	
	return t.Summary()
end