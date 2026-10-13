local log = require "log"
local _M = {}

local openssl_cipher = require("openssl.cipher")
local openssl_rand   = require("openssl.rand")

-- Configuração de criptografia
local CIPHER_ALGO = "aes-256-gcm"
local KEY_SIZE    = 32   -- 256 bits
local IV_SIZE     = 12   -- 96 bits: tamanho recomendado para GCM
local TAG_SIZE    = 16   -- 128 bits: tag de autenticação GCM

-- Versão do formato de payload. Prefixada (1 byte) antes do base64 para
-- permitir rotação de algoritmo/chave sem invalidar tudo de uma vez.
--   v1: aes-256-gcm, formato = versao(1) .. iv(12) .. tag(16) .. ciphertext
local FORMAT_VERSION = string.char(0x01)

-- Base64 helpers (usa ngx para encode/decode)
local b64 = {
    encode = ngx.encode_base64,
    decode = ngx.decode_base64,
}

--[[
  Resolução da chave por request a partir das variáveis nginx.
  Não é cacheada como upvalue de módulo porque:
    1. ngx.var é por-request e pode variar entre locations/vhosts.
    2. Um cache de módulo fixaria valores da primeira requisição para todas as seguintes.
  O overhead é mínimo pois são apenas leituras de string + base64 decode.

  O IV NÃO vem de configuração: é gerado aleatoriamente por operação de
  cifragem e prefixado no payload (ver encrypt/decrypt).
]]
--[[
  resolve_config() -> status, key
  Retorna um de três estados EXPLÍCITOS para não confundir "desligado de
  propósito" com "ligado mas mal configurado" — a distinção que separa
  passthrough intencional de fail-closed:
    "disabled" -> cripto desligada (passthrough intencional)
    "error"    -> cripto habilitada mas chave ausente/inválida (fail-closed)
    "ok", key  -> cripto habilitada e chave válida
]]
local function resolve_config()
    if ngx.var.redis_crypto_enabled ~= "true" then
        return "disabled"
    end

    local key_b64 = ngx.var.redis_crypto_key
    if not key_b64 then
        log.log_err("crypto: redis_crypto_key não configurado com cripto habilitada")
        return "error"
    end

    local key = b64.decode(key_b64)
    if not key then
        log.log_err("crypto: falha ao decodificar redis_crypto_key (base64 inválido)")
        return "error"
    end

    if #key ~= KEY_SIZE then
        log.log_err("crypto: tamanho de chave inválido — esperado " .. KEY_SIZE .. " bytes, recebido " .. #key)
        return "error"
    end

    return "ok", key
end

--[[
  encrypt(plaintext) -> string|nil
  Retorna o payload cifrado como: base64( versao(1) .. iv(12) .. tag(16) .. ciphertext )

  Usa AES-256-GCM (AEAD): garante confidencialidade E integridade. A tag de
  autenticação detecta qualquer adulteração do ciphertext (ao contrário de CBC).

  O IV aleatório (12 bytes) é único por operação e prefixado no payload para
  que decrypt possa recuperá-lo.

  Fail-closed: se o RNG falhar, aborta a cifragem (retorna nil) em vez de
  reusar um IV estático — reuso de IV em GCM é catastrófico (quebra a
  confidencialidade e permite forjar tags).

  Retorna nil em caso de erro. Passthrough (retorna plaintext) APENAS quando a
  cripto está desligada de propósito; se estiver habilitada mas mal configurada
  (chave ausente/inválida), faz fail-closed (retorna nil) para nunca gravar
  plaintext no Redis sem querer.
]]
function _M.encrypt(plaintext)
    if type(plaintext) ~= "string" then
        log.log_err("crypto.encrypt: argumento não é string")
        return nil
    end

    local status, key = resolve_config()

    -- Desligada de propósito: passthrough. Mal configurada: fail-closed.
    if status == "disabled" then
        return plaintext
    elseif status ~= "ok" then
        return nil
    end

    -- Gera IV aleatório por operação. Fail-closed se o RNG não estiver disponível.
    local iv_random, rand_err = openssl_rand.bytes(IV_SIZE)
    if not iv_random or #iv_random ~= IV_SIZE then
        log.log_err("crypto: RNG indisponível, abortando cifragem (" .. tostring(rand_err) .. ")")
        return nil
    end

    local cipher = openssl_cipher.new(CIPHER_ALGO)
    if not cipher then
        log.log_err("crypto: falha ao criar instância de cipher")
        return nil
    end

    local ok, encrypted, tag = pcall(function()
        cipher:encrypt(key, iv_random)
        local ct = cipher:update(plaintext) .. cipher:final()
        return ct, cipher:getTag(TAG_SIZE)
    end)

    -- pcall retorna (true, ct, tag) em sucesso; (false, err) em erro.
    -- Quando ok, "encrypted" é o ciphertext e "tag" a tag de autenticação.
    if not ok then
        log.log_err("crypto: falha na cifragem — " .. tostring(encrypted))
        return nil
    end

    if not encrypted or not tag or #tag ~= TAG_SIZE then
        log.log_err("crypto: cifragem produziu saída inválida (tag ausente/curta)")
        return nil
    end

    -- Formato: versao .. iv .. tag .. ciphertext
    return b64.encode(FORMAT_VERSION .. iv_random .. tag .. encrypted)
end

--[[
  decrypt(ciphertext) -> string|nil
  Espera o formato produzido por encrypt(): base64( versao(1) .. iv(12) .. tag(16) .. ciphertext )

  A verificação da tag GCM ocorre em :final(): se o ciphertext (ou a tag, ou o
  IV) tiver sido adulterado, :final() lança erro e retornamos nil.

  Payloads de formato antigo/desconhecido (ex.: cache legado em CBC, sem byte de
  versão) falham a decifragem e retornam nil — para um cache isso é um simples
  miss, que será repopulado no formato novo. Comportamento auto-corretivo.

  Retorna nil em caso de erro. Passthrough (retorna ciphertext) APENAS quando a
  cripto está desligada de propósito; se estiver habilitada mas mal configurada,
  faz fail-closed (retorna nil -> tratado como cache MISS) em vez de devolver
  bytes cifrados como se fossem plaintext.
]]
function _M.decrypt(ciphertext)
    if type(ciphertext) ~= "string" then
        log.log_err("crypto.decrypt: argumento não é string")
        return nil
    end

    local status, key = resolve_config()

    -- Desligada de propósito: passthrough. Mal configurada: fail-closed.
    if status == "disabled" then
        return ciphertext
    elseif status ~= "ok" then
        return nil
    end

    local raw = b64.decode(ciphertext)
    local header_size = #FORMAT_VERSION + IV_SIZE + TAG_SIZE
    if not raw or #raw <= header_size then
        log.log_err("crypto: ciphertext inválido ou curto demais para conter header")
        return nil
    end

    -- Checa a versão do formato
    local version = string.sub(raw, 1, #FORMAT_VERSION)
    if version ~= FORMAT_VERSION then
        log.log_err("crypto: versão de formato desconhecida (payload legado ou corrompido)")
        return nil
    end

    -- Extrair IV, tag e dado cifrado
    local offset    = #FORMAT_VERSION
    local iv_used   = string.sub(raw, offset + 1, offset + IV_SIZE)
    local tag       = string.sub(raw, offset + IV_SIZE + 1, offset + IV_SIZE + TAG_SIZE)
    local encrypted = string.sub(raw, offset + IV_SIZE + TAG_SIZE + 1)

    local cipher = openssl_cipher.new(CIPHER_ALGO)
    if not cipher then
        log.log_err("crypto: falha ao criar instância de cipher")
        return nil
    end

    local ok, decrypted = pcall(function()
        cipher:decrypt(key, iv_used)
        cipher:setTag(tag)                       -- tag deve ser setada antes de :final()
        return cipher:update(encrypted) .. cipher:final()  -- :final() valida a tag
    end)

    if not ok or decrypted == nil then
        -- Falha aqui = tag inválida (adulteração) ou dado corrompido.
        log.log_err("crypto: falha na decifragem/autenticação — " .. tostring(decrypted))
        return nil
    end

    return decrypted
end

return _M