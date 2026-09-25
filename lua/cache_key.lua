local utils = require "utils"

local _M = {}

local function append_vary_headers(key, headers, cache_headers)
    for _, h in ipairs(cache_headers or {}) do
        local val = headers[h]
        if val then
            key = key .. "|" .. h .. "=" .. val
        end
    end
    return key
end

function _M.build_raw_key(opts)
    local method = opts.method or "GET"
    local raw_uri = opts.raw_uri or "/"
    local scheme = opts.scheme or "http"
    local headers = opts.headers or {}
    local body = opts.body or ""
    local cache_headers = opts.cache_headers or {}
    local use_body_in_key = opts.use_body_in_key == true

    local key = scheme .. method .. raw_uri
    key = append_vary_headers(key, headers, cache_headers)

    if use_body_in_key and (method == "POST" or method == "PUT" or method == "PATCH") then
        key = key .. "|" .. body
    end

    return key
end

function _M.build_hashed_key(opts)
    return ngx.md5(_M.build_raw_key(opts))
end

function _M.parse_cache_headers(value)
    return utils.split(value or "", ",")
end

return _M