#!/bin/sh
# Put the Let's Encrypt wildcard into the rpi-gardener certs volume as
# nginx's default cert, so gardener.@DOMAIN@ serves it: the app's nginx only
# maps *.ts.net names to the Tailscale cert, every other name gets server.*.
# Runs as certbot's deploy hook on renewal and once from setup.sh, which
# fills in @DOMAIN@. nginx picks the cert per handshake (SNI variable), so
# no reload is needed.
# ponytail: overwrites the app's self-signed server.* rather than teaching
# its SNI map about this domain, gardener.local gets the wildcard too
set -eu

command -v docker >/dev/null || { echo "docker missing, run make deploy-gardener first" >&2; exit 1; }

# live/ holds symlinks into archive/, hence cp -L. uid 101 is the nginx
# worker, which reads the key.
docker run --rm -v rpi-gardener-certs:/certs -v /etc/letsencrypt:/le:ro alpine sh -c \
  'cp -L /le/live/@DOMAIN@/fullchain.pem /certs/server.crt \
   && cp -L /le/live/@DOMAIN@/privkey.pem /certs/server.key \
   && chmod 644 /certs/server.crt && chmod 600 /certs/server.key && chown 101:101 /certs/server.key'
