{{- define "mlflow.image" -}}
{{- if .Values.image.digest -}}
{{ required "image.repository is required" .Values.image.repository }}@{{ .Values.image.digest }}
{{- else if .Values.image.tag -}}
{{ required "image.repository is required" .Values.image.repository }}:{{ .Values.image.tag }}
{{- else -}}
{{- fail "image.digest (or image.tag for local tests) is required" -}}
{{- end -}}
{{- end -}}

{{- define "mlflow.labels" -}}
app.kubernetes.io/name: mlflow
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/part-of: smart-hospital-platform
{{- end -}}

{{- define "mlflow.selector" -}}
app.kubernetes.io/name: mlflow
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{- define "mlflow.artifactsDestination" -}}
{{- if .Values.artifacts.destination -}}
{{ .Values.artifacts.destination }}
{{- else -}}
wasbs://{{ .Values.artifacts.container }}@{{ required "artifacts.storageAccount is required" .Values.artifacts.storageAccount }}.blob.core.windows.net/{{ .Values.artifacts.prefix }}
{{- end -}}
{{- end -}}

{{- define "mlflow.containerSecurity" -}}
allowPrivilegeEscalation: false
readOnlyRootFilesystem: true
capabilities: { drop: [ALL] }
{{- end -}}

{{/* PostgreSQL connection variables read by libpq and by the token script. No password here. */}}
{{- define "mlflow.pgenv" -}}
- { name: PGHOST, value: {{ required "database.host is required" .Values.database.host | quote }} }
- { name: PGPORT, value: {{ .Values.database.port | quote }} }
- { name: PGDATABASE, value: {{ .Values.database.name | quote }} }
- { name: PGUSER, value: {{ required "database.user is required" .Values.database.user | quote }} }
{{- if .Values.database.entraAuth.enabled }}
- { name: PGPASSFILE, value: /run/pg/pgpass }
- { name: PG_TOKEN_SCOPE, value: {{ .Values.database.entraAuth.scope | quote }} }
- { name: PG_REFRESH_SECONDS, value: {{ .Values.database.entraAuth.refreshSeconds | quote }} }
{{- end }}
{{- end -}}
