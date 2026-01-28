local log = require "log"
local _M = {}

local openssl_cipher = require("openssl.cipher")

-- Configuração de criptografia
local CIPHER_ALGO = "aes-256-cbc"
local KEY_SIZE = 32
local IV_SIZE = 16

-- Cache de chave/IV (inicializado uma única vez)
local crypto_cache = {
    initialized = false,
    enabled = false,
    key = nil,
    iv = nil,
    error = nil
}

-- Base64 helpers (usa ngx para encode/decode)
local b64 = {
    encode = ngx.encode_base64,
    decode = ngx.decode_base64,
}

-- Inicializa cache de configuração de criptografia
local function init_crypto_config()
    if crypto_cache.initialized then
        return crypto_cache.enabled, crypto_cache.key, crypto_cache.iv, crypto_cache.error
    end

    crypto_cache.initialized = true
    crypto_cache.enabled = ngx.var.redis_crypto_enabled == "true"

    if not crypto_cache.enabled then
        log.log_info("Encryption disabled via redis_crypto_enabled")
        return false
    end

    -- Decodifica chave e IV das variáveis nginx
    local key_b64 = ngx.var.redis_crypto_key
    local iv_b64 = ngx.var.redis_crypto_iv

    if not key_b64 or not iv_b64 then
        crypto_cache.error = "Missing redis_crypto_key or redis_crypto_iv configuration"
        log.log_err(crypto_cache.error)
        return false, nil, nil, crypto_cache.error
    end

    local key = b64.decode(key_b64)
    local iv = b64.decode(iv_b64)

    if not key then
        crypto_cache.error = "Failed to decode redis_crypto_key (invalid base64)"
        log.log_err(crypto_cache.error)
        return false, nil, nil, crypto_cache.error
    end

    if not iv then
        crypto_cache.error = "Failed to decode redis_crypto_iv (invalid base64)"
        log.log_err(crypto_cache.error)
        return false, nil, nil, crypto_cache.error
    end

    if #key ~= KEY_SIZE then
        crypto_cache.error = "Key size mismatch: expected " .. KEY_SIZE .. " bytes, got " .. #key
        log.log_err(crypto_cache.error)
        return false, nil, nil, crypto_cache.error
    end

    if #iv ~= IV_SIZE then
        crypto_cache.error = "IV size mismatch: expected " .. IV_SIZE .. " bytes, got " .. #iv
        log.log_err(crypto_cache.error)
        return false, nil, nil, crypto_cache.error
    end

    crypto_cache.key = key
    crypto_cache.iv = iv
    log.log_info("Encryption initialized successfully with " .. CIPHER_ALGO)
    return true, key, iv, nil
end

function _M.encrypt(plaintext)
    -- Validação de entrada
    if type(plaintext) ~= "string" then
        log.log_err("Encrypt called with non-string plaintext")
        return nil
    end

    if plaintext == "" then
        log.log_warn("Encrypting empty payload")
        return b64.encode("")
    end

    local enabled, key, iv, err = init_crypto_config()

    if not enabled then
        log.log_err("Encryption unavailable: " .. (err or "unknown error"))
        return nil
    end

    local cipher = openssl_cipher.new(CIPHER_ALGO)
    if not cipher then
        log.log_err("Failed to create cipher instance")
        return nil
    end

    local ok, encrypted = pcall(function()
        return cipher:encrypt(key, iv):final(plaintext)
    end)

    if not ok then
        log.log_err("Encryption failed: " .. tostring(encrypted))
        return nil
    end

    if not encrypted or encrypted == "" then
        log.log_err("Encryption produced empty result")
        return nil
    end

    local encoded = b64.encode(encrypted)
    log.log_info("Payload encrypted successfully (" .. #plaintext .. " bytes -> " .. #encoded .. " bytes)")
    return encoded
end

function _M.decrypt(ciphertext)
    -- Validação de entrada
    if type(ciphertext) ~= "string" then
        log.log_err("Decrypt called with non-string ciphertext")
        return nil
    end

    if ciphertext == "" then
        log.log_warn("Decrypting empty payload")
        return ""
    end

    local enabled, key, iv, err = init_crypto_config()

    if not enabled then
        log.log_err("Decryption unavailable: " .. (err or "unknown error"))
        return nil
    end

    -- Decodifica base64
    local raw = b64.decode(ciphertext)
    if not raw then
        log.log_err("Failed to decode ciphertext from base64")
        return nil
    end

    if raw == "" then
        log.log_warn("Ciphertext decoded to empty result")
        return ""
    end

    local cipher = openssl_cipher.new(CIPHER_ALGO)
    if not cipher then
        log.log_err("Failed to create cipher instance")
        return nil
    end

    local ok, decrypted = pcall(function()
        return cipher:decrypt(key, iv):final(raw)
    end)

    if not ok then
        log.log_err("Decryption failed: " .. tostring(decrypted))
        return nil
    end

    if not decrypted then
        log.log_err("Decryption produced nil result")
        return nil
    end

    log.log_info("Payload decrypted successfully (" .. #ciphertext .. " bytes -> " .. #decrypted .. " bytes)")
    return decrypted
end

return _M