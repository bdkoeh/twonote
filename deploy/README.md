# Deploying the TwoNote server

One image, one volume, one port. The server stores only ciphertext; it listens on plain HTTP
port 8080 and is meant for LAN or VPN use (put a TLS-terminating reverse proxy in front if you
want HTTPS — it must pass WebSocket upgrades for `/api/v1/ws`).

| | |
|---|---|
| Port | `8080/tcp` |
| Data | `/data` (SQLite database `twonote.db` plus its `-wal`/`-shm` files) |
| Health | `GET /api/v1/status` (the image's `HEALTHCHECK` calls it) |
| User | unprivileged `app` (uid 1654) by default |
| Settings | `TWONOTE_DATA_DIR` (default `/data`), `ASPNETCORE_HTTP_PORTS` (default `8080`) |

## Build

No registry has been chosen yet, so the image is not published anywhere. The name
`twonote-server:latest` used below and in the Unraid template is a local placeholder.

From the repository root (the build context must be the root so `Directory.Build.props` is included):

```sh
docker build -f deploy/Dockerfile -t twonote-server:latest .
```

## Run

```sh
docker run -d --name twonote --restart unless-stopped -p 8080:8080 -v twonote-data:/data twonote-server:latest
curl http://localhost:8080/api/v1/status
```

or `docker compose -f deploy/docker-compose.yml up -d --build`.

The first client to connect registers the account; after that registration is closed for good
(`registrationOpen: false` in the status response).

## Unraid

`unraid/twonote.xml` is a Community Applications style template: port 8080, `/data` mapped to
`/mnt/user/appdata/twonote`, running as `nobody:users` (`--user 99:100`).

Because the image is not in a registry, get it onto the Unraid box first, either way:

- **Build there**: copy the repository to the server and run the `docker build` command above
  in a terminal.
- **Build elsewhere and load**:
  ```sh
  docker save twonote-server:latest | gzip > twonote-server.tar.gz    # on the build machine
  docker load < /mnt/user/path/to/twonote-server.tar.gz               # on Unraid
  ```

Then copy the template to `/boot/config/plugins/dockerMan/templates-user/my-twonote.xml`, and in
the Docker tab choose *Add Container* and pick `twonote` from the template list. Unraid uses the
local image because the name has no registry; "check for updates" will report it as not
available, which is expected until a registry is chosen.

If the container exits with `Cannot open /data/twonote.db`, the appdata folder is not writable
by uid 99: `chown -R 99:100 /mnt/user/appdata/twonote`.

## Backup and restore

Stop the container and copy the data folder (all three `twonote.db*` files if present), or take
a consistent copy while running with `sqlite3 twonote.db ".backup backup.db"`. Restoring is
putting the files back. Everything in them is ciphertext, device token hashes and public keys.

## Checking a running container

The test project has a round-trip test for a live server with an **empty** data volume
(register, Ed25519 login, push, events, WebSocket, restart):

```powershell
docker run -d --name twonote-e2e -p 18080:8080 -v twonote-e2e-data:/data twonote-server:latest
$env:TWONOTE_E2E_URL = 'http://localhost:18080'
$env:TWONOTE_E2E_RESTART_CMD = 'docker restart twonote-e2e'   # optional
dotnet test tests/TwoNote.Server.Tests --filter "FullyQualifiedName~ContainerRoundTrip"
docker rm -f -v twonote-e2e
docker volume rm twonote-e2e-data
```

If Docker runs inside WSL, prefix the `docker` commands with `wsl -d <distro> --`.

## Notes

- Login rate limiting counts failures per source address as the server sees it. Behind a
  reverse proxy or Docker's userland proxy every client can appear as one address, so the
  limit is then shared.
- Request bodies are capped at 64 MiB and each blob at 8 MiB.
