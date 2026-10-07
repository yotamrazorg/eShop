# eShop on Ubuntu 24.04 (native, no containers)

Runs the eShop services directly on one Ubuntu 24.04 LTS host: PostgreSQL 16 + pgvector,
Redis, RabbitMQ and the .NET services as hardened systemd units. No Docker or Podman is
installed, required or referenced.

Milestone 1 wires the host foundation and one vertical slice: **catalog-api**. The other
services already exist in the service table (`lib/services.sh`) with `wired=no`; wiring a
service later means flipping that marker and adding its env template (the unit is rendered
from `systemd/eshop-service.service.tmpl`).

## Prerequisites

- Ubuntu 24.04 LTS (other releases only get a warning; apt package availability differs).
- Root (or `sudo`) for provisioning and publishing.
- Network access to the Ubuntu archive and, if the apt .NET SDK is older than `global.json`,
  to `https://dot.net/v1/dotnet-install.sh` and the Microsoft download CDN.
- A checkout of this repository (publish builds from it). `global.json` pins SDK 10.0.302.

## Usage order

```bash
sudo deploy/ubuntu/provision-host.sh     # 1. host, packages, .NET, data services, env files, units
sudo deploy/ubuntu/publish.sh catalog-api # 2. build + install /opt/eshop/catalog-api, (re)start unit
sudo systemctl start eshop.target         #    (publish.sh restarts the unit only if it is active)
sudo deploy/ubuntu/verify.sh              # 3. units, /health, catalog items, vector extension
deploy/ubuntu/check-dotnet.sh             #    anytime: does the installed SDK satisfy global.json?
deploy/ubuntu/tests/test-lib.sh           #    self tests of the helpers (no root needed)
```

`provision-host.sh` options: `--list-steps`, `--only STEP`, `--skip STEP` (steps: `host secrets
packages dotnet postgres redis rabbitmq env systemd`). `publish.sh [service|all] [--no-restart]`;
an unknown service is an error that lists the valid names. `verify.sh [--wait SECONDS]` retries
the HTTP checks while the first start runs EF migrations and seeds the catalog.

Everything is installed to fixed locations: binaries `/opt/eshop/<service>`, configuration
`/etc/eshop`, state `/var/lib/eshop`. The scripts find their own directory via `BASH_SOURCE`, so
they can be run from anywhere.

## What provisioning does

| Step | Result |
|---|---|
| host | system user/group `eshop` (nologin, home `/var/lib/eshop`); `/opt/eshop` (0755 root:root), `/etc/eshop` (0750 root:eshop), `/var/lib/eshop` (0750 eshop:eshop) |
| secrets | `/etc/eshop/secrets.env` (0600 root:root), generated once |
| packages | `postgresql-16`, `postgresql-16-pgvector`, `redis-server`, `rabbitmq-server`, `curl`, `ca-certificates`, `gettext-base` (+ `iproute2` for the listener checks) |
| dotnet | SDK satisfying `global.json` + ASP.NET Core runtime (see below) |
| postgres | loopback only, `scram-sha-256`, role `eshop`, databases `catalogdb identitydb orderingdb webhooksdb`, `vector` extension in `catalogdb` |
| redis | loopback only, `requirepass` |
| rabbitmq | loopback only, vhost `eshop`, user `eshop`, `guest` deleted |
| env | `/etc/eshop/common.env` and `/etc/eshop/<service>.env` (0640 root:eshop) |
| systemd | `eshop.target` + one unit per wired service installed and enabled |

### .NET: apt versus `dotnet-install.sh`

`dotnet_sdk_satisfies` (in `lib/steps-dotnet.sh`) evaluates `global.json` (`sdk.version`,
`rollForward`, `allowPrerelease`) against the installed SDKs using the same rules as the .NET
host (feature band = hundreds digit of the patch field). Order of attempts:

1. An installed SDK already satisfies `global.json`: nothing to do.
2. The apt candidate (`dotnet-sdk-10.0`) satisfies it: install it with apt.
3. Otherwise (the distro feed is usually on an older band than the pin, e.g. 10.0.1xx vs
   10.0.302): download `dotnet-install.sh` and install the exact `global.json` version into
   `/usr/share/dotnet`, link `/usr/local/bin/dotnet`, and install the matching
   `aspnetcore` runtime. `/usr/bin/dotnet` (used by the units) is repointed at that install
   with a warning when a distro `dotnet` of an older version shadows it.

`check-dotnet.sh` runs the same test standalone and exits non-zero (with the required and
found versions) when the SDK does not satisfy `global.json`; `publish.sh` calls it first.

## Configuration contract

Rendered by `envsubst` with an explicit variable whitelist from `env/*.env.tmpl`
(deterministic; unchanged files are not rewritten; unset/empty whitelisted variables abort).

| Key | Where | Value |
|---|---|---|
| `ASPNETCORE_ENVIRONMENT` | common.env | `Production` |
| `ASPNETCORE_FORWARDEDHEADERS_ENABLED` | common.env | `true` |
| `ESHOP_EXPOSE_HEALTH_ENDPOINTS` | common.env | `true` (maps `/health`, `/alive` outside Development) |
| `ConnectionStrings__eventbus` | common.env | `amqp://eshop:<pw>@127.0.0.1:5672/eshop` (vhost = URI path) |
| `ConnectionStrings__redis` | common.env | `127.0.0.1:6379,password=<pw>` |
| `ConnectionStrings__catalogdb` | catalog-api.env | `Host=127.0.0.1;Port=5432;Database=catalogdb;Username=eshop;Password=<pw>` |
| `ASPNETCORE_URLS` | `<service>.env` | `http://127.0.0.1:<port>` (catalog-api: 5222) |
| `Services__<name>__http__0` | see note | `http://127.0.0.1:<port>` for every service in the table |
| `OTEL_EXPORTER_OTLP_ENDPOINT` | common.env | commented out; uncomment to export OTLP |

