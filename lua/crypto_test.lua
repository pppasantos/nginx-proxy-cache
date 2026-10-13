--[[
  Teste de round-trip para crypto.lua (AES-256-GCM).

  Requer OpenResty + luaossl. Rode dentro do container, ex.:
    resty lua/crypto_test.lua
  (ou via o container do projeto: docker compose run --rm <svc> resty /path/lua/crypto_test.lua)

  Stuba ngx e o módulo "log" para rodar fora do ciclo de request.
]]

-- Stub mínimo de ngx (apenas o que crypto.lua usa)
_G.ngx = _G.ngx or {}
ngx.encode_base64 = ngx.encode_base64 or function(s)
    return (require("openssl.base64") and nil) or require("mime") and nil
end

-- base64 via luaossl se ngx não existir de verdade
local ok_b64 = pcall(function() return ngx.encode_base64("x") end)
if not ok_b64 or not ngx.encode_base64 then
    local function b64enc(s)
        local b = '0123456789+/ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz'
        -- fallback simples não é necessário dentro do OpenResty; aborta claramente
        error("rode este teste dentro do OpenResty (ngx.encode_base64 ausente)")
    end
    ngx.encode_base64 = b64enc
end

-- Variáveis de request simuladas
local KEY_B64 = "8JWls0vR1m1MnVefTrOqBC8m9/5KmBGEvOwE3XYO4t4="  -- chave de exemplo (32 bytes)
ngx.var = {
    redis_crypto_enabled = "true",
    redis_crypto_key     = KEY_B64,
}

-- Stub de log
package.loaded["log"] = {
    log_err  = function(m) print("[ERR] " .. tostring(m)) end,
    log_warn = function(m) print("[WARN] " .. tostring(m)) end,
}

package.loaded["crypto"] = nil
local crypto = require("crypto")

local function assert_eq(a, b, msg)
    if a ~= b then
        error("FALHOU: " .. msg .. " (esperado=" .. tostring(b) .. " obtido=" .. tostring(a) .. ")")
    end
    print("OK: " .. msg)
end

-- 1) Round-trip básico
local pt = "payload de cache: {\"user\":1234,\"roles\":[\"admin\"]}"
local ct = crypto.encrypt(pt)
assert(ct and ct ~= pt, "encrypt deve produzir ciphertext diferente do plaintext")
assert_eq(crypto.decrypt(ct), pt, "round-trip encrypt/decrypt preserva o plaintext")

-- 2) IV único: duas cifragens do mesmo plaintext devem diferir (IV aleatório)
local ct2 = crypto.encrypt(pt)
assert(ct ~= ct2, "ciphertexts devem diferir entre operações (IV aleatório)")
print("OK: IV aleatório por operação")

-- 3) Integridade: adulterar o ciphertext deve falhar a decifragem (tag GCM)
local raw = ngx.decode_base64(ct)
local tampered = raw:sub(1, #raw - 1) .. string.char((raw:byte(#raw) + 1) % 256)
local bad = crypto.decrypt(ngx.encode_base64(tampered))
assert_eq(bad, nil, "ciphertext adulterado é rejeitado (autenticação GCM)")

-- 4) Payload legado/curto é rejeitado sem crash
assert_eq(crypto.decrypt("AAAA"), nil, "payload curto/legado retorna nil")

-- 4b) Fail-closed: habilitado mas chave inválida -> nunca grava/retorna plaintext
local good_key = ngx.var.redis_crypto_key
ngx.var.redis_crypto_key = "chave-invalida-nao-base64-32-bytes"
assert_eq(crypto.encrypt(pt), nil, "encrypt com chave inválida é fail-closed (nil)")
assert_eq(crypto.decrypt(ct), nil, "decrypt com chave inválida é fail-closed (nil)")
ngx.var.redis_crypto_key = good_key

-- 5) Criptografia desabilitada: passthrough
ngx.var.redis_crypto_enabled = "false"
assert_eq(crypto.encrypt(pt), pt, "encrypt desabilitado faz passthrough")
assert_eq(crypto.decrypt(pt), pt, "decrypt desabilitado faz passthrough")

print("\nTODOS OS TESTES PASSARAM")
