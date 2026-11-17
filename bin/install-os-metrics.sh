#!/bin/bash
set -euo pipefail

SERVICE_NAME_DEFAULT="os-metrics"
CHART_DIR_NAME="openstack-metrics-exporter"
SERVICE_NAMESPACE="monitoring"
OCI_CHART_PATH="oci://ghcr.io/openstack-exporter/charts/prometheus-openstack-exporter"
SOURCE_REPO="openstack-exporter/openstack-exporter"
# Use a full Git commit SHA here for reproducible deployments once selected.
OS_METRICS_CHART_SOURCE_REF="${OS_METRICS_CHART_SOURCE_REF:-main}"

GENESTACK_BASE_DIR="${GENESTACK_BASE_DIR:-/opt/genestack}"
GENESTACK_OVERRIDES_DIR="${GENESTACK_OVERRIDES_DIR:-/etc/genestack}"
KUSTOMIZE_POST_RENDERER_ARGS="${KUSTOMIZE_POST_RENDERER_ARGS:-observability/${CHART_DIR_NAME}/overlay}"

SERVICE_BASE_OVERRIDES="${GENESTACK_BASE_DIR}/base-helm-configs/observability/${CHART_DIR_NAME}"
SERVICE_CUSTOM_OVERRIDES="${GENESTACK_OVERRIDES_DIR}/helm-configs/observability/${CHART_DIR_NAME}"
GLOBAL_OVERRIDES_DIR="${GENESTACK_OVERRIDES_DIR}/helm-configs/global_overrides"
VERSION_FILE="${GENESTACK_OVERRIDES_DIR}/helm-chart-versions.yaml"
FALLBACK_VERSION_FILE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/helm-chart-versions.yaml"

source "$(dirname "$0")/monitoring-common.sh"

get_chart_version() {
    local file="$1"
    [[ -f "${file}" ]] || return 0
    yq -r '.charts."openstack-metrics-exporter" // ""' "${file}"
}

SERVICE_VERSION=""
for version_file in "${VERSION_FILE}" "${FALLBACK_VERSION_FILE}"; do
    SERVICE_VERSION="$(get_chart_version "${version_file}")"
    if [[ -n "${SERVICE_VERSION}" ]]; then
        echo "Using openstack-metrics-exporter version ${SERVICE_VERSION} from ${version_file}"
        break
    fi
done
if [[ -z "${SERVICE_VERSION}" ]]; then
    echo "ERROR: Missing openstack-metrics-exporter version in chart version files" >&2
    exit 1
fi

