local cjson = require "cjson"
local config = require "config"
local http = require "resty.http"

local _M = {}

local ENDPOINT = "https://api.video.dmm.co.jp/graphql"

local QUERY = [[query AvSearch($limit: Int!, $offset: Int, $floor: PPVFloor, $sort: ContentSearchPPVSort!, $filter: ContentSearchPPVFilterInput, $excludeUndelivered: Boolean!, $facetLimit: Int!) {
  legacySearchPPV(limit: $limit, offset: $offset, floor: $floor, sort: $sort, filter: $filter, facetLimit: $facetLimit, includeExplicit: true, excludeUndelivered: $excludeUndelivered) {
    result {
      contents {
        id
        title
        packageImage {
          mediumUrl
          largeUrl
        }
        releaseStatus
        review {
          average
          count
        }
        actresses {
          id
          name
        }
        maker {
          id
          name
        }
        isOnSale
        deliveryStartAt
        salesInfo {
          lowestPrice {
            productId
            price
            discountPrice
          }
          hasMultiplePrices
        }
        sampleImages {
          number
          largeUrl
        }
        sampleMovie {
          hlsUrl
          mp4Url
        }
      }
      pageInfo {
        offset
        limit
        hasNext
        totalCount
      }
    }
  }
}]]

local function fetch_daily(date, offset, limit)
    local payload = cjson.encode({
        operationName = "AvSearch",
        variables = {
            excludeUndelivered = false,
            facetLimit = 100,
            filter = {
                deliveryStartDate = date,
                isSaleItemsOnly = false,
            },
            floor = "AV",
            limit = limit,
            offset = offset,
            sort = "DELIVERY_START_DATE",
        },
        query = QUERY,
    })

    local last_err
    for attempt = 1, 2 do
        local httpc = http.new()
        httpc:set_timeout(15000)
        local res, err = httpc:request_uri(ENDPOINT, {
            method = "POST",
            ssl_verify = false,
            headers = {
                ["Content-Type"] = "application/json",
                ["User-Agent"] = config.WEB.ua,
                ["Origin"] = "https://video.dmm.co.jp",
                ["Referer"] = "https://video.dmm.co.jp/",
            },
            body = payload,
        })
        if not res then
            last_err = err
            ngx.sleep(0.5)
        elseif res.status ~= 200 then
            last_err = "graphql status " .. res.status
            ngx.sleep(0.5)
        else
            local ok, data = pcall(cjson.decode, res.body)
            if not ok or type(data) ~= "table" then
                last_err = "invalid json response"
                ngx.sleep(0.5)
            elseif data.errors then
                last_err = "graphql error: " .. (data.errors[1] and data.errors[1].message or "unknown")
                ngx.sleep(0.5)
            else
                local ppv = data.data and data.data.legacySearchPPV
                if not ppv or not ppv.result then
                    last_err = "unexpected response structure"
                    ngx.sleep(0.5)
                else
                    return ppv.result
                end
            end
        end
    end

    return nil, last_err
end

local function parse_date_param(raw)
    if not raw or raw == "" then
        return nil
    end
    if not raw:match("^%d%d%d%d%-%d%d%-%d%d$") then
        return nil
    end
    local y, m, d = raw:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)$")
    local year = tonumber(y)
    local month = tonumber(m)
    local day = tonumber(d)
    if not year or not month or not day then
        return nil
    end
    if month < 1 or month > 12 or day < 1 or day > 31 then
        return nil
    end
    return string.format("%04d-%02d-%02d", year, month, day)
end

local function get_today_jst()
    local now = ngx.time()
    local jst_offset = 9 * 3600
    local today_jst = os.date("!%Y-%m-%d", now + jst_offset)
    return today_jst
end

local VALID_LIMITS = { [30] = true, [60] = true, [120] = true }

local function parse_limit(raw)
    if not raw or raw == "" then
        return 30
    end
    local n = tonumber(raw)
    if not n or not VALID_LIMITS[n] then
        return 30
    end
    return n
end

local function parse_int_param(raw, default_val)
    if not raw or raw == "" then
        return default_val
    end
    local n = tonumber(raw)
    if not n or n ~= math.floor(n) then
        return default_val
    end
    return n
end

function _M.handle()
    local args = ngx.req.get_uri_args()

    local date = parse_date_param(args.date)
    if not date then
        date = get_today_jst()
    end

    local limit = parse_limit(args.limit)
    local offset = parse_int_param(args.offset, 0)

    local result, err = fetch_daily(date, offset, limit)
    if not result then
        ngx.log(ngx.ERR, "todayupdate fetch failed for date=" .. date .. ": " .. tostring(err))
        ngx.status = 502
        ngx.header["Content-Type"] = "application/json; charset=utf-8"
        ngx.say(cjson.encode({
            error = "upstream_error",
            message = "Failed to fetch data from DMM: " .. tostring(err),
        }))
        return
    end

    local contents = result.contents or {}
    local page = result.pageInfo or {}

    local works = {}
    for i, c in ipairs(contents) do
        local img = c.packageImage or {}
        local work = {
            id = c.id,
            title = c.title or "",
            cover = {
                medium = img.mediumUrl or "",
                large = img.largeUrl or "",
            },
            deliveryStartAt = c.deliveryStartAt or "",
            actresses = {},
            maker = c.maker or {},
            isOnSale = c.isOnSale,
            review = {
                average = c.review and c.review.average or 0,
                count = c.review and c.review.count or 0,
            },
            releaseStatus = c.releaseStatus or "",
        }

        if c.actresses and type(c.actresses) == "table" then
            for _, actress in ipairs(c.actresses) do
                work.actresses[#work.actresses + 1] = {
                    id = actress.id,
                    name = actress.name,
                }
            end
        end

        if c.salesInfo and c.salesInfo.lowestPrice then
            local price = c.salesInfo.lowestPrice
            work.price = {
                productId = price.productId or "",
                price = price.price or 0,
                discountPrice = price.discountPrice,
            }
            work.hasMultiplePrices = c.salesInfo.hasMultiplePrices
        end

        local movie = c.sampleMovie or {}
        if movie.mp4Url or movie.hlsUrl then
            work.sampleMovie = {
                mp4 = movie.mp4Url or "",
                hls = movie.hlsUrl or "",
            }
        end

        if c.sampleImages and type(c.sampleImages) == "table" then
            local images = {}
            for _, img in ipairs(c.sampleImages) do
                images[#images + 1] = {
                    number = img.number or 0,
                    largeUrl = img.largeUrl or "",
                }
            end
            work.sampleImages = images
        end

        works[i] = work
    end

    ngx.status = 200
    ngx.header["Content-Type"] = "application/json; charset=utf-8"
    ngx.say(cjson.encode({
        date = date,
        total = page.totalCount or #works,
        limit = page.limit or limit,
        offset = page.offset or offset,
        hasNext = page.hasNext or false,
        count = #works,
        works = works,
    }))
end

return _M
