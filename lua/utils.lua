local http = require "resty.http"

local _M = {}

function _M.split(str, sep)
    local t = {}
    for s in string.gmatch(str, "([^"..sep.."]+)") do
        t[#t+1] = s
    end
    return t
end

function _M.to_set(list, force_string)
    local s = {}
    for _, v in ipairs(list) do
        s[force_string and tostring(v) or v] = true
    end
    return s
end

function _M.log_err(msg, ...)
    ngx.log(ngx.ERR, "❌ ", msg, ...)
end

function _M.log_warn(msg, ...)
    ngx.log(ngx.ERR, "⚠️ ", msg, ...)
end

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
