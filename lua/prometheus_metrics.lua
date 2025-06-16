local _M = {}
local prometheus = require("prometheus")
local metric_lib = {}

function _M.init()
    local pod_name = io.popen("hostname"):read("*l") or "unknown"
    metric_lib.pod_name = pod_name
    metric_lib.prometheus = prometheus.init("prometheus_metrics")

    -- Métricas server
    metric_lib.server_http_requests = metric_lib.prometheus:counter("server_http_requests", "Number of HTTP requests", {"host", "status", "route", "pod_name"})
    metric_lib.server_http_request_time = metric_lib.prometheus:histogram("server_http_request_time", "HTTP request time", {"host", "route", "pod_name"})
    metric_lib.server_http_request_bytes_received = metric_lib.prometheus:counter("server_http_request_bytes_received", "Number of HTTP request bytes received", {"host", "pod_name"})
    metric_lib.server_http_request_bytes_sent = metric_lib.prometheus:counter("server_http_request_bytes_sent", "Number of HTTP request bytes sent", {"host", "pod_name"})
    metric_lib.server_http_response_size = metric_lib.prometheus:histogram("server_http_response_size", "Size of HTTP responses", {"status", "pod_name"})
    metric_lib.server_http_methods = metric_lib.prometheus:counter("server_http_methods", "HTTP method usage", {"host", "method", "route", "pod_name"})
    metric_lib.server_http_errors = metric_lib.prometheus:counter("server_http_errors", "HTTP error responses", {"host", "code_class", "pod_name"})
    metric_lib.server_http_connections = metric_lib.prometheus:gauge("server_http_connections", "Number of HTTP connections", {"state", "pod_name"})
    metric_lib.server_http_tls_info = metric_lib.prometheus:counter("server_http_tls_info", "TLS handshake info", {"version", "cipher", "pod_name"})
    metric_lib.server_http_cache_status_total = metric_lib.prometheus:counter("server_http_cache_status_total", "Total number of HTTP cache events by status", {"host", "cache_status", "route", "pod_name"})
    metric_lib.server_http_cache_response_time = metric_lib.prometheus:histogram("nginx_http_cache_response_time","Tempo de resposta de requisições servidas pelo cache",{"host", "cache_status", "route", "pod_name"})
    metric_lib.server_http_route_usage = metric_lib.prometheus:counter("server_http_route_usage", "Route usage counter", {"namespace", "deployment", "route", "pod_name"})

    -- Métricas upstream
    metric_lib.upstream_cache_status = metric_lib.prometheus:counter("upstream_cache_status", "Number of HTTP upstream cache status", {"host", "status", "pod_name"})
    metric_lib.upstream_requests = metric_lib.prometheus:counter("upstream_requests", "Number of HTTP upstream requests", {"addr", "status", "route", "pod_name"})
    metric_lib.upstream_response_time = metric_lib.prometheus:histogram("upstream_response_time", "HTTP upstream response time", {"addr", "route", "pod_name"})
    metric_lib.upstream_header_time = metric_lib.prometheus:histogram("upstream_header_time", "HTTP upstream header time", {"addr", "pod_name"})
    metric_lib.upstream_bytes_received = metric_lib.prometheus:counter("upstream_bytes_received", "Number of HTTP upstream bytes received", {"addr", "pod_name"})
    metric_lib.upstream_bytes_sent = metric_lib.prometheus:counter("upstream_bytes_sent", "Number of HTTP upstream bytes sent", {"addr", "pod_name"})
    metric_lib.upstream_connect_time = metric_lib.prometheus:histogram("upstream_connect_time", "HTTP upstream connect time", {"addr", "pod_name"})
    metric_lib.upstream_first_byte_time = metric_lib.prometheus:histogram("upstream_first_byte_time", "HTTP upstream first byte time", {"addr", "pod_name"})
    metric_lib.upstream_session_time = metric_lib.prometheus:histogram("upstream_session_time", "HTTP upstream session time", {"addr", "pod_name"})
end

function _M.collect()
    local pod_name = ngx.var.pod_name or ""
    -- Coleta conexões
    if ngx.var.connections_active ~= nil then
        metric_lib.server_http_connections:set(tonumber(ngx.var.connections_active), {"active", pod_name})
        metric_lib.server_http_connections:set(tonumber(ngx.var.connections_reading), {"reading", pod_name})
        metric_lib.server_http_connections:set(tonumber(ngx.var.connections_waiting), {"waiting", pod_name})
        metric_lib.server_http_connections:set(tonumber(ngx.var.connections_writing), {"writing", pod_name})
    end

    metric_lib.prometheus:collect()
end


