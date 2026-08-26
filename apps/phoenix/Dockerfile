# syntax=docker/dockerfile:1.7
#
# Multi-stage build for the Phoenix/Bandit (Elixir/BEAM) reference.
# Uses a plain Bandit + Plug.Router + Postgrex app (no Phoenix generators,
# no Ecto). The runtime image keeps the compiled beam files only.

FROM elixir:1.16 AS build
WORKDIR /app

# Install hex + rebar, then fetch deps. This layer is cached unless
# mix.exs / mix.lock change.
ENV MIX_ENV=prod
RUN mix local.hex --force && mix local.rebar --force
COPY mix.exs mix.lock* ./
RUN mix deps.get --only prod
RUN mix deps.compile

# Compile the app.
COPY config ./config
COPY lib ./lib
RUN mix compile

# Create a release (escript build is simpler and single-artifact for a
# small Plug app). We build an escript so the runtime image has a single
# executable and a minimal BEAM.
RUN mix escript.build

FROM elixir:1.16
WORKDIR /app
# The escript includes the app + BEAM runtime; it only needs the built
# artifact.
COPY --from=build /app/bench /app/bench
COPY --from=build /app/_build/prod/lib /app/_build/prod/lib

# Run as a non-root user. The escript must be executable.
RUN useradd -m benchuser || true
USER benchuser

EXPOSE 8080
ENTRYPOINT ["/app/bench"]
