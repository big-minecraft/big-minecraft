{{/* vim: set filetype=mustache: */}}
# Expand the name of the chart.
{{- define "common.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

# Common labels. part-of is the uninstall sweep's handle on cluster-scoped
# resources, hardcoded so the selector stays stable.
{{- define "common.labels" -}}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ include "common.name" . }}-{{ .Chart.Version }}
app.kubernetes.io/part-of: bmc
{{- end }}
# Flatten a "files/..." path into a valid ConfigMap key. panel.yaml maps each
# key back via items[].path.
{{- define "bmc.runtimeKey" -}}
{{- . | trimPrefix "files/" | replace "/" "_" -}}
{{- end -}}

# The path a flattened key mounts back to, relative to the volume root.
{{- define "bmc.runtimePath" -}}
{{- . | trimPrefix "files/" -}}
{{- end -}}

# Which secret holds a database password, and under which key.
#   include "bmc.dbSecret" (dict "db" .Values.global.mariaDB "kind" "mariadb")
{{- define "bmc.dbSecret" -}}
{{- if .db.existingSecret }}{{ .db.existingSecret }}{{ else }}bmc-secrets{{ end }}
{{- end }}

{{- define "bmc.dbSecretKey" -}}
{{- if .db.passwordKey }}{{ .db.passwordKey }}{{ else }}{{ .kind }}-root-password{{ end }}
{{- end }}

# Resolve a storage class name, or fail the render naming the missing key.
# Names are empty in values.yaml by design; failing later is far less clear.
#   include "bmc.storageClass" (dict "ctx" . "class" "database")
{{- define "bmc.storageClass" -}}
{{- $classes := .ctx.Values.global.storage.classes -}}
{{- $name := "" -}}
{{- if hasKey $classes .class -}}
{{- $name = (index $classes .class).name -}}
{{- end -}}
{{- required (printf "global.storage.classes.%s.name is empty. Name the storage class this cluster provides for '%s' in your config file (config/<profile>.yaml); 'kubectl get storageclass' lists what is available." .class .class) $name -}}
{{- end -}}

# externalTrafficPolicy for an edge Service, validated. Emits nothing for
# ClusterIP, which the API server rejects the field on.
#   include "bmc.edgePolicy" (dict "type" ... "policy" ... "key" ...)
{{- define "bmc.edgePolicy" -}}
{{- $p := .policy | default "Cluster" -}}
{{- if not (has $p (list "Cluster" "Local")) -}}
{{- fail (printf "%s is %q; it must be \"Cluster\" or \"Local\"." .key $p) -}}
{{- end -}}
{{- if ne .type "ClusterIP" -}}
# See edge.game.externalTrafficPolicy in values.yaml.
externalTrafficPolicy: {{ $p }}
{{- end -}}
{{- end -}}
