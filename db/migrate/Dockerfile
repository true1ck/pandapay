# Build from the repository root; the scoped ignore file excludes credentials.
ARG POSTGRES_CLIENT_MAJOR=17
FROM postgres:${POSTGRES_CLIENT_MAJOR}-alpine
RUN apk add --no-cache bash nodejs npm
WORKDIR /workspace/auth
COPY auth/package.json auth/package-lock.json ./
RUN npm ci --omit=dev --ignore-scripts
COPY auth/scripts ./scripts
COPY auth/src/utils/fieldEncryption.js auth/src/utils/encryptedPhoneSearch.js auth/src/utils/dbTls.js auth/src/utils/safeErrorCode.js ./src/utils/
# The deploy audit (auditContactUniqueness.js, run before any downtime) and the support
# tools (recovery_support.js, account_clusters.js) load these. A test builds this exact
# file set and requires each script, so a new import cannot silently break the deploy gate.
COPY auth/src/utils/emailIdentity.js auth/src/utils/recoveryContacts.js auth/src/utils/claimedPhone.js auth/src/utils/phoneGate.js ./src/utils/
COPY auth/src/data/disposableEmailDomains.js ./src/data/
COPY auth/src/services/phoneClaim.js auth/src/services/deviceAccountLimit.js ./src/services/
COPY auth/db/pandapay-auth/init.sql ./db/pandapay-auth/init.sql
COPY auth/db/migrations ./db/migrations
ENV AUTH_APP_DIR=/workspace/auth
WORKDIR /db
ENTRYPOINT ["bash", "/db/scripts/migrate.sh"]
