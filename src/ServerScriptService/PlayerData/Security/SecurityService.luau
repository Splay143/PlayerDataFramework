--!strict
--@Splay

--[[
	SecurityService

	Turns a rejected client call into an action: nothing, a log line, a kick, or a ban.

	Tiers (see ViolationClassifier for what each reason means):
		Honeypot, MalformedRoute, MalformedPayload, ExtraArguments   -> ban
		NoHandler                                                    -> kick and flag (unless it is a mass trigger)
		Strikes reaching StrikeThreshold                             -> kick and flag
		BanAfterFlags flags                                          -> ban

	Modes:
		Off      does nothing
		LogOnly  logs what it would have done (Warning) and never acts, so flags are not counted either
		Enforce  kicks and bans

	Flags live in this server's memory only. They are kept when a player leaves, so rejoining does not reset them.
	DataService owns the kick and the logging; the ban handler is injected (RobloxBanAdapter comes in a later step).
]]

local ServerScriptService = game:GetService("ServerScriptService")

local DataSchema = require(ServerScriptService.PlayerData.Config.DataSchema)
local ErrorCodes = require(ServerScriptService.PlayerData.Config.ErrorCodes)
local Logger = require(ServerScriptService.PlayerData.Utils.Logger)
local MassTriggerGuard = require(ServerScriptService.PlayerData.Security.MassTriggerGuard)
local StrikeTracker = require(ServerScriptService.PlayerData.Security.StrikeTracker)
local ViolationClassifier = require(ServerScriptService.PlayerData.Security.ViolationClassifier)

export type Mode = "Off" | "LogOnly" | "Enforce"

export type Settings = {
	Mode: Mode,
	InstantActions: boolean,
	InstantFallbackWeight: number,
	Weights: { [string]: number },
	StrikeThreshold: number,
	StrikeDecayPerSecond: number,
	BanAfterFlags: number,
	BanDurationSeconds: number,
	ExemptUserIds: { number },
	MassTriggerPlayers: number,
	MassTriggerWindowSeconds: number,
}

export type Outcome =
	"Off"
	| "Ignored"
	| "Exempt"
	| "AlreadyActed"
	| "Counted"
	| "MassTrigger"
	| "WouldKick"
	| "WouldBan"
	| "Kicked"
	| "Banned"

-- Throws when the ban fails. Yielding is fine.
export type BanHandler = (userId: number, reason: string, durationSeconds: number) -> ()

export type Options = {
	Settings: unknown?, -- validated here; defaults to DataSchema.Security
	Now: (() -> number)?,
	Log: (input: Logger.EventInput) -> (),
	-- Must log the incident and kick the player (DataService.kickPlayer does both).
	Kick: (player: Player, incident: Logger.EventInput) -> (),
	BanHandler: BanHandler?,
	IsStudio: boolean?,
	CreatorId: number?, -- 0 or nil when the game is group-owned
}

type Fields = {
	_settings: Settings,
	_log: (input: Logger.EventInput) -> (),
	_kick: (player: Player, incident: Logger.EventInput) -> (),
	_banHandler: BanHandler?,
	_isStudio: boolean,
	_exempt: { [number]: boolean },
	_tracker: StrikeTracker.StrikeTracker,
	_guard: MassTriggerGuard.MassTriggerGuard,
	_flags: { [number]: number }, -- kept after the player leaves
	_banned: { [number]: boolean }, -- kept for the life of the server
	_acted: { [number]: boolean }, -- already kicked or being banned this join
}

local MODES: { [string]: boolean } = { Off = true, LogOnly = true, Enforce = true }

local SecurityService = {}
SecurityService.__index = SecurityService

export type SecurityService = typeof(setmetatable({} :: Fields, SecurityService))

local function isFiniteNumber(value: number): boolean
	return value == value and value > -math.huge and value < math.huge
end

local function isWholeNumber(value: number): boolean
	return isFiniteNumber(value) and value == math.floor(value)
end

-- The route came from a client, so only a short, quoted slice of it ever reaches the log.
local function describe(reason: string, route: unknown): string
	if type(route) == "string" then
		return ("reason=%s route=%q"):format(reason, string.sub(route, 1, 60))
	end
	return ("reason=%s routeType=%s"):format(reason, type(route))