function _M.log()
    local function split(str)
        local array = {}
        for mem in string.gmatch(str, '([^, ]+)') do
            table.insert(array, mem)
        end
        return array
    end

    local function getWithIndex(str, idx)
        if str == nil then return nil end
        return split(str)[idx]
    end

    local function normalize_addr(addr)
        if addr == "[::1]:8888" or addr == "localhost:8888" or addr == "localhost" then
            return "127.0.0.1:8888"
        end
        return addr
    end

    local host = ngx.var.host
    local status = ngx.var.status
    local route = ngx.var.normalized_uri
    local method = ngx.req.get_method()
    local cache_status_val = ngx.var.cache_status
    local namespace = os.getenv("POD_NAMESPACE") or "unknown"
    local deployment = os.getenv("POD_DEPLOYMENT") or "unknown"
    local pod_name = metric_lib.pod_name

    metric_lib.server_http_requests:inc(1, {host, status, route, pod_name})
    metric_lib.server_http_methods:inc(1, {host, method, route, pod_name})
    metric_lib.server_http_request_time:observe(ngx.now() - ngx.req.start_time(), {host, route, pod_name})
    metric_lib.server_http_response_size:observe(tonumber(ngx.var.bytes_sent), {status, pod_name})
    metric_lib.server_http_request_bytes_sent:inc(tonumber(ngx.var.bytes_sent), {host, pod_name})

    if route and route ~= "" then
        metric_lib.server_http_route_usage:inc(1, {namespace, deployment, route, pod_name})
    end

    if ngx.var.bytes_received ~= nil then
        metric_lib.server_http_request_bytes_received:inc(tonumber(ngx.var.bytes_received), {host, pod_name})
    end

    local code_class = string.sub(status, 1, 1) .. "xx"
    if code_class == "4xx" or code_class == "5xx" then
        metric_lib.server_http_errors:inc(1, {host, code_class, pod_name})
    end

    local ssl_protocol = ngx.var.ssl_protocol
    local ssl_cipher = ngx.var.ssl_cipher
    if ssl_protocol and ssl_cipher then
        metric_lib.server_http_tls_info:inc(1, {ssl_protocol, ssl_cipher, pod_name})
    end

    if cache_status_val and cache_status_val ~= "" then
        metric_lib.server_http_cache_status_total:inc(1, {host, cache_status_val, route, pod_name})
    end

    if cache_status_val and (cache_status_val == "HIT" or cache_status_val == "MISS") then
        local response_time = ngx.now() - ngx.req.start_time()
        metric_lib.server_http_cache_response_time:observe(response_time, {host, cache_status_val, route, pod_name})
    end

    local upstream_cache_status_val = ngx.var.upstream_cache_status
    if upstream_cache_status_val then
        metric_lib.upstream_cache_status:inc(1, {host, upstream_cache_status_val, pod_name})
    end

    local upstream_addr_val = ngx.var.upstream_addr
    if upstream_addr_val then
        local addrs = split(upstream_addr_val)

        local upstream_status_val = ngx.var.upstream_status
        local upstream_response_time_val = ngx.var.upstream_response_time
        local upstream_connect_time_val = ngx.var.upstream_connect_time
        local upstream_first_byte_time_val = ngx.var.upstream_first_byte_time
        local upstream_header_time_val = ngx.var.upstream_header_time
        local upstream_session_time_val = ngx.var.upstream_session_time
        local upstream_bytes_received_val = ngx.var.upstream_bytes_received
        local upstream_bytes_sent_val = ngx.var.upstream_bytes_sent

        for idx, addr in ipairs(addrs) do
            addr = normalize_addr(addr)
            if #addrs > 1 then
                upstream_status_val = getWithIndex(ngx.var.upstream_status, idx)
                upstream_response_time_val = getWithIndex(ngx.var.upstream_response_time, idx)
                upstream_connect_time_val = getWithIndex(ngx.var.upstream_connect_time, idx)
                upstream_first_byte_time_val = getWithIndex(ngx.var.upstream_first_byte_time, idx)
                upstream_header_time_val = getWithIndex(ngx.var.upstream_header_time, idx)
                upstream_session_time_val = getWithIndex(ngx.var.upstream_session_time, idx)
                upstream_bytes_received_val = getWithIndex(ngx.var.upstream_bytes_received, idx)
                upstream_bytes_sent_val = getWithIndex(ngx.var.upstream_bytes_sent, idx)
            end

            metric_lib.upstream_requests:inc(1, {addr, upstream_status_val, route, pod_name})
            if upstream_response_time_val then
                metric_lib.upstream_response_time:observe(tonumber(upstream_response_time_val), {addr, route, pod_name})
            end
            if upstream_header_time_val then
                metric_lib.upstream_header_time:observe(tonumber(upstream_header_time_val), {addr, pod_name})
            end
            if upstream_first_byte_time_val then
                metric_lib.upstream_first_byte_time:observe(tonumber(upstream_first_byte_time_val), {addr, pod_name})
            end
            if upstream_connect_time_val then
                metric_lib.upstream_connect_time:observe(tonumber(upstream_connect_time_val), {addr, pod_name})
            end
            if upstream_session_time_val then
                metric_lib.upstream_session_time:observe(tonumber(upstream_session_time_val), {addr, pod_name})
            end
            if upstream_bytes_received_val then
                metric_lib.upstream_bytes_received:inc(tonumber(upstream_bytes_received_val), {addr, pod_name})
            end
            if upstream_bytes_sent_val then
                metric_lib.upstream_bytes_sent:inc(tonumber(upstream_bytes_sent_val), {addr, pod_name})
            end
        end
    end
end

return _M
