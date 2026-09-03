local cjson = require "cjson"
local config = require "config"
local web = require "web"

local _M = {}

local function cdn_for(host, cid)
    return host .. "/digital/video/" .. cid .. "/" .. cid
end

-- Cover large pl.jpg (2K if available via awsimgsrc, else standard pics)
local function cover_large(cid)
    return {
        hd = cdn_for(config.CDN.images_hd, cid) .. "pl.jpg",
        sd = cdn_for(config.CDN.images, cid) .. "pl.jpg",
    }
end

function _M.handle(raw_id)
    local cids = config.to_cids(raw_id)

    for _, cid in ipairs(cids) do
        local covers = cover_large(cid)
        local cid_dir = "digital/video/" .. cid .. "/"

        -- Try high-res (awsimgsrc) first for a 2K cover
        local chosen_hd = web.check_url_exists(covers.hd)
        local chosen_sd = false
        if not chosen_hd then
            chosen_sd = web.check_url_exists(covers.sd)
        end

        if chosen_hd or chosen_sd then
            local small_url = cdn_for(config.CDN.images, cid) .. "pt.jpg"
            local samples = {}
            for i = 1, 20 do
                local sample_file = cid .. "jp-" .. i .. ".jpg"
                local sample_url = cdn_for(config.CDN.images, cid) .. sample_file
                if web.check_url_exists(sample_url) then
                    samples[#samples + 1] = sample_url
                else
                    break
                end
            end

            ngx.status = 200
            ngx.header["Content-Type"] = "application/json; charset=utf-8"
            ngx.say(cjson.encode({
                id = string.upper(raw_id),
                cid = cid,
                cover = {
                    -- primary: 2K high-res when available, else standard
                    large = chosen_hd and covers.hd or covers.sd,
                    hd = covers.hd,
                    sd = covers.sd,
                    small = small_url,
                    samples = samples,
                    -- proxied through THIS VPS (Japan IP), so clients avoid
                    -- DMM geo-blocking / 403
                    proxy = {
                        hd = config.proxy_path("aws", cid_dir .. cid .. "pl.jpg"),
                        sd = config.proxy_path("pics", cid_dir .. cid .. "pl.jpg"),
                        small = config.proxy_path("pics", cid_dir .. cid .. "pt.jpg"),
                        -- samples via proxy (same files as direct)
                        samples_url = config.proxy_path("pics", cid_dir),
                    },
                },
            }))
            return
        end
    end

    ngx.status = 404
    ngx.header["Content-Type"] = "application/json; charset=utf-8"
    ngx.say(cjson.encode({
        error = "not_found",
        message = "Cover not found for id: " .. raw_id,
    }))
end

return _M
