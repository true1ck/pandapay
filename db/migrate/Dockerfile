# Build from the repository root; the scoped ignore file excludes credentials.
ARG POSTGRES_CLIENT_MAJOR=17
FROM postgres:${POSTGRES_CLIENT_MAJOR}-alpine
RUN apk add --no-cache bash nodejs npm
WORKDIR /workspace/auth
COPY auth/package.json auth/package-lock.json ./
RUN npm ci --omit=dev --ignore-scripts
COPY auth/scripts ./scripts
COPY auth/src/utils/fieldEncryption.js auth/src/utils/encryptedPhoneSearch.js auth/src/utils/dbTls.js auth/src/utils/safeErrorCode.js ./src/utils/
COPY auth/db/pandapay-auth/init.sql ./db/pandapay-auth/init.sql
COPY auth/db/migrations ./db/migrations
ENV AUTH_APP_DIR=/workspace/auth
WORKDIR /db
ENTRYPOINT ["bash", "/db/scripts/migrate.sh"]
