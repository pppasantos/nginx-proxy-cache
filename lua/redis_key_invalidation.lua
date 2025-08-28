local cjson = require "cjson.safe"
local redis = require "redis"
local log = require "log"
 
local _M = {}
 
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
 
    -- Usando a função do redis.lua para obter cliente Redis
    local red = redis.get_redis_client(false)  -- false para write host
    if not red then
        log.log_err("Falha ao conectar ao Redis")
        ngx.status = 500
        return ngx.say("Erro de conexão Redis")
    end
 
    local deleted = 0
    local removed_keys = {}
 
    for _, key in ipairs(decoded.keys) do
        local res, err = red:del(key)
        if res and res > 0 then
            deleted = deleted + res
            table.insert(removed_keys, key)
            log.log_info("Chave removida: ", key)
        elseif err then
            log.log_err("Erro ao deletar chave: ", key, " -> ", err)
        end
    end
 
    log.log_info("Total removido: ", deleted, " | chaves: ", table.concat(removed_keys, ", "))
 
    ngx.header.content_type = "application/json"
    ngx.say(cjson.encode({
        deleted = deleted,
        removed_keys = removed_keys
    }))
end
 
return _M