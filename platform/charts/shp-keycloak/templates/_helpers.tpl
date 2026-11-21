{{- define "shp-keycloak.labels" -}}
app.kubernetes.io/name: keycloak
app.kubernetes.io/part-of: shp-iam
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}
{{- define "shp-keycloak.selector" -}}
app.kubernetes.io/name: keycloak
{{- end }}
