#!/bin/sh
#
# Eddytor self-host installer.
#
#   curl -fsSL https://get.eddytor.com | sh
#
# Scaffolds an install directory (~/eddytor) containing docker-compose.yml,
# config.toml (non-secret settings), and a generated .env (secrets), starts the
# stack, and creates the first admin via `eddytoradm` (run inside the server
# container — no public setup endpoint).
# POSIX sh — pipe-to-sh safe. The directory is yours: back it up, version it.
#
# Re-running is the upgrade path: it re-downloads docker-compose.yml, bumps
# EDDYTOR_VERSION in your .env to the published release, keeps every secret,
# and restarts the stack.
#
# Windows: run this inside WSL2 (Docker Desktop's default backend) or Git Bash,
# where `curl … | sh` works unchanged.
#
# Env knobs:
#   EDDYTOR_BASE_URL    where to fetch compose + config.toml (default get.eddytor.com)
#   EDDYTOR_DIR         install dir (default: ~/eddytor)
#   EDDYTOR_VERSION     image tag to pin in .env (default: the tag published
#                       at <BASE_URL>/VERSION; 'latest' if unreachable)
#   EDDYTOR_ADMIN_EMAIL first-admin email (else prompts)
#   EDDYTOR_ORG_NAME    first organisation name (else prompts; default "Default")
#   EDDYTOR_WITH_UI     true/false — include the web UI (else prompts on fresh
#                       install; re-runs keep your existing choice unless set)
#   EDDYTOR_SEED_DEMO   true/false — after admin setup, register the bundled
#                       Garage store and seed a demo table (else prompts; yes
#                       when non-interactive). Best-effort, never blocks.

set -eu

BASE_URL="${EDDYTOR_BASE_URL:-https://get.eddytor.com}"
DIR="${EDDYTOR_DIR:-$HOME/eddytor}"
PUBLIC_URL="http://localhost:8080"

# Fresh vs re-run: an existing .env means we are re-running/upgrading an install
# we already own, whose own containers legitimately hold the host ports — so the
# port preflight below applies to fresh installs only.
if [ -f "${DIR}/.env" ]; then FRESH=false; else FRESH=true; fi

red()  { printf '\033[31m%s\033[0m\n' "$*" >&2; }
bold() { printf '\033[1m%s\033[0m\n' "$*"; }
info() { printf '==> %s\n' "$*"; }
die()  { red "✗ $*"; exit 1; }

# Cheap structural email check, mirroring the server's is_plausible_email: a
# non-empty local part, an '@', and a dotted domain. Not RFC-complete — just
# enough to catch typos before we hand the value to eddytoradm.
valid_email() {
  printf '%s' "$1" | grep -Eq '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$'
}

# ---- preflight --------------------------------------------------------------
command -v docker  >/dev/null 2>&1 || die "docker is required: https://docs.docker.com/get-docker/"
command -v curl    >/dev/null 2>&1 || die "curl is required"
command -v openssl >/dev/null 2>&1 || die "openssl is required"
if docker compose version >/dev/null 2>&1; then
  DC="docker compose"
elif command -v docker-compose >/dev/null 2>&1; then
  DC="docker-compose"
else
  die "docker compose v2 is required"
fi
docker info >/dev/null 2>&1 || die "the docker daemon is not running"

# ---- scaffold install dir ---------------------------------------------------
info "installing Eddytor into ${DIR}"
mkdir -p "$DIR"

info "downloading compose + config from ${BASE_URL}"
# docker-compose.yml is replaced on every run (you should not edit it).
curl -fsSL "${BASE_URL}/docker-compose.yml" -o "${DIR}/docker-compose.yml" \
  || die "could not download ${BASE_URL}/docker-compose.yml"
# config.toml holds your non-secret config (public URL, CORS, …). Downloaded
# once, then yours to edit — never clobbered on re-run.
if [ -f "${DIR}/config.toml" ]; then
  info "reusing existing ${DIR}/config.toml"
else
  curl -fsSL "${BASE_URL}/config.toml" -o "${DIR}/config.toml" \
    || die "could not download ${BASE_URL}/config.toml"
fi

