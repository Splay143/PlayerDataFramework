--!strict
--@Splay

export type Policy = {
	Capacity: number,
	RefillPerSecond: number,
}

export type Options = {
	Now: (() -> number)?,
}

export type RateLimiter = {
	TryConsume: (self: RateLimiter, key: any, bucketName: string) -> boolean,
	Remove: (self: RateLimiter, key: any) -> (),
}

type Bucket = {
	Tokens: number,
	LastRefill: number,
}

local RateLimiter = {}
RateLimiter.__index = RateLimiter

function RateLimiter.new(policy: Policy, options: Options?): RateLimiter
	assert(type(policy) == "table", "RateLimiter.new: policy must be a table")
	assert(type(policy.Capacity) == "number" and policy.Capacity >= 1, "RateLimiter.new: Capacity must be at least 1")
	assert(
		type(policy.RefillPerSecond) == "number" and policy.RefillPerSecond > 0,
		"RateLimiter.new: RefillPerSecond must be greater than 0"
	)

	local self = setmetatable({
		_capacity = policy.Capacity,
		_refillPerSecond = policy.RefillPerSecond,
		_now = (options and options.Now) or os.clock,
		_buckets = {} :: { [any]: { [string]: Bucket } },
	}, RateLimiter)

	return (self :: any) :: RateLimiter
end

function RateLimiter.TryConsume(self: any, key: any, bucketName: string): boolean
	assert(key ~= nil, "RateLimiter:TryConsume: key must not be nil")
	assert(
		type(bucketName) == "string" and bucketName ~= "",
		"RateLimiter:TryConsume: bucketName must be a non-empty string"
	)

	local nowSeconds: number = self._now()

	local keyBuckets = self._buckets[key]
	if keyBuckets == nil then
		keyBuckets = {}
		self._buckets[key] = keyBuckets
	end

	local bucket: Bucket? = keyBuckets[bucketName]
	if bucket == nil then
		bucket = { Tokens = self._capacity, LastRefill = nowSeconds }
		keyBuckets[bucketName] = bucket
	else
		local elapsed = math.max(0, nowSeconds - bucket.LastRefill)
		bucket.Tokens = math.min(self._capacity, bucket.Tokens + elapsed * self._refillPerSecond)
		bucket.LastRefill = nowSeconds
	end

	if (bucket :: Bucket).Tokens < 1 then
		return false
	end

	(bucket :: Bucket).Tokens -= 1
	return true
end

function RateLimiter.Remove(self: any, key: any)
	assert(key ~= nil, "RateLimiter:Remove: key must not be nil")
	self._buckets[key] = nil
end

return RateLimiter
