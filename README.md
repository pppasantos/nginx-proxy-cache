# NGINX Cache CDN - Modular Proxy with Redis, Lua, and Observability

## Overview

This project is a high-performance, modular CDN and HTTP cache solution based on **NGINX**.  
It uses Lua scripting for advanced cache logic, logging, metrics collection, and header manipulation.  
**Redis** is used as the cache backend, and **Prometheus** is used for rich traffic and cache metrics—making it perfect for Kubernetes or any environment where control, performance, and observability matter.

---

## Architecture

- **NGINX** acts as a reverse proxy and main HTTP router.
- **Lua** (via [OpenResty](https://openresty.org/)) is used for all advanced logic: cache, metrics, logging, and custom header handling.
- **Redis** stores cached HTTP responses.
- **Prometheus** collects and exposes real-time metrics.
- **Full modularization**: All business logic, logs, headers, and cache behavior live in external Lua modules and config files.

---

## Project Structure

- `nginx.conf`: Main NGINX configuration.
- `log_format.conf`: Custom JSON log format for integrations (e.g., Elasticsearch).
- `http_globals.conf`: Global HTTP performance, security, and gzip settings.
- `maps.conf`: Route normalization and mapping rules.
- `http_settings_module_vhost_traffic_status.conf`: vhost traffic status module settings.
- **Lua scripts**:
  - `cache_handler.lua`: Main Redis-based cache logic.
  - `prometheus_metrics.lua`: Prometheus metrics exporter.
  - `body_logger.lua` & `headers_logger.lua`: Capture response body and request headers for logging.
  - `add_header.lua`: Adds security/debug headers to all responses.
  - `redis_key_invalidation.lua`: Manual Redis cache key invalidation endpoint.
- Easily add new Lua scripts for more logic (auth, rate limiting, etc).

---

## Key Features

### 1. **Redis-Powered HTTP Caching**

- Cache key is generated using method, URI, selected headers, and (optionally) the request body (for POST/PUT).
- Cache TTL, relevant headers, cacheable HTTP methods, and status codes are all set via NGINX variables.
- Distributed locking avoids cache stampedes under load.
- **Stale cache** support: If backend is down, still serve old cache if available.
- Manual cache invalidation via `/cache_invalidate`.

### 2. **Structured Logging**

- JSON log output as defined in `log_format.conf`, suitable for Elasticsearch and other log analytics platforms:
    ```json
    {
      "http_user_agent": "...",
      "request_uri": "/api/...",
      "status": "200",
      "cache_status": "HIT",
      "request_body": "...",
      "response_body": "...",
      ...
    }
    ```

### 3. **Advanced Metrics (Prometheus)**

- Exposed on `/monitoring/metrics`
- Per-route, method, status, pod, namespace, and deployment metrics.
- Cache events (hit, miss, stale, bypass), errors, request size/timing, connections, TLS info, upstream timings, etc.
- **Ready for Grafana dashboards!**

### 4. **Security and Header Control**

- Security headers (CSP, X-Frame-Options, etc.) out-of-the-box.
- Debug headers (pod hostname, cache status).
- All logic managed through `add_header.lua`.

### 5. **Observability & Debugging**

- `/monitoring/_nginx_status`: HTML dashboard for traffic status per vhost/route.
- `/nginx_healthcheck`: Simple healthcheck endpoint for probes.
- Logs and metrics are easy to consume for production monitoring.

### 6. **Route Normalization**

- Use `maps.conf` to normalize and map URIs for metric aggregation and cleaner dashboards.

---

## How to Use

### Prerequisites

- NGINX with [lua-nginx-module](https://github.com/openresty/lua-nginx-module) support (e.g., OpenResty).
- Redis instance accessible (local or remote).
- Prometheus configured to scrape `/monitoring/metrics`.

### Quick Deploy

1. **Clone the repo and adjust config files for your environment.**
2. Set your Redis endpoints, cache/TTL variables, and any custom headers in `vars.conf`.
3. Start NGINX (Docker/K8s/VM).
4. Expose the ports as set in `nginx.conf` (`8889` for API, `8890` for metrics).
5. [Optional] Forward logs to Elasticsearch or any SIEM tool.

---

## Key Variables (`vars.conf` example)

```nginx
# Redis
set $redis_host            "localhost";
set $redis_read_host       "localhost";
set $redis_write_host      "localhost";
set $redis_timeout         "1000";
set $redis_pool_size       "100";
set $redis_ttl             "3600";
# Cache
set $cache_methods         "GET,HEAD";
set $cache_statuses        "200,203,204,206,301,404";
set $cache_headers         "Authorization";
set $cache_use_body_in_key "false";
set $treat_head_as_get     "true";
# Add more variables as needed
