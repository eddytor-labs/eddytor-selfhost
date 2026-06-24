{{/* Chart name, overridable. */}}
{{- define "eddytor.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/* Fully-qualified release-scoped name. */}}
{{- define "eddytor.fullname" -}}
{{- if .Values.fullnameOverride -}}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- $name := default .Chart.Name .Values.nameOverride -}}
{{- if contains $name .Release.Name -}}
{{- .Release.Name | trunc 63 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{/* FIXED component names — NOT release-prefixed. The server proxy hardcodes
     the engine Service names `eddytor-engine` / `eddytor-engine-headless` for
     its HTTP, MCP and Flight paths (crates/server/src/proxy.rs), so these must
     match verbatim. One Eddytor release per namespace (as in production). */}}
{{- define "eddytor.server.name" -}}eddytor-server{{- end -}}
{{- define "eddytor.engine.name" -}}eddytor-engine{{- end -}}
{{- define "eddytor.engine.headlessName" -}}eddytor-engine-headless{{- end -}}
{{- define "eddytor.postgres.name" -}}eddytor-postgres{{- end -}}
{{- define "eddytor.garage.name" -}}eddytor-garage{{- end -}}
{{- define "eddytor.ui.name" -}}eddytor-ui{{- end -}}

{{/* Name of the Secret holding EDDYTOR_* secrets. */}}
{{- define "eddytor.secretName" -}}
{{- if .Values.secrets.existingSecret -}}
{{- .Values.secrets.existingSecret -}}
{{- else -}}
eddytor-secrets
{{- end -}}
{{- end -}}

{{- define "eddytor.labels" -}}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
app.kubernetes.io/name: {{ include "eddytor.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
{{- end -}}

{{/* Non-secret EDDYTOR__* config env, shared by server and engine. */}}
{{- define "eddytor.configEnv" -}}
- name: AWS_EC2_METADATA_DISABLED
  value: "true"
- name: EDDYTOR__SERVER__PUBLIC_URL
  value: {{ .Values.config.publicUrl | quote }}
- name: EDDYTOR__SERVER__COOKIE_DOMAIN
  value: {{ .Values.config.cookieDomain | quote }}
{{- with .Values.config.oauthRedirectBase }}
- name: EDDYTOR__SERVER__OAUTH_REDIRECT_BASE
  value: {{ . | quote }}
{{- end }}
- name: EDDYTOR__SERVER__CORS__ALLOWED_ORIGINS
  value: {{ .Values.config.cors.allowedOrigins | quote }}
- name: EDDYTOR__SERVER__CORS__ALLOW_CREDENTIALS
  value: {{ .Values.config.cors.allowCredentials | quote }}
- name: EDDYTOR__SERVER__CORS__MAX_AGE_SECS
  value: {{ .Values.config.cors.maxAgeSecs | quote }}
- name: EDDYTOR__DATABASE__MAX_CONNECTIONS
  value: {{ .Values.config.database.maxConnections | quote }}
{{- with .Values.config.telemetry.logLevel }}
- name: EDDYTOR__TELEMETRY__LOG_LEVEL
  value: {{ . | quote }}
{{- end }}
{{- with .Values.config.telemetry.otlpEndpoint }}
- name: EDDYTOR__TELEMETRY__OTLP_ENDPOINT
  value: {{ . | quote }}
{{- end }}
{{- if .Values.ui.enabled }}
# Register the web UI origin as an OAuth web redirect_uri so SPA login resolves
# (mirrors what the compose installer writes to .env). Server-only; the engine
# parses the same Config and ignores it.
- name: EDDYTOR__SERVER__WEB_REDIRECT_URIS
  value: {{ printf "%s/auth/callback" (.Values.ui.origin | trimSuffix "/") | quote }}
{{- end }}
# Engine discovery — server resolves {service_name}.{namespace}.svc.cluster.local.
- name: EDDYTOR__SESSION__SERVICE_NAME
  value: {{ include "eddytor.engine.headlessName" . | quote }}
- name: EDDYTOR__SESSION__SERVICE_NAMESPACE
  value: {{ .Release.Namespace | quote }}
# Engine validates user JWTs against the server's JWKS. public_url is the
# browser-facing URL (often localhost / an external host) and is NOT reachable
# from the engine pod, so point the engine at the in-cluster server Service.
- name: EDDYTOR__ENGINE__JWKS_URL
  value: {{ printf "http://%s:8080/.well-known/jwks.json" (include "eddytor.server.name" .) | quote }}
{{- end -}}

{{/* Secret-backed env. Required keys always; optional keys only when present
     in chart-managed values (existingSecret => emit all, optional). */}}
{{- define "eddytor.secretEnv" -}}
{{- $secret := include "eddytor.secretName" . -}}
{{- $optional := list "EDDYTOR_SMTP_HOST" "EDDYTOR_SMTP_PORT" "EDDYTOR_SMTP_FROM" "EDDYTOR_SMTP_USER" "EDDYTOR_SMTP_PASS" -}}
{{- $required := list "EDDYTOR_DATABASE_URL" "EDDYTOR_ENCRYPTION_KEY" "EDDYTOR_API_KEY_SECRET" -}}
{{- range $required }}
- name: {{ . }}
  valueFrom:
    secretKeyRef:
      name: {{ $secret }}
      key: {{ . }}
{{- end }}
{{- range $k := $optional }}
{{- if or $.Values.secrets.existingSecret (index $.Values.secrets.values $k) }}
- name: {{ $k }}
  valueFrom:
    secretKeyRef:
      name: {{ $secret }}
      key: {{ $k }}
      optional: true
{{- end }}
{{- end }}
{{- end -}}

{{/* Hardened pod-level security context (non-root uid 10001). */}}
{{- define "eddytor.securityContext" -}}
runAsNonRoot: true
runAsUser: 10001
runAsGroup: 10001
readOnlyRootFilesystem: true
allowPrivilegeEscalation: false
capabilities:
  drop: ["ALL"]
{{- end -}}

{{/* wait-for-db initContainer, rendered when waitForDb.enabled. Probes the host
     parsed from EDDYTOR_DATABASE_URL, so it works for the bundled Service
     (eddytor-postgres) AND any external DB. */}}
{{- define "eddytor.waitForDbInit" -}}
{{- if .Values.waitForDb.enabled }}
- name: wait-for-db
  image: {{ .Values.waitForDb.image | quote }}
  env:
    - name: EDDYTOR_DATABASE_URL
      valueFrom:
        secretKeyRef:
          name: {{ include "eddytor.secretName" . }}
          key: EDDYTOR_DATABASE_URL
  command:
    - sh
    - -c
    - |
      # Parse host:port from the connection string (handles user:pass@ and
      # ?sslmode=… query); default to 5432 when no explicit port.
      rest="${EDDYTOR_DATABASE_URL#*://}"
      rest="${rest##*@}"
      hostport="${rest%%/*}"
      hostport="${hostport%%\?*}"
      host="${hostport%%:*}"
      port="${hostport##*:}"
      [ "$port" = "$host" ] && port=5432
      echo "waiting for postgres at ${host}:${port}..."
      until nc -z "$host" "$port"; do
        echo "waiting for postgres..."; sleep 2
      done
  securityContext:
    {{- include "eddytor.securityContext" . | nindent 4 }}
{{- end }}
{{- end -}}