# The operator guide — refreshed every run (a doc, not config you edit). Best
# effort: a missing guide must never block the install.
curl -fsSL "${BASE_URL}/HOSTING.md" -o "${DIR}/HOSTING.md" 2>/dev/null \
  || info "operator guide unavailable at ${BASE_URL}/HOSTING.md (skipping)"

# Pin the concrete release tag published for the channel at BASE_URL. An
# explicit EDDYTOR_VERSION wins; otherwise read the VERSION marker, falling
# back to 'latest' only if it is unreachable.
VER="${EDDYTOR_VERSION:-$(curl -fsSL "${BASE_URL}/VERSION" 2>/dev/null || echo latest)}"

# ---- web UI opt-in ----------------------------------------------------------
# The web UI is a compose profile (COMPOSE_PROFILES=ui in .env). Explicit
# EDDYTOR_WITH_UI wins; a re-run keeps the choice already recorded in .env;
# a fresh install prompts (default yes; non-interactive runs get yes).
if [ -n "${EDDYTOR_WITH_UI:-}" ]; then
  WITH_UI="$EDDYTOR_WITH_UI"
elif [ -f "${DIR}/.env" ]; then
  if grep -q '^COMPOSE_PROFILES=.*ui' "${DIR}/.env"; then WITH_UI=true; else WITH_UI=false; fi
else
  printf 'Include the web UI (adds http://localhost:3000)? [Y/n] '
  ANS=""
  read -r ANS </dev/tty || true
  case "$ANS" in [Nn]*) WITH_UI=false ;; *) WITH_UI=true ;; esac
fi

# The UI releases on its own cadence — pin from its own VERSION marker.
if [ "$WITH_UI" = "true" ]; then
  UI_VER="${EDDYTOR_UI_VERSION:-$(curl -fsSL "${BASE_URL}/ui/VERSION" 2>/dev/null || echo latest)}"
fi

# Append `NAME=generated-value` to .env if NAME is not already present.
# Lets a re-run heal an .env generated by an older installer that predates a
# newly-required secret, instead of crash-looping the server.
ensure_env() {
  if ! grep -q "^$1=" "${DIR}/.env"; then
    info "adding missing $1 to .env"
    printf '%s=%s\n' "$1" "$2" >> "${DIR}/.env"
  fi
}

# ---- generate .env (once) ---------------------------------------------------
# .env carries only secrets + the bundled-stack wiring Docker Compose needs to
# interpolate. Non-secret app config lives in config.toml.
if [ -f "${DIR}/.env" ]; then
  info "reusing existing ${DIR}/.env (secrets kept)"
  # Upgrade: re-pin the image tag to the published release. Everything else in
  # .env is yours and is left untouched.
  if grep -q '^EDDYTOR_VERSION=' "${DIR}/.env"; then
    CUR="$(sed -n 's/^EDDYTOR_VERSION=//p' "${DIR}/.env" | head -1)"
    if [ "$CUR" != "$VER" ]; then
      info "bumping EDDYTOR_VERSION ${CUR} → ${VER}"
      ROLLBACK_VER="$CUR"   # restore this if the pull below fails on a bad tag
      sed "s|^EDDYTOR_VERSION=.*|EDDYTOR_VERSION=${VER}|" "${DIR}/.env" > "${DIR}/.env.tmp" \
        && mv "${DIR}/.env.tmp" "${DIR}/.env" && chmod 600 "${DIR}/.env"
    fi
  else
    ensure_env EDDYTOR_VERSION "$VER"
  fi
  # Heal secrets a newer server requires that an older .env predates.
  ensure_env EDDYTOR_API_KEY_SECRET "$(openssl rand -base64 32)"
  # Heal Garage creds — a pre-Garage (MinIO-era) .env predates these, and
  # docker-compose.yml references them with no default, so empty creds would
  # provision an unusable bucket. (garage.toml is regenerated below if missing.)
  ensure_env GARAGE_ACCESS_KEY "GK$(openssl rand -hex 16)"
  ensure_env GARAGE_SECRET_KEY "$(openssl rand -hex 32)"
  ensure_env EDDYTOR_BUCKET "eddytor"
  # Web UI: enable the profile + redirect_uri wiring, and re-pin the UI tag.
  if [ "$WITH_UI" = "true" ]; then
    ensure_env COMPOSE_PROFILES ui
    if ! grep -q '^EDDYTOR__SERVER__WEB_REDIRECT_URIS=' "${DIR}/.env"; then
      bold "note: EDDYTOR__SERVER__WEB_REDIRECT_URIS is an env override — it REPLACES (not merges) any web_redirect_uris in config.toml. Add further URIs to that .env line, comma-separated."
    fi
    ensure_env EDDYTOR__SERVER__WEB_REDIRECT_URIS "http://localhost:3000/auth/callback"
    if grep -q '^EDDYTOR_UI_VERSION=' "${DIR}/.env"; then
      CUR_UI="$(sed -n 's/^EDDYTOR_UI_VERSION=//p' "${DIR}/.env" | head -1)"
      if [ "$CUR_UI" != "$UI_VER" ]; then
        info "bumping EDDYTOR_UI_VERSION ${CUR_UI} → ${UI_VER}"
        sed "s|^EDDYTOR_UI_VERSION=.*|EDDYTOR_UI_VERSION=${UI_VER}|" "${DIR}/.env" > "${DIR}/.env.tmp" \
          && mv "${DIR}/.env.tmp" "${DIR}/.env" && chmod 600 "${DIR}/.env"
      fi
    else
      ensure_env EDDYTOR_UI_VERSION "$UI_VER"
    fi
  fi
