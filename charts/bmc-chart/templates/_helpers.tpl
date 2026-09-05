{{/* vim: set filetype=mustache: */}}
{{/*
Expand the name of the chart.
*/}}
{{- define "common.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create common labels
*/}}
{{- define "common.labels" -}}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ include "common.name" . }}-{{ .Chart.Version }}
{{- end }}
{{/*
Flatten a "files/..." path into a valid ConfigMap key.
ConfigMap keys must match [-._a-zA-Z0-9]+, so "/" becomes "_". The "files/"
prefix is dropped so the key mirrors the path as mounted. No filename in
files/ contains "_", so this is unambiguous -- but nothing has to decode it
anyway: panel.yaml states the real path explicitly via items[].path.
*/}}
{{- define "bmc.runtimeKey" -}}
{{- . | trimPrefix "files/" | replace "/" "_" -}}
{{- end -}}

{{/*
The path a flattened key must be mounted back to, relative to the volume root.
*/}}
{{- define "bmc.runtimePath" -}}
{{- . | trimPrefix "files/" -}}
{{- end -}}
