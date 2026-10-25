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
# Use the Node 22 release line for both stages. The build gate must verify the
# exact release source and resulting image before deployment.
FROM node:22-alpine AS deps

WORKDIR /app

# Copied on their own, before the source, so a source-only change reuses the
# cached dependency layer instead of reinstalling on every build.
COPY package.json package-lock.json ./

# Preserve the reviewed dependency versions and fail if the manifest drifts.
RUN npm ci --omit=dev

FROM node:22-alpine AS runtime

# dumb-init gives the process a real PID 1 that forwards signals. Without it
# Node runs as PID 1, ignores SIGTERM by default, and every deploy waits out
# the orchestrator's kill timeout before the old container dies — turning a
# rolling restart into a visible outage.
RUN apk add --no-cache dumb-init

ENV NODE_ENV=production
ENV PORT=3210
WORKDIR /app

COPY --from=deps --chown=node:node /app/node_modules ./node_modules
COPY --chown=node:node package.json ./
COPY --chown=node:node src ./src

# Never root. A container that is compromised through a dependency should not
# also be running as uid 0 — `node` is a non-root user the base image already
# provides, so this costs nothing.
USER node

EXPOSE 3210

# The orchestrator needs a readiness signal that exercises the database, not
# just the process. GET /ready is a real route in src/index.js.
HEALTHCHECK --interval=30s --timeout=3s --start-period=25s --retries=3 \
  CMD node -e "fetch('http://127.0.0.1:'+(process.env.PORT||3210)+'/ready').then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))"

ENTRYPOINT ["dumb-init", "--"]
CMD ["node", "src/index.js"]
