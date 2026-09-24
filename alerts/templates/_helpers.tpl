{{/*
Generate a deterministic, collision-safe PrometheusRule resource name.

Uniqueness is based on:
  - rule type: alert / record
  - source file path
  - additionalPrometheusRulesMap key

The hash means identical map keys in different files cannot collide.
*/}}
{{- define "genestack-prometheus-rules.resourceName" -}}
{{- $type := index . "type" -}}
{{- $path := index . "path" -}}
{{- $ruleName := index . "ruleName" -}}

{{- $normalized := $ruleName | lower | replace "_" "-" -}}
{{- $normalized = regexReplaceAll "[^a-z0-9.-]+" $normalized "-" -}}
{{- $normalized = trimAll "-" $normalized -}}

{{- $hashInput := printf "%s:%s:%s" $type $path $ruleName -}}
{{- $hash := sha256sum $hashInput | trunc 10 -}}

{{- $base := $normalized | trunc 45 | trimSuffix "-" -}}

{{- printf "%s-%s-%s" $type $base $hash | trunc 63 | trimSuffix "-" -}}
{{- end -}}
