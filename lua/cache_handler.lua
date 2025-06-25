local redis = require "resty.redis"
local http = require "resty.http"
local cjson = require "cjson.safe"

local _M = {}

local function split(str, sep)
    local t = {}
    for s in string.gmatch(str, "([^"..sep.."]+)") do
        t[#t+1] = s
    end
    return t
end

local function to_set(list, force_string)
    local s = {}
    for _, v in ipairs(list) do
        s[force_string and tostring(v) or v] = true
    end
    return s
end

local function log_err(msg, ...) ngx.log(ngx.ERR, "❌ ", msg, ...) end
local function log_warn(msg, ...) ngx.log(ngx.ERR, "⚠️ ", msg, ...) end

local function get_redis_client(read_only)
    local red = redis:new()
    local redis_timeout = tonumber(ngx.var.redis_timeout) or 1000
    red:set_timeout(redis_timeout)
    red:set_keepalive(60000, tonumber(ngx.var.redis_pool_size or 100))
    local host = read_only and (ngx.var.redis_read_host or ngx.var.redis_host)
                 or (ngx.var.redis_write_host or ngx.var.redis_host)
    local ok, err = red:connect(host, 6379)
    if not ok then
        log_err("Failed to connect to Redis ("..(read_only and "READ" or "WRITE").."): ", err)
        return nil
    end
    return red
end

local function acquire_lock(red, key)
    local lock_ttl = math.ceil((tonumber(ngx.var.lua_backend_timeout) or 3000) / 1000) + 1
    local ok, err = red:set(key, "locked", "EX", lock_ttl, "NX")
    if ok ~= "OK" then
        --log_warn("Lock not acquired: ", key)
    else
        --log_warn("Lock successfully acquired: ", key)
    end
    return ok == "OK"
end

local function fetch_cache(red, key)
    local val = red:get(key)
    if val and val ~= ngx.null then
        local data = cjson.decode(val)
        if data then return data end
        --log_warn("Failed to decode cache: ", key)
    else
        --log_warn("Cache missing for key: ", key)
    end
end

local function respond_from_cache(data, src)
    for k, v in pairs(data.headers or {}) do ngx.header[k] = v end
    ngx.header["X-Cache"] = src
    ngx.var.cache_status = src
    ngx.status = data.status
    if ngx.req.get_method() ~= "HEAD" then ngx.print(data.body) end
end

local function respond_locked()
    ngx.status = 503
    ngx.header["Retry-After"] = 2
    if not ngx.headers_sent then
        ngx.say("Request is being processed, retry shortly.")
    end
end

function _M.handle()
    local method = ngx.req.get_method()
    local treat_head_as_get = ngx.var.treat_head_as_get == "true"
    local cache_methods = to_set(split(ngx.var.cache_methods or "", ","))
    local cache_statuses = to_set(split(ngx.var.cache_statuses or "", ","), true)
    local cache_headers = split(ngx.var.cache_headers or "", ",")
    local use_body_in_key = ngx.var.cache_use_body_in_key == "true"
    local ttl = tonumber(ngx.var.redis_ttl) or 3600

    --log_warn("Request method: ", method)
    --log_warn("Cacheable methods: ", ngx.var.cache_methods)
    --log_warn("Cacheable statuses: ", ngx.var.cache_statuses)
    --log_warn("Configured TTL: ", ttl)

    ngx.req.read_body()
    local body_data = ngx.req.get_body_data() or ""
    local raw_uri = ngx.var.request_uri
    local headers = ngx.req.get_headers()

    local key = ngx.var.scheme .. method .. raw_uri
    for _, h in ipairs(cache_headers) do
        local val = headers[h]
        if val then key = key .. "|" .. h .. "=" .. val end
    end
    if use_body_in_key and (method == "POST" or method == "PUT" or method == "PATCH") then
        key = key .. "|" .. body_data
    end
    local key_hash = ngx.md5(key)
    ngx.var.cache_key = key_hash
    local lock_key = "lock:" .. key_hash

    --log_warn("Generated Cache Key: ", key_hash)

    local red_read = get_redis_client(true)
    local red_write = get_redis_client(false)
    if not red_read or not red_write then
        log_err("Error initializing Redis")
        return ngx.exit(500)
    end

    -- Check if the method is not in the cacheable methods list
    if not cache_methods[method] then
        --log_warn("Non-cached method: ", method)

        -- Send directly to backend without passing through cache
        local httpc = http.new()
        httpc:set_timeout(tonumber(ngx.var.lua_backend_timeout) or 3000)

        local backend_method = (method == "HEAD" and ngx.var.treat_head_as_get == "true") and "GET" or method
        --log_warn("Backend request: method = ", backend_method, " URI = ", raw_uri)

        local url = ngx.var.backend_url_scheme .. "://" ..
            ngx.var.backend_url_host .. ":" ..
            ngx.var.backend_host_port .. raw_uri

        local res, err = httpc:request_uri(url, {
            method = backend_method,
            body = body_data,
            headers = headers,
            ssl_verify = ngx.var.lua_ssl_verify == "true"
        })


        if not res then
            log_err("Backend error: ", err)
            ngx.status = 502
            if not ngx.headers_sent then
                ngx.say("Error consulting backend")
            end
            return ngx.exit(502)
        end

        --log_warn("Backend response received with status: ", res.status)

        -- Send the backend response
        for k, v in pairs(res.headers) do
            if k:lower() ~= "transfer-encoding" and k:lower() ~= "connection" then
                ngx.header[k] = v
            end
        end
        ngx.status = res.status
        if method ~= "HEAD" then ngx.print(res.body) end

        return ngx.exit(res.status)
    end

    -- If the method is in cache_methods, continue with the cache process
    if not acquire_lock(red_write, lock_key) then
        local cached = fetch_cache(red_read, key_hash)
        if cached then
            --log_warn("Serving cache during lock: ", key_hash)
            red_read:close(); red_write:close()
            return respond_from_cache(cached, "HIT")
        end
        --log_warn("No cache and lock active: ", key_hash)
        red_read:close(); red_write:close()
        return respond_locked()
    end

    local cached = fetch_cache(red_read, key_hash)
    if cached then
        --log_warn("Cache populated between lock and fetch: ", key_hash)
        red_write:del(lock_key)
        red_read:close(); red_write:close()
        return respond_from_cache(cached, "HIT")
    end

    --log_warn("Confirmed cache MISS, proceeding to backend: ", raw_uri)
    ngx.header["X-Cache"] = "MISS"
    ngx.var.cache_status = "MISS"

    local httpc = http.new()
    httpc:set_timeout(tonumber(ngx.var.lua_backend_timeout) or 3000)

    local backend_method = (method == "HEAD" and treat_head_as_get) and "GET" or method
    --log_warn("Backend request: method = ", backend_method, " URI = ", raw_uri)

    local url = ngx.var.backend_url_scheme .. "://" ..
        ngx.var.backend_url_host .. ":" ..
        ngx.var.backend_host_port .. raw_uri

    local res, err = httpc:request_uri(url, {
        method = backend_method,
        body = body_data,
        headers = headers,
        ssl_verify = ngx.var.lua_ssl_verify == "true"
        })

    if not res then
        log_err("Backend error: ", err)
        local stale = fetch_cache(red_read, key_hash)
        if stale then
            --log_warn("Serving stale cache due to error: ", key_hash)
            red_write:del(lock_key)
            red_read:close(); red_write:close()
            return respond_from_cache(stale, "STALE-IF-ERROR")
        end
        ngx.status = 502
        if not ngx.headers_sent then
            ngx.say("Error consulting backend")
        end
        red_write:del(lock_key)
        red_read:close(); red_write:close()
        return ngx.exit(502)
    end

    --log_warn("Backend response received with status: ", res.status)

    if cache_methods[method] and cache_statuses[tostring(res.status)] then
        local filtered = {}
        for k, v in pairs(res.headers) do
            if k:lower() == "content-type" or k:lower() == "etag" or k:lower() == "cache-control" then
                filtered[k] = v
            end
        end

        local payload = cjson.encode({ status = res.status, headers = filtered, body = res.body })
        if payload then
            local ok, err = red_write:set(key_hash, payload)
            if ok then
                local check_val, check_err = red_write:get(key_hash)
                if check_val and check_val ~= ngx.null then
                    local ttl_set, ttl_err = red_write:expire(key_hash, ttl)
                    if ttl_set then
                        --log_warn("Response saved to cache: ", key_hash)
                    else
                        log_err("Error setting TTL: ", ttl_err)
                    end
                else
                    log_err("Failed to verify key in Redis: ", check_err)
                end
            else
                log_err("Error saving to Redis: ", err)
            end
        else
            log_err("Error serializing response for cache")
        end
    else
        --log_warn("Method or status not allowed for cache. Not storing.")
    end

    for k, v in pairs(res.headers) do
        if k:lower() ~= "transfer-encoding" and k:lower() ~= "connection" then
            ngx.header[k] = v
        end
    end
    ngx.status = res.status
    if method ~= "HEAD" then ngx.print(res.body) end

    --log_warn("✅ Finishing request, cleaning lock")
    red_write:del(lock_key)
    red_read:close(); red_write:close()
end

return _M
