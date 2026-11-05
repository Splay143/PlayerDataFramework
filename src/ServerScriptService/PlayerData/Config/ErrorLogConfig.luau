--!strict
--@Splay

--[[
	ErrorLogConfig

	Decides what the Logger records. Pick a preset in Settings, then override only
	what you need.

	Presets:
		Diagnostic   everything from Info up, to every sink, nothing summarised
		Standard     Warning and above recorded, kicks logged one by one (default)
		Production   like Standard, but warnings and kicks are rolled into summaries
		DataLossOnly only DataLoss events are recorded

	Always true, however this is set (enforced by the Logger):
		- DataLoss events are never disabled, sampled, summarised or re-rated or capped.
		- Counters count every event, even a filtered one.
]]

local ServerScriptService = game:GetService("ServerScriptService")

local ErrorCodes = require(ServerScriptService.PlayerData.Config.ErrorCodes)

export type Severity = "Info" | "Warning" | "Error" | "DataLoss"
export type PresetName = "Diagnostic" | "Standard" | "Production" | "DataLossOnly"

export type SinkFloors = {
	Output: Severity,
	DataStore: Severity,
	Webhook: Severity,
}

export type CodeRule = {
	Enabled: boolean?,
	Severity: Severity?,
	Sample: number?,
	Summarise: boolean?,
	SummaryIntervalSeconds: number?,
}

export type Settings = {
	Preset: PresetName?,
	Sinks: { Output: Severity?, DataStore: Severity?, Webhook: Severity? }?,
	Categories: { [number]: boolean }?,
	Codes: { [number]: CodeRule }?,
	MaxEventsPerPlayerPerMinute: number?,
	MaxEventsPerServerPerMinute: number?,
}

export type Resolved = {
	MinSeverity: Severity,
	SummariseWarnings: boolean,
	SummariseKicks: boolean,
	SummaryIntervalSeconds: number,
	Sinks: SinkFloors,
	Categories: { [number]: boolean },
	Codes: { [number]: CodeRule },
	MaxEventsPerPlayerPerMinute: number,
	MaxEventsPerServerPerMinute: number,
}

type Preset = {
	MinSeverity: Severity,
	SummariseWarnings: boolean,
	SummariseKicks: boolean,
	Sinks: SinkFloors,
}

local SEVERITY_RANK: { [string]: number } = { Info = 1, Warning = 2, Error = 3, DataLoss = 4 }

local PRESETS: { [string]: Preset } = {
	Diagnostic = {
		MinSeverity = "Info",
		SummariseWarnings = false,
		SummariseKicks = false,
		Sinks = { Output = "Info", DataStore = "Info", Webhook = "Info" },
	},
	Standard = {
		MinSeverity = "Warning",
		SummariseWarnings = false,
		SummariseKicks = false,
		Sinks = { Output = "Warning", DataStore = "Error", Webhook = "DataLoss" },
	},
	Production = {
		MinSeverity = "Warning",
		SummariseWarnings = true,
		SummariseKicks = true,
		Sinks = { Output = "Warning", DataStore = "Error", Webhook = "DataLoss" },
	},
	DataLossOnly = {
		MinSeverity = "DataLoss",
		SummariseWarnings = false,
		SummariseKicks = false,
		Sinks = { Output = "DataLoss", DataStore = "DataLoss", Webhook = "DataLoss" },
	},
}

local SETTINGS_KEYS: { [string]: boolean } = {
	Preset = true,
	Sinks = true,
	Categories = true,
	Codes = true,
	MaxEventsPerPlayerPerMinute = true,
	MaxEventsPerServerPerMinute = true,
}

local SINK_KEYS: { [string]: boolean } = { Output = true, DataStore = true, Webhook = true }
local RULE_KEYS: { [string]: boolean } = {
	Enabled = true,
	Severity = true,
	Sample = true,
	Summarise = true,
	SummaryIntervalSeconds = true,
}

local ErrorLogConfig = {}

ErrorLogConfig.SeverityRank = SEVERITY_RANK
ErrorLogConfig.DefaultSummaryIntervalSeconds = 300
ErrorLogConfig.MaxEventsPerPlayerPerMinute = 20
ErrorLogConfig.MaxEventsPerServerPerMinute = 200

--[[
	Edit this table. Example with overrides:

		local settings: Settings = {
			Preset = "Production",
			Sinks = { Webhook = "Error" },
			Categories = { [6] = true },
			Codes = {
				[401] = { Summarise = true, SummaryIntervalSeconds = 300 },
				[402] = { Sample = 0.1 },
			},
		}
]]

local settings: Settings = {
	Preset = "Diagnostic",
}
ErrorLogConfig.Settings = settings

local function isSeverity(value: unknown): boolean
	return type(value) == "string" and SEVERITY_RANK[value] ~= nil
end

