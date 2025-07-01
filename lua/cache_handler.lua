local redis = require "resty.redis"
local cjson = require "cjson.safe"
local lock = require "resty.lock"
local utils = require("utils")

local split = utils.split
local to_set = utils.to_set
local log_err = utils.log_err
local log_warn = utils.log_warn
local call_backend = utils.call_backend

local _M = {}

local function get_redis_client(read_only)
    local ctx_key = read_only and "red_read" or "red_write"
    if ngx.ctx[ctx_key] then return ngx.ctx[ctx_key] end

    local red = redis:new()
    local redis_timeout = tonumber(ngx.var.redis_timeout) or 1000
    red:set_timeout(redis_timeout)
    red:set_keepalive(60000, tonumber(ngx.var.redis_pool_size or 100))
    local host = read_only and (ngx.var.redis_read_host or ngx.var.redis_host)
                 or (ngx.var.redis_write_host or ngx.var.redis_host)
    local ok, err = red:connect(host, 6379)
    if not ok then
        log_err("Redis ", read_only and "READ" or "WRITE", " error: ", err)
        return nil
    end

    ngx.ctx[ctx_key] = red
    return red
end

local function acquire_lock(key)
    local l, err = lock:new("locks", {timeout = 2, exptime = 5})
    if not l then
        log_err("Failed to create lock: ", err)
        return nil
    end

    local elapsed, err = l:lock(key)
    if not elapsed then
        log_warn("Lock not acquired (wait timeout): ", key, " - ", err)
        return nil
    end

    log_warn("Lock acquired: ", key)
    return l
end

local function fetch_cache(red, key)
    local val = red:get(key)
    if val and val ~= ngx.null then
        local data = cjson.decode(val)
        if data then return data end
        log_warn("Failed to decode cache: ", key)
    else
        log_warn("Cache missing for key: ", key)
    end
end

local function respond_from_cache(data, src)
    local skip_headers = to_set(split(ngx.var.cache_exclude_response_headers or "", ","), false)
    for k, v in pairs(data.headers or {}) do
        if not skip_headers[k:lower()] then ngx.header[k] = v end
    end
    ngx.header["X-Cache"] = src
    ngx.var.cache_status = src
    ngx.status = data.status
    local body = ngx.decode_base64(data.body)
    if ngx.req.get_method() ~= "HEAD" then ngx.print(body) end
    log_warn("Responding from cache [", src, "]")
end

local function respond_locked()
    log_warn("Request locked and no cache available")
    ngx.status = 503
    ngx.header["Retry-After"] = 2
    if not ngx.headers_sent then ngx.say("Request is being processed, retry shortly.") end
end

