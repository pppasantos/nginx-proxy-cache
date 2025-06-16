local _M = {}

function _M.capture_response_body()
    local resp_body = string.sub(ngx.arg[1], 1, 32768)
    ngx.ctx.buffered = (ngx.ctx.buffered or "") .. resp_body
    if ngx.arg[2] then
        ngx.var.resp_body = ngx.ctx.buffered
    end
end

return _M