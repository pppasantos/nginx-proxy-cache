local redis = require "resty.redis"
local cjson = require "cjson.safe"
local _M = {}

local function log_err(msg, ...) ngx.log(ngx.ERR, "❌ [invalidate] ", msg, ...) end
local function log_info(msg, ...) ngx.log(ngx.INFO, "✅ [invalidate] ", msg, ...) end

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
        return ngx.say("Corpo da requisição ausente ou inválido.")
    end

    local decoded, err = cjson.decode(body_data)
    if not decoded or type(decoded.keys) ~= "table" then
        ngx.status = 400
        return ngx.say("Formato inválido. Esperado: { \"keys\": [\"chave1\", \"chave2\"] }")
    end

    local red = redis:new()
    red:set_timeout(1000)
    local ok, err = red:connect(ngx.var.redis_write_host or "127.0.0.1", 6379)
    if not ok then
        log_err("Falha ao conectar ao Redis: ", err)
        ngx.status = 500
        return ngx.say("Erro de conexão Redis: ", err)
    end

    local deleted = 0
    local removed_keys = {}

    for _, key in ipairs(decoded.keys) do
        local res, err = red:del(key)
        if res and res > 0 then
            deleted = deleted + res
            table.insert(removed_keys, key)
        elseif err then
            log_err("Erro ao deletar chave: ", key, " -> ", err)
        end
    end

    log_info("Total removed: ", deleted, " | keys: ", table.concat(removed_keys, ", "))

    ngx.header.content_type = "application/json"
    ngx.say(cjson.encode({
        deleted = deleted,
        removed_keys = removed_keys
    }))

    local ok, err = red:set_keepalive(10000, 100)
    if not ok then
        log_err("Erro ao liberar conexão: ", err)
    end
end

return _M