function _M.handle()
    local method = ngx.req.get_method()
    local treat_head_as_get = ngx.var.treat_head_as_get == "true"
    local cache_methods = to_set(split(ngx.var.cache_methods or "", ","))
    local cache_statuses = to_set(split(ngx.var.cache_statuses or "", ","), true)
    local cache_headers = split(ngx.var.cache_headers or "", ",")
    local use_body_in_key = ngx.var.cache_use_body_in_key == "true"
    local ttl = tonumber(ngx.var.redis_ttl) or 3600

    local body_data = ""
    if method == "POST" or method == "PUT" or method == "PATCH" then
        ngx.req.read_body()
        body_data = ngx.req.get_body_data() or ""
    end

    local raw_uri = ngx.var.request_uri
    local headers = ngx.req.get_headers()

    local key = ngx.var.scheme .. method .. raw_uri
    for _, h in ipairs(cache_headers) do
        local val = headers[h]
        if val then key = key .. "|" .. h .. "=" .. val end
    end
    if use_body_in_key then key = key .. "|" .. body_data end

    local key_hash = ngx.md5(key)
    local lock_key = "lock:" .. key_hash
    ngx.var.cache_key = key_hash
    log_warn("Generated cache key: ", key_hash)

    local red_read = get_redis_client(true)
    local red_write = get_redis_client(false)
    if not red_read or not red_write then return ngx.exit(500) end

    if not cache_methods[method] then
        log_warn("Non-cacheable method: ", method)
        local backend_method = (method == "HEAD" and treat_head_as_get) and "GET" or method
        local url = ngx.var.backend_url_scheme .. "://" .. ngx.var.backend_url_host .. ":" .. ngx.var.backend_host_port .. raw_uri

        local res, err = call_backend(backend_method, url, body_data, headers)
        if not res then
            log_err("Backend error: ", err)
            ngx.status = 502
            if not ngx.headers_sent then ngx.say("Error consulting backend") end
            return ngx.exit(502)
        end

        log_warn("Backend response (no cache): ", res.status)
        for k, v in pairs(res.headers) do
            if k:lower() ~= "transfer-encoding" and k:lower() ~= "connection" then ngx.header[k] = v end
        end
        ngx.status = res.status
        if method ~= "HEAD" then ngx.print(res.body) end
        return ngx.exit(res.status)
    end

    local lock_obj = acquire_lock(lock_key)
    if not lock_obj then
        local cached = fetch_cache(red_read, key_hash)
        if cached then
            red_read:close(); red_write:close()
            return respond_from_cache(cached, "HIT")
        end
        red_read:close(); red_write:close()
        return respond_locked()
    end

    local cached = fetch_cache(red_read, key_hash)
    if cached then
        log_warn("Cache appeared after lock: ", key_hash)
        local ok, err = lock_obj:unlock()
        if not ok then log_err("Failed to release lock: ", err) end
        red_read:close(); red_write:close()
        return respond_from_cache(cached, "HIT")
    end

    log_warn("Confirmed cache MISS for key: ", key_hash)
    ngx.header["X-Cache"] = "MISS"
    ngx.var.cache_status = "MISS"

    local backend_method = (method == "HEAD" and treat_head_as_get) and "GET" or method
    local url = ngx.var.backend_url_scheme .. "://" .. ngx.var.backend_url_host .. ":" .. ngx.var.backend_host_port .. raw_uri

    local res, err = call_backend(backend_method, url, body_data, headers)
    if not res then
        log_err("Backend error: ", err)
        local stale = fetch_cache(red_read, key_hash)
        if stale then
            log_warn("Serving stale cache due to backend error")
            local ok, err = lock_obj:unlock()
            if not ok then log_err("Failed to release lock: ", err) end
            red_read:close(); red_write:close()
            return respond_from_cache(stale, "STALE-IF-ERROR")
        end
        ngx.status = 502
        if not ngx.headers_sent then ngx.say("Error consulting backend") end
        local ok, err = lock_obj:unlock()
        if not ok then log_err("Failed to release lock: ", err) end
        red_read:close(); red_write:close()
        return ngx.exit(502)
    end

    log_warn("Backend response received: ", res.status)
    if cache_statuses[tostring(res.status)] then
        local filtered = {}
        for k, v in pairs(res.headers) do
            local kl = k:lower()
            if kl == "content-type" or kl == "etag" or kl == "cache-control"
               or kl == "expires" or kl == "content-length" then
                filtered[k] = v
            end
        end

        local body_encoded = ngx.encode_base64(res.body)
        local payload = cjson.encode({ status = res.status, headers = filtered, body = body_encoded })
        if payload then
            local ok = red_write:set(key_hash, payload, "EX", ttl)
            if ok then
                log_warn("Saved response to cache: ", key_hash)
            else
                log_err("Failed to save cache for ", key_hash)
            end
        else
            log_err("Serialization failure for cache payload")
        end
    else
        log_warn("Response not cached due to status or method")
    end

    for k, v in pairs(res.headers) do
        if k:lower() ~= "transfer-encoding" and k:lower() ~= "connection" then ngx.header[k] = v end
    end
    ngx.status = res.status
    if method ~= "HEAD" then ngx.print(res.body) end

    log_warn("Finishing request, removing lock")
    local ok, err = lock_obj:unlock()
    if not ok then log_err("Failed to release lock: ", err) end

    red_read:close(); red_write:close()
end

return _M
