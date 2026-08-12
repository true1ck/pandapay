# Plan Phase 0.2 — the auth service's container. Same shape as api/Dockerfile;
# see that file for why each step is the way it is.
#
# auth/ differs in one respect that matters operationally: it loads secrets
# from AWS SSM at startup (src/utils/awsSsm.js) when JWT_SECRETS_ARN is set,
# so the container needs outbound network and an instance role at boot, not
# just at request time. A health check that passes before secrets resolve
# would let a broken deploy go green, which is why the start period below is
# longer than api/'s.
#
# Pinned to a digest-less but explicit minor (`22-alpine` rather than `node` or
# `latest`): a floating tag means the image that passed CI is not necessarily
# the image that ships, which is the whole class of "works on the runner"
# failure that container builds exist to prevent.
FROM node:22-alpine AS deps

WORKDIR /app

# Copied on their own, before the source, so a source-only change reuses the
# cached dependency layer instead of reinstalling on every build.
COPY package.json package-lock.json* ./

# `npm ci` when a lockfile is present — it installs exactly what's pinned and
# fails on drift, unlike `npm install` which will happily resolve something
# newer. Falls back to `npm install` only because this repo does not currently
# commit a lockfile; committing one is the right follow-up.
RUN if [ -f package-lock.json ]; then npm ci --omit=dev; else npm install --omit=dev; fi

FROM node:22-alpine AS runtime

# dumb-init gives the process a real PID 1 that forwards signals. Without it
# Node runs as PID 1, ignores SIGTERM by default, and every deploy waits out
# the orchestrator's kill timeout before the old container dies — turning a
# rolling restart into a visible outage.
RUN apk add --no-cache dumb-init

ENV NODE_ENV=production
WORKDIR /app

COPY --from=deps /app/node_modules ./node_modules
COPY package.json ./
COPY src ./src

# Never root. A container that is compromised through a dependency should not
# also be running as uid 0 — `node` is a non-root user the base image already
# provides, so this costs nothing.
USER node

EXPOSE 3210

# The orchestrator needs a liveness signal that exercises the process rather
# than just the port. GET /health is a real route in src/index.js.
HEALTHCHECK --interval=30s --timeout=3s --start-period=25s --retries=3 \
  CMD node -e "fetch('http://127.0.0.1:'+(process.env.PORT||3210)+'/health').then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))"

ENTRYPOINT ["dumb-init", "--"]
CMD ["node", "src/index.js"]