else
  info "generating ${DIR}/.env with fresh secrets"
  ENC="$(openssl rand -base64 32)"
  AKS="$(openssl rand -base64 32)"
  # hex (URL-safe): the postgres password is embedded in a connection URL.
  PGP="$(openssl rand -hex 16)"
  # Garage creds: key id must be `GK` + 32 hex (Garage's access-key format),
  # secret 64 hex. rpc_secret/admin_token go into garage.toml, not .env.
  GAK="GK$(openssl rand -hex 16)"
  GSK="$(openssl rand -hex 32)"
  cat > "${DIR}/.env" <<EOF
# Eddytor self-host secrets + Compose wiring — generated by install.sh.
# Non-secret config lives in config.toml. BACK THIS FILE UP: losing
# EDDYTOR_ENCRYPTION_KEY makes every stored secret unrecoverable.

# Image tag to run. Re-run the installer to upgrade (it bumps this), or edit
# it yourself and \`docker compose pull && docker compose up -d\`.
EDDYTOR_VERSION=${VER}

# Secrets (32 random bytes, base64). Required.
EDDYTOR_ENCRYPTION_KEY=${ENC}
EDDYTOR_API_KEY_SECRET=${AKS}

# Database — bundled postgres (password generated at install). Point at
# managed Postgres for production, e.g.
# EDDYTOR_DATABASE_URL=postgres://user:pass@db.internal:5432/eddytor
EDDYTOR_DATABASE_URL=postgres://eddytor:${PGP}@postgres:5432/eddytor
POSTGRES_USER=eddytor
POSTGRES_PASSWORD=${PGP}
POSTGRES_DB=eddytor

# Object store — bundled Garage (S3-compatible store by Deuxfleurs, AGPLv3;
# garagehq.deuxfleurs.fr). Creds generated at install. Register it after
# sign-in (endpoint http://garage:3900, region us-east-1).
GARAGE_ACCESS_KEY=${GAK}
GARAGE_SECRET_KEY=${GSK}
EDDYTOR_BUCKET=eddytor

# Host interface for the API ports (8080 HTTP, 8082 Flight SQL).
# 127.0.0.1 = loopback only; set 0.0.0.0 for LAN/VPN access (put TLS in front
# first — see HOSTING.md). Postgres/Garage/engine always stay loopback-only.
EDDYTOR_BIND_ADDR=127.0.0.1

# Email — with SMTP unset, sign-in magic links are logged to stdout. Fill these
# to deliver real email to your users.
# EDDYTOR_SMTP_HOST=smtp.acme.com
# EDDYTOR_SMTP_PORT=587
# EDDYTOR_SMTP_FROM=eddytor@acme.com
# EDDYTOR_SMTP_USER=
# EDDYTOR_SMTP_PASS=
EOF
  if [ "$WITH_UI" = "true" ]; then
    cat >> "${DIR}/.env" <<EOF

