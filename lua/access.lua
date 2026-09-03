-- Request gate, honouring the DMM_API_PROTECT master switch in config.lua.
--
-- When protection is OFF: gate() and require_sig() allow everything, and nothing
-- is rate-limited or signed (fully open).
--
-- When protection is ON:
--   * gate()         -> enforces the optional client-IP whitelist (all requests).
--   * require_sig()  -> /proxy/* requests must carry a valid, unexpired HMAC
--                       signature so leaked URLs only work for SIGN_TTL seconds.

local cjson = require "cjson"
local config = require "config"
local sign = require "sign"

local _M = {}

local function deny(code, reason, message)
    ngx.status = code
    ngx.header["Content-Type"] = "application/json; charset=utf-8"
    ngx.say(cjson.encode({
        error = reason,
        message = message,
    }))
    return ngx.exit(code)
end

-- Client-IP whitelist. Enforced only when protection is enabled.
function _M.gate()
    if not config.protect_enabled() then
        return
    end
    local ip = ngx.var.remote_addr
    if not config.ip_allowed(ip) then
        deny(403, "forbidden", "Client IP not allowed: " .. (ip or ""))
    end
    if not _M.rate_limit() then
        deny(429, "too_many_requests", "Rate limit exceeded")
    end
end

-- Simple fixed-window per-IP rate limiter using the shared dict.
-- Returns false (=> deny 429) when the client exceeds RATE_PER_MIN in a minute.
-- Only counts when protection is enabled (gate() guards this).
local window = 60
function _M.rate_limit()
    local dict = ngx.shared.rate_limit
    if not dict then
        return true
    end
    local key = "rl:" .. ngx.var.remote_addr
    local n = dict:incr(key, 1, 0)
    if n == 1 then
        dict:expire(key, window)
    end
    return n <= config.RATE_PER_MIN
end

-- Mandatory short-lived signature on /proxy/* requests. Enforced only when
-- protection is enabled; when disabled any (unsigned) URL is allowed so that
-- clients can use plain proxy paths.
function _M.require_sig()
    if not config.protect_enabled() then
        return
    end
    if not sign.verify() then
        deny(403, "forbidden", "Invalid or expired signature")
    end
end

-- Mandatory Bearer token on ALL external interfaces (both /api/* and /proxy/*),
-- regardless of the DMM_API_PROTECT switch. Behaviour mirrors router.check_auth().
function _M.require_token()
    local auth_header = ngx.req.get_headers()["Authorization"]
    if not auth_header then
        deny(401, "unauthorized", "Missing Authorization header. Use: Authorization: Bearer <token>")
    end
    local token = auth_header:match("^Bearer%s+(.+)$")
    if not token or token ~= config.AUTH_TOKEN then
        deny(403, "forbidden", "Invalid token")
    end
end

return _M
