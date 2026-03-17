local log = require "log"
local _M = {}
 
local openssl_cipher = require("openssl.cipher")
local openssl_rand   = require("openssl.rand")
 
-- Configuração de criptografia
local CIPHER_ALGO = "aes-256-cbc"
local KEY_SIZE    = 32
local IV_SIZE     = 16
 
-- Base64 helpers (usa ngx para encode/decode)
local b64 = {
    encode = ngx.encode_base64,
    decode = ngx.decode_base64,
}
 
--[[
  Resolução da chave/IV por request a partir das variáveis nginx.
  Não são cacheadas como upvalue de módulo porque:
    1. ngx.var é por-request e pode variar entre locations/vhosts.
    2. Um cache de módulo fixaria valores da primeira requisição para todas as seguintes.
  O overhead é mínimo pois são apenas leituras de string + base64 decode.
]]
local function resolve_config()
    local enabled = ngx.var.redis_crypto_enabled == "true"
    if not enabled then
        return false
    end
 
    local key_b64 = ngx.var.redis_crypto_key
    local iv_b64  = ngx.var.redis_crypto_iv
 
    if not key_b64 or not iv_b64 then
        log.log_err("crypto: redis_crypto_key ou redis_crypto_iv não configurados")
        return false
    end
 
    local key = b64.decode(key_b64)
    local iv  = b64.decode(iv_b64)
 
    if not key then
        log.log_err("crypto: falha ao decodificar redis_crypto_key (base64 inválido)")
        return false
    end
 
    if not iv then
        log.log_err("crypto: falha ao decodificar redis_crypto_iv (base64 inválido)")
        return false
    end
 
    if #key ~= KEY_SIZE then
        log.log_err("crypto: tamanho de chave inválido — esperado " .. KEY_SIZE .. " bytes, recebido " .. #key)
        return false
    end
 
    if #iv ~= IV_SIZE then
        log.log_err("crypto: tamanho de IV inválido — esperado " .. IV_SIZE .. " bytes, recebido " .. #iv)
        return false
    end
 
    return true, key, iv
end
 
--[[
  encrypt(plaintext) -> string|nil
  Retorna o payload cifrado como: base64( random_iv .. ciphertext )
  O IV aleatório (16 bytes) é prefixado no ciphertext para que cada
  mensagem tenha um IV único, evitando vulnerabilidades de CBC com IV fixo.
  Retorna nil em caso de erro; retorna plaintext diretamente se criptografia desabilitada.
]]
function _M.encrypt(plaintext)
    if type(plaintext) ~= "string" then
        log.log_err("crypto.encrypt: argumento não é string")
        return nil
    end
 
    local enabled, key, iv_config = resolve_config()
 
    -- Criptografia desabilitada: retorna o dado sem transformação
    if not enabled then
        return plaintext
    end
 
    -- Gera IV aleatório por operação (segurança CBC)
    local iv_random, rand_err = openssl_rand.bytes(IV_SIZE)
    if not iv_random then
        log.log_warn("crypto: falha ao gerar IV aleatório (" .. tostring(rand_err) .. "), usando IV de config")
        iv_random = iv_config
    end
 
    local cipher = openssl_cipher.new(CIPHER_ALGO)
    if not cipher then
        log.log_err("crypto: falha ao criar instância de cipher")
        return nil
    end
 
    local ok, encrypted = pcall(function()
        return cipher:encrypt(key, iv_random):final(plaintext)
    end)
 
    if not ok or not encrypted or encrypted == "" then
        log.log_err("crypto: falha na cifragem — " .. tostring(encrypted))
        return nil
    end
 
    -- Prefixar IV aleatório no ciphertext para que decrypt possa recuperá-lo
    return b64.encode(iv_random .. encrypted)
end
 
--[[
  decrypt(ciphertext) -> string|nil
  Espera o formato produzido por encrypt(): base64( random_iv .. ciphertext )
  Extrai os primeiros IV_SIZE bytes como IV e decifra o restante.
  Retorna nil em caso de erro; retorna ciphertext diretamente se criptografia desabilitada.
]]
function _M.decrypt(ciphertext)
    if type(ciphertext) ~= "string" then
        log.log_err("crypto.decrypt: argumento não é string")
        return nil
    end
 
    local enabled, key, _ = resolve_config()
 
    -- Criptografia desabilitada: retorna o dado sem transformação
    if not enabled then
        return ciphertext
    end
 
    local raw = b64.decode(ciphertext)
    if not raw or #raw <= IV_SIZE then
        log.log_err("crypto: ciphertext inválido ou curto demais para conter IV")
        return nil
    end
 
    -- Extrair IV prefixado e dado cifrado
    local iv_used   = string.sub(raw, 1, IV_SIZE)
    local encrypted = string.sub(raw, IV_SIZE + 1)
 
    local cipher = openssl_cipher.new(CIPHER_ALGO)
    if not cipher then
        log.log_err("crypto: falha ao criar instância de cipher")
        return nil
    end
 
    local ok, decrypted = pcall(function()
        return cipher:decrypt(key, iv_used):final(encrypted)
    end)
 
    if not ok or decrypted == nil then
        log.log_err("crypto: falha na decifragem — " .. tostring(decrypted))
        return nil
    end
 
    return decrypted
end
 
return _M