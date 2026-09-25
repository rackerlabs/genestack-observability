{{/*
Alerting rules
*/}}
{{- range $path, $_ := .Files.Glob "prometheus-alerts/**/*.yaml" }}
{{- $document := $.Files.Get $path | fromYaml }}

{{- if $document.additionalPrometheusRulesMap }}
{{- range $ruleName, $ruleSpec := $document.additionalPrometheusRulesMap }}
---
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: {{ include "genestack-prometheus-rules.resourceName" (dict
    "type" "alert"
    "path" $path
    "ruleName" $ruleName
  ) }}
  namespace: {{ $.Release.Namespace }}
  labels:
    release: {{ $.Values.prometheus.releaseLabel | quote }}
    app.kubernetes.io/name: genestack-prometheus-rules
    app.kubernetes.io/instance: {{ $.Release.Name | quote }}
    app.kubernetes.io/managed-by: {{ $.Release.Service | quote }}
    genestack.io/rule-type: alerting
  annotations:
    genestack.io/rule-source: {{ $path | quote }}
spec:
{{ $ruleSpec | toYaml | nindent 2 }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Recording rules
*/}}
{{- range $path, $_ := .Files.Glob "recording/**/*.yaml" }}
{{- $document := $.Files.Get $path | fromYaml }}

{{- if $document.additionalPrometheusRulesMap }}
{{- range $ruleName, $ruleSpec := $document.additionalPrometheusRulesMap }}
---
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: {{ include "genestack-prometheus-rules.resourceName" (dict
    "type" "record"
    "path" $path
    "ruleName" $ruleName
  ) }}
  namespace: {{ $.Release.Namespace }}
  labels:
    release: {{ $.Values.prometheus.releaseLabel | quote }}
    app.kubernetes.io/name: genestack-prometheus-rules
    app.kubernetes.io/instance: {{ $.Release.Name | quote }}
    app.kubernetes.io/managed-by: {{ $.Release.Service | quote }}
    genestack.io/rule-type: recording
  annotations:
    genestack.io/rule-source: {{ $path | quote }}
spec:
{{ $ruleSpec | toYaml | nindent 2 }}
{{- end }}
{{- end }}
{{- end }}
