FROM openresty/openresty:alpine

# lua-resty-http (pure-Lua, no deps). Vended locally to avoid relying on
# opm/perl or the LuaJIT-incompatible alpine lua5.4 luarocks package.
COPY vendor/resty/http.lua /usr/local/openresty/site/lualib/resty/http.lua
COPY vendor/resty/http_headers.lua /usr/local/openresty/site/lualib/resty/http_headers.lua
COPY vendor/resty/http_connect.lua /usr/local/openresty/site/lualib/resty/http_connect.lua

COPY conf/nginx.conf /usr/local/openresty/nginx/conf/nginx.conf
COPY lua/ /etc/openresty/lua/

RUN mkdir -p /var/log/openresty

EXPOSE 80 443

CMD ["/usr/local/openresty/bin/openresty", "-g", "daemon off;"]