add_override_directory() {
    local directory="$1" file filename
    [[ -d "${directory}" ]] || return 0
    for file in "${directory}"/*.yaml; do
        [[ -f "${file}" ]] || continue
        filename="$(basename "${file}")"
        [[ "${filename}" == "Chart.yaml" ]] && continue
        echo " - ${file}"
        overrides_args+=("-f" "${file}")
    done
}

# Resolve the chart before creating or modifying anything in Kubernetes.
CHART_WORKDIR=""
cleanup() {
    if [[ -n "${CHART_WORKDIR}" && -d "${CHART_WORKDIR}" ]]; then
        rm -rf -- "${CHART_WORKDIR}"
    fi
}
trap cleanup EXIT

HELM_CHART_PATH="${OCI_CHART_PATH}"
helm_chart_version_args=(--version "${SERVICE_VERSION}")
echo "Checking OCI chart ${OCI_CHART_PATH}:${SERVICE_VERSION} ..."
if helm show chart "${OCI_CHART_PATH}" --version "${SERVICE_VERSION}" >/dev/null 2>&1; then
    echo "Using published OCI chart."
else
    echo "OCI chart unavailable; using upstream source-chart fallback."
    if [[ "${OS_METRICS_CHART_SOURCE_REF}" == "main" ]]; then
        echo "WARNING: Source ref 'main' moves over time. Set OS_METRICS_CHART_SOURCE_REF to a tested commit SHA for reproducible installs." >&2
    fi
    CHART_WORKDIR="$(mktemp -d)"
    archive="${CHART_WORKDIR}/source.tar.gz"
    source_url="https://codeload.github.com/${SOURCE_REPO}/tar.gz/${OS_METRICS_CHART_SOURCE_REF}"
    if ! curl -fsSL --retry 3 --connect-timeout 15 "${source_url}" -o "${archive}"; then
        echo "ERROR: Could not download upstream chart source from ${source_url}" >&2
        exit 1
    fi
    mkdir -p "${CHART_WORKDIR}/source"
    tar -xzf "${archive}" -C "${CHART_WORKDIR}/source" --strip-components=1
    HELM_CHART_PATH="${CHART_WORKDIR}/source/helmcharts"
    if [[ ! -f "${HELM_CHART_PATH}/Chart.yaml" ]]; then
        echo "ERROR: helmcharts/Chart.yaml not found in upstream source ref ${OS_METRICS_CHART_SOURCE_REF}" >&2
        exit 1
    fi

    source_chart_version="$(yq -r '.version // ""' "${HELM_CHART_PATH}/Chart.yaml")"
    source_app_version="$(yq -r '.appVersion // ""' "${HELM_CHART_PATH}/Chart.yaml")"
    source_image_tag="$(yq -r '.image.tag // ""' "${HELM_CHART_PATH}/values.yaml")"
    # The source Chart.yaml version (e.g. 0.4.4) differs from the exporter
    # release (e.g. 1.6.0). Accept a pin to either, but never silently deploy
    # an unrelated source chart or image.
    if [[ "${SERVICE_VERSION}" != "${source_chart_version}" && \
          "${SERVICE_VERSION#v}" != "${source_app_version#v}" ]]; then
        echo "ERROR: Configured version ${SERVICE_VERSION} does not match source chart ${source_chart_version} or app ${source_app_version}" >&2
        exit 1
    fi
    if [[ -z "${source_image_tag}" || "${source_app_version#v}" != "${source_image_tag#v}" ]]; then
        echo "ERROR: Source image tag '${source_image_tag}' does not match appVersion '${source_app_version}'" >&2
        exit 1
    fi
    if ! helm lint "${HELM_CHART_PATH}" >/dev/null; then
        echo "ERROR: Downloaded upstream chart did not pass helm lint" >&2
        exit 1
    fi
    echo "Using source chart ${source_chart_version} (image ${source_image_tag}) from ${SOURCE_REPO}@${OS_METRICS_CHART_SOURCE_REF}"
    # --version is meaningful only when fetching from a chart repository.
    helm_chart_version_args=()
fi

# Complete local preflight before writing a Secret.
POST_RENDERER="${GENESTACK_OVERRIDES_DIR}/kustomize/kustomize.sh"
KUSTOMIZE_OVERLAY_PATH="${GENESTACK_OVERRIDES_DIR}/kustomize/${KUSTOMIZE_POST_RENDERER_ARGS}"
if [[ ! -f "${POST_RENDERER}" ]]; then
    echo "ERROR: Missing Kustomize post-renderer: ${POST_RENDERER}" >&2
    exit 1
fi
if [[ ! -f "${KUSTOMIZE_OVERLAY_PATH}/kustomization.yaml" ]]; then
    echo "ERROR: Missing Kustomize overlay: ${KUSTOMIZE_OVERLAY_PATH}/kustomization.yaml" >&2
    exit 1
fi

overrides_args=()
for directory in "${SERVICE_BASE_OVERRIDES}" "${GLOBAL_OVERRIDES_DIR}" "${SERVICE_CUSTOM_OVERRIDES}"; do
    if [[ -d "${directory}" ]]; then
        echo "Including Helm overrides from ${directory}:"
        add_override_directory "${directory}"
    fi
done

# OS_METRICS_REGION_NAME takes priority, followed by the standard OpenStack
# OS_REGION_NAME. Otherwise use the region advertised by Keystone endpoints.
resolve_os_metrics_region() {
    local endpoint_regions region
    local -a detected_regions=()

    if [[ -n "${OS_METRICS_REGION_NAME:-}" ]]; then
        REGION_NAME="${OS_METRICS_REGION_NAME}"
        REGION_SOURCE="OS_METRICS_REGION_NAME"
    elif [[ -n "${OS_REGION_NAME:-}" ]]; then
        REGION_NAME="${OS_REGION_NAME}"
        REGION_SOURCE="OS_REGION_NAME"
    elif command -v openstack >/dev/null 2>&1 && \
         endpoint_regions="$(openstack endpoint list --interface internal -f value -c Region 2>/dev/null)"; then
        mapfile -t detected_regions < <(printf '%s\n' "${endpoint_regions}" | awk 'NF {print $1}' | sort -u)
        if (( ${#detected_regions[@]} == 1 )); then
            REGION_NAME="${detected_regions[0]}"
            REGION_SOURCE="Keystone internal endpoints"
        elif (( ${#detected_regions[@]} > 1 )); then
            echo "WARNING: Multiple endpoint regions found: ${detected_regions[*]}; set OS_REGION_NAME to select one." >&2
        else
            echo "WARNING: Keystone returned no internal endpoint regions." >&2
        fi
    else
        echo "WARNING: Unable to query Keystone endpoints for a region." >&2
    fi

    if [[ -z "${REGION_NAME:-}" ]]; then
        REGION_NAME="RegionOne"
        REGION_SOURCE="default"
    fi
    echo "Using OpenStack region: ${REGION_NAME} (${REGION_SOURCE})"
}

monitoring_ensure_os_metrics_config_secret() {
    local config_secret="os-metrics-config"
    local user_secret="os-metrics-user"
    local metrics_password password_yaml region_yaml current_region config_file

    if kubectl -n "${SERVICE_NAMESPACE}" get secret "${config_secret}" >/dev/null 2>&1; then
        if [[ -z "$(kubectl -n "${SERVICE_NAMESPACE}" get secret "${config_secret}" -o jsonpath='{.data.clouds\.yaml}')" ]]; then
            echo "ERROR: ${SERVICE_NAMESPACE}/${config_secret} exists without clouds.yaml" >&2
            return 1
        fi

        # Preserve existing credentials and custom clouds.yaml settings. Only
        # reconcile the region when it was explicitly set or discovered.
        if [[ "${REGION_SOURCE}" == "default" ]]; then
            echo "Keeping existing secret ${SERVICE_NAMESPACE}/${config_secret} (region not verified)"
            return 0
        fi

        config_file="$(mktemp)"
        chmod 600 "${config_file}"
        if ! kubectl -n "${SERVICE_NAMESPACE}" get secret "${config_secret}" \
            -o jsonpath='{.data.clouds\.yaml}' | base64 -d > "${config_file}"; then
            rm -f -- "${config_file}"
            echo "ERROR: Cannot decode ${config_secret}/clouds.yaml" >&2
            return 1
        fi
        current_region="$(yq -r '.clouds.default.region_name // ""' "${config_file}")"
        if [[ "${current_region}" == "${REGION_NAME}" ]]; then
            rm -f -- "${config_file}"
            echo "Keeping existing secret ${SERVICE_NAMESPACE}/${config_secret} (region ${REGION_NAME})"
            return 0
        fi

        echo "Updating ${SERVICE_NAMESPACE}/${config_secret} region: ${current_region:-<unset>} -> ${REGION_NAME}"
        if ! RESOLVED_REGION="${REGION_NAME}" yq -i \
            '.clouds.default.region_name = strenv(RESOLVED_REGION)' "${config_file}"; then
            rm -f -- "${config_file}"
            return 1
        fi
        if ! kubectl -n "${SERVICE_NAMESPACE}" create secret generic "${config_secret}" \
            --from-file="clouds.yaml=${config_file}" --dry-run=client -o yaml | kubectl apply -f -; then
            rm -f -- "${config_file}"
            return 1
        fi
        rm -f -- "${config_file}"
        OS_METRICS_SECRET_UPDATED=1
        return 0
    fi

    if ! kubectl -n "${SERVICE_NAMESPACE}" get secret "${user_secret}" >/dev/null 2>&1; then
        echo "ERROR: Required credential secret ${SERVICE_NAMESPACE}/${user_secret} is missing" >&2
        return 1
    fi

    metrics_password="$(kubectl -n "${SERVICE_NAMESPACE}" get secret "${user_secret}" \
        -o jsonpath='{.data.password}' | base64 -d)"
    if [[ -z "${metrics_password}" ]]; then
        echo "ERROR: ${SERVICE_NAMESPACE}/${user_secret} has no password value" >&2
        return 1
    fi

    password_yaml="$(printf '%s' "${metrics_password}" | jq -Rs .)"
    region_yaml="$(printf '%s' "${REGION_NAME}" | jq -Rs .)"
    echo "Creating ${SERVICE_NAMESPACE}/${config_secret} (region ${REGION_NAME}) ..."
    kubectl -n "${SERVICE_NAMESPACE}" create secret generic "${config_secret}" \
        --from-file=clouds.yaml=/dev/stdin <<EOF
clouds:
  default:
    region_name: ${region_yaml}
    identity_api_version: 3
    interface: internal
    auth:
      auth_url: http://keystone-api.openstack.svc.cluster.local:5000/v3
      username: os-metrics
      password: ${password_yaml}
      project_name: service
      project_domain_name: service
      user_domain_name: service
EOF
}

OS_METRICS_SECRET_UPDATED=0
resolve_os_metrics_region
monitoring_ensure_namespace "${SERVICE_NAMESPACE}"
monitoring_label_namespace_for_talos "${SERVICE_NAMESPACE}"
monitoring_ensure_os_metrics_config_secret

helm_command=(
    helm upgrade --install "${SERVICE_NAME_DEFAULT}" "${HELM_CHART_PATH}"
    "${helm_chart_version_args[@]}"
    --namespace "${SERVICE_NAMESPACE}"
    --create-namespace
    --timeout 15m
    "${overrides_args[@]}"
    --set-string "clouds_yaml_secret_name=os-metrics-config"
    --set-string "cloud=default"
    --set "multicloud.enabled=false"
    --post-renderer "${POST_RENDERER}"
    --post-renderer-args "${KUSTOMIZE_POST_RENDERER_ARGS}"
    "$@"
)

echo
printf 'Executing Helm command: '
printf '%q ' "${helm_command[@]}"
echo
"${helm_command[@]}"

# An externally managed Secret is not part of Helm's rollout checksum.
# Restart an existing exporter when its region was corrected.
if [[ "${OS_METRICS_SECRET_UPDATED}" == "1" ]]; then
    kubectl -n "${SERVICE_NAMESPACE}" rollout restart deployment \
        -l "app.kubernetes.io/instance=${SERVICE_NAME_DEFAULT}"
fi

echo

echo "OpenStack metrics exporter reconciliation complete."
echo "  Release: ${SERVICE_NAME_DEFAULT}"
echo "  Namespace: ${SERVICE_NAMESPACE}"
echo "  Chart: ${HELM_CHART_PATH}"
