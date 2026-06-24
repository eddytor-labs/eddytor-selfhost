# Self-hosting Eddytor

Eddytor is free, self-hostable, and vendor-neutral. Postgres + S3-compatible
storage + the two prebuilt Eddytor images are everything you need — no source,
no build. Two image editions are published to `ghcr.io/nordalf`:

| Edition        | Tag             | Use it for                                   |
|----------------|-----------------|----------------------------------------------|
| **Community**  | `:latest`       | Docker Compose / single host (direct TCP).   |
| **Kubernetes** | `:k8s`          | Helm chart (DNS-based engine discovery).     |

> Guided, step-by-step install walkthroughs (including AKS) are available as
> LLM skills at https://github.com/eddytor-labs/eddytor-skills.

## Quickstart

One command — pulls the prebuilt public images:

```bash
curl -fsSL https://get.eddytor.com | sh
```

The installer scaffolds an install directory (`~/eddytor`) holding
`docker-compose.yml`, `config.toml`, a copy of this guide, and a generated
`.env`, starts the stack, and walks you through creating the first admin.
**That directory is yours — back up `.env` and version the rest.**

```
~/eddytor/
├── docker-compose.yml   # replaced on upgrade — don't edit
├── config.toml          # non-secret settings (public URL, CORS, …) — edit this
├── HOSTING.md           # this guide
└── .env                 # secrets + bundled-stack wiring (generated) — back up
```

Prefer to drive it yourself:

```bash
mkdir -p ~/eddytor && cd ~/eddytor
curl -fsSL https://get.eddytor.com/docker-compose.yml -o docker-compose.yml
curl -fsSL https://get.eddytor.com/config.toml -o config.toml
cat > .env <<EOF                # generate the required secrets
EDDYTOR_ENCRYPTION_KEY=$(openssl rand -base64 32)
EDDYTOR_API_KEY_SECRET=$(openssl rand -base64 32)
EDDYTOR_DATABASE_URL=postgres://eddytor:eddytor@postgres:5432/eddytor
EDDYTOR_VERSION=$(curl -fsSL https://get.eddytor.com/VERSION)
# Bundled Garage creds — compose interpolates these (no defaults). Key id MUST
# be `GK` + 32 hex; secret 64 hex.
GARAGE_ACCESS_KEY=GK$(openssl rand -hex 16)
GARAGE_SECRET_KEY=$(openssl rand -hex 32)
EDDYTOR_BUCKET=eddytor
EOF
# Bundled Garage also needs garage.toml — compose mounts it read-only, so a
# missing file would become a directory and Garage would fail to start.
cat > garage.toml <<EOF
metadata_dir = "/var/lib/garage/meta"
data_dir = "/var/lib/garage/data"
db_engine = "sqlite"
replication_factor = 1
rpc_bind_addr = "[::]:3901"
rpc_secret = "$(openssl rand -hex 32)"
[s3_api]
s3_region = "us-east-1"
api_bind_addr = "[::]:3900"
root_domain = ".s3.garage.localhost"
[admin]
api_bind_addr = "[::]:3903"
admin_token = "$(openssl rand -base64 32)"
EOF
docker compose up -d
```

