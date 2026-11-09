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
{{- /*
part-of is the uninstall sweep's handle on cluster-scoped resources, which
survive a namespace delete. Hardcoded rather than derived from the release
name so the selector is stable. Only used in metadata.labels -- never in a
selector, which would make it an immutable-field change on upgrade.
*/}}
app.kubernetes.io/part-of: bmc
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

{{/*
Which secret holds a database password, and under which key.

Defaults to the secret `task secrets:generate` writes. Overridable for a
database that something else created.

Usage: include "bmc.dbSecret" (dict "db" .Values.global.mariaDB "kind" "mariadb")
*/}}
{{- define "bmc.dbSecret" -}}
{{- if .db.existingSecret }}{{ .db.existingSecret }}{{ else }}bmc-secrets{{ end }}
{{- end }}

{{- define "bmc.dbSecretKey" -}}
{{- if .db.passwordKey }}{{ .db.passwordKey }}{{ else }}{{ .kind }}-root-password{{ end }}
{{- end }}

{{/*
Resolve a storage class name, or fail the render saying which key is missing.

values.yaml leaves every class name empty on purpose: there is no storage class
that every cluster has, so the neutral layer cannot supply a sensible one. Each
profile's config file names its own.

This exists so that a missing name fails here, loudly, naming the key. The
alternatives both fail much later and much less clearly: a hardcoded fallback
emits a plausible-looking class that is simply not present on this cluster, and
omitting storageClassName silently selects the cluster default -- which on EKS
is RWO-only EBS, so an RWX claim surfaces as a file-edit pod that will not
schedule alongside its running server.

Usage: include "bmc.storageClass" (dict "ctx" . "class" "database")
*/}}
{{- define "bmc.storageClass" -}}
{{- $classes := .ctx.Values.global.storage.classes -}}
{{- $name := "" -}}
{{- if hasKey $classes .class -}}
{{- $name = (index $classes .class).name -}}
{{- end -}}
{{- required (printf "global.storage.classes.%s.name is empty. Name the storage class this cluster provides for '%s' in your config file (config/<profile>.yaml); 'kubectl get storageclass' lists what is available." .class .class) $name -}}
{{- end -}}

{{/*
externalTrafficPolicy for an edge Service, validated.

Emits nothing for ClusterIP: the API server rejects the field on that type, so
a config that sets it would otherwise fail at apply time with a message about
the field rather than about the type it conflicts with.

The game edge is the only caller. The file edge deliberately has no such knob:
it is ClusterIP on every cloud profile, where the field is rejected outright,
and on bare metal nothing reads the SFTP client's address -- so the only effect
a policy there could have is to stop some nodes answering.

Usage: include "bmc.edgePolicy" (dict "type" .Values.global.edge.game.type
                                      "policy" .Values.global.edge.game.externalTrafficPolicy
                                      "key" "edge.game.externalTrafficPolicy")
*/}}
{{- define "bmc.edgePolicy" -}}
{{- $p := .policy | default "Cluster" -}}
{{- if not (has $p (list "Cluster" "Local")) -}}
{{- fail (printf "%s is %q; it must be \"Cluster\" or \"Local\"." .key $p) -}}
{{- end -}}
{{- if ne .type "ClusterIP" -}}
# Local preserves the client's real address; Cluster may SNAT it away. See
# edge.game.externalTrafficPolicy in values.yaml.
externalTrafficPolicy: {{ $p }}
{{- end -}}
{{- end -}}
