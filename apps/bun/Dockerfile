# syntax=docker/dockerfile:1.7
#
# Multi-stage build for the Hono on Bun reference implementation.
#
# The final image is `bench/bun:latest`. The testbed starts it with
#   APP_IMAGE=bench/bun:latest bench/scripts/run-trial.sh bun
# and stops it again before the next trial.
#
# Bun executes TypeScript natively, so there is no compile step: the source
# is shipped as-is and `bun run` transpiles it in-process at startup. The
# multi-stage build only separates dependency resolution (network) from the
# runtime image, so a source-only edit reuses the cached layerless
# install.

# Stage 1: resolve dependencies (prod only) so the network work is cached
# independently of the source, and the runtime image carries no build tools.
FROM oven/bun:1 AS install
WORKDIR /app
# --frozen-lockfile: the commit must contain a bun.lock that exactly matches
# package.json; a drift fails the build rather than silently resolving.
COPY package.json bun.lock ./
RUN bun install --frozen-lockfile --production

# Stage 2: runtime. Non-root, listens on 8080.
FROM oven/bun:1 AS runtime
WORKDIR /app
COPY --from=install /app/node_modules ./node_modules
COPY package.json bun.lock ./
COPY src ./src

# The oven/bun base ships a non-root `bun` user (UID 1000). The contract
# requires a non-root final process; we never lift privileges.
USER bun
# The contract requires PORT=8080. EXPOSE documents that; the compose port
# mapping still controls external reachability.
EXPOSE 8080

# Frameworks.yaml supplies the entrypoint (["bun","run","src/index.ts"]),
# so we rely on CMD rather than ENTRYPOINT to allow override.
CMD ["bun", "run", "src/index.ts"]