(The `curl | sh` installer does all of the above for you — including the Garage
creds + `garage.toml` — so prefer it unless you're wiring an external Postgres/S3.) Images are pulled (seconds), not built. Change a setting
by editing `config.toml` then `docker compose restart`. Upgrade by bumping
`EDDYTOR_VERSION` in `.env` and running `docker compose pull && docker compose
up -d`. Wait for `eddytor-server` to show `(healthy)` in `docker compose ps`.

> **Eddytor is API-first.** `http://localhost:8080` is the REST + gRPC API, not
> a UI — you operate Eddytor with the `eddytor` CLI, the REST API, or MCP. An
> optional **web UI** is available as a compose profile; the installer asks
> whether to include it (see _Web UI_ below).

## Web UI (optional)

The web UI ships as a separate prebuilt image (`ghcr.io/nordalf/eddytor-ce-ui`)
behind the `ui` compose profile. The installer prompts on a fresh install
(answer **Y**, or set `EDDYTOR_WITH_UI=true` for non-interactive runs); when
enabled it serves at `http://localhost:3000`.

Enabling it does three things in `.env`:

```bash
COMPOSE_PROFILES=ui                       # compose starts the eddytor-ui service
EDDYTOR_UI_VERSION=<published ui tag>     # pinned from get.eddytor.com/ui/VERSION
EDDYTOR__SERVER__WEB_REDIRECT_URIS=http://localhost:3000/auth/callback
```

The last line registers the UI origin as an OAuth `redirect_uri` on the server —
without it sign-in fails with 400 `redirect_uri does not match any registered
URI`. It is an env **override**: it replaces (not merges with) any
`web_redirect_uris` in `config.toml`, so add further URIs to that env line,
comma-separated.

No CORS changes are needed: the browser only talks to the UI's own origin — a
same-origin BFF proxy inside the UI forwards to `eddytor-server` over the
compose network.

Add the UI to an existing install:

```bash
EDDYTOR_WITH_UI=true sh -c "$(curl -fsSL https://get.eddytor.com)"   # re-run installer
# or by hand: add the three .env lines above, then
docker compose pull && docker compose up -d
```

Disable it again by removing the `COMPOSE_PROFILES` line and running
`docker compose up -d --remove-orphans`.

**Beyond localhost**, the UI is a second public origin with its own knobs in
`.env` (compose interpolates them):

| Variable | Meaning |
|---|---|
| `EDDYTOR_UI_ORIGIN` | The UI's public origin (e.g. `https://ui.example.com`). Must match a registered redirect URI: also update `EDDYTOR__SERVER__WEB_REDIRECT_URIS` to `${EDDYTOR_UI_ORIGIN}/auth/callback`. |
| `EDDYTOR_UI_API_BASE_URL` | Backend origin the **browser** is redirected to for OAuth login — your public `server.public_url`, not the compose service name. |
| `EDDYTOR_UI_COOKIE_DOMAIN` | Auth cookie domain. Empty (default) = host-only, correct for separate origins. |

Terminate TLS for the UI origin at your edge proxy exactly like the API (see
_TLS_ below) — the UI container itself serves plaintext on `:3000` and honors
`EDDYTOR_BIND_ADDR` the same way the API ports do.

### Install the `eddytor` CLI

```bash
# macOS / Linux (Homebrew)
brew install eddytor-labs/tap/eddytor

# macOS / Linux (shell)
curl -fsSL https://raw.githubusercontent.com/eddytor-labs/eddytor-cli/main/install.sh | sh

# Windows (Scoop)
scoop bucket add eddytor https://github.com/eddytor-labs/eddytor-cli
scoop install eddytor
```

**Create the first admin.** Provisioning runs **inside the server container**
via `eddytoradm` — there is no public setup endpoint and no token to leak. The
auth boundary is "can you exec into the container," the same model as `kubeadm`
writing `admin.conf` to a control-plane node. The `curl | sh` installer prompts
you for this; to do it by hand:

```bash
docker compose exec eddytor-server eddytoradm setup \
  --email you@example.com --org "Default"
# ✓ Admin you@example.com created in organisation 'Default'.
```

It's idempotent — a no-op once an admin exists. Then sign in (no password —
Eddytor uses magic-link login; with SMTP unset the link is printed to the logs):

```bash
eddytor config set-api-url    http://localhost:8080
eddytor config set-flight-url http://localhost:8082   # `eddytor query` uses a separate Flight SQL endpoint
eddytor login                                         # device-code flow; opens your browser
eddytor get tables
eddytor query "SELECT 1"
```

Prefer a headless key (no browser round-trip)? Mint one from inside the
container — same exec boundary:

```bash
docker compose exec eddytor-server eddytoradm create-api-key --email you@example.com
# Admin API key for you@example.com (shown once): edd_live_…
eddytor config set-key edd_live_…
```

> Two gotchas, both surfaced as `GetFlightInfo failed: Invalid or expired token`:
> - **`set-flight-url` is separate from `set-api-url`.** `eddytor query` talks
>   Flight SQL on the server's Flight proxy (port **8082**), not the REST port.
>   If you only set `api_url`, `query` still points at the default and your
>   local credential is rejected.
> - **Use the API key, not `eddytor login`, for `query`.** The bootstrap API key
>   doesn't expire; the device-login token lasts 15 minutes and `query` won't
>   refresh it.

**Sign-in for everyone else is email-based.** Magic-link / device-code sign-in
sends a link by email. With **no SMTP configured (the default), links are
written to the server logs** instead of sent — fine for a solo operator
(`docker compose logs eddytor-server | grep -i 'sign in to eddytor' -A2`), but
to let teammates log in you must set `EDDYTOR_SMTP_*` in `.env`.

**Create your first table.** A bucket (`EDDYTOR_BUCKET`, default `eddytor`) is
created in the bundled Garage on boot. Register it as a storage connection, then
create tables against it (the `GARAGE_ACCESS_KEY` / `GARAGE_SECRET_KEY` are the
random creds the installer wrote to `.env`):

```bash
eddytor create storage s3 --bucket eddytor \
  --endpoint http://garage:3900 --region us-east-1 \
  --access-key-id "$GARAGE_ACCESS_KEY" --secret-access-key "$GARAGE_SECRET_KEY"
```

