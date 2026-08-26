# syntax=docker/dockerfile:1.7
#
# Multi-stage build for the Fastify (Node.js) reference implementation.
# Final image is bench/node:latest. Prod deps only; dev deps never ship.
# Runs as the non-root `node` user and listens on 8080.

FROM node:26-bookworm-slim AS deps
WORKDIR /app

# Install production dependencies only, from the committed lockfile so the
# build is reproducible. No dev deps are declared anyway.
COPY package.json package-lock.json ./
RUN npm ci --omit=dev

# Copy the application source.
COPY src ./src

# ---------------------------------------------------------------------------
# Runtime image
# ---------------------------------------------------------------------------

FROM node:26-bookworm-slim
WORKDIR /app

ENV NODE_ENV=production

COPY --from=deps /app/node_modules ./node_modules
COPY --from=deps /app/src ./src
COPY package.json ./

# Official node images ship the nonroot `node` user.
USER node

# The contract is PORT=8080. EXPOSE documents it; the compose port mapping
# controls external reachability.
EXPOSE 8080

ENTRYPOINT ["node", "src/index.js"]
