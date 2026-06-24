#!/usr/bin/env bash
#
# Upgrade / re-run test for the self-host installer (ED-522).
#
# smoke-test.sh writes its own .env and never runs install.sh, so the installer's
# heal logic (ensure_env GARAGE_*/EDDYTOR_API_KEY_SECRET + idempotent garage.toml)
# is untested. This harness drives the REAL install.sh end to end:
#
#   1. serve deploy/selfhost over local HTTP (a fake release channel)
#   2. fresh install against it (local images, no registry pull) → assert healthy
#   3. mangle the install into a stale pre-Garage state (drop GARAGE_*, the
#      API-key secret, and garage.toml — what a MinIO-era .env looks like)
#   4. re-run install.sh (the documented upgrade path) → assert it HEALED the
#      .env + regenerated garage.toml + booted healthy again
#
# Usage:
#   deploy/selfhost/test-install.sh            # build :smoke images, run, tear down
#   SKIP_BUILD=1 deploy/selfhost/test-install.sh   # reuse existing :smoke images
#
# Requires: docker, docker compose, curl, openssl, python3. Uses host ports
# 8080/3900/50051 (the stack) + 8077 (file server) — stop conflicts first.

set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SELFHOST="${REPO_ROOT}/deploy/selfhost"
SERVER_IMG="${SERVER_IMG:-ghcr.io/nordalf/eddytor-ce-server:smoke}"
ENGINE_IMG="${ENGINE_IMG:-ghcr.io/nordalf/eddytor-ce-engine:smoke}"
HTTP_PORT=8077
BASE="http://localhost:8080"
export COMPOSE_PROJECT_NAME="eddytor-install-test"   # so install.sh's `up` + our teardown agree
WORK="" ; SRV_DIR="" ; HTTP_PID="" ; FAIL=0

green() { printf '\033[32m✓\033[0m %s\n' "$*"; }
red()   { printf '\033[31m✗ %s\033[0m\n' "$*"; FAIL=1; }
info()  { printf '\033[1m==>\033[0m %s\n' "$*"; }

cleanup() {
  info "tearing down"
  [ -n "$HTTP_PID" ] && kill "$HTTP_PID" 2>/dev/null
  [ -n "$WORK" ] && ( cd "$WORK" && docker compose down -v >/dev/null 2>&1 )
  [ -n "$WORK" ] && rm -rf "$WORK"
  [ -n "$SRV_DIR" ] && rm -rf "$SRV_DIR"
}
trap cleanup EXIT

# ---- build images -----------------------------------------------------------
if [ "${SKIP_BUILD:-0}" != "1" ]; then
  info "building community images (first build is slow)…"
  docker build --target eddytor-server -t "$SERVER_IMG" "$REPO_ROOT" || { red "server image build failed"; exit 1; }
  docker build --target eddytor-engine -t "$ENGINE_IMG" "$REPO_ROOT" || { red "engine image build failed"; exit 1; }
  green "images built"
fi

# ---- fake release channel (what `curl get.eddytor.com/...` would serve) ------
SRV_DIR="$(mktemp -d)"
cp "${SELFHOST}/docker-compose.yml" "${SELFHOST}/config.toml" "$SRV_DIR/"
[ -f "${SELFHOST}/HOSTING.md" ] && cp "${SELFHOST}/HOSTING.md" "$SRV_DIR/"
printf 'latest\n' > "${SRV_DIR}/VERSION"
( cd "$SRV_DIR" && exec python3 -m http.server "$HTTP_PORT" >/dev/null 2>&1 ) &
HTTP_PID=$!
i=0; until curl -fsS "http://localhost:${HTTP_PORT}/VERSION" >/dev/null 2>&1; do
  i=$((i+1)); [ "$i" -gt 20 ] && { red "local file server never came up"; exit 1; }; sleep 0.5
done
green "serving deploy/selfhost on :${HTTP_PORT}"

