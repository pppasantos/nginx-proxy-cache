local redis = require "resty.redis"
local log = require "log"
local cjson = require "cjson.safe"
local crypto = require "crypto"
 
local _M = {}
 
function _M.get_redis_client(read_only)
    local red = redis:new()
    local redis_timeout = tonumber(ngx.var.redis_timeout) or 1000
    red:set_timeout(redis_timeout)

    local host = read_only and (ngx.var.redis_read_host or ngx.var.redis_host)
                 or (ngx.var.redis_write_host or ngx.var.redis_host)
    local port = tonumber(ngx.var.redis_port) or 6379
    local ok, err = red:connect(host, port)
    if not ok then
        log.log_err("Failed to connect to Redis ("..(read_only and "READ" or "WRITE").."): ", err)
        return nil
    end

    -- AUTH opcional: só autentica se uma senha estiver configurada.
    -- Com usuário preenchido usa ACL do Redis 6+ (AUTH <user> <pass>);
    -- sem usuário cai no modo legado (AUTH <pass>, equivale ao usuário "default").
    local username = ngx.var.redis_username
    local password = ngx.var.redis_password
    if password and password ~= "" then
        local auth_ok, auth_err
        if username and username ~= "" then
            auth_ok, auth_err = red:auth(username, password)
        else
            auth_ok, auth_err = red:auth(password)
        end
        if not auth_ok then
            log.log_err("Failed to authenticate to Redis: ", auth_err)
            red:close()
            return nil
        end
    end

    return red
end

-- Devolve a conexão ao pool de keepalive (em vez de fechá-la), para que o
-- redis_pool_size seja efetivamente reaproveitado. set_keepalive só pode ser
-- chamado em uma conexão aberta e saudável; se a conexão estiver em estado ruim
-- (ex.: timeout no meio de um comando), caímos para close() para não poluir o pool.
function _M.release(red)
    if not red then return end
    local keepalive_timeout = tonumber(ngx.var.redis_keepalive_timeout) or 60000
    local pool_size = tonumber(ngx.var.redis_pool_size) or 100
    local ok, err = red:set_keepalive(keepalive_timeout, pool_size)
    if not ok then
        log.log_warn("Failed to set Redis keepalive, closing connection: ", err)
        pcall(function() red:close() end)
    end
end
 
function _M.acquire_lock(red, key, owner_id)
    local lock_ttl = math.ceil((tonumber(ngx.var.lua_backend_timeout) or 3000) / 1000) + 1
    local ok, err = red:set(key, owner_id, "EX", lock_ttl, "NX")
    if ok ~= "OK" then
        log.log_info("Lock not acquired (held by another request): ", key)
    else
        log.log_info("Lock successfully acquired: ", key, " with owner: ", owner_id)
    end
    return ok == "OK"
end
 
function _M.fetch_cache(red, key)
    local val = red:get(key)
    if val and val ~= ngx.null then
        local decrypted = crypto.decrypt(val)
        if not decrypted then
            log.log_warn("Failed to decrypt cache: ", key)
            return nil
        end
        local data = cjson.decode(decrypted)
        if data then return data end
        log.log_warn("Failed to decode cache: ", key)
    else
        log.log_warn("Cache missing for key: ", key)
    end
end

return _M