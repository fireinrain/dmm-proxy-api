local cjson = require "cjson"
local config = require "config"

local _M = {}

function _M.check_auth()
    local auth_header = ngx.req.get_headers()["Authorization"]
    if not auth_header then
        ngx.status = 401
        ngx.header["Content-Type"] = "application/json; charset=utf-8"
        ngx.say(cjson.encode({
            error = "unauthorized",
            message = "Missing Authorization header. Use: Authorization: Bearer <token>",
        }))
        return ngx.exit(ngx.HTTP_UNAUTHORIZED)
    end

    local token = auth_header:match("^Bearer%s+(.+)$")
    if not token or token ~= config.AUTH_TOKEN then
        ngx.status = 403
        ngx.header["Content-Type"] = "application/json; charset=utf-8"
        ngx.say(cjson.encode({
            error = "forbidden",
            message = "Invalid token",
        }))
        return ngx.exit(ngx.HTTP_FORBIDDEN)
    end
end

function _M.handle_cover()
    local id = ngx.var.api_id
    if not id or id == "" then
        ngx.status = 400
        ngx.header["Content-Type"] = "application/json; charset=utf-8"
        ngx.say(cjson.encode({
            error = "bad_request",
            message = "Missing id parameter. Usage: /api/cover/:id",
        }))
        return
    end

    local cover = require "api_cover"
    cover.handle(id)
end

function _M.handle_trailer()
    local id = ngx.var.api_id
    if not id or id == "" then
        ngx.status = 400
        ngx.header["Content-Type"] = "application/json; charset=utf-8"
        ngx.say(cjson.encode({
            error = "bad_request",
            message = "Missing id parameter. Usage: /api/trailer/:id",
        }))
        return
    end

    local trailer = require "api_trailer"
    trailer.handle(id)
end

return _M
