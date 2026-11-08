--!strict
--@Splay

--[[
	ViolationClassifier

	Decides what a rejected client call is worth.

	Three kinds of answer:
		Ignore  - normal behaviour or our own bug (NotLoaded, UnknownPlayer, Unavailable, HandlerError).
		Strike  - could be lag or a dev bug, so it only counts when it keeps happening.
		Instant - our own client can never produce it, so it can only come from a modified client.
]]

local ServerScriptService = game:GetService("ServerScriptService")

local DataSchema = require(ServerScriptService.PlayerData.Config.DataSchema)

export type Kind = "Ignore" | "Strike" | "Instant"

export type Verdict = {
	Kind: Kind,
	Weight: number,
}

export type Settings = {
	InstantActions: boolean,
	InstantFallbackWeight: number,
	Weights: { [string]: number },
}


local INSTANT_REASONS: { [string]: boolean } = {
	MalformedRoute = true,
	MalformedPayload = true,
	ExtraArguments = true,
	NoHandler = true,
	Honeypot = true,
}

local STRIKE_REASONS: { [string]: boolean } = {
	RateLimited = true,
	SnapshotRateLimited = true,
	InvalidPayload = true,
}

local ViolationClassifier = {}

local function isFiniteNumber(value: unknown): boolean
	return type(value) == "number" and value == value and value > -math.huge and value < math.huge
end

-- Called once at startup by whoever owns the config
function ViolationClassifier.ValidateSettings(settings: any)
	assert(type(settings) == "table", "ViolationClassifier.ValidateSettings: settings must be a table")
	assert(
		type(settings.InstantActions) == "boolean",
		"ViolationClassifier.ValidateSettings: InstantActions must be a boolean"
	)
	assert(
		isFiniteNumber(settings.InstantFallbackWeight) and settings.InstantFallbackWeight >= 0,
		"ViolationClassifier.ValidateSettings: InstantFallbackWeight must be a finite number of at least 0"
	)
	assert(
		isFiniteNumber(settings.StrikeThreshold) and settings.StrikeThreshold > 0,
		"ViolationClassifier.ValidateSettings: StrikeThreshold must be a finite number above 0"
	)
	assert(
		isFiniteNumber(settings.StrikeDecayPerSecond) and settings.StrikeDecayPerSecond >= 0,
		"ViolationClassifier.ValidateSettings: StrikeDecayPerSecond must be a finite number of at least 0"
	)

	local weights = settings.Weights
	assert(type(weights) == "table", "ViolationClassifier.ValidateSettings: Weights must be a table")

	for reason in STRIKE_REASONS do
		assert(
			isFiniteNumber(weights[reason]) and weights[reason] >= 0,
			("ViolationClassifier.ValidateSettings: %s needs a finite weight of at least 0"):format(reason)
		)
	end

	for reason in weights do
		assert(
			type(reason) == "string" and STRIKE_REASONS[reason] == true,
			("ViolationClassifier.ValidateSettings: %s cannot be given a weight"):format(tostring(reason))
		)
	end
end

function ViolationClassifier.Classify(reason: string, settings: Settings?): Verdict
	assert(type(reason) == "string", "ViolationClassifier.Classify: reason must be a string")

	local resolved: any = settings or DataSchema.Security

	if INSTANT_REASONS[reason] then
		if resolved.InstantActions then
			return { Kind = "Instant", Weight = 0 }
		end
		return { Kind = "Strike", Weight = resolved.InstantFallbackWeight or 0 }
	end

	if STRIKE_REASONS[reason] then
		-- A missing entry means no punishment, never a crash or a surprise strike.
		return { Kind = "Strike", Weight = resolved.Weights[reason] or 0 }
	end

	-- This covers the never-counted reasons and anything unknown: when unsure, do not punish.
	return { Kind = "Ignore", Weight = 0 }
end

return ViolationClassifier