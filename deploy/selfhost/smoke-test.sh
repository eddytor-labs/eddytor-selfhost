#!/usr/bin/env bash
#
# Operator-perspective smoke test for the community self-host.
#
# Builds the community images locally, brings up the standalone compose stack
# exactly as an operator would (env_file + generated secrets + bundled
# pg/garage), then walks the onboarding journey via REST and asserts each step:
#
#   health → eddytoradm setup creates the admin → setup is idempotent →
#   eddytoradm mints an API key → key authenticates → unauth is rejected →
#   register Garage storage → JWKS served → JWT round-trip validated by engine
#
# This catches the things that break for a real operator (not just config
# parsing). Table creation is gRPC + Arrow IPC and is covered by the engine
# integration tests, so it's out of scope here.
#
# Usage:
#   deploy/selfhost/smoke-test.sh            # build images, run, tear down
#   SKIP_BUILD=1 deploy/selfhost/smoke-test.sh   # reuse existing :smoke images
#   SKIP_BUILD=1 SERVER_IMG=… ENGINE_IMG=… deploy/selfhost/smoke-test.sh
#                                            # test already-pulled images (CI gate)
#   WITH_UI=1 deploy/selfhost/smoke-test.sh  # also bring up + check the web UI
#                                            # profile (pulls eddytor-ce-ui)
#
# Requires: docker, docker compose, curl, openssl. Uses host ports 8080/50051/
# 3900 — stop any conflicting stack first.

set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SELFHOST="${REPO_ROOT}/deploy/selfhost"
PROJECT="eddytor-smoke"
SERVER_IMG="${SERVER_IMG:-ghcr.io/nordalf/eddytor-ce-server:smoke}"
ENGINE_IMG="${ENGINE_IMG:-ghcr.io/nordalf/eddytor-ce-engine:smoke}"
BASE="http://localhost:8080"
WORK=""
FAIL=0

green() { printf '\033[32m✓\033[0m %s\n' "$*"; }
red()   { printf '\033[31m✗ %s\033[0m\n' "$*"; FAIL=1; }
info()  { printf '\033[1m==>\033[0m %s\n' "$*"; }

cleanup() {
  info "tearing down"
  [ -n "$WORK" ] && ( cd "$WORK" && docker compose -p "$PROJECT" down -v >/dev/null 2>&1 )
  [ -n "$WORK" ] && rm -rf "$WORK"
}
trap cleanup EXIT

# ---- build images (community edition = no CARGO_FEATURES) --------------------
if [ "${SKIP_BUILD:-0}" != "1" ]; then
  info "building community images (first build is slow)…"
  docker build --target eddytor-server -t "$SERVER_IMG" "$REPO_ROOT" || { red "server image build failed"; exit 1; }
  docker build --target eddytor-engine -t "$ENGINE_IMG" "$REPO_ROOT" || { red "engine image build failed"; exit 1; }
  green "images built"
fi

# ---- scaffold the operator's install dir ------------------------------------
WORK="$(mktemp -d)"
cp "${SELFHOST}/docker-compose.yml" "${SELFHOST}/config.toml" "${WORK}/"
# Garage creds — reused in .env (provisioning) and the storage registration.
GAK="GK$(openssl rand -hex 16)"
GSK="$(openssl rand -hex 32)"
cat > "${WORK}/.env" <<EOF
EDDYTOR_ENCRYPTION_KEY=$(openssl rand -base64 32)
EDDYTOR_API_KEY_SECRET=$(openssl rand -base64 32)
EDDYTOR_DATABASE_URL=postgres://eddytor:eddytor@postgres:5432/eddytor
POSTGRES_USER=eddytor
POSTGRES_PASSWORD=eddytor
POSTGRES_DB=eddytor
GARAGE_ACCESS_KEY=${GAK}
GARAGE_SECRET_KEY=${GSK}
EDDYTOR_BUCKET=eddytor
EDDYTOR_BIND_ADDR=127.0.0.1
EOF

# Opt-in (WITH_UI=1): also bring up the web UI compose profile and wire the
# server redirect_uri, so the UI login path is exercised end to end.
if [ "${WITH_UI:-0}" = "1" ]; then
  cat >> "${WORK}/.env" <<EOF
COMPOSE_PROFILES=ui
EDDYTOR_UI_VERSION=${EDDYTOR_UI_VERSION:-latest}
EDDYTOR__SERVER__WEB_REDIRECT_URIS=http://localhost:3000/auth/callback
EOF
fi

# garage.toml — the compose stack mounts ./garage.toml read-only.
cat > "${WORK}/garage.toml" <<EOF
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

# Use the locally-built images instead of pulling from ghcr.
cat > "${WORK}/docker-compose.override.yml" <<EOF
services:
  eddytor-server:
    image: ${SERVER_IMG}
    pull_policy: never
  eddytor-engine:
    image: ${ENGINE_IMG}
    pull_policy: never
EOF

