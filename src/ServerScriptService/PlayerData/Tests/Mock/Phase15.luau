--!strict
--@Splay

--[[
	Phase 15 tests: Logger core and OutputSink.
	Wrong types are passed on purpose by casting through `unknown`.
	A throwing sink prints one expected warning.
	It returns true when every check passed.
]]

local ServerScriptService = game:GetService("ServerScriptService")

local PlayerData = ServerScriptService.PlayerData

local ErrorCodes = require(PlayerData.Config.ErrorCodes)
local ErrorLogConfig = require(PlayerData.Config.ErrorLogConfig)
local Harness = require(PlayerData.Tests.Harness)
local Logger = require(PlayerData.Utils.Logger)
local OutputSink = require(PlayerData.Adapters.LogSinks.OutputSink)

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
	
	return t.Summary()
end