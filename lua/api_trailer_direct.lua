local cjson = require "cjson"
local config = require "config"

local _M = {}

-- Cache TTL for a found trailer (7 days).
local CACHE_TTL = 7 * 86400
-- Total budget for the three racing upstream requests.
local REQ_TIMEOUT = 5000 -- ms

-- Three independent upstream sources. Each returns (url, source) on success.
-- Implemented as cosocket functions so they can be raced via ngx.thread.

-- Source 1: AVWikiDB
-- Parses the __NEXT_DATA__ JSON embedded in the page and reads
-- props.pageProps.movie.sampleVideoBestUrl.
local function fetch_avwikidb(code)
    local url = "https://avwikidb.com/work/" .. ngx.escape_uri(code) .. "/"
    local httpc = require "resty.http".new()
    httpc:set_timeout(REQ_TIMEOUT)
    local res, err = httpc:request_uri(url, {
        method = "GET",
        ssl_verify = false,
        headers = { ["User-Agent"] = config.WEB.ua },
    })
    if not res or res.status ~= 200 then
        ngx.log(ngx.ERR, "avwikidb status=" .. (res and res.status or "nil") .. " err=" .. tostring(err))
        return nil
    end
    local json_text = res.body:match('<script id="__NEXT_DATA__" type="application/json">(.-)</script>')
    if not json_text then return nil end
    local ok, data = pcall(cjson.decode, json_text)
    if not ok or type(data) ~= "table" then return nil end
    local movie = data.props and data.props.pageProps and data.props.pageProps.movie
    if type(movie) ~= "table" then return nil end
    local trailer = movie.sampleVideoBestUrl
    if type(trailer) ~= "string" or trailer == "" then return nil end
    return trailer, "avwikidb"
end

-- Source 2: DMM FANZA
-- Resolves the content_id via the affiliate API, then hits the html5_player
-- endpoint to obtain the preview "src".
local function fetch_dmm(code)
    local httpc = require "resty.http".new()
    httpc:set_timeout(REQ_TIMEOUT)

    local api_url =
        "https://api.dmm.com/affiliate/v3/ItemList?"
        .. ngx.encode_args({
            api_id = "UrwskPfkqQ0DuVry2gYL",
            affiliate_id = "10278-996",
            output = "json",
            site = "FANZA",
            sort = "match",
            keyword = code,
        })
    local res, err = httpc:request_uri(api_url, {
        method = "GET",
        ssl_verify = false,
        headers = { ["User-Agent"] = config.WEB.ua },
    })
    if not res or res.status ~= 200 then
        ngx.log(ngx.ERR, "dmm api status=" .. (res and res.status or "nil") .. " err=" .. tostring(err))
        return nil
    end
    local ok, body = pcall(cjson.decode, res.body)
    if not ok or type(body) ~= "table" then return nil end
    local items = body.result and body.result.items
    if type(items) ~= "table" or #items == 0 then return nil end
    local first = items[1]
    if type(first) ~= "table" then return nil end
    local cid = first.content_id
    local service = first.service_code
    local floor = first.floor_code
    if not cid or not service or not floor then return nil end

    local player_url = "https://www.dmm.co.jp/service/digitalapi/-/html5_player/=/cid="
        .. ngx.escape_uri(cid)
        .. "/mtype=AhRVShI_/service=" .. ngx.escape_uri(service)
        .. "/floor=" .. ngx.escape_uri(floor) .. "/mode=/"
    local presto_res, prestr = httpc:request_uri(player_url, {
        method = "GET",
        ssl_verify = false,
        headers = {
            ["User-Agent"] = config.WEB.ua,
            ["Cookie"] = "age_check_done=1",
        },
    })
    if not presto_res then
        ngx.log(ngx.ERR, "dmm player err=" .. tostring(prestr))
        return nil
    end
    local text = presto_res.body or ""
    if not text:find("dmmplayer", 1, true) then return nil end
    local src_match = text:match('"src"%s*:%s*("(.-)")')
    local src_raw = src_match and src_match:gsub("\\\"", '"'):gsub("\\\\", "\\") or nil
    if not src_raw or not src_raw:find("//", 1, true) then return nil end
    local trailer = src_raw:sub(1, 2) == "//" and ("https:" .. src_raw) or src_raw
    return trailer, "dmm"
end

-- Source 3: JAVDatabase
-- Reads the first <source src="..."> under <video id="jav-player">.
local function fetch_javdatabase(code)
    local url = "https://www.javdatabase.com/movies/" .. ngx.escape_uri(code) .. "/"
    local httpc = require "resty.http".new()
    httpc:set_timeout(REQ_TIMEOUT)
    local res, err = httpc:request_uri(url, {
        method = "GET",
        ssl_verify = false,
        headers = { ["User-Agent"] = config.WEB.ua },
    })
    if not res or res.status ~= 200 then
        ngx.log(ngx.ERR, "javdatabase status=" .. (res and res.status or "nil") .. " err=" .. tostring(err))
        return nil
    end
    local trailer = res.body:match('<video id="jav%-player".-<source src="([^"]+)"')
    if not trailer then return nil end
    return trailer, "javdatabase"
end

-- Runs the three fetchers concurrently and adopts the first that succeeds.
-- Each fetcher is spawned as a light thread; we harvest in spawn order and
-- return as soon as one succeeds (all run in parallel, so this is "first that
-- succeeds"). Returns (url, source) or (nil, nil).
local function race_fetch(code)
    local threads = {}
    threads[1] = ngx.thread.spawn(fetch_avwikidb, code)
    threads[2] = ngx.thread.spawn(fetch_dmm, code)
    threads[3] = ngx.thread.spawn(fetch_javdatabase, code)

    for i = 1, 3 do
        local ok, url, source = ngx.thread.wait(threads[i])
        if ok and url then
            return url, source
        end
    end
    return nil, nil
end

local function lookup_code(code)
    local cache = ngx.shared.trailer_cache
    local key = "td:" .. code

    -- 1. cache hit?
    local cached = cache:get(key)
    if cached then
        return cached, cache:get(key .. ":src") or "cache"
    end

    -- 2. miss: race the upstream sources.
    local url, source = race_fetch(code)
    if not url then
        return nil, nil
    end

    -- 3. persist result (7 days).
    cache:set(key, url, CACHE_TTL)
    cache:set(key .. ":src", source, CACHE_TTL)
    return url, source
end

function _M.handle(raw_id)
    -- Normalise the code to the uppercase form used as the cache key and,
    -- where applicable, the DMM affiliate keyword.
    local code = string.upper(raw_id):gsub("%s+", "")
    if code == "" then
        ngx.status = 400
        ngx.header["Content-Type"] = "application/json; charset=utf-8"
        ngx.say(cjson.encode({ error = "bad_request", message = "Missing code" }))
        return
    end

    local trailer, source = lookup_code(code)
    if not trailer then
        ngx.status = 404
        ngx.header["Content-Type"] = "application/json; charset=utf-8"
        ngx.say(cjson.encode({
            error = "not_found",
            message = "No trailer found for code: " .. code,
        }))
        return
    end

    ngx.status = 200
    ngx.header["Content-Type"] = "application/json; charset=utf-8"
    ngx.say(cjson.encode({
        code = code,
        trailer = trailer,
        source = source,
    }))
end

return _M