local cjson = require "cjson.safe"
local cache_key = require "cache_key"
local redis = require "redis"
local log = require "log"
 
local _M = {}

local function normalize_request_definition(def)
    local cache_headers = def.cache_headers

    if type(cache_headers) == "string" then
        cache_headers = cache_key.parse_cache_headers(cache_headers)
    elseif type(cache_headers) ~= "table" then
        cache_headers = cache_key.parse_cache_headers(ngx.var.cache_headers or "")
    end

    return {
        scheme = def.scheme or ngx.var.scheme,
        method = def.method or "GET",
        raw_uri = def.uri or def.raw_uri,
        headers = def.headers or {},
        body = def.body or "",
        cache_headers = cache_headers,
        use_body_in_key = def.cache_use_body_in_key == true
            or def.cache_use_body_in_key == "true"
            or (def.cache_use_body_in_key == nil and ngx.var.cache_use_body_in_key == "true"),
    }
end

local function derive_keys_from_requests(requests)
    local derived_keys = {}

    for _, request_def in ipairs(requests or {}) do
        local normalized = normalize_request_definition(request_def)
        if normalized.raw_uri then
            table.insert(derived_keys, cache_key.build_hashed_key(normalized))
        end
    end

    return derived_keys
end
 
function _M.invalidate_key()
    if ngx.req.get_method() ~= "POST" then
        ngx.status = 405
        ngx.say("Use POST.")
        return
    end
 
    ngx.req.read_body()
    local body_data = ngx.req.get_body_data()
    if not body_data then
        ngx.status = 400
        return ngx.say("Request body missing or invalid.")
    end
 
    local decoded, err = cjson.decode(body_data)
    if not decoded then
        ngx.status = 400
        return ngx.say("Invalid JSON payload.")
    end

    local keys = {}
    if type(decoded.keys) == "table" then
        for _, key in ipairs(decoded.keys) do
            table.insert(keys, key)
        end
    end

    local derived_keys = derive_keys_from_requests(decoded.requests)
    for _, key in ipairs(derived_keys) do
        table.insert(keys, key)
    end

    if #keys == 0 then
        ngx.status = 400
        return ngx.say("Invalid format. Expected: { \"keys\": [\"key1\"], \"requests\": [{ \"uri\": \"/path\", \"method\": \"GET\" }] }")
    end
 
    -- Using the function from redis.lua to get Redis client
    local red = redis.get_redis_client(false)  -- false for write host
    if not red then
        log.log_err("Failed to connect to Redis")
        ngx.status = 500
        return ngx.say("Redis connection error")
    end
 
    local deleted = 0
    local removed_keys = {}
 
    for _, key in ipairs(keys) do
        local res, err = red:del(key)
        if res and res > 0 then
            deleted = deleted + res
            table.insert(removed_keys, key)
            log.log_info("Key removed: ", key)
        elseif err then
            log.log_err("Error deleting key: ", key, " -> ", err)
        end
    end
 
    log.log_info("Total deleted: ", deleted, " | keys: ", table.concat(removed_keys, ", "))
 
    ngx.header.content_type = "application/json"
    ngx.say(cjson.encode({
        deleted = deleted,
        removed_keys = removed_keys,
        requested_keys = keys,
        derived_keys = derived_keys,
    }))
end
 
return _M
