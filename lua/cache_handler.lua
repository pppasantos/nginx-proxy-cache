local http = require "resty.http"
local cjson = require "cjson.safe"
local crypto = require "crypto"
local utils = require "utils"
local log = require "log"
local redis = require "redis"
 
local _M = {}
 
-- Fecha ambas as conexões Redis de forma segura
local function close_redis(red_read, red_write)
    if red_read  then red_read:close()  end
    if red_write then red_write:close() end
end
 
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
        log.log_err("Failed to send cached response: ", err)
    else
        log.log_info("Responding from cache [", src, "]")
    end
    return ngx.exit(ngx.status)
end
 
-- Envia resposta do backend para o cliente
local function send_backend_response(res, method)
    for k, v in pairs(res.headers) do
        if k:lower() ~= "transfer-encoding" and k:lower() ~= "connection" then
            ngx.header[k] = v
        end
    end
    ngx.status = res.status
    if method ~= "HEAD" then ngx.print(res.body) end
    return ngx.exit(res.status)
end
 
function _M.handle()
    local method = ngx.req.get_method()
    local treat_head_as_get = ngx.var.treat_head_as_get == "true"
    local cache_methods = utils.to_set(utils.split(ngx.var.cache_methods or "", ","))
    local cache_statuses = utils.to_set(utils.split(ngx.var.cache_statuses or "", ","), true)
    local cache_headers = utils.split(ngx.var.cache_headers or "", ",")
    local use_body_in_key = ngx.var.cache_use_body_in_key == "true"
    local ttl = tonumber(ngx.var.redis_ttl) or 3600
 
    log.log_info("Request method: ", method)
    log.log_info("Cacheable methods: ", ngx.var.cache_methods)
    log.log_info("Cacheable statuses: ", ngx.var.cache_statuses)
    log.log_info("Configured TTL: ", ttl)
 
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
 
    -- ID único deste request para ownership do lock
    local owner_id = ngx.var.request_id or ngx.var.msec
 
    log.log_info("Generated Cache Key: ", key_hash)
 
    local red_read = redis.get_redis_client(true)
    local red_write = redis.get_redis_client(false)
    if not red_read or not red_write then
        log.log_err("Error initializing Redis")
        close_redis(red_read, red_write)
        return ngx.exit(500)
    end
 
    -- Métodos não cacheáveis: proxy direto sem tocar no Redis
    if not cache_methods[method] then
        log.log_warn("Non-cached method: ", method)
        close_redis(red_read, red_write)
 
        local httpc = http.new()
        httpc:set_timeout(tonumber(ngx.var.lua_backend_timeout) or 3000)
        local backend_method = (method == "HEAD" and treat_head_as_get) and "GET" or method
        log.log_info("Backend request: method = ", backend_method, " URI = ", raw_uri)
 
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
 
        log.log_info("Backend response received with status: ", res.status)
        return send_backend_response(res, method)
    end
 
    -- Cache HIT?
    local cached = redis.fetch_cache(red_read, key_hash)
    if cached then
        log.log_info("Cache HIT: ", key_hash)
        close_redis(red_read, red_write)
        return respond_from_cache(cached, "HIT")
    end
 
    -- Cache MISS — verificar se há lock ativo de outro request
    local lock_owner = red_read:get(lock_key)
    local i_own_lock = false
 
    if lock_owner and lock_owner ~= ngx.null then
        -- Lock de outro request: bypass direto ao backend sem armazenar
        log.log_info("Lock found (owner: ", lock_owner, "), bypassing to backend: ", key_hash)
        ngx.header["X-Cache"] = "LOCKED-BYPASS"
        ngx.var.cache_status = "LOCKED-BYPASS"
    else
        -- Sem lock: tentar adquirir ownership
        if not redis.acquire_lock(red_write, lock_key, owner_id) then
            close_redis(red_read, red_write)
            return ngx.exit(500)
        end
        i_own_lock = true
        log.log_info("Lock acquired with owner: ", owner_id)
        ngx.header["X-Cache"] = "MISS"
        ngx.var.cache_status = "MISS"
    end
 
    local httpc = http.new()
    httpc:set_timeout(tonumber(ngx.var.lua_backend_timeout) or 3000)
    local backend_method = (method == "HEAD" and treat_head_as_get) and "GET" or method
    log.log_info("Backend request: method = ", backend_method, " URI = ", raw_uri)
 
    local url = ngx.var.backend_url_scheme .. "://" .. ngx.var.backend_url_host .. ":" .. ngx.var.backend_host_port .. raw_uri
    local res, err = httpc:request_uri(url, {
        method = backend_method,
        body = body_data,
        headers = headers,
        ssl_verify = ngx.var.lua_ssl_verify == "true"
    })
 
    if not res then
        log.log_err("Backend error: ", err)
        -- Tentar servir cache stale se disponível
        local stale = redis.fetch_cache(red_read, key_hash)
        if i_own_lock then red_write:del(lock_key) end
        close_redis(red_read, red_write)
        if stale then
            log.log_warn("Serving stale cache due to backend error: ", key_hash)
            return respond_from_cache(stale, "STALE-IF-ERROR")
        end
        ngx.status = 502
        if not ngx.headers_sent then ngx.say("Error consulting backend") end
        return ngx.exit(502)
    end
 
    log.log_info("Backend response received with status: ", res.status)
 
    -- Armazenar no cache apenas se dono do lock e status/método elegíveis
    if i_own_lock and cache_methods[method] and cache_statuses[tostring(res.status)] then
        local filtered = {}
        for k, v in pairs(res.headers) do
            local lk = k:lower()
            if lk == "content-type" or lk == "etag" or lk == "cache-control" then
                filtered[k] = v
            end
        end
 
        local payload = cjson.encode({ status = res.status, headers = filtered, body = res.body })
        if payload then
            local encrypted = crypto.encrypt(payload)
            if not encrypted then
                log.log_err("Encryption failed, skipping cache storage")
            else
                -- SET com EX atômico: evita chave sem TTL se o processo morrer entre SET e EXPIRE
                local ok, set_err = red_write:set(key_hash, encrypted, "EX", ttl)
                if ok == "OK" then
                    log.log_info("Response saved to cache: ", key_hash, " (TTL: ", ttl, "s)")
                else
                    log.log_err("Error saving to Redis: ", set_err)
                end
            end
        else
            log.log_err("Error serializing response for cache")
        end
    elseif not i_own_lock then
        log.log_info("Not lock owner, skipping cache storage")
    else
        log.log_warn("Method or status not eligible for cache. Not storing.")
    end
 
    log.log_info("Finishing request, cleaning lock")
    if i_own_lock then red_write:del(lock_key) end
    close_redis(red_read, red_write)
 
    return send_backend_response(res, method)
end
 
return _M