The loopback address and the PostgreSQL / Redis / RabbitMQ ports are defined once in `lib/common.sh`
(`ESHOP_LOOPBACK_ADDR`, `ESHOP_PG_PORT`, `ESHOP_REDIS_PORT`, `ESHOP_AMQP_PORT`) and fed into the env
files, unit template and service configs from there.

`ConnectionStrings__identitydb|orderingdb|webhooksdb` follow in the milestones that wire those services.

**Service discovery keys and systemd.** systemd `EnvironmentFile=` ignores lines whose variable
name contains characters other than `[A-Za-z0-9_]`, and every service name contains a `-`
(`catalog-api`), so `Services__catalog-api__http__0=...` cannot be delivered through an
`EnvironmentFile`. `common.env` therefore lists the contract lines as comments (documentation,
and usable with `export`/`env` in a shell or a container-free AppHost) and the units pass the
same endpoints as command-line configuration through `ESHOP_CONFIG_ARGS`
(`--Services:catalog-api:http:0=http://127.0.0.1:5222 ...`) which `ExecStart` expands. This is
read by the .NET command-line configuration provider and gives exactly the keys the
ServiceDiscovery configuration provider reads.

## Secrets

`/etc/eshop/secrets.env` holds `POSTGRES_PASSWORD`, `REDIS_PASSWORD`, `RABBITMQ_PASSWORD`
(32 random alphanumeric characters from `/dev/urandom`, mode 0600 root:root). They are generated
once; re-runs only add keys that are missing and never rotate existing ones. Every service step
re-applies the stored password to its service on each run (so a manually changed password is
repaired), and the env files are re-rendered from it. To rotate: remove a key from the file and
re-run provisioning, then restart the units. Nothing secret lives in the repository; the env
templates only contain `${PLACEHOLDERS}`. Note that `rabbitmqctl` takes the password as an
argument, so it is visible in the process list for a moment during provisioning (Postgres and
Redis passwords are passed over stdin/environment instead).

## Idempotency

Every step checks current state first: users/dirs/modes are converged, files are written only
when their content differs (`write_file_if_changed`), packages are installed only when missing,
and Postgres/Redis/RabbitMQ are restarted only when their configuration file changed. A second
`provision-host.sh` run therefore reports "unchanged" everywhere and restarts nothing. On a host
without a running systemd (a plain container) systemctl calls are guarded: units are installed
but not enabled/started, services fall back to `service`/`pg_ctlcluster`, and a warning is printed.

## Redis version

`redis-server` comes from the Ubuntu 24.04 archive: **Redis 7.0.x (BSD-3-Clause)**. Newer
upstream releases (7.4+, 8) changed licence terms and are deliberately not used; changing that
needs legal review. RabbitMQ is the distro 3.12.x (MPL-2.0). Duende IdentityServer (commercial)
and MediatR (pinned before its licence change) keep their existing flags, unchanged here.

## Unit hardening notes

`systemd/eshop-service.service.tmpl` is the single unit template for all services; the catalog-api
unit is rendered from it by `lib/steps-systemd.sh` (an explicit `systemd/eshop-<name>.service` would
override it). The rendered catalog unit validates with `systemd-analyze verify` in the self test.

- `User=eshop`, `UMask=0027`, `Type=exec`, `Restart=on-failure`, start-limit window of 10 tries in
  5 minutes.
- `ExecStartPre` gates replace the Aspire `WaitFor` graph: `pg_isready` against 127.0.0.1:5432 and
  a TCP probe of RabbitMQ (60 s each); `After=`/`Wants=` order the units behind the data services.
- Sandboxing: `NoNewPrivileges`, `ProtectSystem=strict` (only `/var/lib/eshop` writable, also
  `HOME` for DataProtection keys), `ProtectHome`, `PrivateTmp`, `PrivateDevices`,
  `ProtectKernel{Tunables,Modules,Logs}`, `ProtectControlGroups`, `ProtectClock`,
  `ProtectHostname`, `ProtectProc=invisible`, `RestrictSUIDSGID`, `RestrictRealtime`,
  `RestrictNamespaces`, `RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX AF_NETLINK`,
  `LockPersonality`, `RemoveIPC`, `SystemCallArchitectures=native`, empty capability sets.
- A `SystemCallFilter=@system-service` could be added later; it was left out because it is not
  validated against the .NET runtime (JIT needs W^X memory) without a real host to test on.
- Units are `PartOf=eshop.target` and `WantedBy=eshop.target`, which is wanted by `multi-user.target`.
- Services only bind to loopback; WebApp (a later milestone) is the planned public listener.

## Testing the scripts without root

Paths are overridable so helpers can be exercised in a scratch directory: `ESHOP_OPT_DIR`,
`ESHOP_ETC_DIR`, `ESHOP_STATE_DIR`, `ESHOP_SYSTEMD_DIR`, `ESHOP_SECRETS_FILE`, `ESHOP_GLOBAL_JSON`,
`ESHOP_FORCE_NO_SYSTEMD=1`, `ESHOP_VERIFY_BASE_URL`. `tests/test-lib.sh` uses them to cover the
SDK version logic, the service table, template rendering and determinism, file helpers, secret
generation, unit/template consistency and script hygiene. Do not set them for real provisioning.