# Web UI — started because COMPOSE_PROFILES includes 'ui'. To disable, remove
# the COMPOSE_PROFILES line and run \`docker compose up -d --remove-orphans\`.
COMPOSE_PROFILES=ui
EDDYTOR_UI_VERSION=${UI_VER}
# Registers the UI origin as an OAuth redirect_uri on the server. NOTE: this
# env override REPLACES any web_redirect_uris in config.toml (comma-separated
# list — add further URIs here, not there).
EDDYTOR__SERVER__WEB_REDIRECT_URIS=http://localhost:3000/auth/callback
EOF
  fi
  chmod 600 "${DIR}/.env"
  bold "Secrets written to ${DIR}/.env — back this file up. Losing EDDYTOR_ENCRYPTION_KEY makes stored secrets unrecoverable."
fi

# ---- garage.toml (idempotent) -----------------------------------------------
# Written once and kept. Generated here (not only on fresh install) so an
# upgrade from a pre-Garage install — which has no garage.toml — still gets one;
# docker-compose.yml hard-mounts ./garage.toml, so a missing file would become
# an empty directory and Garage would fail to start. Carries the rpc_secret +
# admin_token (secrets); s3_region pinned to us-east-1 to match registration.
if [ ! -f "${DIR}/garage.toml" ]; then
  info "writing ${DIR}/garage.toml"
  cat > "${DIR}/garage.toml" <<EOF
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
  chmod 600 "${DIR}/garage.toml"
fi

# ---- start ------------------------------------------------------------------
# Restore the pre-bump image tag after a failed upgrade pull, so a re-run isn't
# stuck pointing at a bad tag. No-op on a fresh install (ROLLBACK_VER unset).
restore_version() {
  if [ -n "${ROLLBACK_VER:-}" ]; then
    info "restoring EDDYTOR_VERSION=${ROLLBACK_VER}"
    sed "s|^EDDYTOR_VERSION=.*|EDDYTOR_VERSION=${ROLLBACK_VER}|" "${DIR}/.env" > "${DIR}/.env.tmp" \
      && mv "${DIR}/.env.tmp" "${DIR}/.env" && chmod 600 "${DIR}/.env"
  fi
}

# Port preflight (fresh installs only). Nothing of ours runs yet, so a listener
# on a port we need belongs to a foreign process — a host Postgres on 5432 is
# the classic one. Catch it now and name the exact port, instead of letting
# `docker compose up` fail later with a message that looks like an image error.
# curl exit 7 = connection refused = free; any other result = something answered.
port_busy() {
  rc=0
  curl -fsS -o /dev/null --connect-timeout 1 --max-time 2 "http://127.0.0.1:$1/" >/dev/null 2>&1 || rc=$?
  [ "$rc" -ne 7 ]
}
if [ "$FRESH" = "true" ]; then
  PORTS="8080 8082 5432 3900"
  [ "$WITH_UI" = "true" ] && PORTS="$PORTS 3000"
  BUSY=""
  for p in $PORTS; do
    if port_busy "$p"; then BUSY="${BUSY}${BUSY:+ }${p}"; fi
  done
  if [ -n "$BUSY" ]; then
    red "✗ host port(s) already in use: ${BUSY}"
    info "Eddytor needs these host ports free: 8080 (API), 8082 (Flight), 5432 (Postgres), 3900 (Garage)$([ "$WITH_UI" = "true" ] && printf ', 3000 (UI)')."
    info "Find what holds them:  lsof -nP -iTCP -sTCP:LISTEN | grep -E '$(printf '%s' "$BUSY" | sed 's/ /|/g')'"
    die "a local Postgres on 5432 is the usual culprit — stop it (or free the port[s] above), then re-run."
  fi
fi

info "pulling images (first pull can take a few minutes)"
if ! ( cd "$DIR" && $DC pull ); then
  restore_version
  die "could not pull images. Check that EDDYTOR_VERSION=${VER} exists on ghcr.io/nordalf and the registry is reachable. Logs: (cd ${DIR} && ${DC} logs)"
fi