# ---- install dir + image override (local images, no ghcr) -------------------
WORK="$(mktemp -d)/eddytor"
mkdir -p "$WORK"
# install.sh runs `docker compose pull` + `up` in $WORK, which auto-read this
# override. `pull_policy: never` pins the locally-built server/engine AND makes
# `docker compose pull` skip them (it honours never), so the installer's pull
# succeeds against ghcr for garage/postgres without ever reaching for our
# local-only :smoke tags — no installer knob needed.
cat > "${WORK}/docker-compose.override.yml" <<EOF
services:
  eddytor-server:
    image: ${SERVER_IMG}
    pull_policy: never
  eddytor-engine:
    image: ${ENGINE_IMG}
    pull_policy: never
EOF

run_installer() {
  EDDYTOR_BASE_URL="http://localhost:${HTTP_PORT}" \
  EDDYTOR_DIR="$WORK" \
  EDDYTOR_ADMIN_EMAIL=operator@example.com \
  EDDYTOR_ORG_NAME=Upgrade \
  EDDYTOR_WITH_UI=false \
    sh "${SELFHOST}/install.sh"
}

env_has() { grep -q "^$1=" "${WORK}/.env" 2>/dev/null; }
healthy() {
  i=0; until curl -fsS "${BASE}/healthz" >/dev/null 2>&1; do
    i=$((i+1)); [ "$i" -gt 60 ] && return 1; sleep 2
  done
}

# ---- 1. fresh install -------------------------------------------------------
info "fresh install via install.sh"
if run_installer >/tmp/install-1.log 2>&1; then green "fresh install completed"; else red "fresh install failed (see /tmp/install-1.log)"; fi
healthy && green "stack healthy after fresh install" || red "stack not healthy after fresh install"
env_has GARAGE_ACCESS_KEY && env_has GARAGE_SECRET_KEY && env_has EDDYTOR_API_KEY_SECRET && env_has EDDYTOR_BUCKET \
  && green ".env has Garage creds + API-key secret" || red ".env missing expected keys after fresh install"
[ -f "${WORK}/garage.toml" ] && green "garage.toml generated" || red "garage.toml missing after fresh install"

# ---- 2. mangle into a stale pre-Garage install -----------------------------
info "simulating a stale pre-Garage .env (drop Garage creds + API-key secret + garage.toml)"
( cd "$WORK" && docker compose down >/dev/null 2>&1 )   # stop, keep volumes (an upgrade keeps data)
grep -vE '^(GARAGE_ACCESS_KEY|GARAGE_SECRET_KEY|EDDYTOR_BUCKET|EDDYTOR_API_KEY_SECRET)=' "${WORK}/.env" > "${WORK}/.env.stale"
mv "${WORK}/.env.stale" "${WORK}/.env"
rm -f "${WORK}/garage.toml"
# sanity: the stale state really is missing them
if env_has EDDYTOR_API_KEY_SECRET || env_has GARAGE_ACCESS_KEY || [ -f "${WORK}/garage.toml" ]; then
  red "could not produce a stale install (mangle step failed)"
fi

# ---- 3. re-run = upgrade path: must heal + boot -----------------------------
info "re-running install.sh (upgrade path) against the stale install"
if run_installer >/tmp/install-2.log 2>&1; then green "re-run completed"; else red "re-run failed (see /tmp/install-2.log)"; fi
env_has EDDYTOR_API_KEY_SECRET && green "healed EDDYTOR_API_KEY_SECRET" || red "did NOT heal EDDYTOR_API_KEY_SECRET"
env_has GARAGE_ACCESS_KEY && env_has GARAGE_SECRET_KEY && env_has EDDYTOR_BUCKET \
  && green "healed Garage creds + bucket" || red "did NOT heal Garage creds"
[ -f "${WORK}/garage.toml" ] && green "regenerated garage.toml" || red "did NOT regenerate garage.toml"
healthy && green "stack healthy after upgrade re-run" || red "stack not healthy after upgrade re-run"

# ---- verdict ----------------------------------------------------------------
echo
if [ "$FAIL" -eq 0 ]; then green "INSTALLER UPGRADE TEST PASSED"; else red "INSTALLER UPGRADE TEST FAILED"; fi
exit "$FAIL"
