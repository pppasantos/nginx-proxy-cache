local redis = require "resty.redis"
local _M = {}

local function log_err(msg, ...) ngx.log(ngx.ERR, "❌ ", msg, ...) end
local function log_info(msg, ...) ngx.log(ngx.INFO, "✅ ", msg, ...) end

function _M.invalidate_key()
    local red = redis:new()
    red:set_timeout(1000)

    local redis_host = ngx.var.redis_write_host  or "127.0.0.1"
    local ok, err = red:connect(ngx.var.redis_write_host, 6379)
    if not ok then
        log_err("Falha ao conectar ao Redis: ", err)
        ngx.status = 500
        return ngx.say("Erro de conexão Redis: ", err)
    end

    local args = ngx.req.get_uri_args()
    local keys = args["key"]

    if not keys then
        ngx.status = 400
        return ngx.say("Parâmetro 'key' é necessário")
    end

    if type(keys) == "string" then
        keys = { keys }
    end

    local deleted = 0
    local removed_keys = {}

    for _, key in ipairs(keys) do
        local res, err = red:del(key)
        if res and res > 0 then
            deleted = deleted + res
            table.insert(removed_keys, key)
        elseif err then
            log_err("Erro ao deletar chave: ", key, " -> ", err)
        end
    end

    if #removed_keys > 0 then
        log_info("Chaves removidas: ", table.concat(removed_keys, ", "))
    else
        log_info("Nenhuma chave removida")
    end

    ngx.header.content_type = "application/json"
    ngx.say(require("cjson").encode({
        deleted = deleted,
        removed_keys = removed_keys
    }))

    local ok, err = red:set_keepalive(10000, 100)
    if not ok then
        log_err("Erro ao liberar conexão: ", err)
    end
end

return _M