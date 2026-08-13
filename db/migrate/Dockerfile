# db-migrate's runner image. A code review of docker-compose.prod.yml/
# staging.yml caught that their db-migrate service ran `apk add --no-cache
# bash` in the container's entrypoint, at every single migration invocation
# — a network fetch from Alpine's package mirror on every deploy, not once
# at build time. db/backup/Dockerfile already shows the right pattern
# (bash baked in via `RUN apk add`); this is the same fix applied here.
#
# No COPY of db/scripts — those arrive via the `./db:/db:ro` volume mount in
# docker-compose.prod.yml/staging.yml, same as before. This image only needs
# to provide bash + the postgres client tools (already in the base image).
FROM postgres:16-alpine

RUN apk add --no-cache bash

ENTRYPOINT ["bash", "/db/scripts/migrate.sh"]
