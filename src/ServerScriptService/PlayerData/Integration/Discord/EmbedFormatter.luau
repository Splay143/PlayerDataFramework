--!strict
--@Splay

--[[
	EmbedFormatter

	Turns one Logger.Event into the JSON body of a Discord webhook message.
]]

local ServerScriptService = game:GetService("ServerScriptService")

local Logger = require(ServerScriptService.PlayerData.Utils.Logger)

-- Discord rejects the whole message when a limit is exceeded, and when a field value is empty.
local MAX_TITLE_LENGTH = 256
local MAX_DESCRIPTION_LENGTH = 2000
local MAX_FIELD_VALUE_LENGTH = 1024
local MAX_GAME_NAME_LENGTH = 100

local SEVERITY_COLOURS: { [string]: number } = {
	Info = 0x3498DB,
	Warning = 0xF1C40F,
	Error = 0xE74C3C,
	DataLoss = 0x992D22,
}

local FALLBACK_COLOUR = 0x95A5A6

type Field = {
	name: string,
	value: string,
	inline: boolean,
}

export type Options = {
	GameName: string?,
}

local EmbedFormatter = {}

local function truncate(text: string, maxLength: number): string
	if #text <= maxLength then
		return text
	end

	-- Cut on a character boundary: a half-cut character is invalid text and the message would be rejected.
	local characterStart = utf8.offset(text, 0, maxLength - 2) or (maxLength - 2)
	return string.sub(text, 1, characterStart - 1) .. "..."
end

local function addField(fields: { Field }, name: string, value: string?, inline: boolean)
	if value == nil or value == "" then
		return
	end
	table.insert(fields, { name = name, value = truncate(value, MAX_FIELD_VALUE_LENGTH), inline = inline })
end

function EmbedFormatter.Format(event: Logger.Event, options: Options?): { [string]: unknown }
	assert(type(event) == "table", "EmbedFormatter.Format: event must be a table")
	assert(options == nil or type(options) == "table", "EmbedFormatter.Format: options must be a table when provided")

	local fields: { Field } = {}
	addField(fields, "Severity", event.Severity, true)
	addField(fields, "Fault", event.Fault, true)
	addField(fields, "Stage", event.Stage, true)
	addField(fields, "User", if event.UserId ~= nil then tostring(event.UserId) else nil, true)
	addField(fields, "Namespace", event.Namespace, true)

	-- Only a summary event carries these.
	if event.Count ~= nil then
		addField(fields, "Occurrences", tostring(event.Count), true)
	end
	if event.FirstTimestamp ~= nil and event.LastTimestamp ~= nil then
		addField(fields, "Window", ("<t:%d:T> to <t:%d:T>"):format(event.FirstTimestamp, event.LastTimestamp), false)
	end

	addField(fields, "Incident ID", "`" .. event.Id .. "`", false)

	if event.Detail ~= nil and event.Detail ~= "" then
		-- A backtick in the detail would end the code block early.
		local safeDetail = (string.gsub(event.Detail, "`", "'"))
		addField(fields, "Detail", "```" .. truncate(safeDetail, MAX_FIELD_VALUE_LENGTH - 6) .. "```", false)
	end

	-- JobId is empty in Studio.
	-- JobId is empty in Studio.
	local server = if event.JobId ~= "" then event.JobId else "Studio"
	
	-- The name lookup can fail and an unpublished place has none, so the place id is the fallback.
	local gameName = options and options.GameName
	local place = if gameName ~= nil and gameName ~= ""
		then truncate(gameName, MAX_GAME_NAME_LENGTH)
		else ("Place %d"):format(event.PlaceId)

	return {
		username = "PlayerData",
		-- Detail text can hold anything, so no message may ping @everyone or a role.
		allowed_mentions = { parse = {} },
		embeds = {
			{
				title = truncate(("[Error %d] %s"):format(event.Code, event.Name), MAX_TITLE_LENGTH),
				description = truncate(event.Message, MAX_DESCRIPTION_LENGTH),
				color = SEVERITY_COLOURS[event.Severity] or FALLBACK_COLOUR,
				fields = fields,
				footer = { text = ("v%s | %s | server %s"):format(event.FrameworkVersion, place, server) },
				timestamp = DateTime.fromUnixTimestamp(event.Timestamp):ToIsoDate(),
			},
		},
	}
end

return EmbedFormatter