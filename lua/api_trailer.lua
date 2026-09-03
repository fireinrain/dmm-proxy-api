local cjson = require "cjson"
local config = require "config"
local web = require "web"

local _M = {}

local qualities = {
    { quality = "sm",  suffix = "_sm_w.mp4",  bitrate = 300  },
    { quality = "dm",  suffix = "_dm_w.mp4",  bitrate = 1000 },
    { quality = "dmb", suffix = "_dmb_w.mp4", bitrate = 1500 },
    { quality = "mhb", suffix = "_mhb_w.mp4", bitrate = 2500 },
}

function _M.handle(raw_id)
    local cids = config.to_cids(raw_id)

    for _, cid in ipairs(cids) do
        local trailers = {}
        local lite_dir = "litevideo/freepv/"
            .. string.sub(cid, 1, 1) .. "/" .. string.sub(cid, 1, 3) .. "/" .. cid .. "/"
        local base = config.CDN.litevideo .. "/" .. lite_dir

        for _, q in ipairs(qualities) do
            local file = cid .. q.suffix
            local url = base .. file
            if web.check_url_exists(url) then
                trailers[#trailers + 1] = {
                    quality = q.quality,
                    bitrate = q.bitrate,
                    url = url,
                    -- stream through this VPS to avoid DMM geo-block
                    proxy = config.proxy_path("video", lite_dir .. file),
                }
            end
        end

        if #trailers > 0 then
            ngx.status = 200
            ngx.header["Content-Type"] = "application/json; charset=utf-8"
            ngx.say(cjson.encode({
                id = string.upper(raw_id),
                cid = cid,
                trailers = trailers,
            }))
            return
        end
    end

    ngx.status = 404
    ngx.header["Content-Type"] = "application/json; charset=utf-8"
    ngx.say(cjson.encode({
        error = "not_found",
        message = "Trailer not found for id: " .. raw_id,
    }))
end

return _M
