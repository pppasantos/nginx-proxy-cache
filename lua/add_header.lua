local _M = {}

function _M.set_response_headers()
  local headers = {
    ["X-Frame-Options"] = "SAMEORIGIN",
    ["X-Content-Type-Options"] = "nosniff",
    ["X-XSS-Protection"] = "1; mode=block",
    ["Referrer-Policy"] = "no-referrer-when-downgrade",
  }

  for k, v in pairs(headers) do
    ngx.header[k] = v
  end
end

return _M