info "starting the stack"
UP_RC=0
UP_OUT="$( cd "$DIR" && $DC up -d 2>&1 )" || UP_RC=$?
if [ "$UP_RC" -ne 0 ]; then
  printf '%s\n' "$UP_OUT" >&2
  if printf '%s' "$UP_OUT" | grep -qiE 'address already in use|port is already allocated|bind for .* failed|ports are not available'; then
    HOSTPORT="$(printf '%s' "$UP_OUT" | grep -oiE '(0\.0\.0\.0|127\.0\.0\.1|\[::1?\]):[0-9]+' | head -1)"
    restore_version
    die "a host port Eddytor needs is already in use${HOSTPORT:+ (${HOSTPORT})} — this is NOT an image problem. A local Postgres on 5432 is the usual culprit. Free it (lsof -nP -iTCP -sTCP:LISTEN) and re-run."
  fi
  restore_version
  die "could not start the stack — see the output above. Full logs: (cd ${DIR} && ${DC} logs)"
fi

info "waiting for the server to become healthy"
i=0
until curl -fsS "${PUBLIC_URL}/healthz" >/dev/null 2>&1; do
  i=$((i + 1))
  if [ "$i" -gt 90 ]; then
    red "✗ server did not become healthy. Last server logs:"
    ( cd "$DIR" && $DC logs --tail=25 eddytor-server ) || true
    die "see above — full logs: (cd ${DIR} && ${DC} logs eddytor-server)"
  fi
  sleep 2
done
info "server is up at ${PUBLIC_URL}"

# ---- create the first admin -------------------------------------------------
# Runs `eddytoradm` INSIDE the server container — the only place provisioning is
# reachable from (the kubeadm model). No public endpoint, no token. Idempotent:
# a no-op once an admin already exists.
EMAIL="${EDDYTOR_ADMIN_EMAIL:-}"
# A bad EDDYTOR_ADMIN_EMAIL is a headless-install typo: fail loud rather than
# provision an admin nobody can sign in as.
if [ -n "$EMAIL" ] && ! valid_email "$EMAIL"; then
  die "EDDYTOR_ADMIN_EMAIL='$EMAIL' is not a valid email address."
fi
if [ -z "$EMAIL" ]; then
  # No tty (CI / `docker exec` without -t / systemd): skip provisioning rather
  # than die after the stack is already up — print the exact command instead.
  if [ -r /dev/tty ]; then
    while :; do
      printf 'Admin email for first sign-in: '
      read -r EMAIL </dev/tty || true
      [ -z "$EMAIL" ] && break          # empty → fall through to the skip path
      valid_email "$EMAIL" && break
      red "  '$EMAIL' is not a valid email address — try again."
    done
  fi
fi
if [ -z "$EMAIL" ]; then
  bold "No admin email (set EDDYTOR_ADMIN_EMAIL for headless installs). The stack is up — create the first admin when ready:"
  info "  cd ${DIR} && ${DC} exec eddytor-server eddytoradm setup --email you@example.com --org \"Default\""
  exit 0
fi

ORG="${EDDYTOR_ORG_NAME:-}"
if [ -z "$ORG" ]; then
  printf 'Organisation name [Default]: '
  read -r ORG </dev/tty || true
  ORG="${ORG:-Default}"
fi

info "creating first admin via eddytoradm"
SETUP_OK=true
# `</dev/null`: `docker compose exec` forwards our stdin to the container and
# drains it. Under `curl … | sh` our stdin IS the script, so without this the
# exec eats the rest of the installer and everything after here silently never
# runs. Prompts read /dev/tty, so they are unaffected.
if ! ( cd "$DIR" && $DC exec -T eddytor-server eddytoradm setup --email "$EMAIL" --org "$ORG" </dev/null ); then
  SETUP_OK=false
  red "first-admin setup did NOT complete — the stack is up but has no admin yet."
  info "retry once the server is healthy:"
  info "  cd ${DIR} && ${DC} exec eddytor-server eddytoradm setup --email \"$EMAIL\" --org \"$ORG\""
fi

