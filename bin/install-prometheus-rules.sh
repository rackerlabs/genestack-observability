#!/bin/bash

set -euo pipefail

GENESTACK_OBSERVABILITY_DIR="${GENESTACK_OBSERVABILITY_DIR:-/opt/genestack-observability}"
NAMESPACE="${NAMESPACE:-monitoring}"

RULES_CHART="${GENESTACK_OBSERVABILITY_DIR}/alerts"

helm upgrade --install prometheus-rules \
  "${RULES_CHART}" \
  --namespace "${NAMESPACE}" \
  --create-namespace \
  --wait
