# syntax=docker/dockerfile:1.7
#
# Multi-stage build for the Go + Gin reference implementation.
#
# The final image is `bench/go:latest`. The testbed starts it with
#   APP_IMAGE=bench/go:latest bench/scripts/run-trial.sh go
# and stops it again before the next trial.

FROM golang:1.26-alpine AS build
WORKDIR /src

# Cache dependencies as a separate layer so a source-only edit does not
# invalidate the module download.
COPY go.mod go.sum ./
RUN go mod download

COPY . .

# CGO is disabled; the binary is statically linked, so the runtime image
# does not need glibc or alpine's package manager. A static binary also
# makes the image smaller and the runtime behavior more reproducible
# (no surprise lib updates in production).
ARG VERSION=dev
RUN CGO_ENABLED=0 GOOS=linux go build \
      -trimpath \
      -ldflags="-s -w -X main.version=${VERSION}" \
      -o /out/bench-go \
      .

FROM gcr.io/distroless/static-debian12:nonroot
COPY --from=build /out/bench-go /usr/local/bin/bench-go

# The nonroot user has UID 65532. The image's USER is already nonroot.
USER nonroot:nonroot

# The contract requires PORT=8080. EXPOSE documents that; the
# docker-compose port mapping still controls external reachability.
EXPOSE 8080

# Distroless has no shell, so ENTRYPOINT is the binary directly.
ENTRYPOINT ["/usr/local/bin/bench-go"]
