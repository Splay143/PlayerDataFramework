--!strict
--@Splay
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ClientStore = require(ReplicatedStorage.PlayerDataShared.Client.ClientStore)
local Protocol = require(ReplicatedStorage.PlayerDataShared.Shared.Protocol)

const REMOTES_WAIT_SECONDS = 60 --high timeout due to production tests taking longer. This is just to prevent an error from an assert
const SNAPSHOT_RETRY_SECONDS = 5
const REQUEST_TIMEOUT_SECONDS = 10

local store = ClientStore.new()
local replicationRemote: RemoteEvent? = nil
local requestRemote: RemoteFunction? = nil
local sendRemote: RemoteEvent? = nil
local started = false
local awaitingSnapshot = false
local waitingThreads: { thread }= {}

export type Result = {
    Success: boolean,
    Reason: string?,
    Data: { [any]: any}?,
}
local PlayerData = {}

local function sendSnapshotRequest()
    local remote = replicationRemote :: RemoteEvent
    remote:FireServer()

    task.delay(SNAPSHOT_RETRY_SECONDS, function()
        if awaitingSnapshot then
            sendSnapshotRequest()
        end
    end)
end


local function requestSnapshot()
    if awaitingSnapshot then
        return
    end

    awaitingSnapshot = true
    sendSnapshotRequest()
end

local function resumeWaitingThreads()
    local threads = waitingThreads
    waitingThreads = {}

    for _, thread in threads do
        task.spawn(thread)
    end
end


local function onReplication(message: any)
	local status = store:Apply(message)

	if status == "NeedsSnapshot" then
		requestSnapshot()
		return
	end

	-- Only a snapshot that was actually applied ends the wait; an ignored one changes nothing.
	if status == "Applied" and message.Type == "Snapshot" then
		awaitingSnapshot = false
		resumeWaitingThreads()
	end
end

function PlayerData.Start()
    assert(not started, "PlayerData.Start: already started")
    started = true

    local folder = ReplicatedStorage:WaitForChild(Protocol.RemoteFolderName, REMOTES_WAIT_SECONDS)
    assert(folder ~= nil, "PlayerData.Start: the servers remotes folder never appeared")

    local remote = folder:WaitForChild(Protocol.RemoteNames.Replication, REMOTES_WAIT_SECONDS)
    assert(remote ~= nil and remote:IsA("RemoteEvent"), "PlayerData.Start: replication remote is missing")

    local request = folder:WaitForChild(Protocol.RemoteNames.Request, REMOTES_WAIT_SECONDS)
	assert(request ~= nil and request:IsA("RemoteFunction"), "PlayerData.Start: request remote is missing")
	requestRemote = request :: RemoteFunction

	local send = folder:WaitForChild(Protocol.RemoteNames.Send, REMOTES_WAIT_SECONDS)
	assert(send ~= nil and send:IsA("RemoteEvent"), "PlayerData.Start: send remote is missing")
	sendRemote = send :: RemoteEvent

    replicationRemote = remote :: RemoteEvent
    remote.OnClientEvent:Connect(onReplication)

    requestSnapshot()
end

function PlayerData.Get(key: string): any?
	return store:Get(key)
end

function PlayerData.Changed(key: string, callback: (value: any?) -> ()): () -> ()
	return store:Changed(key, callback)
end

function PlayerData.IsReady(): boolean
	return store:IsReady()
end

function PlayerData.WaitUntilReady()
	if store:IsReady() then
		return
	end

	table.insert(waitingThreads, coroutine.running())
	coroutine.yield()
end

local function failure(reason: string): Result
	return { Success = false, Reason = reason }
end

-- Rebuilt field by field so a malformed reply can never leak odd shapes into game code.
local function normalizeResponse(response: any): Result
	if type(response) ~= "table" or type(response.Success) ~= "boolean" then
		return failure("Unavailable")
	end

	local reason = if type(response.Reason) == "string" then response.Reason else nil
	local data = if type(response.Data) == "table" then response.Data else nil
	return { Success = response.Success, Reason = reason, Data = data }
end

-- Asks the server to do something and waits for its answer. Never throws on network trouble.
function PlayerData.Request(route: string, payload: { [any]: any }?): Result
	Protocol.AssertRouteName(route)
	assert(payload == nil or type(payload) == "table", "PlayerData.Request: payload must be a table or nil")

	local remote = requestRemote
	assert(remote ~= nil, "PlayerData.Request: call PlayerData.Start first")

	local caller = coroutine.running()
	local finished = false
	local waiting = false
	local outcome: Result = failure("Unavailable")

	-- Whichever of the reply or the timer arrives first wins; the other is ignored.
	local function finish(result: Result)
		if finished then
			return
		end

		finished = true
		outcome = result
		if waiting then
			task.spawn(caller)
		end
	end

	task.spawn(function()
		local ok, response = pcall(function(): any
			return remote:InvokeServer(route, payload)
		end)
		finish(if ok then normalizeResponse(response) else failure("Unavailable"))
	end)

	task.delay(REQUEST_TIMEOUT_SECONDS, function()
		finish(failure("Timeout"))
	end)

	if not finished then
		waiting = true
		coroutine.yield()
	end

	return outcome
end

-- Fire-and-forget: tells the server something happened and expects no answer.
function PlayerData.Send(route: string, payload: { [any]: any }?)
	Protocol.AssertRouteName(route)
	assert(payload == nil or type(payload) == "table", "PlayerData.Send: payload must be a table or nil")

	local remote = sendRemote
	assert(remote ~= nil, "PlayerData.Send: call PlayerData.Start first")

	remote:FireServer(route, payload)
end

return PlayerData
