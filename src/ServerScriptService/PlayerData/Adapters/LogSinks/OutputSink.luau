--!strict
--@Splay

local ServerScriptService = game:GetService("ServerScriptService")

local Logger = require(ServerScriptService.PlayerData.Utils.Logger)

local OutputSink = {}

-- Starts with "[Error <code>]" for every severity
function OutputSink.Format(event: Logger.Event): string
	local parts: { string } = {}
	if event.UserId ~= nil then
		table.insert(parts, "user " .. tostring(event.UserId))
	end
	if event.Namespace ~= nil then
		table.insert(parts, "namespace " .. event.Namespace)
	end
	table.insert(parts, "incident " .. event.Id)

	local line = ("[Error %d] %s (%s): %s (%s)"):format(
		event.Code,
		event.Name,
		event.Severity,
		event.Message,
		table.concat(parts, ", ")
	)

	if event.Detail ~= nil then
		line ..= " | " .. event.Detail
	end
	return line
end

-- Used directly as a sink: logger:AddSink(OutputSink.Write)
function OutputSink.Write(event: Logger.Event)
	local line = OutputSink.Format(event)
	if event.Severity == "Info" then
		print(line)
	else
		warn(line)
	end
end

return OutputSink