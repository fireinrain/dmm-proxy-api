FROM openresty/openresty:alpine

# lua-resty-http (pure-Lua, no deps). Vended locally to avoid relying on
# opm/perl or the LuaJIT-incompatible alpine lua5.4 luarocks package.
COPY vendor/resty/http.lua /usr/local/openresty/site/lualib/resty/http.lua
COPY vendor/resty/http_headers.lua /usr/local/openresty/site/lualib/resty/http_headers.lua
COPY vendor/resty/http_connect.lua /usr/local/openresty/site/lualib/resty/http_connect.lua

COPY conf/nginx.conf /usr/local/openresty/nginx/conf/nginx.conf
COPY conf/dmm.ssl.conf.template /usr/local/openresty/nginx/conf/dmm.ssl.conf.template
COPY lua/ /etc/openresty/lua/
COPY docker/entrypoint.sh /usr/local/bin/entrypoint.sh

RUN mkdir -p /var/log/openresty \
    && chmod +x /usr/local/bin/entrypoint.sh \
    && mkdir -p /etc/ssl/dmm \
    && mkdir -p /etc/openresty/static

EXPOSE 80 443

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["/usr/local/openresty/bin/openresty", "-g", "daemon off;"]
