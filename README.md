# Eddytor — self-host files

Alternate download mirror of the Eddytor self-hosting artifacts. The
primary, recommended source is **https://get.eddytor.com**. These files
are generated from the upstream release — do not edit here.

- `deploy/selfhost/` — Docker Compose single-host install
- `deploy/helm/eddytor/` — Kubernetes Helm chart

Full operator guide: [`deploy/selfhost/HOSTING.md`](deploy/selfhost/HOSTING.md).

## Filling in the required secrets

**Docker Compose** generates every secret for you — `install.sh` writes
them into `.env` on first run, nothing to fill by hand. Back up `.env`:
losing `EDDYTOR_ENCRYPTION_KEY` makes stored secrets unrecoverable.

**Helm** needs three secrets, generated in one shot:

```bash
kubectl -n eddytor create secret generic eddytor-secrets \
  --from-literal=EDDYTOR_DATABASE_URL="postgres://user:pass@host:5432/eddytor" \
  --from-literal=EDDYTOR_ENCRYPTION_KEY="$(openssl rand -base64 32)" \
  --from-literal=EDDYTOR_API_KEY_SECRET="$(openssl rand -base64 32)"
```

Pass `--set secrets.existingSecret=eddytor-secrets` to `helm install`.

For quick testing — no external datastores — bundle a Postgres and an
object store that come up alongside the chart (eval only, no HA/backups):

- `--set postgres.bundled=true` runs an in-cluster Postgres. Point your
  `EDDYTOR_DATABASE_URL` at it: `postgres://eddytor:eddytor@eddytor-postgres:5432/eddytor`.
- `--set garage.bundled=true` runs an in-cluster S3 (Garage). It also
  needs its four creds — `accessKey` must be `GK` + 32 hex:

```bash
  --set-string garage.accessKey="GK$(openssl rand -hex 16)" \
  --set-string garage.secretKey="$(openssl rand -hex 32)" \
  --set-string garage.rpcSecret="$(openssl rand -hex 32)" \
  --set-string garage.adminToken="$(openssl rand -base64 32)"
```

Current version: **v2.4.3** (see the matching `v2.4.3` git tag).
