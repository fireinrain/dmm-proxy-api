-- Short-lived signed proxy URL validation.
--
-- Proxy URLs are issued as:
--   /proxy/{kind}/{path}?sig=<hex-hmac>&exp=<unix_ts>
-- where sig = HMAC-SHA256(secret, request_uri .. ":" .. exp).
-- exp is ISSUE_TIME + SIGN_TTL. On request, the proxy location re-derives the
-- signature and requires exp to still be in the future, so a leaked URL stops
-- working once the window (default 220s) elapses.
--
-- The secret is the API auth token, so only a client who knows the token can
-- mint valid signed URLs (via /api/cover, /api/trailer).

local config = require "config"
local hmac = require "resty.openssl.hmac"
local to_hex = require("resty.string").to_hex

local _M = {}

_M.TTL = config.SIGN_TTL

local secret = config.AUTH_TOKEN

local function sign_bytes(msg)
    local h = hmac.new(secret, "sha256")
    h:update(msg)
    return to_hex(h:final())
end

-- Sign a proxy request URI path. Returns the URI with ?sig=&exp= appended.
function _M.sign(uri_path)
    local exp = ngx.time() + _M.TTL
    local sig = sign_bytes(uri_path .. ":" .. exp)
    return uri_path .. "?sig=" .. sig .. "&exp=" .. exp
end

-- Verify the current request's signature. Returns true on success.
function _M.verify()
    local args = ngx.req.get_uri_args()
    local sig = args.sig
    local exp = args.exp
    if not sig or not exp then
        return false
    end
    if tonumber(exp) and tonumber(exp) <= ngx.time() then
        return false
    end
    local uri = ngx.var.uri
    local expected = sign_bytes(uri .. ":" .. tostring(exp))
    if #sig ~= #expected then
        return false
    end
    -- constant-time compare
    local ok = true
    for i = 1, #sig do
        if string.byte(sig, i) ~= string.byte(expected, i) then
            ok = false
        end
    end
    return ok
end

return _M
