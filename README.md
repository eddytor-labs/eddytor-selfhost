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
Only when you bundle the demo Garage (`--set garage.bundled=true`, eval
only) also supply its four creds — `accessKey` must be `GK` + 32 hex:

```bash
  --set-string garage.accessKey="GK$(openssl rand -hex 16)" \
  --set-string garage.secretKey="$(openssl rand -hex 32)" \
  --set-string garage.rpcSecret="$(openssl rand -hex 32)" \
  --set-string garage.adminToken="$(openssl rand -base64 32)"
```

Current version: **v2.4.2** (see the matching `v2.4.2` git tag).