end

local function incidentFor(
	userId: number,
	code: number,
	severity: Logger.Severity,
	stage: Logger.Stage,
	message: string,
	detail: string
): Logger.EventInput
	return {
		Code = code,
		Severity = severity,
		Fault = "Unknown",
		Stage = stage,
		Message = message,
		Detail = detail,
		UserId = userId,
	}
end

function SecurityService.ValidateSettings(settings: unknown): Settings
	-- The classifier validates the keys it reads (InstantActions, weights, strike threshold and decay).
	ViolationClassifier.ValidateSettings(settings)

	local candidate = settings :: { [string]: unknown }

	local mode = candidate.Mode
	assert(
		type(mode) == "string" and MODES[mode] == true,
		"SecurityService.ValidateSettings: Mode must be Off, LogOnly or Enforce"
	)

	local banAfterFlags = candidate.BanAfterFlags
	assert(
		type(banAfterFlags) == "number" and isWholeNumber(banAfterFlags) and banAfterFlags >= 1,
		"SecurityService.ValidateSettings: BanAfterFlags must be a whole number of at least 1"
	)

	local duration = candidate.BanDurationSeconds
	assert(
		type(duration) == "number" and isWholeNumber(duration) and (duration == -1 or duration > 0),
		"SecurityService.ValidateSettings: BanDurationSeconds must be -1 (permanent) or a whole number above 0"
	)

	local exempt = candidate.ExemptUserIds
	assert(type(exempt) == "table", "SecurityService.ValidateSettings: ExemptUserIds must be a table")
	for index, userId in exempt :: { [unknown]: unknown } do
		assert(
			type(index) == "number" and type(userId) == "number" and isWholeNumber(userId),
			"SecurityService.ValidateSettings: ExemptUserIds must be a list of whole-number UserIds"
		)
	end

	local minPlayers = candidate.MassTriggerPlayers
	assert(
		type(minPlayers) == "number" and isWholeNumber(minPlayers) and minPlayers >= 2,
		"SecurityService.ValidateSettings: MassTriggerPlayers must be a whole number of at least 2"
	)

	local windowSeconds = candidate.MassTriggerWindowSeconds
	assert(
		type(windowSeconds) == "number" and isFiniteNumber(windowSeconds) and windowSeconds > 0,
		"SecurityService.ValidateSettings: MassTriggerWindowSeconds must be a finite number above 0"
	)

	-- Every field is checked above, so this is the one place the shape is trusted.
	return settings :: Settings
end

function SecurityService.new(options: Options): SecurityService
	assert(type(options) == "table", "SecurityService.new: options must be a table")
	assert(type(options.Log) == "function", "SecurityService.new: Log must be a function")
	assert(type(options.Kick) == "function", "SecurityService.new: Kick must be a function")
	assert(
		options.BanHandler == nil or type(options.BanHandler) == "function",
		"SecurityService.new: BanHandler must be a function when provided"
	)
	assert(options.Now == nil or type(options.Now) == "function", "SecurityService.new: Now must be a function")

	local raw: unknown = options.Settings
	if raw == nil then
		raw = DataSchema.Security
	end
	local settings = SecurityService.ValidateSettings(raw)

	local exempt: { [number]: boolean } = {}
	for _, userId in settings.ExemptUserIds do
		exempt[userId] = true
	end
	local creatorId = options.CreatorId or 0
	if creatorId > 0 then
		exempt[creatorId] = true
	end

	return setmetatable({
		_settings = settings,
		_log = options.Log,
		_kick = options.Kick,
		_banHandler = options.BanHandler,
		_isStudio = options.IsStudio == true,
		_exempt = exempt,
		_tracker = StrikeTracker.new({
			Now = options.Now,
			Threshold = settings.StrikeThreshold,
			DecayPerSecond = settings.StrikeDecayPerSecond,
		}),
		_guard = MassTriggerGuard.new({
			Now = options.Now,
			MinPlayers = settings.MassTriggerPlayers,
			WindowSeconds = settings.MassTriggerWindowSeconds,
		}),
		_flags = {} :: { [number]: number },
		_banned = {} :: { [number]: boolean },
		_acted = {} :: { [number]: boolean },
	}, SecurityService)
end

