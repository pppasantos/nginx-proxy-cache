local http = require "resty.http"

local _M = {}

-- Split a string by separator (returns table)
function _M.split(str, sep)
    local t = {}
    for s in string.gmatch(str, "([^"..sep.."]+)") do
        t[#t+1] = s
    end
    return t
end

-- Convert list to set (used to lookup values efficiently)
function _M.to_set(list, force_string)
    local s = {}
    for _, v in ipairs(list) do
        s[force_string and tostring(v) or v] = true
    end
    return s
end

-- Log error message with prefix ❌
function _M.log_err(msg, ...)
    ngx.log(ngx.ERR, "❌ ", msg, ...)
end

-- Log warning message with prefix ⚠️
function _M.log_warn(msg, ...)
    ngx.log(ngx.ERR, "⚠️ ", msg, ...)
end

-- Make HTTP request to backend using resty.http
function _M.call_backend(method, url, body, headers)
    local httpc = http.new()
    httpc:set_timeout(tonumber(ngx.var.lua_backend_timeout) or 3000)
    _M.log_warn("Calling backend: ", url)
    return httpc:request_uri(url, {
        method = method,
        body = body,
        headers = headers,
        ssl_verify = ngx.var.lua_ssl_verify == "true"
    })
end

return _M