info "starting the stack (exactly as an operator would)"
( cd "$WORK" && docker compose -p "$PROJECT" up -d ) || { red "compose up failed"; exit 1; }

# ---- 1. health --------------------------------------------------------------
info "waiting for server health"
i=0; until curl -fsS "${BASE}/healthz" >/dev/null 2>&1; do
  i=$((i+1)); [ "$i" -gt 90 ] && { red "server never became healthy"; ( cd "$WORK" && docker compose -p "$PROJECT" logs --tail=40 eddytor-server ); exit 1; }
  sleep 2
done
green "server /healthz ok"
curl -fsS "http://localhost:50051/healthz" >/dev/null 2>&1 && green "engine /healthz ok" || red "engine /healthz failed"

# ---- 2. garage healthy (bucket auto-provisioned via --default-bucket) -------
# Scratch image: only the /garage binary exists, so probe with `garage status`
# (exits 0 once the node is up) rather than an HTTP client.
if ( cd "$WORK" && docker compose -p "$PROJECT" exec -T garage \
  /garage status >/dev/null 2>&1; ); then
  green "garage healthy (default bucket auto-provisioned)"
else
  red "garage did not report healthy"
fi

# ---- 3. eddytoradm setup creates the first admin ----------------------------
info "creating first admin via eddytoradm (inside the server container)"
SETUP="$( ( cd "$WORK" && docker compose -p "$PROJECT" exec -T eddytor-server \
  eddytoradm setup --email operator@example.com --org "Smoke" ) 2>&1 )"
case "$SETUP" in
  *"created in organisation"*) green "eddytoradm setup created the admin";;
  *) red "eddytoradm setup did not create an admin — got: ${SETUP}";;
esac

# ---- 4. setup is idempotent -------------------------------------------------
AGAIN="$( ( cd "$WORK" && docker compose -p "$PROJECT" exec -T eddytor-server \
  eddytoradm setup --email again@example.com --org "Again" ) 2>&1 )"
case "$AGAIN" in
  *"Already initialised"*) green "second setup is a no-op (idempotent)";;
  *) red "second setup not idempotent — got: ${AGAIN}";;
esac

# ---- 4b. eddytoradm mints a headless API key --------------------------------
API_KEY="$( ( cd "$WORK" && docker compose -p "$PROJECT" exec -T eddytor-server \
  eddytoradm create-api-key --email operator@example.com ) 2>/dev/null \
  | sed -n 's/^  \(edd_[A-Za-z0-9_]*\)$/\1/p' | tail -1 )"
case "$API_KEY" in
  edd_*) green "eddytoradm minted an API key (${API_KEY%%_*}_…)";;
  *) red "eddytoradm create-api-key returned no edd_ key";;
esac

# ---- 5. API key authenticates; missing key is rejected ----------------------
if [ -n "${API_KEY:-}" ]; then
  CODE="$(curl -s -o /dev/null -w '%{http_code}' -H "Authorization: Bearer ${API_KEY}" "${BASE}/api/v1/storages/tables")"
  [ "$CODE" = "200" ] && green "API key authenticates (GET tables → 200)" || red "authed request returned ${CODE}, expected 200"
fi
CODE="$(curl -s -o /dev/null -w '%{http_code}' "${BASE}/api/v1/storages/tables")"
[ "$CODE" = "401" ] && green "unauthenticated request rejected (401)" || red "unauth request returned ${CODE}, expected 401"

# ---- 6. register the bundled Garage (engine ↔ object store works) -----------
if [ -n "${API_KEY:-}" ]; then
  SRESP="$(curl -s -w '\n%{http_code}' -X POST "${BASE}/api/v1/storages/s3" \
    -H "Authorization: Bearer ${API_KEY}" -H 'content-type: application/json' \
    -d "{\"accessKeyId\":\"${GAK}\",\"secretKey\":\"${GSK}\",\"region\":\"us-east-1\",\"bucketName\":\"eddytor\",\"endpoint\":\"http://garage:3900\",\"discoverDelta\":true,\"discoverIceberg\":false}")"
  SCODE="$(printf '%s' "$SRESP" | tail -1)"
  [ "$SCODE" = "200" ] && green "registered bundled Garage storage (engine reached the bucket)" \
    || red "storage register returned ${SCODE}: $(printf '%s' "$SRESP" | head -1)"
fi

# ---- 7. JWKS is served with keys -------------------------------------------
# Necessary for JWT auth: the engine fetches this to validate user tokens. An
# empty/unreachable JWKS silently 401s every token-based request (the engine
# never validates an API key against it — that's HMAC — so only this catches a
# broken JWKS).
JWKS="$(curl -s "${BASE}/.well-known/jwks.json")"
case "$JWKS" in
  *'"keys"'*'"kty"'*) green "JWKS served with at least one key" ;;
  *) red "JWKS missing/empty: $(printf '%s' "$JWKS" | head -c 120)" ;;
esac

