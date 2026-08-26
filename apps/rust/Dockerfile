# syntax=docker/dockerfile:1.7
#
# Multi-stage build for the Axum (Rust/Tokio) reference implementation.
# Final image is bench/rust:latest. The binary is statically linked, so
# the runtime image needs no glibc or package manager.

FROM rust:1.97-bookworm AS build
WORKDIR /src

# Cache dependencies as a separate layer: copy the manifest + any lock
# file, then a stub main to force dependency compilation. This layer
# only changes when Cargo.toml/Cargo.lock change.
COPY Cargo.toml Cargo.lock* ./
RUN mkdir -p src \
    && printf 'fn main() {}\n' > src/main.rs \
    && cargo build --release 2>/dev/null || true

# Copy the real sources and rebuild. Removing the build output for the
# stub binary so cargo recompiles the real crate rather than reusing
# the stub's artifacts.
COPY src ./src
RUN rm -rf target/release/.fingerprint/bench-axum-* \
    && rm -f target/release/bench-axum* \
    && cargo build --release

FROM gcr.io/distroless/cc-debian12:nonroot
COPY --from=build /src/target/release/bench-axum /usr/local/bin/bench-axum
USER nonroot:nonroot
EXPOSE 8080
ENTRYPOINT ["/usr/local/bin/bench-axum"]
