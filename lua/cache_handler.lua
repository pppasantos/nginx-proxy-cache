local http = require "resty.http"
local cjson = require "cjson.safe"
local crypto = require "crypto"
local utils = require "utils"
local log = require "log"
local redis = require "redis"
 
local _M = {}
 
local function respond_from_cache(data, src)
    local ok, err = pcall(function()
        local skip_headers = utils.to_set(utils.split(ngx.var.cache_exclude_response_headers or "", ","))
        for k, v in pairs(data.headers or {}) do
            if not skip_headers[k:lower()] then
                ngx.header[k] = v
            end
        end
        ngx.header["X-Cache"] = src
        ngx.var.cache_status = src
        ngx.status = data.status
        if ngx.req.get_method() ~= "HEAD" then
            ngx.print(data.body)
        end
    end)
    if not ok then
        log.log_err("⚠️ Failed to send cached response: ", err)
    else
        --log.log_warn("Responding from cache [", src, "]")
    end
end
 
function _M.handle()
    local method = ngx.req.get_method()
    local treat_head_as_get = ngx.var.treat_head_as_get == "true"
    local cache_methods = utils.to_set(utils.split(ngx.var.cache_methods or "", ","))
    local cache_statuses = utils.to_set(utils.split(ngx.var.cache_statuses or "", ","), true)
    local cache_headers = utils.split(ngx.var.cache_headers or "", ",")
    local use_body_in_key = ngx.var.cache_use_body_in_key == "true"
    local ttl = tonumber(ngx.var.redis_ttl) or 3600
 
    --log.log_warn("Request method: ", method)
    --log.log_warn("Cacheable methods: ", ngx.var.cache_methods)
    --log.log_warn("Cacheable statuses: ", ngx.var.cache_statuses)
    --log.log_warn("Configured TTL: ", ttl)
 
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
 
    --log.log_warn("Generated Cache Key: ", key_hash)
 
    local red_read = redis.get_redis_client(true)
    local red_write = redis.get_redis_client(false)
    if not red_read or not red_write then
        log.log_err("Error initializing Redis")
        return ngx.exit(500)
    end
 
    if not cache_methods[method] then
        --log.log_warn("Non-cached method: ", method)
        local httpc = http.new()
        httpc:set_timeout(tonumber(ngx.var.lua_backend_timeout) or 3000)
        local backend_method = (method == "HEAD" and ngx.var.treat_head_as_get == "true") and "GET" or method
        --log.log_warn("Backend request: method = ", backend_method, " URI = ", raw_uri)
        local url = ngx.var.backend_url_scheme .. "://" .. ngx.var.backend_url_host .. ":" .. ngx.var.backend_host_port .. raw_uri
        local res, err = httpc:request_uri(url, {
            method = backend_method,
            body = body_data,
            headers = headers,
            ssl_verify = ngx.var.lua_ssl_verify == "true"
        })
 
        if not res then
            log.log_err("Backend error: ", err)
            ngx.status = 502
            if not ngx.headers_sent then ngx.say("Error consulting backend") end
            return ngx.exit(502)
        end
 
        --log.log_warn("Backend response received with status: ", res.status)
        for k, v in pairs(res.headers) do
            if k:lower() ~= "transfer-encoding" and k:lower() ~= "connection" then ngx.header[k] = v end
        end
        ngx.status = res.status
        if method ~= "HEAD" then ngx.print(res.body) end
        return ngx.exit(res.status)
    end
 
    if not redis.acquire_lock(red_write, lock_key) then
        red_read:close(); red_write:close()
        return redis.respond_locked(red_read, key_hash, respond_from_cache)
    end
 
    local cached = redis.fetch_cache(red_read, key_hash)
    if cached then
        --log.log_warn("Cache populated between lock and fetch: ", key_hash)
        red_write:del(lock_key)
        red_read:close(); red_write:close()
        return respond_from_cache(cached, "HIT")
    end
 
    --log.log_warn("Confirmed cache MISS, proceeding to backend: ", raw_uri)
    ngx.header["X-Cache"] = "MISS"
    ngx.var.cache_status = "MISS"
 
    local httpc = http.new()
    httpc:set_timeout(tonumber(ngx.var.lua_backend_timeout) or 3000)
    local backend_method = (method == "HEAD" and treat_head_as_get) and "GET" or method
    --log.log_warn("Backend request: method = ", backend_method, " URI = ", raw_uri)
 
    local url = ngx.var.backend_url_scheme .. "://" .. ngx.var.backend_url_host .. ":" .. ngx.var.backend_host_port .. raw_uri
    local res, err = httpc:request_uri(url, {
        method = backend_method,
        body = body_data,
        headers = headers,
        ssl_verify = ngx.var.lua_ssl_verify == "true"
    })
 
    if not res then
        log.log_err("Backend error: ", err)
        local stale = redis.fetch_cache(red_read, key_hash)
        if stale then
            --log.log_warn("Serving stale cache due to error: ", key_hash)
            red_write:del(lock_key)
            red_read:close(); red_write:close()
            return respond_from_cache(stale, "STALE-IF-ERROR")
        end
        ngx.status = 502
        if not ngx.headers_sent then ngx.say("Error consulting backend") end
        red_write:del(lock_key)
        red_read:close(); red_write:close()
        return ngx.exit(502)
    end
 
    --log.log_warn("Backend response received with status: ", res.status)
    if cache_methods[method] and cache_statuses[tostring(res.status)] then
        local filtered = {}
        for k, v in pairs(res.headers) do
            if k:lower() == "content-type" or k:lower() == "etag" or k:lower() == "cache-control" then
                filtered[k] = v
            end
        end
 
        local payload = cjson.encode({ status = res.status, headers = filtered, body = res.body })
        if payload then
            local encrypted = crypto.encrypt(payload)
            local ok, err = red_write:set(key_hash, encrypted)
            if ok then
                local check_val, check_err = red_write:get(key_hash)
                if check_val and check_val ~= ngx.null then
                    local ttl_set, ttl_err = red_write:expire(key_hash, ttl)
                    if ttl_set then
                        --log.log_warn("Response saved to cache: ", key_hash)
                    else
                        log.log_err("Error setting TTL: ", ttl_err)
                    end
                else
                    log.log_err("Failed to verify key in Redis: ", check_err)
                end
            else
                log.log_err("Error saving to Redis: ", err)
            end
        else
            log.log_err("Error serializing response for cache")
        end
    else
        --log.log_warn("Method or status not allowed for cache. Not storing.")
    end
 
    for k, v in pairs(res.headers) do
        if k:lower() ~= "transfer-encoding" and k:lower() ~= "connection" then ngx.header[k] = v end
    end
    ngx.status = res.status
    if method ~= "HEAD" then ngx.print(res.body) end
 
    --log.log_warn("✅ Finishing request, cleaning lock")
    red_write:del(lock_key)
    red_read:close(); red_write:close()
end
 
return _M