(`http://garage:3900` is the in-cluster S3 endpoint the engine uses.)

> **Garage** is an S3-compatible object store by
> [Deuxfleurs](https://garagehq.deuxfleurs.fr), licensed AGPLv3. Eddytor bundles
> their published image unmodified — full credit and thanks to the Garage team
> for a great piece of software. The bundled single-node setup is **evaluation
> only** (one sqlite node, no replication); point Eddytor at a managed S3 / a
> multi-node Garage cluster for anything you keep.

Registration probes the store before saving anything, so a misconfiguration
fails fast with a specific reason — `authentication failed …` (rejected
credentials), `storage path or bucket not found …` (wrong bucket/container or
base path), or `could not reach storage …` (network/endpoint) — rather than a
generic discovery error. A reachable but **empty** bucket is fine: registration
succeeds and reports `0 tables`.

### Managing & deleting tables (bundled Garage)

Garage has **no web console** (that was a MinIO feature) and the bundled image is
`scratch` — only the `/garage` binary, no shell — so you can't `exec` in to browse
data. Manage tables through Eddytor instead, which keeps the object store and
Eddytor's metadata/discovery in sync:

```bash
# delete a table (catalog is always `eddytor`); needs the TABLES_DELETE scope
eddytor delete table eddytor <schema> <table>
```

`delete table` removes the table's Delta files from Garage **and** deregisters it —
the storage and Eddytor's view stay consistent. (Equivalent: `DELETE
/tables/{catalog}/{schema}/{table}`, or the web UI.)

**Last resort — deleting at the S3 layer.** Only for orphaned data Eddytor no
longer tracks. A table is an object **prefix** in the `eddytor` bucket; point any
S3 client at the endpoint (`http://127.0.0.1:3900`, region `us-east-1`, creds =
`GARAGE_ACCESS_KEY` / `GARAGE_SECRET_KEY` from `.env`):

```bash
export AWS_ACCESS_KEY_ID="$GARAGE_ACCESS_KEY" AWS_SECRET_ACCESS_KEY="$GARAGE_SECRET_KEY"
EP="--endpoint-url http://127.0.0.1:3900 --region us-east-1"
aws s3 ls s3://eddytor/ $EP --recursive            # find the table prefix
aws s3 rm s3://eddytor/<path-to-table>/ $EP --recursive
```

⚠️ Deleting objects behind Eddytor's back leaves **stale discovery/metadata** until
the next discovery pass — prefer `eddytor delete table`.

## Kubernetes (Helm)

Docker Compose runs a single server and engine. To scale — the engine is
stateless and scales out under load — install the **Helm chart** on any
Kubernetes cluster (EKS / GKE / AKS / k3s / OpenShift / Docker Desktop). You
only need `kubectl` + `helm` pointed at your cluster; nothing Eddytor-specific.

### Install

The chart is published as an OCI artifact — no clone needed. Create the three
required secrets, then install:

```bash
kubectl create namespace eddytor

kubectl -n eddytor create secret generic eddytor-secrets \
  --from-literal=EDDYTOR_DATABASE_URL="postgres://user:pass@host:5432/eddytor" \
  --from-literal=EDDYTOR_ENCRYPTION_KEY="$(openssl rand -base64 32)" \
  --from-literal=EDDYTOR_API_KEY_SECRET="$(openssl rand -base64 32)"

helm upgrade --install eddytor oci://ghcr.io/nordalf/charts/eddytor -n eddytor \
  --set secrets.existingSecret=eddytor-secrets \
  --set config.publicUrl="https://eddytor.example.com" \
  --set ingress.enabled=true --set ingress.host=eddytor.example.com
```

