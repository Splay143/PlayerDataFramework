--!strict
--@Splay

local ServerScriptService = game:GetService("ServerScriptService")

local DataSchema = require(ServerScriptService.PlayerData.Config.DataSchema)
local StoreHandler = require(ServerScriptService.PlayerData.Data.StoreHandler)

export type ClaimStatus = "Claimed" | "Invalid" | "Failed"
export type SaveStatus = "Saved" | "Lost" | "Failed"

export type StoreHandlerLike = {
	Update: (self: StoreHandlerLike, key: string, transform: (any?) -> any?) -> (StoreHandler.Status, any?),
}

export type Options = {
	Now: (() -> number)?,
}

export type NamespaceStore = {
	Claim: (self: NamespaceStore, userId: number, namespace: string, sessionId: string) -> (ClaimStatus, any?),
	Save: (self: NamespaceStore, userId: number, namespace: string, sessionId: string, data: any) -> SaveStatus,
}

local NamespaceStore = {}
NamespaceStore.__index = NamespaceStore

function NamespaceStore.new(store: StoreHandlerLike, options: Options?): NamespaceStore
	assert(
		type(store) == "table" and type(store.Update) == "function",
		"NamespaceStore.new: store must be a StoreHandler"
	)

	local self = setmetatable({
		_store = store,
		_now = (options and options.Now) or os.time,
	}, NamespaceStore)

	return (self :: any) :: NamespaceStore
end

function NamespaceStore:Claim(userId: number, namespace: string, sessionId: string): (ClaimStatus, any?)
	local key = DataSchema.SecondaryKeyFor(userId, namespace)
	assert(
		type(sessionId) == "string" and sessionId ~= "",
		"NameSpaceStore:Claim: sessionId must be a non-empty string"
	)

	local transform = function(current: any?): any?
		if current == nil then
			return { SessionId = sessionId, SavedAt = self._now() }
		end

		if type(current) ~= "table" then
			return nil
		end

		return {
			SessionId = sessionId,
			Data = current.Data,
			SavedAt = if type(current.SavedAt) == "number" then current.SavedAt else 0,
		}
	end

	local status, record = self._store:Update(key, transform)

	if status == "Ok" then
		return "Claimed", (record :: any).Data
	elseif status == "Cancelled" then
		return "Invalid", nil
	end
	return "Failed", nil
end

function NamespaceStore:Save(userId: number, namespace: string, sessionId: string, data: any): SaveStatus
	local key = DataSchema.SecondaryKeyFor(userId, namespace)
	assert(type(sessionId) == "string" and sessionId ~= "", "NamespaceStore:Save: sessionId must be a non-empty string")
	assert(data ~= nil, "NamespaceStore:Save: data must not be nil")

	local transform = function(current: any?): any?
		-- Refuse unless our stamp is still on the record. This is the fence.
		if type(current) ~= "table" or current.SessionId ~= sessionId then
			return nil
		end

		return { SessionId = sessionId, Data = data, SavedAt = self._now() }
	end

	local status = self._store:Update(key, transform)

	if status == "Ok" then
		return "Saved"
	elseif status == "Cancelled" then
		return "Lost"
	end
	return "Failed"
end

return NamespaceStore