# ---- 8. JWT round-trip: magic-link OAuth → token → engine-proxied call ------
# API keys are HMAC-validated locally; only a JWT exercises the engine's REMOTE
# JWKS verifier. A wrong/unreachable engine.jwks_url 401s here while every
# API-key check above stays green — the exact blind spot that hid the JWKS bug.
info "exercising the OAuth magic-link → JWT → engine path"
VERIFIER="$(openssl rand -hex 32)"
CHALLENGE="$(printf '%s' "$VERIFIER" | openssl dgst -sha256 -binary | openssl base64 | tr -d '\n' | tr '+/' '-_' | tr -d '=')"
REDIR="http://localhost:8080/auth/callback"   # implicit {public_url}/auth/callback — always allowed
# 1) GET authorize → pending session; scrape the form-embedded session_id.
SID="$(curl -s -G "${BASE}/v1/oauth/authorize" \
  --data-urlencode "response_type=code" --data-urlencode "client_id=eddytor-web" \
  --data-urlencode "redirect_uri=${REDIR}" --data-urlencode "code_challenge=${CHALLENGE}" \
  --data-urlencode "code_challenge_method=S256" --data-urlencode "state=smoke" \
  | sed -n 's/.*name="session_id" value="\([^"]*\)".*/\1/p')"
# 2) POST the email (operator@example.com exists from step 3) → magic link logged.
curl -s -o /dev/null "${BASE}/v1/oauth/authorize" \
  --data-urlencode "email=operator@example.com" --data-urlencode "session_id=${SID}"
# 3) pull the verify URL from the server logs (noop mail), follow it for the code.
VLINK="$( ( cd "$WORK" && docker compose -p "$PROJECT" logs eddytor-server 2>/dev/null ) \
  | grep -o 'http://localhost:8080/v1/oauth/verify?token=[A-Za-z0-9_-]*' | tail -1)"
ACODE="$(curl -s -o /dev/null -D - "$VLINK" | tr -d '\r' | sed -n 's/^[Ll]ocation:.*[?&]code=\([^&]*\).*/\1/p')"
# 4) exchange the code (+ PKCE verifier) for a JWT access token.
JWT="$(curl -s "${BASE}/v1/oauth/token" \
  --data-urlencode "grant_type=authorization_code" --data-urlencode "code=${ACODE}" \
  --data-urlencode "redirect_uri=${REDIR}" --data-urlencode "code_verifier=${VERIFIER}" \
  --data-urlencode "client_id=eddytor-web" \
  | sed -n 's/.*"access_token":"\([^"]*\)".*/\1/p')"
# 5) call an engine-proxied route with the JWT — forces engine JWKS validation.
if [ -n "$JWT" ]; then
  JCODE="$(curl -s -o /dev/null -w '%{http_code}' -H "Authorization: Bearer ${JWT}" "${BASE}/api/v1/storages/tables")"
  [ "$JCODE" = "200" ] && green "JWT validated by engine via JWKS (GET tables → 200)" \
    || red "engine rejected the JWT (HTTP ${JCODE}) — check engine.jwks_url reachability"
else
  red "could not obtain a JWT (session_id=${SID:+ok} verify_link=${VLINK:+found} code=${ACODE:+got})"
fi

# ---- 9. web UI profile (opt-in: WITH_UI=1) ----------------------------------
# Exercises the UI image + its redirect_uri wiring (the most failure-prone DX
# path). Off by default so the core suite stays fast and image-independent.
if [ "${WITH_UI:-0}" = "1" ]; then
  info "checking the web UI profile"
  i=0; until curl -fsS "http://localhost:3000/" >/dev/null 2>&1; do
    i=$((i+1)); [ "$i" -gt 30 ] && break; sleep 2
  done
  curl -fsS "http://localhost:3000/" >/dev/null 2>&1 \
    && green "web UI reachable on :3000" || red "web UI not reachable on :3000"
  # The server must accept the UI's redirect_uri (else login 400s). Reuse the
  # PKCE challenge from section 8.
  UCODE="$(curl -s -o /dev/null -w '%{http_code}' -G "${BASE}/v1/oauth/authorize" \
    --data-urlencode "response_type=code" --data-urlencode "client_id=eddytor-web" \
    --data-urlencode "redirect_uri=http://localhost:3000/auth/callback" \
    --data-urlencode "code_challenge=${CHALLENGE}" --data-urlencode "code_challenge_method=S256" \
    --data-urlencode "state=ui")"
  [ "$UCODE" = "200" ] && green "authorize accepts the UI redirect_uri (registered)" \
    || red "authorize rejected the UI redirect_uri (HTTP ${UCODE}) — web_redirect_uris not wired"
fi

# ---- verdict ----------------------------------------------------------------
echo
if [ "$FAIL" -eq 0 ]; then green "OPERATOR SMOKE TEST PASSED"; else red "SMOKE TEST FAILED"; fi
exit "$FAIL"
