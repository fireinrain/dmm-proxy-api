local _M = {}

_M.AUTH_TOKEN = os.getenv("DMM_AUTH_TOKEN") or "change-me-in-production"

-- Master protection switch. Values treated as ON: "on", "true", "1", "yes".
--   ON  -> /api/* needs bearer token; /proxy/* needs a short-lived signed URL
--          (valid for SIGN_TTL); rate limiting + optional IP whitelist apply.
--   OFF -> no token, no signature requirement, no rate limit (fully open).
_M.PROTECT = (os.getenv("DMM_API_PROTECT") or ""):lower()

local function is_on(v)
    return v == "on" or v == "true" or v == "1" or v == "yes"
end

-- Short-lived signed proxy URL window, in seconds.
_M.SIGN_TTL = tonumber(os.getenv("DMM_SIGN_TTL") or "220") or 220

-- Per-IP request budget per minute when protection is enabled.
_M.RATE_PER_MIN = tonumber(os.getenv("DMM_RATE_PER_MIN") or "240") or 240

-- Comma-separated allowed client IPs / CIDRs (empty => allow all, rely on token
-- + rate limit). e.g. "1.2.3.4,203.0.113.0/24"
_M.ALLOW_IPS = os.getenv("DMM_ALLOW_IPS") or ""

_M.CDN = {
    -- pics.dmm.co.jp : standard cover/preview
    images = "https://pics.dmm.co.jp",
    -- awsimgsrc.dmm.co.jp/pics_dig : 2K high-res cover (2024-06+, not all titles)
    images_hd = "https://awsimgsrc.dmm.co.jp/pics_dig",
    -- oppg server for sample movie / litevideo
    litevideo = "https://cc3001.dmm.co.jp",
}

-- User-Agent / Referer used when probing existence (avoids 403 on some CDNs)
_M.WEB = {
    ua = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
    referer = "https://www.dmm.co.jp/",
}

-- CID conversion: user input "ABP-477" -> try multiple DMM CID variants.
-- DMM internal ids are many-to-many with product ids (e.g. dldss00409 vs 1dldss409),
-- so we probe several variants.
function _M.to_cids(raw_id)
    local id = string.lower(raw_id):gsub("%s+", ""):gsub("-", "")

    local prefix = id:match("^%a+")
    local number = id:match("%a+(%d+)$")

    if not prefix or not number then
        return { id }
    end

    local n = tonumber(number)
    local padded = string.format("%05d", n)
    local raw = tostring(n)

    local cids = {}
    local seen = {}

    local function add(cid)
        if not seen[cid] then
            seen[cid] = true
            cids[#cids + 1] = cid
        end
    end

    -- digital variants (zero-padded to 5)
    add(prefix .. padded)             -- abp00477
    add(prefix .. string.format("%04d", n)) -- abp0477
    add(prefix .. raw)                -- abp477

    -- DVD / mono variants (prefix "1", sometimes dropping leading 0)
    add("1" .. prefix .. raw)         -- 1abp477
    add("1" .. prefix .. padded)      -- 1abp00477

    -- alternate: drop a single leading zero from padded
    if string.sub(padded, 1, 1) == "0" then
        add(prefix .. string.sub(padded, 2)) -- abp0477-ish already covered
    end

    return cids
end

-- Build a path on OUR proxy so clients can pull resources through this VPS
-- (avoids DMM geo-blocks / 403 by fetching from a Japan IP).
-- kind: "pics" | "aws" | "video"
-- When protection is ON the returned URL is signed (?sig=&exp=) and only valid
-- for SIGN_TTL seconds; when OFF a plain unsigned path is returned.
function _M.proxy_path(kind, path)
    local base
    if kind == "aws" then
        base = "/proxy/aws/" .. path
    elseif kind == "sample" then
        base = "/proxy/sample/" .. path
    elseif kind == "video" then
        base = "/proxy/video/" .. path
    else
        base = "/proxy/pics/" .. path
    end
    if not is_on(_M.PROTECT) then
        return base
    end
    local sign = require "sign"
    return sign.sign(base)
end

-- Whether the protection features are currently enabled.
function _M.protect_enabled()
    return is_on(_M.PROTECT)
end

-- Client IP whitelist. Returns true when:
--   * DMM_ALLOW_IPS is empty (no restriction), or
--   * ip is listed as a literal IPv4 or a CIDR.
-- Rules are parsed and cached on first call.
local bit = require "bit"

local ip_rules
local function compile_ip_rules()
    local rules = {}
    for entry in (_M.ALLOW_IPS .. ""):gmatch("[^,%s]+") do
        local ip, cidr = entry:match("^([^/]+)/(%d+)$")
        if cidr then
            rules[#rules + 1] = { kind = "cidr", ip = ip, prefix = tonumber(cidr) }
        else
            rules[#rules + 1] = { kind = "ip", ip = entry }
        end
    end
    ip_rules = rules
end

local function ip_to_long(ip)
    local a, b, c, d = ip:match("^(%d+)%.(%d+)%.(%d+)%.(%d+)$")
    if not a then
        return nil
    end
    return (tonumber(a) * 16777216) + (tonumber(b) * 65536) + (tonumber(c) * 256) + tonumber(d)
end

local function cidr_mask(prefix)
    if prefix >= 32 then
        return 0xffffffff
    end
    return bit.band(0xffffffff, bit.lshift(0xffffffff, 32 - prefix))
end

function _M.ip_allowed(ip)
    if _M.ALLOW_IPS == "" then
        return true
    end
    if not ip_rules then
        compile_ip_rules()
    end
    if #ip_rules == 0 then
        return true
    end
    local ipv4 = ip_to_long(ip)
    for _, r in ipairs(ip_rules) do
        if r.kind == "ip" and r.ip == ip then
            return true
        end
        if r.kind == "cidr" and ipv4 then
            local net = ip_to_long(r.ip)
            if net then
                local mask = cidr_mask(r.prefix)
                if bit.band(ipv4, mask) == bit.band(net, mask) then
                    return true
                end
            end
        end
    end
    return false
end

return _M
