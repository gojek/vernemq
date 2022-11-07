#!lua name=enqueue_msg

--[[
KEYS[1] = mainQueueKey
ARGV[1] = SubscriberId
ARGV[2] = SubInfo&Msg
]]

local function enqueue_msg(KEYS, ARGV)
    local mainQKey = KEYS[1]
    local subscriberId = ARGV[1]
    local msg = ARGV[2]

    local t = redis.call('TIME')
    return redis.call("LPUSH", mainQKey, cmsgpack.pack({subscriberId, msg, t[1], t[2]}))
end

redis.register_function('enqueue_msg', enqueue_msg)
