local http = require "resty.http"
local config = require "config"

local _M = {}

-- Check whether a URL is fetchable.
-- Sends a Range request (bytes=0-1023) so the CDN returns only ~1KB instead of
-- the whole file (trailer mp4s are large), making each probe fast.
-- GET is used (not HEAD) because some DMM CDNs (awsimgsrc) return 405 on HEAD
-- (see mdcx issue #672). Both 200 (no range support) and 206 (partial) mean the
-- resource exists; 416 (range not satisfiable) also proves it exists.
local function check_url_exists(url)
    local httpc = http.new()
    httpc:set_timeout(10000)
    local res, err = httpc:request_uri(url, {
        method = "GET",
        ssl_verify = false,
        max_body_size = 8192,
        headers = {
            ["User-Agent"] = config.WEB.ua,
            ["Referer"] = config.WEB.referer,
            ["Range"] = "bytes=0-1023",
        },
    })
    if res and (res.status == 200 or res.status == 206 or res.status == 416) then
        return true
    end
    return false
end

-- Fetch full body of a URL (for potential future use / streaming)
local function fetch_body(url)
    local httpc = http.new()
    httpc:set_timeout(10000)
    local res, err = httpc:request_uri(url, {
        method = "GET",
        ssl_verify = false,
        headers = {
            ["User-Agent"] = config.WEB.ua,
            ["Referer"] = config.WEB.referer,
        },
    })
    if not res then
        return nil, err
    end
    return res.body, nil, res.status
end

_M.check_url_exists = check_url_exists
_M.fetch_body = fetch_body

return _M
