local cjson = require "cjson"
local config = require "config"
local web = require "web"

local _M = {}

local QUERY = [[query FetchFanzaTvPlusContent($id: ID!, $device: Device!, $isForeign: Boolean) {
  fanzaTvPlus(device: $device) {
    content(id: $id, isForeign: $isForeign) {
      id
      productId
      samplePictures {
        image
        imageLarge
      }
      __typename
    }
    __typename
  }
}]]

-- Fetch all sample images for a cid via the public FANZA TV GraphQL API.
-- Returns { {image=, imageLarge=}, ... } or nil.
local ENDPOINT = "https://api.tv.dmm.co.jp/graphql"

local function fetch_samples(cid)
    local payload = cjson.encode({
        operationName = "FetchFanzaTvPlusContent",
        variables = {
            id = cid,
            device = "BROWSER",
            isForeign = false,
        },
        query = QUERY,
    })

    local httpc = require "resty.http".new()
    httpc:set_timeout(10000)
    local res, err = httpc:request_uri(ENDPOINT, {
        method = "POST",
        ssl_verify = false,
        headers = {
            ["Content-Type"] = "application/json",
            ["User-Agent"] = config.WEB.ua,
        },
        body = payload,
    })
    if not res then
        return nil, err
    end
    if res.status ~= 200 then
        return nil, "graphql status " .. res.status
    end

    local ok, data = pcall(cjson.decode, res.body)
    if not ok or type(data) ~= "table" or not data.data
        or type(data.data) ~= "table"
        or not data.data.fanzaTvPlus
        or type(data.data.fanzaTvPlus) ~= "table"
        or not data.data.fanzaTvPlus.content
        or type(data.data.fanzaTvPlus.content) ~= "table"
        or not data.data.fanzaTvPlus.content.samplePictures
        or type(data.data.fanzaTvPlus.content.samplePictures) ~= "table" then
        return nil, "unexpected response"
    end

    return data.data.fanzaTvPlus.content.samplePictures
end

function _M.handle(raw_id)
    local cids = config.to_cids(raw_id)

    for _, cid in ipairs(cids) do
        local pics, err = fetch_samples(cid)
        if not pics then
            ngx.log(ngx.ERR, "film_sample fetch failed for cid=" .. cid .. ": " .. tostring(err))
        end
        if pics and #pics > 0 then
            local samples = {}
            for i, pic in ipairs(pics) do
                local image = pic.image or ""
                local imageLarge = pic.imageLarge or ""
                local rel = (imageLarge:gsub("^https?://awsimgsrc%.dmm%.co%.jp/dig_white/", ""))
                samples[i] = {
                    index = i,
                    small = image,
                    large = imageLarge,
                    proxy = config.proxy_path("sample", rel),
                }
            end

            ngx.status = 200
            ngx.header["Content-Type"] = "application/json; charset=utf-8"
            ngx.say(cjson.encode({
                id = string.upper(raw_id),
                cid = cid,
                total = #samples,
                samples = samples,
            }))
            return
        end
    end

    ngx.status = 404
    ngx.header["Content-Type"] = "application/json; charset=utf-8"
    ngx.say(cjson.encode({
        error = "not_found",
        message = "No sample images found for id: " .. raw_id,
    }))
end

return _M