Production uses your own external Postgres + object store (the chart defaults
`postgres.bundled` / `garage.bundled` to `false`). The three secrets above are the
only ones you generate. Bundle the demo datastores only for local eval — see
[Trying it locally](#trying-it-locally), where Garage also needs its own creds.

The chart defaults to the **kubernetes-edition** images (`:k8s` tag, built with
DNS engine discovery) — that's what lets the server fan out across engine
replicas.

`secrets.existingSecret` points the chart at a Secret you manage (so credentials
never pass through `helm --set`, where base64 padding and commas bite). Drop it
to let the chart build the Secret from `secrets.values` in your own values file
instead. Ingress + autoscaling (HPA) + PodDisruptionBudgets are on by default;
point `config.publicUrl` at your external URL and bring your own Postgres +
object store (`postgres.bundled` / `garage.bundled` default `false`).

After install, follow the printed `NOTES` to create the first admin — it runs
`eddytoradm setup` inside the server pod (`kubectl exec`), then sign in:

```bash
eddytor config set-api-url https://eddytor.example.com
eddytor login        # device-code flow; the CLI is the client (like kubectl)
```

Scale the engine any time:

```bash
kubectl -n eddytor scale deploy/eddytor-engine --replicas=5
```

Notes: the server runs migrations at boot under a Postgres advisory lock (safe
across replicas); the engine skips them. `helm test eddytor` hits `/healthz` on
both services.

### Trying it locally

No cluster? Either run `docker compose up` (single node, simplest), or stand up a
throwaway local cluster with [k3d](https://k3d.io), [kind](https://kind.sigs.k8s.io),
minikube, or Docker Desktop's built-in Kubernetes — then install the chart with
bundled Postgres + Garage on a NodePort:

```bash
k3d cluster create eddytor -p "8080:30080@server:0"

kubectl create namespace eddytor
kubectl -n eddytor create secret generic eddytor-secrets \
  --from-literal=EDDYTOR_DATABASE_URL="postgres://eddytor:eddytor@eddytor-postgres:5432/eddytor" \
  --from-literal=EDDYTOR_ENCRYPTION_KEY="$(openssl rand -base64 32)" \
  --from-literal=EDDYTOR_API_KEY_SECRET="$(openssl rand -base64 32)"

helm install eddytor oci://ghcr.io/nordalf/charts/eddytor -n eddytor \
  --set secrets.existingSecret=eddytor-secrets \
  --set postgres.bundled=true --set garage.bundled=true \
  --set-string garage.accessKey="GK$(openssl rand -hex 16)" \
  --set-string garage.secretKey="$(openssl rand -hex 32)" \
  --set-string garage.rpcSecret="$(openssl rand -hex 32)" \
  --set-string garage.adminToken="$(openssl rand -base64 32)" \
  --set server.service.type=NodePort --set server.service.nodePort=30080
# server reachable at http://localhost:8080
```

> Bundled Garage now requires its own credentials (no world-known defaults ship
> in the public chart). The four `--set-string garage.*` lines above generate
> them inline; `accessKey` must be `GK` + 32 hex chars. Omit them and the render
> fails fast with a clear `garage.* is required` message.

> Bundled single-replica Postgres/Garage are **evaluation only** — no HA, no
> backups. Use external, backed-up datastores and real secrets in production.
> Note `postgres.bundled=true` does not rewrite your connection string — keep
> `EDDYTOR_DATABASE_URL` pointed at the in-cluster service
> (`postgres://eddytor:eddytor@eddytor-postgres:5432/eddytor`), as the example above does.

The `-p "8080:30080@server:0"` flag is what maps the host's `localhost:8080` onto
the NodePort — that's a **k3d** feature, so the example above assumes k3d.

#### minikube

minikube does **not** surface NodePorts on `localhost` — a NodePort lives at
`$(minikube ip):30080`, which won't match the demo `publicUrl` (`localhost:8080`).
Reuse the `eddytor-secrets` Secret + bundled flags from the k3d example above,
then pick one of two ways to reach the stack.

**Option 1 — port-forward (recommended; the only path on the `docker` driver).**
Keeps the `localhost` URLs the chart defaults assume:

```bash
helm install eddytor oci://ghcr.io/nordalf/charts/eddytor -n eddytor \
  --set secrets.existingSecret=eddytor-secrets \
  --set postgres.bundled=true --set garage.bundled=true --set ui.enabled=true \
  --set-string garage.accessKey="GK$(openssl rand -hex 16)" \
  --set-string garage.secretKey="$(openssl rand -hex 32)" \
  --set-string garage.rpcSecret="$(openssl rand -hex 32)" \
  --set-string garage.adminToken="$(openssl rand -base64 32)"
kubectl -n eddytor port-forward svc/eddytor-server 8080:8080 &
kubectl -n eddytor port-forward svc/eddytor-ui     3000:3000 &   # if ui.enabled
# server → http://localhost:8080, UI → http://localhost:3000
```

**Option 2 — point the config at the NodePort URLs (no port-forward).** Only
works where the node IP is routable from your host:

```bash
helm install eddytor oci://ghcr.io/nordalf/charts/eddytor -n eddytor \
  --set secrets.existingSecret=eddytor-secrets \
  --set postgres.bundled=true --set garage.bundled=true --set ui.enabled=true \
  --set-string garage.accessKey="GK$(openssl rand -hex 16)" \
  --set-string garage.secretKey="$(openssl rand -hex 32)" \
  --set-string garage.rpcSecret="$(openssl rand -hex 32)" \
  --set-string garage.adminToken="$(openssl rand -base64 32)" \
  --set server.service.type=NodePort --set server.service.nodePort=30080 \
  --set ui.service.type=NodePort --set ui.service.nodePort=30300 \
  --set config.publicUrl=http://$(minikube ip):30080 \
  --set ui.origin=http://$(minikube ip):30300 \
  --set ui.apiBaseUrl=http://$(minikube ip):30080
# the chart derives web_redirect_uris from ui.origin automatically
```

> **`docker` driver (default on macOS/Windows): use Option 1.** There
> `minikube ip` is an address *inside* the Docker VM (e.g. `192.168.49.2`) that
> the host browser cannot route to, so Option 2's NodePort URLs are unreachable
> and `minikube service --url` only hands back a random `127.0.0.1:<port>` that
> won't match `ui.origin`. `kubectl port-forward` tunnels through the API server
> and is the reliable path. Option 2 fits Linux (`docker`/`none` driver) or VM
> drivers whose node IP the host can reach.

The browser origin **must** match `publicUrl` / `ui.origin`, or OAuth redirects and
cookies break — that's the whole reason these have to line up.

#### Create your first table (Helm)

After `eddytoradm setup` + `eddytor login`, register the bundled Garage so you can
create tables. The endpoint is the **in-cluster Service name** `eddytor-garage:3900`
(not `garage:3900` — that's the compose name), and the creds are the chart's demo
defaults (`garage.accessKey` / `garage.secretKey` — override for real use):

```bash
eddytor create storage s3 --bucket eddytor \
  --endpoint http://eddytor-garage:3900 --region us-east-1 \
  --access-key-id GK00000000000000000000000000000000 \
  --secret-access-key 0000000000000000000000000000000000000000000000000000000000000000
```

Bulk queries (`eddytor query`) use Flight SQL on server port **8082**, which stays
ClusterIP — port-forward it and point the CLI at it:

```bash
kubectl -n eddytor port-forward svc/eddytor-server 8082:8082 &
eddytor config set-flight-url http://localhost:8082
```

(`helm install … --set garage.bundled=true` prints these same commands in its NOTES.)

### Web UI (optional)

The chart can also deploy the web UI (`eddytor-ce-ui`), off by default — Eddytor
is API-first. Enable it and give it a public origin; the chart registers
`{ui.origin}/auth/callback` as a server OAuth redirect_uri automatically:

```bash
helm upgrade --install eddytor oci://ghcr.io/nordalf/charts/eddytor -n eddytor \
  --set ui.enabled=true \
  --set ui.origin=https://app.eddytor.example.com \
  --set ui.ingress.enabled=true --set ui.ingress.host=app.eddytor.example.com
```

The UI runs on its **own origin** (separate host from the server), proxying to
the server in-cluster via a BFF. For a local eval, expose it on a NodePort
instead: `--set ui.enabled=true --set ui.service.type=NodePort --set
ui.service.nodePort=30300 --set ui.origin=http://localhost:3000` (then
port-forward, or on k3d add `-p "3000:30300@server:0"` to the cluster). `ui.image.tag`
tracks the UI's own release cadence, independent of the server/engine `image.tag`.

## Configuration

Operator settings live in `config.toml` (the installer downloads it into your
install directory and the compose file mounts it). Secrets stay in env
(`EDDYTOR_DATABASE_URL`, `EDDYTOR_ENCRYPTION_KEY`, `EDDYTOR_API_KEY_SECRET`,
OAuth/SMTP credentials).

Resolution order:

1. `EDDYTOR__SECTION__KEY` env override (e.g. `EDDYTOR__SERVER__PUBLIC_URL=https://app.example.com`)
2. `$EDDYTOR_CONFIG_FILE` path
3. `./eddytor.toml`
4. `/etc/eddytor/config.toml`
5. Built-in defaults

The shipped `config.toml` documents every section and field inline.

### Using your own config file with docker-compose

The bind-mount source is overridable, so you don't have to edit the file the
installer wrote. Set `EDDYTOR_CONFIG_FILE` on the host before running compose:

```bash
cp config.toml /etc/eddytor/my-config.toml
# edit /etc/eddytor/my-config.toml
EDDYTOR_CONFIG_FILE=/etc/eddytor/my-config.toml docker compose up -d
```

Or persist it in a `.env` file next to `docker-compose.yml` (compose auto-loads it):

```
# .env  (gitignored)
EDDYTOR_CONFIG_FILE=/etc/eddytor/my-config.toml
```

Restart the containers after editing the file — config is read at boot, not hot-reloaded.

### CORS

`server.cors.allowed_origins` is an allowlist of origin patterns. Each entry is
matched literally or as a glob via `*` (multi-level — matches across dots):

```toml
[server.cors]
allowed_origins = [
  "https://app.example.com",   # exact
  "https://*.example.com",     # any subdomain: a.example.com, a.b.example.com
  "http://localhost:*",        # any localhost port (dev)
]
allow_credentials = true
max_age_secs = 86400
```

**Security:** every glob MUST include at least one literal label after the `*`.
`https://*.com` allows every `.com` domain on the internet. `*.example.com` is
safe; `*.com` is not. The server validates this at boot: a bare `*` origin with
`allow_credentials = true` is **fatal** (browsers reject it, so every
credentialed request would silently fail), and over-broad globs plus an
all-localhost allowlist behind an `https://` `public_url` log a startup warning.
Keep patterns specific.

`/v1/oauth/*` and `/.well-known/*` are intentionally outside CORS (programmatic
OAuth flows, browser redirects don't need preflight). `/mcp` is also outside
CORS — MCP clients are programmatic and have their own origin/DNS-rebinding
protection.

### Required env (minimum)

| Variable | Purpose |
|----------|---------|
| `EDDYTOR_DATABASE_URL` | Postgres connection string |
| `EDDYTOR_ENCRYPTION_KEY` | 32-byte base64 AES-256-GCM-SIV master key. Generate via `openssl rand -base64 32`. |
| `EDDYTOR_CONFIG_FILE` | Optional. Path to `config.toml`. |

In the self-host stack these secrets live in `.env` — generated by the installer
(or hand-written; see _Quickstart_). **Back up `.env`**: losing
`EDDYTOR_ENCRYPTION_KEY` means losing every stored secret. (The repo-root
build-from-source compose generates them into a shared volume via a
`secret-bootstrap` init container instead — a maintainer path, not this one.)

### Optional env

* **SMTP** (production magic-link delivery): `EDDYTOR_SMTP_HOST`, `_PORT`, `_USER`, `_PASS`, `_FROM`. For production point this at SES SMTP / Postfix / Mailgun. With no SMTP, magic-link bodies log to stdout.
* **Provider OAuth apps** (optional, lets users link Azure/Google for delegated storage discovery): configured **per-organisation at runtime** via the provider-apps API/CLI — not env vars. See _Provider OAuth apps_ below. (SSO *sign-in* is separate; see _Okta / other OIDC_.)

## TLS

Eddytor's binaries speak **plaintext** everywhere — server↔engine over h2c, the
HTTP/gRPC listeners unencrypted — and **TLS is terminated at the edge**: a
reverse proxy / load balancer in front of the server, or a service mesh
(Istio mTLS) in k8s. Trust the local network, encrypt at the boundary. There is
no internal self-signed cert mesh to manage.

For production, terminate TLS at your own LB / ingress (Nginx, Envoy, ALB,
Traefik, Caddy) pointing at the server's plaintext `:8080`, and set
`server.public_url` to the HTTPS hostname the edge serves.

**Multi-host / separate engine container:** the server reaches the engine via
`engine.host` (config) — `localhost` for co-located dev, the service name
(`eddytor-engine`) for compose, DNS discovery in the kubernetes edition. All
plaintext; secure the server↔engine hop with your network (mesh mTLS, private
subnet, WireGuard) rather than in-process TLS.

## Encryption key rotation

The secret store is stateless — the handle IS the ciphertext. Per-secret
revocation is impossible without rotating the master key, which invalidates
every ciphertext at once. Treat key rotation as a **blast-radius reset**, not
routine hygiene.

Runbook:

1. Generate a new key (`openssl rand -base64 32`).
2. Schedule a maintenance window.
3. For each user / org, re-enter the secrets (re-link OAuth providers, re-create storage credentials, re-add AI credentials). There is no scriptable migration — by design, the old key can't decrypt under the new master.
4. Swap `EDDYTOR_ENCRYPTION_KEY`, restart all replicas.
5. Old handles in the DB will fail decrypt and surface as `provider_reauth_required` / similar errors; users re-enter on next use.

## Azure storage registration auth modes

`POST /v1/storages/az` (CLI `eddytor create storage azure …`) accepts one auth mode:

| Mode | Fields | Notes |
|------|--------|-------|
| Access key | `access_key` | Storage account key. |
| SAS token | `sas_token` | Shared Access Signature. |
| Bearer / delegated | `bearer_token`, or omit all when the user has a linked Azure identity | Uses the per-org provider OAuth app (below). |
| **Service principal** | `client_id` + `client_secret` + `tenant_id` | Works on any deployment. Self-refreshes; no linked identity needed. |
| **Managed identity** | `use_msi` (+ optional `client_id` for a user-assigned identity) | Works only when Eddytor runs **on Azure infrastructure** (AKS/VM/ACI) with an identity assigned — it fetches tokens from the Azure IMDS endpoint. There is no build-time gate; if IMDS is unreachable, registration fails at the storage probe with `managed identity unavailable — not running on Azure infrastructure…`. |

Service-principal `client_secret` is encrypted at rest in the credentials vault like any
other key. Managed identity and service principal both refresh tokens internally, so they
need no delegated-OAuth link.

## Provider OAuth apps (optional)

To let users link their Azure / Google account so Eddytor can enumerate their
storage accounts/buckets and discover tables, register an OAuth app **per
organisation**. The client id/secret are stored encrypted in the database — not
env vars — so each org brings its own app and an unconfigured deployment simply
returns `provider_not_configured` (no crash).

Register the app, then store its credentials:

```bash
eddytor set provider-app azure \
  --client-id "<application-client-id>" \
  --client-secret "<client-secret>" \
  --tenant "<directory-tenant-id-or-domain>"   # omit for multi-tenant apps
# or: POST /v1/organisations/<org_id>/provider-apps/azure  (scope provider_apps:write)
```

Check what's configured (secrets never returned):

```bash
eddytor get provider-app                # all configured providers
eddytor get provider-app azure          # one provider
# or: GET /v1/organisations/<org_id>/provider-apps  (scope provider_apps:read)
```

Once an app is registered, users link their own account from the CLI with
`eddytor link provider azure` (re-run with `--azure-storage-access` to also
grant blob data access) or `eddytor link provider google` — the browser opens
for consent and the CLI waits for the link to land. Inspect links with
`eddytor get providers`, remove one with `eddytor unlink provider <provider>`.

### Microsoft Entra ID (Azure AD)

1. **App registrations** → **New registration**. Name it _Eddytor_. **Supported account types**: single-tenant for org-only, multi-tenant for shared.
2. **Redirect URI** (Web): `${public_url}/api/v1/auth/providers/azure/callback`. Replace `${public_url}` with your `server.public_url` (e.g. `https://app.eddytor.example.com`).
3. Copy the **Application (client) ID** (and **Directory (tenant) ID** for single-tenant apps).
4. **Certificates & secrets** → **New client secret** → 24-month expiry → copy the secret value.
5. **API permissions** → add `openid`, `email`, `profile`, `offline_access`, `User.Read`, `https://storage.azure.com/user_impersonation`, and `https://management.azure.com/user_impersonation`. Grant admin consent.
6. Store the client id / secret / tenant with `eddytor set provider-app azure …`.

### Google Workspace

1. Google Cloud Console → **APIs & Services** → **Credentials** → **Create Credentials** → **OAuth client ID** → **Web application**.
2. **Authorized redirect URI**: `${public_url}/api/v1/auth/providers/google/callback`.
3. Store the client id + secret with `eddytor set provider-app google …` (no tenant).
4. **OAuth consent screen** → publish (or keep in testing for a closed user list). Add the `devstorage.full_control` + `cloud-platform.read-only` scopes.

### Okta / other OIDC — REST walkthrough

Eddytor's SSO layer accepts any standards-compliant OIDC provider. There's no
admin UI yet, so configure via the REST API. End-to-end walkthrough from a
clean install:

**1. Register an OIDC app at your IdP.**

* **Okta:** Applications → Create App Integration → OIDC / Web Application. Sign-in redirect URI: `${server.public_url}/v1/oauth/sso/callback`. Capture `Client ID`, `Client secret`, and the issuer URL (e.g. `https://your-tenant.okta.com`).
* Other OIDC providers (Keycloak, Auth0, Authentik, etc.): same pattern. The redirect URI is always `${server.public_url}/v1/oauth/sso/callback`.

**2. Get an Eddytor admin bearer token.** The curl calls below need one in an
env var; mint an API key from inside the container — it *is* a bearer token and
doesn't expire:

```bash
docker compose exec eddytor-server eddytoradm create-api-key --email you@example.com
export EDDYTOR_TOKEN="edd_live_…"
```

(Interactively you can instead `eddytor login` and use the `eddytor` CLI, but it
stores the token in `~/.config/eddytor/config.toml` and doesn't print it, so for
scripting the raw curl calls below an API key is simpler.)

**3. Look up your organisation ID.**

```bash
ORG_ID=$(curl -fsS http://localhost:8080/api/v1/organisations \
  -H "Authorization: Bearer $EDDYTOR_TOKEN" | jq -r '.[0].id')
```

**4. Enable the SSO feature flag for the org.** SSO is a Preview feature; it's
off by default until explicitly enabled per-org.

```bash
curl -fsS -X PATCH "http://localhost:8080/api/v1/organisations/$ORG_ID/config" \
  -H "Authorization: Bearer $EDDYTOR_TOKEN" \
  -H 'Content-Type: application/json' \
  -d '{"features":{"sso":true}}'
```

**5. Create the OIDC connection.**

```bash
curl -fsS -X POST "http://localhost:8080/api/v1/organisations/$ORG_ID/sso" \
  -H "Authorization: Bearer $EDDYTOR_TOKEN" \
  -H 'Content-Type: application/json' \
  -d '{
    "display_name": "Okta",
    "issuer_url": "https://your-tenant.okta.com",
    "client_id": "0oa…",
    "client_secret": "…",
    "email_domain": "example.com",
    "enforce_sso": false,
    "default_role": "editor"
  }'
```

Field semantics:

| Field | Notes |
|---|---|
| `issuer_url` | Must be `https://`. Eddytor probes `${issuer}/.well-known/openid-configuration` at create time and rejects on failure. |
| `email_domain` | Lowercase domain (`example.com`). When a sign-in lands at `/v1/oauth/authorize` with an email at this domain, Eddytor routes to your IdP instead of magic link. |
| `enforce_sso` | `true` blocks magic-link fallback for the domain. Start with `false`, flip to `true` once you've confirmed the IdP works. |
| `default_role` | One of `viewer`, `editor`, `builder`, `admin`. Granted to first-time sign-ins via this connection. |

**6. Smoke-test.** Sign out, hit
`${server.public_url}/v1/oauth/authorize?login_hint=alice@example.com` in a
browser — Eddytor should 302 you to Okta. Approve, get bounced back to
`/v1/oauth/sso/callback`, then to your session.

Update / delete the connection later via `PUT` / `DELETE` on
`/v1/organisations/$ORG_ID/sso/$CONN_ID`.

### `oauth_redirect_base`

If your callback host differs from `public_url` (rare — typical when the IdP
allow-list is locked to a single FQDN behind a CDN), override:

```toml
[server]
oauth_redirect_base = "https://idp-callbacks.example.com"
```

The IdP app's redirect URI must match exactly:
`${oauth_redirect_base}/api/v1/auth/providers/<provider>/callback`.

## MCP clients

Eddytor exposes an MCP endpoint at `${public_url}/mcp`. Add the host to your
MCP-aware client:

**Claude Desktop** (`~/Library/Application Support/Claude/claude_desktop_config.json` on macOS):

```json
{
  "mcpServers": {
    "eddytor": {
      "url": "http://localhost:8080/mcp"
    }
  }
}
```

**Cursor** (Settings → MCP Servers):

```json
{
  "eddytor": {
    "url": "http://localhost:8080/mcp"
  }
}
```

The client triggers an OAuth 2.1 device-code flow on first use — open the URL in
your browser, approve, and the client caches the token.

## Production checklist

* **Check your credentials.** The installer generates a random `POSTGRES_PASSWORD` and Garage `GARAGE_ACCESS_KEY` / `GARAGE_SECRET_KEY` into `.env`; if your `.env` predates that (or you wrote it by hand), rotate any `eddytor`/`eddytor-secret` defaults before exposing the stack.
* Set `server.public_url` to your HTTPS hostname.
* Configure `server.cookie_domain` to the apex (e.g. `.eddytor.example.com` for cross-subdomain SSO).
* Lock `server.cors.allowed_origins` to your SPA host(s); drop the localhost wildcard.
* Running the web UI? Set `EDDYTOR_UI_ORIGIN` + `EDDYTOR_UI_API_BASE_URL` to the public HTTPS origins and point `EDDYTOR__SERVER__WEB_REDIRECT_URIS` at `${EDDYTOR_UI_ORIGIN}/auth/callback` (see _Web UI_).
* Wire real SMTP — without it, magic links only log to stdout.
* Front Eddytor with a TLS-terminating load balancer.
* Back up `.env` (compose) or the `eddytor-secrets` k8s Secret — losing `EDDYTOR_ENCRYPTION_KEY` makes stored secrets unrecoverable, and a wrong key fails server boot with "secret decrypt failed".
* Snapshot Postgres before upgrades; migrations are forward-only.

## Troubleshooting

### I can't sign in / lost my API key

Nothing to recover and nothing to miss — there is no one-shot token. Re-run the
in-container tools as often as you like (the auth boundary is exec access, not a
secret):

```bash
# Lost your key? Mint a fresh one (existing admin):
docker compose exec eddytor-server eddytoradm create-api-key --email you@example.com

# Or just sign in again — the magic link is re-requestable:
eddytor login
# With SMTP unset the link is in the logs:
docker compose logs --tail 50 eddytor-server | grep -i 'sign in to eddytor'
```

`eddytoradm setup` is idempotent: once an admin exists it's a no-op, so a leaked
DB role can't use it to seize a second admin. To restart from zero on a
throwaway local stack:

```bash
docker compose down -v && docker compose up -d
```