local function banPlayer(
	self: SecurityService,
	player: Player,
	stage: Logger.Stage,
	detail: string
): Outcome
	local userId = player.UserId

	-- Never ban from Studio: a test session must not lock the developer out.
	if self._isStudio then
		self._kick(
			player,
			incidentFor(userId, ErrorCodes.Codes.SecurityKick, "Error", stage, "would ban, kicked instead in Studio", detail)
		)
		return "Kicked"
	end

	local failure: string? = nil
	local handler = self._banHandler
	if handler == nil then
		failure = "no ban handler is configured"
	else
		local ok, handlerError = pcall(function(): nil
			handler(userId, "PlayerData security: " .. detail, self._settings.BanDurationSeconds)
			return nil
		end)
		if not ok then
			failure = tostring(handlerError)
		end
	end

	if failure ~= nil then
		-- A failed ban is not recorded as banned, so a later rejoin can try again.
		self._kick(
			player,
			incidentFor(
				userId,
				ErrorCodes.Codes.SecurityBanFailed,
				"Error",
				stage,
				"ban failed, kicked instead",
				detail .. " failure=" .. failure
			)
		)
		return "Kicked"
	end

	self._banned[userId] = true
	self._kick(player, incidentFor(userId, ErrorCodes.Codes.SecurityBan, "Error", stage, "banned", detail))
	return "Banned"
end

local function applyAction(
	self: SecurityService,
	player: Player,
	wantsBan: boolean,
	stage: Logger.Stage,
	detail: string
): Outcome
	local userId = player.UserId

	if self._settings.Mode == "LogOnly" then
		local message = if wantsBan then "would ban" else "would kick and flag"
		self._log(incidentFor(userId, ErrorCodes.Codes.SecurityWouldAct, "Warning", stage, message, detail))
		return if wantsBan then "WouldBan" else "WouldKick"
	end

	-- Marked before anything can yield, so a second report during a slow ban does nothing.
	self._acted[userId] = true

	if not wantsBan then
		local flags = (self._flags[userId] or 0) + 1
		self._flags[userId] = flags
		wantsBan = flags >= self._settings.BanAfterFlags
	end

	if wantsBan then
		return banPlayer(self, player, stage, detail)
	end

	self._kick(
		player,
		incidentFor(userId, ErrorCodes.Codes.SecurityKick, "Error", stage, "kicked and flagged", detail)
	)
	return "Kicked"
end

-- `route` is nil for replication, which has no routes.
function SecurityService.Report(
	self: SecurityService,
	player: Player,
	reason: string,
	route: unknown,
	stage: Logger.Stage
): Outcome
	assert(type(reason) == "string", "SecurityService:Report: reason must be a string")

	if self._settings.Mode == "Off" then
		return "Off"
	end

	local verdict = ViolationClassifier.Classify(reason, self._settings)
	if verdict.Kind == "Ignore" then
		return "Ignored"
	end

	local userId = player.UserId
	if self._exempt[userId] then
		return "Exempt"
	end
	if self._acted[userId] or self._banned[userId] then
		return "AlreadyActed"
	end

	local detail = describe(reason, route)
	local wantsBan = false

	if verdict.Kind == "Instant" then
		if reason == "NoHandler" then
			-- A typo in the game's own route name looks the same
			local key = "NoHandler:" .. (if type(route) == "string" then route else "?")
			if self._guard:Record(key, userId) then
				self._log(
					incidentFor(
						userId,
						ErrorCodes.Codes.SecurityMassTrigger,
						"Warning",
						stage,
						"many players hit the same unknown route, likely a typo, no action taken",
						detail
					)
				)
				return "MassTrigger"
			end
		else
			wantsBan = true
		end
	else
		self._tracker:Add(userId, verdict.Weight)
		if not self._tracker:IsOverThreshold(userId) then
			return "Counted"
		end
		self._tracker:Clear(userId)
	end

	return applyAction(self, player, wantsBan, stage, detail)
end

function SecurityService.GetFlags(self: SecurityService, userId: number): number
	return self._flags[userId] or 0
end

-- Called when a player leaves. Flags and the banned list are kept on purpose.
function SecurityService.Clear(self: SecurityService, userId: number)
	self._tracker:Clear(userId)
	self._acted[userId] = nil
end

return SecurityService