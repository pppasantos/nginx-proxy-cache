local _M = {}

function _M.capture_request_headers()
    local headers = ngx.req.get_headers()
    local headers_str = ""

    for k, v in pairs(headers) do
        if type(v) == "table" then
            v = table.concat(v, ", ")
        end
        headers_str = headers_str .. k .. ": " .. v .. "; "
    end

    ngx.var.req_headers = headers_str
end

return _M
