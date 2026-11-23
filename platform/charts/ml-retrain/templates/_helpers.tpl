{{- define "ml-retrain.image" -}}
{{- if .Values.image.digest -}}
{{ required "image.repository is required" .Values.image.repository }}@{{ .Values.image.digest }}
{{- else if .Values.image.tag -}}
{{ required "image.repository is required" .Values.image.repository }}:{{ .Values.image.tag }}
{{- end -}}
{{- end -}}

{{- define "ml-retrain.labels" -}}
app.kubernetes.io/name: ml-retrain
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/part-of: smart-hospital-platform
{{- end -}}
