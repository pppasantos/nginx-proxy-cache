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
 
return _M