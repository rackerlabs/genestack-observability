#!/bin/bash

set -euo pipefail

SERVICE_NAME_DEFAULT="openstack-exporter"
CHART_DIR_NAME="openstack-api-exporter-chart"
SERVICE_NAMESPACE="monitoring"

GENESTACK_BASE_DIR="${GENESTACK_BASE_DIR:-/opt/genestack}"
GENESTACK_OVERRIDES_DIR="${GENESTACK_OVERRIDES_DIR:-/etc/genestack}"

KUSTOMIZE_POST_RENDERER_ARGS="${KUSTOMIZE_POST_RENDERER_ARGS:-observability/${CHART_DIR_NAME}/overlay}"

CHART_DIR="${GENESTACK_BASE_DIR}/base-helm-configs/observability/${CHART_DIR_NAME}"
SERVICE_CUSTOM_OVERRIDES="${GENESTACK_OVERRIDES_DIR}/helm-configs/observability/${CHART_DIR_NAME}"
GLOBAL_OVERRIDES_DIR="${GENESTACK_OVERRIDES_DIR}/helm-configs/global_overrides"

source "$(dirname "$0")/monitoring-common.sh"

# Check if chart directory exists.
if [[ ! -d "${CHART_DIR}" ]]; then
    echo "ERROR: Chart directory does not exist:"
    echo "  ${CHART_DIR}"
    exit 1
fi

# Find an unused Kubernetes Service port.
find_unused_port() {
    local port=49152

    while :; do
        if ! kubectl get svc --all-namespaces \
            -o jsonpath='{range .items[*]}{range .spec.ports[*]}{.port}{"\n"}{end}{end}' \
            | grep -qx "${port}"; then
            echo "${port}"
            return 0
        fi

        ((port++))

        if [[ "${port}" -gt 65535 ]]; then
            echo "ERROR: No unused port found in range 49152-65535" >&2
            exit 1
        fi
    done
}

# Reuse the currently configured service port when the Helm release already
# exists. This keeps repeated bootstrap/install runs idempotent instead of
# selecting a new port on every upgrade.
get_existing_service_port() {
    local port=""

    if ! helm status "${SERVICE_NAME_DEFAULT}" \
        --namespace "${SERVICE_NAMESPACE}" \
        >/dev/null 2>&1; then
        return 1
    fi

    port="$(
        helm get values "${SERVICE_NAME_DEFAULT}" \
            --namespace "${SERVICE_NAMESPACE}" \
            --output yaml 2>/dev/null \
        | yq eval -r '.service.port // ""' - 2>/dev/null \
        || true
    )"

    if [[ "${port}" =~ ^[0-9]+$ ]]; then
        echo "${port}"
        return 0
    fi

    return 1
}

monitoring_ensure_keystone_auth_openstack_exporter_secret() {
    local target_namespace="${SERVICE_NAMESPACE}"
    local secret_name="keystone-auth-openstack-exporter"
    local keystone_namespace="openstack"
    local keystone_secret="keystone-admin"
    local keystone_password=""

    if kubectl -n "${target_namespace}" get secret "${secret_name}" \
        >/dev/null 2>&1; then
        echo "Keeping existing secret ${target_namespace}/${secret_name}"
        return 0
    fi

    if ! kubectl -n "${keystone_namespace}" get secret "${keystone_secret}" \
        >/dev/null 2>&1; then
        echo "ERROR: Required Keystone secret does not exist:" >&2
        echo "  ${keystone_namespace}/${keystone_secret}" >&2
        exit 1
    fi

    keystone_password="$(
        kubectl -n "${keystone_namespace}" \
            get secret "${keystone_secret}" \
            -o jsonpath='{.data.password}' \
        | base64 -d
    )"

    if [[ -z "${keystone_password}" ]]; then
        echo "ERROR: Unable to read password from ${keystone_namespace}/${keystone_secret}" >&2
        exit 1
    fi

    echo "Creating ${target_namespace}/${secret_name} from the live Keystone admin secret..."

    kubectl create secret generic "${secret_name}" \
        --namespace "${target_namespace}" \
        --type Opaque \
        --from-literal=AUTH_URL="http://keystone-api.openstack.svc.cluster.local:5000/v3" \
        --from-literal=USERNAME="admin" \
        --from-literal=PASSWORD="${keystone_password}" \
        --from-literal=USER_DOMAIN_NAME="Default" \
        --from-literal=PROJECT_NAME="admin" \
        --from-literal=PROJECT_DOMAIN_NAME="Default" \
        --dry-run=client \
        -o yaml \
    | kubectl apply -f -
}

monitoring_ensure_namespace "${SERVICE_NAMESPACE}"
monitoring_label_namespace_for_talos "${SERVICE_NAMESPACE}"

monitoring_ensure_keystone_auth_openstack_exporter_secret

if DYNAMIC_PORT="$(get_existing_service_port)"; then
    echo "Reusing existing service port: ${DYNAMIC_PORT}"
else
    DYNAMIC_PORT="$(find_unused_port)"
    echo "Using new service port: ${DYNAMIC_PORT}"
fi

DYNAMIC_TAG="sha-7951e2c"
echo "Using image tag: ${DYNAMIC_TAG}"

overrides_args=()

for base_file in "${CHART_DIR}/values.yaml" "${CHART_DIR}/probe_target.yaml"; do
    if [[ -f "${base_file}" ]]; then
        echo " - ${base_file}"
        overrides_args+=("-f" "${base_file}")
    fi
done

if [[ -d "${GLOBAL_OVERRIDES_DIR}" ]]; then
    echo "Including global overrides from directory: ${GLOBAL_OVERRIDES_DIR}"

    shopt -s nullglob
    for file in "${GLOBAL_OVERRIDES_DIR}"/*.yaml; do
        echo " - ${file}"
        overrides_args+=("-f" "${file}")
    done
    shopt -u nullglob
fi

if [[ -d "${SERVICE_CUSTOM_OVERRIDES}" ]]; then
    echo "Including overrides from service config directory: ${SERVICE_CUSTOM_OVERRIDES}"

    shopt -s nullglob
    for file in "${SERVICE_CUSTOM_OVERRIDES}"/*.yaml; do
        echo " - ${file}"
        overrides_args+=("-f" "${file}")
    done
    shopt -u nullglob
fi

helm_command=(
    helm upgrade --install "${SERVICE_NAME_DEFAULT}" "${CHART_DIR}"
    --namespace "${SERVICE_NAMESPACE}"
    --create-namespace
    --timeout 15m
    "${overrides_args[@]}"
    --set "image.tag=${DYNAMIC_TAG}"
    --set "service.port=${DYNAMIC_PORT}"
    --post-renderer "${GENESTACK_OVERRIDES_DIR}/kustomize/kustomize.sh"
    --post-renderer-args "${KUSTOMIZE_POST_RENDERER_ARGS}"
    "$@"
)

echo
echo "Executing Helm command (arguments are quoted safely):"
printf '%q ' "${helm_command[@]}"
echo
echo

"${helm_command[@]}"

echo
echo "Verifying deployment..."
kubectl get pods -n "${SERVICE_NAMESPACE}"
kubectl get svc -n "${SERVICE_NAMESPACE}"
kubectl get servicemonitor -n "${SERVICE_NAMESPACE}"

echo
echo "OpenStack exporter reconciliation complete."
echo "  Release: ${SERVICE_NAME_DEFAULT}"
echo "  Namespace: ${SERVICE_NAMESPACE}"
echo "  Service port: ${DYNAMIC_PORT}"
