#!/bin/sh
# Container entrypoint.
#
# Enables the HTTPS (443) server block only when both SSL certificate files
# exist in /etc/ssl/dmm/. If either is missing, HTTPS is disabled and only
# the HTTP (80) listener runs. The rendered result is written to
# /usr/local/openresty/nginx/conf/dmm.d/ssl.conf, which is included by
# conf/nginx.conf.

set -e

CERT_DIR="${DMM_CERT_DIR:-/etc/ssl/dmm}"
CERT_FILE="${DMM_CERT_FILE:-fullchain.pem}"
KEY_FILE="${DMM_CERT_KEY:-privkey.pem}"
CONF_DIR=/usr/local/openresty/nginx/conf/dmm.d
RENDERED="$CONF_DIR/ssl.conf"
TEMPLATE=/usr/local/openresty/nginx/conf/dmm.ssl.conf.template

mkdir -p "$CONF_DIR"

if [ -f "$CERT_DIR/$CERT_FILE" ] && [ -f "$CERT_DIR/$KEY_FILE" ]; then
    echo "[entrypoint] SSL enabled: using $CERT_DIR/{$CERT_FILE,$KEY_FILE}"
    cp "$TEMPLATE" "$RENDERED"
else
    echo "[entrypoint] SSL disabled: no certificate files in $CERT_DIR, HTTP only"
    : > "$RENDERED"
fi

exec "$@"
