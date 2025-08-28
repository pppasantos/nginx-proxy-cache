local _M = {}
 
function _M.log_err(msg, ...)
    ngx.log(ngx.ERR, "❌ ", msg, ...)
end
 
function _M.log_warn(msg, ...)
    ngx.log(ngx.WARN, "⚠️ ", msg, ...)
end
 
function _M.log_info(msg, ...)
    ngx.log(ngx.INFO, "ℹ️ ", msg, ...)
end
 
return _M