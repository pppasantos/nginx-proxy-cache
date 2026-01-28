local redis = require "resty.redis"
local log = require "log"
local cjson = require "cjson.safe"
local crypto = require "crypto"
 
local _M = {}
 
function _M.get_redis_client(read_only)
    local red = redis:new()
    local redis_timeout = tonumber(ngx.var.redis_timeout) or 1000
    red:set_timeout(redis_timeout)
    red:set_keepalive(60000, tonumber(ngx.var.redis_pool_size or 100))
    local host = read_only and (ngx.var.redis_read_host or ngx.var.redis_host)
                 or (ngx.var.redis_write_host or ngx.var.redis_host)
    local ok, err = red:connect(host, 6379)
    if not ok then
        log.log_err("Failed to connect to Redis ("..(read_only and "READ" or "WRITE").."): ", err)
        return nil
    end
    return red
end
 
function _M.acquire_lock(red, key, owner_id)
    local lock_ttl = math.ceil((tonumber(ngx.var.lua_backend_timeout) or 3000) / 1000) + 1
    local ok, err = red:set(key, owner_id, "EX", lock_ttl, "NX")
    if ok ~= "OK" then
        log.log_warn("Lock not acquired: ", key)
    else
        log.log_warn("Lock successfully acquired: ", key, " with owner: ", owner_id)
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