# ---- golden path: storage + demo table (best-effort) ------------------------
# install → login → register storage → demo table → see it. Mints a bootstrap
# API key, registers the bundled Garage store, and seeds a demo table. The stack
# is already up, so every failure here only prints the manual steps — it never
# aborts the install.
DEMO_SEEDED=false
DEMO_CONFIG=""
BUCKET="$(sed -n 's/^EDDYTOR_BUCKET=//p' "${DIR}/.env" | head -1)"; BUCKET="${BUCKET:-eddytor}"
if [ "$SETUP_OK" = "true" ]; then
  SEED="${EDDYTOR_SEED_DEMO:-}"
  if [ -z "$SEED" ]; then
    if [ -r /dev/tty ]; then
      printf 'Register the bundled Garage store and seed a demo table now? [Y/n] '
      ANS=""; read -r ANS </dev/tty || true
      case "$ANS" in [Nn]*) SEED=false ;; *) SEED=true ;; esac
    else
      SEED=true
    fi
  fi
  if [ "$SEED" = "true" ]; then
    GAK="$(sed -n 's/^GARAGE_ACCESS_KEY=//p' "${DIR}/.env" | head -1)"
    GSK="$(sed -n 's/^GARAGE_SECRET_KEY=//p' "${DIR}/.env" | head -1)"
    info "minting a short-lived bootstrap API key"
    # create-api-key prints the key on its own indented line — pull the edd_live_… token.
    # --expires-in-minutes scopes this one-shot Admin key to the seed window so it
    # self-revokes even if the steps below die mid-run (no long-lived root key left in the DB).
    KEY="$( cd "$DIR" && $DC exec -T eddytor-server eddytoradm create-api-key --email "$EMAIL" --name installer-bootstrap --expires-in-minutes 10 </dev/null 2>/dev/null \
              | grep -oE 'edd_live_[A-Za-z0-9_-]+' | head -1 )"
    if [ -z "$KEY" ]; then
      info "could not mint an API key — skipping the demo seed (do it later; see 'Storage & demo table' below)."
    else
      info "registering the bundled Garage store"
      # Engine reaches Garage over the compose network, so the endpoint is the
      # service name (garage:3900), not localhost.
      if curl -fsS -o /dev/null -X POST "${PUBLIC_URL}/api/v1/storages/s3" \
           -H "Authorization: Bearer ${KEY}" -H 'Content-Type: application/json' \
           -d "{\"bucketName\":\"${BUCKET}\",\"region\":\"us-east-1\",\"accessKeyId\":\"${GAK}\",\"secretKey\":\"${GSK}\",\"endpoint\":\"http://garage:3900\",\"discoverDelta\":true,\"discoverIceberg\":false}" 2>/dev/null
      then
        # Register's response omits the config id — read it back from the list
        # (a fresh install has exactly one config) by extracting the "id" UUID.
        DEMO_CONFIG="$(curl -fsS "${PUBLIC_URL}/api/v1/storages/configs" -H "Authorization: Bearer ${KEY}" 2>/dev/null \
            | grep -oE '"id":"[0-9a-fA-F-]{36}"' | head -1 | sed 's/.*"id":"//; s/"//')"
        if [ -n "$DEMO_CONFIG" ] && curl -fsS -o /dev/null -X POST \
             "${PUBLIC_URL}/api/v1/storages/configs/${DEMO_CONFIG}/demo-table" \
             -H "Authorization: Bearer ${KEY}" 2>/dev/null
        then
          DEMO_SEEDED=true
          info "seeded demo table 'demo_products' (storage config ${DEMO_CONFIG})"
        else
          info "registered Garage, but seeding the demo table failed — see 'Storage & demo table' below."
        fi
      else
        info "could not register Garage automatically — see 'Storage & demo table' below."
      fi
    fi
  fi
fi

# ---- done -------------------------------------------------------------------
echo
bold "✓ Eddytor is running — ${PUBLIC_URL}"
echo "  Install dir: ${DIR}   (config.toml = settings · .env = secrets — back .env up)"

# Warn if the API is bound beyond loopback without TLS in front.
BIND="$(sed -n 's/^EDDYTOR_BIND_ADDR=//p' "${DIR}/.env" | head -1)"
if [ -n "$BIND" ] && [ "$BIND" != "127.0.0.1" ] && [ "$BIND" != "localhost" ]; then
  if grep -q '^public_url *= *"http://' "${DIR}/config.toml" 2>/dev/null; then
    red "⚠  API is bound to ${BIND} (beyond loopback) over plaintext HTTP. Put TLS in front (edge proxy / LB) before exposing it — see HOSTING.md."
  fi
fi

