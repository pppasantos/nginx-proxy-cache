function _M.capture()
    local headers = ngx.resp.get_headers()
    local headers_str = ""
 
    for k, v in pairs(headers) do
        if type(v) == "table" then
            v = table.concat(v, ", ")
        end
        headers_str = headers_str .. k .. ": " .. v .. "; "
    end
 
    ngx.var.resp_headers = headers_str
 
    return headers_str
end
 
return _M