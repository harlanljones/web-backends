# syntax=docker/dockerfile:1.7
#
# Multi-stage build for the FastAPI (Python ASGI) reference implementation.
#
# Stage one builds the dependencies into a virtual environment with uv on a
# python:3.12-slim base. Stage two copies only that venv (plus main.py) into a
# second, identical slim image, so the runtime is non-root and shell-free in
# the sense that nothing needs to compile at start.

FROM python:3.12-slim AS build
WORKDIR /src

ENV UV_COMPILE_BYTECODE=1 \
    UV_LINK_MODE=copy \
    PYTHONDONTWRITEBYTECODE=1

# Install uv (the versioned, standalone binary from the ghcr image).
COPY --from=ghcr.io/astral-sh/uv:0.12.5 /uv /uvx /bin/

# Lockfile + manifest first so a source-only change does not re-resolve the
# dependency graph.
COPY pyproject.toml uv.lock* ./

# Provision the venv. `package = false` in pyproject.toml means only the
# dependencies are installed; the project itself is not built/installed.
RUN uv sync --frozen --no-dev

FROM python:3.12-slim
WORKDIR /app

ENV UV_COMPILE_BYTECODE=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PATH="/app/.venv/bin:$PATH"

COPY --from=build /src/.venv /app/.venv
COPY main.py /app/main.py

# Non-root user. The venv and app files are world-readable so the unprivileged
# user can run them.
RUN useradd --create-home --uid 10001 --shell /usr/sbin/nologin bench
USER bench:bench

# The contract requires the container to listen on 8080 (Compose maps the host
# port). EXPOSE documents that; PORT is still read from the environment by
# main.run().
EXPOSE 8080

ENV PORT=8080 \
    LOG_LEVEL=warn

# Reads PORT/LOG_LEVEL from the environment and runs uvicorn (uvloop) with the
# access log off. Equivalent to:
#   venv/bin/uvicorn main:app --host 0.0.0.0 --port 8080 --no-access-log
ENTRYPOINT ["/app/.venv/bin/python", "/app/main.py"]