# --- NEXT STEPS (the one path to follow) ---
echo
bold "Next steps"
if [ "$WITH_UI" = "true" ]; then
  cat <<EOF
  1. Open the web UI:  http://localhost:3000
     Sign in as ${EMAIL} (magic link). With SMTP unset the link is in the logs:
       cd ${DIR} && ${DC} logs eddytor-server | grep -iA2 'sign in to eddytor'
EOF
  if [ "$DEMO_SEEDED" = "true" ]; then
    echo "  2. Your 'demo_products' table is already seeded — open it in the UI."
  else
    echo "  2. Register storage + create a table — see 'Storage & demo table' below."
  fi
  echo "  3. Invite teammates from the UI (or CLI / REST)."
else
  cat <<EOF
  1. Install the CLI:
       brew install eddytor-labs/tap/eddytor
       # or: curl -fsSL https://raw.githubusercontent.com/eddytor-labs/eddytor-cli/main/install.sh | sh
  2. Point it at THIS server — the CLI defaults to Eddytor Cloud, so set BOTH urls:
       eddytor config set-api-url    ${PUBLIC_URL}
       eddytor config set-flight-url http://localhost:8082
  3. Sign in (magic link; with SMTP unset the link is in the logs):
       eddytor login
       cd ${DIR} && ${DC} logs eddytor-server | grep -iA2 'sign in to eddytor'
EOF
  if [ "$DEMO_SEEDED" = "true" ]; then
    echo "  4. See the seeded demo table:  eddytor get tables"
  else
    echo "  4. Register storage + create a table — see 'Storage & demo table' below."
  fi
fi

# --- STORAGE & DEMO TABLE ---
echo
bold "Storage & demo table"
if [ "$DEMO_SEEDED" = "true" ]; then
  echo "  ✓ Bundled Garage registered and a 'demo_products' table seeded (config ${DEMO_CONFIG})."
  echo "    Browse it:  GET ${PUBLIC_URL}/api/v1/storages/tables   (or 'eddytor get tables')."
else
  cat <<EOF
  Register the bundled Garage store, then seed a demo table. From a configured CLI:
    eddytor create storage s3 --bucket ${BUCKET} --region us-east-1 \\
      --endpoint http://garage:3900 \\
      --access-key-id <GARAGE_ACCESS_KEY> --secret-access-key <GARAGE_SECRET_KEY>
    eddytor create demo-table --config <config-id-from-output>
  Creds are GARAGE_ACCESS_KEY / GARAGE_SECRET_KEY in ${DIR}/.env. The endpoint is the
  in-container service name http://garage:3900 (the engine reaches the store over the
  compose network — not the host's localhost), the same value the installer registers.
EOF
fi

# --- ENDPOINTS ---
echo
bold "Endpoints"
cat <<EOF
  REST API      ${PUBLIC_URL}/api/v1
  OpenAPI spec  ${PUBLIC_URL}/spec
  MCP           ${PUBLIC_URL}/mcp
  Flight SQL    localhost:8082
  Health        ${PUBLIC_URL}/healthz
EOF
[ "$WITH_UI" = "true" ] && echo "  Web UI        http://localhost:3000"
echo "  (loopback-only unless you set EDDYTOR_BIND_ADDR — see .env)"

# --- HEADLESS ACCESS ---
echo
bold "Headless access (no browser)"
cat <<EOF
  Mint an admin API key:
    KEY=\$(cd ${DIR} && ${DC} exec -T eddytor-server eddytoradm create-api-key --email ${EMAIL})   # edd_live_…
  REST:  curl -H "Authorization: Bearer \$KEY" ${PUBLIC_URL}/api/v1/storages/tables
  MCP :  { "url": "${PUBLIC_URL}/mcp", "headers": { "Authorization": "Bearer \$KEY" } }
EOF

# --- OPS ---
echo
bold "Ops"
cat <<EOF
  cd ${DIR}
  ${DC} ps                                # status
  ${DC} logs -f                           # logs
  \$EDITOR config.toml && ${DC} restart    # change settings (public URL, CORS, …)
  ${DC} down                              # stop (keeps data)
  ${DC} down -v                           # stop and DELETE all data

Full operator guide: ${DIR}/HOSTING.md
Upgrade: re-run this installer — re-downloads docker-compose.yml, bumps
EDDYTOR_VERSION in .env, keeps your secrets and config.toml.
EOF
