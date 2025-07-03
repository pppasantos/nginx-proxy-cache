local _M = {}

local openssl_cipher = require("openssl.cipher")

-- Base64 helpers (usa ngx para encode/decode)
local b64 = {
    encode = ngx.encode_base64,
    decode = ngx.decode_base64,
}

-- Logging helpers
local function log_warn(msg, ...) ngx.log(ngx.ERR, "⚠️ ", msg, ...) end
local function log_err(msg, ...) ngx.log(ngx.ERR, "❌ ", msg, ...) end

-- Check if encryption is enabled via NGINX variable
local function is_enabled()
    return ngx.var.redis_crypto_enabled == "true"
end

-- Retrieves key and IV from NGINX variables
local function get_key_iv()
    local key_b64 = ngx.var.redis_crypto_key
    local iv_b64 = ngx.var.redis_crypto_iv

    if not key_b64 or not iv_b64 then
        return nil, "Missing key or IV"
    end

    local key = b64.decode(key_b64)
    local iv = b64.decode(iv_b64)

    if not key or #key ~= 32 then
        return nil, "Key must be 32 bytes (base64 of 32-byte string)"
    end
    if not iv or #iv ~= 16 then
        return nil, "IV must be 16 bytes (base64 of 16-byte string)"
    end

    return key, iv
end

function _M.encrypt(plaintext)
    if not is_enabled() then
        log_warn("Encryption is disabled. Skipping.")
        return plaintext
    end

    local key, iv_or_err = get_key_iv()
    if not key then
        log_err("Encryption skipped: ", iv_or_err)
        return plaintext
    end

    local cipher = openssl_cipher.new("aes-256-cbc")
    local ok, encrypted = pcall(function()
        return cipher:encrypt(key, iv_or_err):final(plaintext)
    end)

    if not ok then
        log_err("Encryption error: ", encrypted)
        return plaintext
    end

    log_warn("Payload encrypted successfully.")
    return b64.encode(encrypted)
end

function _M.decrypt(ciphertext)
    if not is_enabled() then
        log_warn("Decryption is disabled. Skipping.")
        return ciphertext
    end

    local key, iv_or_err = get_key_iv()
    if not key then
        log_err("Decryption skipped: ", iv_or_err)
        return ciphertext
    end

    local raw = b64.decode(ciphertext)
    if not raw then
        log_err("Failed to base64 decode ciphertext")
        return ciphertext
    end

    local cipher = openssl_cipher.new("aes-256-cbc")
    local ok, decrypted = pcall(function()
        return cipher:decrypt(key, iv_or_err):final(raw)
    end)

    if not ok then
        log_err("Decryption error: ", decrypted)
        return ciphertext
    end

    log_warn("Payload decrypted successfully.")
    return decrypted
end

return _M
