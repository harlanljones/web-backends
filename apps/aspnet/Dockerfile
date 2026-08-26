# syntax=docker/dockerfile:1.7
#
# Multi-stage build for the ASP.NET Core (minimal API) reference implementation.
# Final image is `bench/aspnet:latest`. The runtime image is the ASP.NET Core
# shared-framework image, which ships the `Microsoft.AspNetCore.App` framework
# reference the app needs; only the app's own DLLs are copied.

FROM mcr.microsoft.com/dotnet/sdk:8.0 AS build
WORKDIR /src

# Restore first so a source-only edit does not invalidate the NuGet layer.
COPY Bench.csproj ./
RUN dotnet restore

COPY . .
RUN dotnet publish -c Release -o /app/publish \
    --no-restore \
    -p:UseAppHost=false

FROM mcr.microsoft.com/dotnet/aspnet:8.0 AS runtime
WORKDIR /app/publish
COPY --from=build /app/publish .

# Non-root, matching the distroless nonroot convention of the Go/Rust images.
USER 65534:65534

# Kestrel binds via Program.cs UseUrls to http://0.0.0.0:$PORT. EXPOSE documents
# the contract default; the docker-compose port mapping controls reachability.
EXPOSE 8080

ENTRYPOINT ["dotnet", "/app/publish/Bench.dll"]
