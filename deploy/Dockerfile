# TwoNote server image. Build from the repository root:
#   docker build -f deploy/Dockerfile -t twonote-server:latest .

FROM mcr.microsoft.com/dotnet/sdk:10.0 AS build
ENV DOTNET_CLI_TELEMETRY_OPTOUT=1 DOTNET_NOLOGO=1
WORKDIR /src
COPY Directory.Build.props ./
COPY src/TwoNote.Core/TwoNote.Core.csproj src/TwoNote.Core/
COPY src/TwoNote.Server/TwoNote.Server.csproj src/TwoNote.Server/
RUN dotnet restore src/TwoNote.Server/TwoNote.Server.csproj
COPY src/TwoNote.Core/ src/TwoNote.Core/
COPY src/TwoNote.Server/ src/TwoNote.Server/
RUN dotnet publish src/TwoNote.Server/TwoNote.Server.csproj -c Release --no-restore -o /app

# The default aspnet:10.0 tag is glibc based (Ubuntu), which the bundled libsodium and SQLite
# native libraries are verified against. Do not switch to Alpine without re-testing.
FROM mcr.microsoft.com/dotnet/aspnet:10.0 AS runtime
ENV DOTNET_CLI_TELEMETRY_OPTOUT=1 \
    ASPNETCORE_HTTP_PORTS=8080 \
    TWONOTE_DATA_DIR=/data
WORKDIR /app
COPY --from=build /app ./
# /data is created owned by the unprivileged user so a fresh named volume inherits it.
RUN mkdir /data && chown $APP_UID:$APP_UID /data
USER $APP_UID
VOLUME /data
EXPOSE 8080
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
    CMD ["dotnet", "/app/TwoNote.Server.dll", "--healthcheck"]
ENTRYPOINT ["dotnet", "/app/TwoNote.Server.dll"]