local function assertKnownKeys(value: unknown, allowed: { [string]: boolean }, label: string)
	assert(type(value) == "table", label .. " must be a table")
	for key in value :: { [unknown]: unknown } do
		assert(type(key) == "string" and allowed[key] == true, label .. " has an unknown field: " .. tostring(key))
	end
end

local function pickFloor(override: unknown, default: Severity, name: string): Severity
	if override == nil then
		return default
	end
	assert(isSeverity(override), ("ErrorLogConfig: Sinks.%s must be a severity name"):format(name))
	return override :: Severity
end

local function checkedLimit(value: unknown, default: number, name: string): number
	if value == nil then 
		return default
	end
	assert(
		type(value) == "number" and value >= 1 and value < math.huge and value == math.floor(value),
		("ErrorLogConfig: %s must be a whole number of at least 1"):format(name)
	)
	return value :: number
end
local function checkedRule(code: number, value: unknown): CodeRule
	local label = ("ErrorLogConfig: Codes[%d]"):format(code)
	assertKnownKeys(value, RULE_KEYS, label)

	local rule = value :: CodeRule
	local sample = rule.Sample
	local interval = rule.SummaryIntervalSeconds

	assert(rule.Enabled == nil or type(rule.Enabled) == "boolean", label .. ".Enabled must be a boolean")
	assert(
		rule.Severity == nil or (isSeverity(rule.Severity) and rule.Severity ~= "DataLoss"),
		label .. ".Severity must be Info, Warning or Error"
	)
	assert(
		sample == nil or (type(sample) == "number" and sample >= 0 and sample <= 1),
		label .. ".Sample must be a number from 0 to 1"
	)
	assert(rule.Summarise == nil or type(rule.Summarise) == "boolean", label .. ".Summarise must be a boolean")
	assert(
		interval == nil or (type(interval) == "number" and interval > 0 and interval < math.huge),
		label .. ".SummaryIntervalSeconds must be a number greater than 0"
	)
	assert(not (sample ~= nil and rule.Summarise == true), label .. " cannot use both Sample and Summarise")

	return table.freeze(table.clone(rule))
end

function ErrorLogConfig.Resolve(overrides: Settings?): Resolved
	local input: Settings = overrides or {}
	assertKnownKeys(input, SETTINGS_KEYS, "ErrorLogConfig")

	local presetName = input.Preset or "Standard"
	local preset = PRESETS[presetName]
	assert(preset ~= nil, "ErrorLogConfig: unknown preset " .. tostring(presetName))

	local sinkOverrides: { Output: Severity?, DataStore: Severity?, Webhook: Severity? } = input.Sinks or {}
	assertKnownKeys(sinkOverrides, SINK_KEYS, "ErrorLogConfig.Sinks")
	local sinks: SinkFloors = {
		Output = pickFloor(sinkOverrides.Output, preset.Sinks.Output, "Output"),
		DataStore = pickFloor(sinkOverrides.DataStore, preset.Sinks.DataStore, "DataStore"),
		Webhook = pickFloor(sinkOverrides.Webhook, preset.Sinks.Webhook, "Webhook"),
	}

	local categoryInput: unknown = input.Categories or {}
	assert(type(categoryInput) == "table", "ErrorLogConfig.Categories must be a table")
	local categories: { [number]: boolean } = {}
	for key, enabled in categoryInput :: { [unknown]: unknown } do
		assert(
			type(key) == "number" and key >= 1 and key <= 7 and key == math.floor(key),
			"ErrorLogConfig.Categories keys must be whole numbers from 1 to 7"
		)
		assert(type(enabled) == "boolean", "ErrorLogConfig.Categories values must be booleans")
		categories[key] = enabled
	end

	local codeInput: unknown = input.Codes or {}
	assert(type(codeInput) == "table", "ErrorLogConfig.Codes must be a table")
	local codes: { [number]: CodeRule } = {}
	for code, rule in codeInput :: { [unknown]: unknown } do
		assert(
			type(code) == "number" and ErrorCodes.IsKnown(code),
			"ErrorLogConfig.Codes has an unknown error code: " .. tostring(code)
		)
		codes[code] = checkedRule(code, rule)
	end

	return table.freeze({
		MinSeverity = preset.MinSeverity,
		SummariseWarnings = preset.SummariseWarnings,
		SummariseKicks = preset.SummariseKicks,
		SummaryIntervalSeconds = ErrorLogConfig.DefaultSummaryIntervalSeconds,
		Sinks = table.freeze(sinks),
		Categories = table.freeze(categories),
		Codes = table.freeze(codes),
		MaxEventsPerPlayerPerMinute = checkedLimit(
			input.MaxEventsPerPlayerPerMinute,
			ErrorLogConfig.MaxEventsPerPlayerPerMinute,
			"MaxEventsPerPlayerPerMinute"
		),
		MaxEventsPerServerPerMinute = checkedLimit(
			input.MaxEventsPerServerPerMinute,
			ErrorLogConfig.MaxEventsPerServerPerMinute,
			"MaxEventsPerServerPerMinute"
		),
	})
end

return ErrorLogConfig