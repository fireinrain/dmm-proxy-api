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
        bookmarkCount
        salesInfo {
          lowestPrice {
            productId
            price
            discountPrice
          }
          hasMultiplePrices
        }
        sampleMovie {
          hlsUrl
          mp4Url
        }
        sampleImages {
          number
          largeUrl
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

local function fetch_ranking(offset, limit)
    local payload = cjson.encode({
        operationName = "AvSearch",
        variables = {
            excludeUndelivered = false,
            facetLimit = 100,
            filter = {
                isSaleItemsOnly = false,
            },
            floor = "AV",
            limit = limit,
            offset = offset,
            sort = "SALES_RANK_SCORE",
        },
        query = QUERY,
    })

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
        return nil, err
    end
    if res.status ~= 200 then
        return nil, "graphql status " .. res.status
    end

    local ok, data = pcall(cjson.decode, res.body)
    if not ok or type(data) ~= "table" then
        return nil, "invalid json response"
    end

    if data.errors then
        return nil, "graphql error: " .. (data.errors[1] and data.errors[1].message or "unknown")
    end

    local ppv = data.data and data.data.legacySearchPPV
    if not ppv or not ppv.result then
        return nil, "unexpected response structure"
    end

    return ppv.result
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

    local limit = parse_limit(args.limit)
    local offset = parse_int_param(args.offset, 0)

    local result, err = fetch_ranking(offset, limit)
    if not result then
        ngx.log(ngx.ERR, "ranking fetch failed: " .. tostring(err))
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
            rank = offset + i,
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
            bookmarkCount = c.bookmarkCount or 0,
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
            for _, img_item in ipairs(c.sampleImages) do
                images[#images + 1] = {
                    number = img_item.number or 0,
                    largeUrl = img_item.largeUrl or "",
                }
            end
            work.sampleImages = images
        end

        works[i] = work
    end

    ngx.status = 200
    ngx.header["Content-Type"] = "application/json; charset=utf-8"
    ngx.say(cjson.encode({
        total = page.totalCount or #works,
        limit = page.limit or limit,
        offset = page.offset or offset,
        hasNext = page.hasNext or false,
        count = #works,
        works = works,
    }))
end

return _M
