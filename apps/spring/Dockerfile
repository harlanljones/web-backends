# syntax=docker/dockerfile:1.7
#
# Multi-stage build for the Spring Boot 3 + Java 21 (Project Loom)
# reference implementation. Final image is bench/spring:latest.
#
# The build needs Maven + JDK 21 to compile the sources and repackage the fat
# jar; the runtime only needs a JDK 21 runtime. No ORM, no build tool, no
# package manager in the final image.

FROM maven:3.9-eclipse-temurin-21 AS build
WORKDIR /app

# Warm the dependency cache first so a source-only edit does not re-download
# Maven's whole dependency tree. dependency:go-offline fetches what the build
# needs; a failure here is non-fatal (network may be flaky once, and `package`
# below re-tries).
COPY pom.xml ./
RUN mvn -q -DskipTests dependency:go-offline || true

COPY src ./src
RUN mvn -q -DskipTests package

FROM eclipse-temurin:21-jre AS runtime

# Non-root final user. The VM binds 8080 (>= 1024) so no privileged ports.
RUN groupadd -r bench && useradd -r -g bench bench

WORKDIR /app
COPY --from=build /app/target/app.jar app.jar

USER bench
EXPOSE 8080

# The contract maps PORT -> server.port through the placeholder in
# application.properties (server.port=${PORT:8080}), which Spring resolves
# from the PORT env var. Spring's relaxed name SERVER_PORT overrides that.
# Virtual threads are enabled by spring.threads.virtual.enabled=true, not a
# VM flag.
ENTRYPOINT ["java", "-jar", "/app/app.jar"]
