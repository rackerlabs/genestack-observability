#!/usr/bin/env bash

set -euo pipefail

GENESTACK_DIR="${GENESTACK_DIR:-/opt/genestack}"
GENESTACK_OBSERVABILITY_DIR="${GENESTACK_OBSERVABILITY_DIR:-/opt/genestack-observability}"
GENESTACK_CONFIG_DIR="${GENESTACK_CONFIG_DIR:-/etc/genestack}"

GENESTACK_OBSERVABILITY_REPO="${GENESTACK_OBSERVABILITY_REPO:-git@github.com:rackerlabs/genestack-observability.git}"

HELM_SOURCE="${GENESTACK_OBSERVABILITY_DIR}/helm-configs"
HELM_TARGET="${GENESTACK_DIR}/base-helm-configs/observability"

KUSTOMIZE_SOURCE="${GENESTACK_OBSERVABILITY_DIR}/kustomize"
KUSTOMIZE_TARGET="${GENESTACK_DIR}/base-kustomize/observability"

DEFAULT_COMPONENTS_FILE="${GENESTACK_OBSERVABILITY_DIR}/bin/observability-components.yaml"
SITE_COMPONENTS_FILE="${GENESTACK_CONFIG_DIR}/observability-components.yaml"

GATEWAY_ROUTE_SOURCE_DIR="${GENESTACK_OBSERVABILITY_DIR}/etc/gateway-api/routes"
GATEWAY_ROUTE_TARGET_DIR="${GENESTACK_CONFIG_DIR}/gateway-api/routes"
GATEWAY_LISTENER_SOURCE_DIR="${GENESTACK_OBSERVABILITY_DIR}/etc/gateway-api/listeners"
GATEWAY_LISTENER_FALLBACK_DIR="${GENESTACK_DIR}/etc/gateway-api/listeners"
GATEWAY_LISTENER_TARGET_DIR="${GENESTACK_CONFIG_DIR}/gateway-api/listeners"

RUN_INSTALL=true
UPDATE_REPO=true
MANAGE_ROUTES=true

usage() {
    cat <<EOF
Usage: $0 [OPTIONS]

Bootstrap genestack-observability on a Genestack overseer.

Options:
  --no-install    Configure the repository and links but do not install services.
  --no-update     Do not git pull when the repository already exists.
  --no-routes     Do not seed or apply observability Gateway API routes.
  -h, --help      Show this help.

Environment:
  GENESTACK_DIR                  Default: /opt/genestack
  GENESTACK_OBSERVABILITY_DIR    Default: /opt/genestack-observability
  GENESTACK_CONFIG_DIR           Default: /etc/genestack
  GENESTACK_OBSERVABILITY_REPO   Default:
                                 git@github.com:rackerlabs/genestack-observability.git
  OBSERVABILITY_GATEWAY_DOMAIN   Optional domain used when rendering missing
                                 route templates containing your.domain.tld.
                                 Falls back to GATEWAY_DOMAIN, envoy-gateways.yaml,
                                 or a wildcard Gateway listener.

Observability route templates are sourced from:
  /opt/genestack-observability/etc/gateway-api/routes

Rendered/site-specific routes live under:
  /etc/genestack/gateway-api/routes
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --no-install)
            RUN_INSTALL=false
            shift
            ;;
        --no-update)
            UPDATE_REPO=false
            shift
            ;;
        --no-routes)
            MANAGE_ROUTES=false
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "ERROR: Unknown option: $1"
            usage
            exit 1
            ;;
    esac
done

if [[ ! -d "${GENESTACK_DIR}" ]]; then
    echo "ERROR: Genestack directory does not exist: ${GENESTACK_DIR}"
    exit 1
fi

for path in \
    "${GENESTACK_DIR}/base-helm-configs" \
    "${GENESTACK_DIR}/base-kustomize"
do
    if [[ ! -d "${path}" ]]; then
        echo "ERROR: Expected Genestack directory does not exist: ${path}"
        exit 1
    fi
done

if [[ ! -d "${GENESTACK_OBSERVABILITY_DIR}/.git" ]]; then
    if [[ -e "${GENESTACK_OBSERVABILITY_DIR}" ]]; then
        echo "ERROR: ${GENESTACK_OBSERVABILITY_DIR} exists but is not a Git checkout."
        exit 1
    fi

    echo "Cloning genestack-observability..."
    git clone \
        --recurse-submodules \
        -j4 \
        "${GENESTACK_OBSERVABILITY_REPO}" \
        "${GENESTACK_OBSERVABILITY_DIR}"
elif [[ "${UPDATE_REPO}" == "true" ]]; then
    echo "Updating genestack-observability..."
    git -C "${GENESTACK_OBSERVABILITY_DIR}" pull --ff-only

    echo "Synchronizing and updating submodules..."
    git -C "${GENESTACK_OBSERVABILITY_DIR}" submodule sync --recursive
    git -C "${GENESTACK_OBSERVABILITY_DIR}" submodule update \
        --init \
        --recursive \
        -j4
fi

for source in "${HELM_SOURCE}" "${KUSTOMIZE_SOURCE}"; do
    if [[ ! -d "${source}" ]]; then
        echo "ERROR: Required observability directory does not exist: ${source}"
        exit 1
    fi
done

ensure_symlink() {
    local source="$1"
    local target="$2"

    if [[ -L "${target}" ]]; then
        ln -sfn "${source}" "${target}"
        echo "Updated symlink: ${target} -> ${source}"
        return
    fi

    if [[ -e "${target}" ]]; then
        echo "ERROR: Refusing to replace existing non-symlink path:"
        echo "  ${target}"
        echo "Reconcile or remove it before rerunning bootstrap."
        exit 1
    fi

    ln -s "${source}" "${target}"
    echo "Created symlink: ${target} -> ${source}"
}

ensure_symlink "${HELM_SOURCE}" "${HELM_TARGET}"
ensure_symlink "${KUSTOMIZE_SOURCE}" "${KUSTOMIZE_TARGET}"

mkdir -p "${GENESTACK_CONFIG_DIR}"

if [[ ! -f "${SITE_COMPONENTS_FILE}" ]]; then
    if [[ ! -f "${DEFAULT_COMPONENTS_FILE}" ]]; then
        echo "ERROR: Default component configuration is missing:"
        echo "  ${DEFAULT_COMPONENTS_FILE}"
        exit 1
    fi

    cp "${DEFAULT_COMPONENTS_FILE}" "${SITE_COMPONENTS_FILE}"
    echo "Created site component configuration: ${SITE_COMPONENTS_FILE}"
else
    echo "Keeping existing site component configuration: ${SITE_COMPONENTS_FILE}"
fi


resolve_gateway_domain() {
    local domain=""

    if [[ -n "${OBSERVABILITY_GATEWAY_DOMAIN:-}" ]]; then
        printf '%s\n' "${OBSERVABILITY_GATEWAY_DOMAIN}"
        return 0
    fi

    if [[ -n "${GATEWAY_DOMAIN:-}" ]]; then
        printf '%s\n' "${GATEWAY_DOMAIN}"
        return 0
    fi

    if command -v yq >/dev/null 2>&1 && \
       [[ -f "${GENESTACK_CONFIG_DIR}/envoy-gateways.yaml" ]]; then
        domain="$(
            yq eval -r '.domain // ""' \
                "${GENESTACK_CONFIG_DIR}/envoy-gateways.yaml" 2>/dev/null || true
        )"
        if [[ -n "${domain}" && "${domain}" != "null" ]]; then
            printf '%s\n' "${domain}"
            return 0
        fi
    fi

    if command -v kubectl >/dev/null 2>&1; then
        domain="$(
            kubectl get gateway -A \
                -o jsonpath='{range .items[*].spec.listeners[*]}{.hostname}{"\n"}{end}' \
                2>/dev/null |
            sed -n 's/^\*\.//p' |
            head -n1
        )"
        if [[ -n "${domain}" ]]; then
            printf '%s\n' "${domain}"
            return 0
        fi
    fi

    return 1
}

gateway_config_mode_enabled() {
    local config_file="${GENESTACK_CONFIG_DIR}/envoy-gateways.yaml"
    local gateway_count="0"

    [[ -f "${config_file}" ]] || return 1
    command -v yq >/dev/null 2>&1 || return 1

    gateway_count="$(
        yq eval -r '(.gateways // {}) | length' "${config_file}" 2>/dev/null || true
    )"

    [[ "${gateway_count}" =~ ^[0-9]+$ ]] && [[ "${gateway_count}" -gt 0 ]]
}

route_is_observability() {
    local route_file="$1"
    local kind
    local route_namespace
    local backend_namespaces

    command -v yq >/dev/null 2>&1 || return 1

    kind="$(yq eval -r '.kind // ""' "${route_file}" 2>/dev/null || true)"
    [[ "${kind}" == "HTTPRoute" ]] || return 1

    route_namespace="$(
        yq eval -r '.metadata.namespace // ""' "${route_file}" 2>/dev/null || true
    )"

    if [[ "${route_namespace}" == "monitoring" ]]; then
        return 0
    fi

    backend_namespaces="$(
        yq eval -r '.spec.rules[]?.backendRefs[]?.namespace // ""' \
            "${route_file}" 2>/dev/null || true
    )"

    grep -qx 'monitoring' <<< "${backend_namespaces}"
}

find_listener_template() {
    local listener_name="$1"
    local source_dir
    local candidate

    for source_dir in \
        "${GATEWAY_LISTENER_SOURCE_DIR}" \
        "${GATEWAY_LISTENER_FALLBACK_DIR}"; do
        [[ -d "${source_dir}" ]] || continue

        for candidate in \
            "${source_dir}/${listener_name}.json" \
            "${source_dir}/${listener_name}-https.json" \
            "${source_dir}/${listener_name}-listener.json"; do
            if [[ -f "${candidate}" ]]; then
                printf '%s\n' "${candidate}"
                return 0
            fi
        done
    done

    return 1
}

seed_listener_template() {
    local listener_name="$1"
    local gateway_domain="$2"
    local source_file=""
    local target_file=""
    local temp_file=""

    source_file="$(find_listener_template "${listener_name}" || true)"
    [[ -n "${source_file}" ]] || return 0

    mkdir -p "${GATEWAY_LISTENER_TARGET_DIR}"
    target_file="${GATEWAY_LISTENER_TARGET_DIR}/$(basename "${source_file}")"

    if [[ -e "${target_file}" ]]; then
        echo "Keeping existing Gateway listener: ${target_file}"
        return 0
    fi

    if grep -q 'your\.domain\.tld' "${source_file}"; then
        if [[ -z "${gateway_domain}" ]]; then
            echo "WARNING: Cannot render missing listener ${listener_name} without a gateway domain:"
            echo "  ${source_file}"
            return 0
        fi

        temp_file="$(mktemp)"
        sed "s/your\\.domain\\.tld/${gateway_domain}/g" \
            "${source_file}" > "${temp_file}"
        mv "${temp_file}" "${target_file}"
    else
        cp "${source_file}" "${target_file}"
    fi

    echo "Created Gateway listener: ${target_file}"
}

seed_observability_routes() {
    local route_template
    local target_file
    local gateway_domain=""
    local temp_file
    local listener_name

    if gateway_config_mode_enabled; then
        echo "Envoy multi-gateway config mode detected:"
        echo "  ${GENESTACK_CONFIG_DIR}/envoy-gateways.yaml"
        echo "Skipping legacy observability route seeding; config mode owns route rendering."
        return 0
    fi

    if [[ ! -d "${GATEWAY_ROUTE_SOURCE_DIR}" ]]; then
        echo "Observability Gateway route template directory not found; skipping route seeding:"
        echo "  ${GATEWAY_ROUTE_SOURCE_DIR}"
        return 0
    fi

    if ! command -v yq >/dev/null 2>&1; then
        echo "WARNING: yq is not available; skipping observability route discovery."
        return 0
    fi

    mkdir -p "${GATEWAY_ROUTE_TARGET_DIR}"
    gateway_domain="$(resolve_gateway_domain || true)"

    while IFS= read -r -d '' route_template; do
        route_is_observability "${route_template}" || continue

        target_file="${GATEWAY_ROUTE_TARGET_DIR}/$(basename "${route_template}")"

        # genestack-observability owns the route templates; /etc/genestack is the
        # site-owned rendered/override location. Never replace an existing route.
        if [[ -e "${target_file}" ]]; then
            echo "Keeping existing observability route: ${target_file}"
        elif grep -q 'your\.domain\.tld' "${route_template}"; then
            if [[ -z "${gateway_domain}" ]]; then
                echo "WARNING: Cannot render missing observability route without a gateway domain:"
                echo "  ${route_template}"
                echo "Set OBSERVABILITY_GATEWAY_DOMAIN or GATEWAY_DOMAIN and rerun bootstrap."
                continue
            fi

            temp_file="$(mktemp)"
            sed "s/your\\.domain\\.tld/${gateway_domain}/g" \
                "${route_template}" > "${temp_file}"
            mv "${temp_file}" "${target_file}"
            echo "Created observability route: ${target_file}"
        else
            cp "${route_template}" "${target_file}"
            echo "Created observability route: ${target_file}"
        fi

        # Seed only listener templates referenced by the observability route.
        while IFS= read -r listener_name; do
            [[ -n "${listener_name}" && "${listener_name}" != "null" ]] || continue
            seed_listener_template "${listener_name}" "${gateway_domain}"
        done < <(
            yq eval -r '.spec.parentRefs[]?.sectionName // ""' \
                "${target_file}" 2>/dev/null |
            sed '/^$/d' |
            sort -u
        )
    done < <(
        find "${GATEWAY_ROUTE_SOURCE_DIR}" \
            -maxdepth 1 \
            -type f \
            \( -name '*.yaml' -o -name '*.yml' \) \
            -print0 |
        sort -z
    )
}

listener_file_for_section() {
    local listener_name="$1"
    local candidate

    [[ -d "${GATEWAY_LISTENER_TARGET_DIR}" ]] || return 1

    for candidate in \
        "${GATEWAY_LISTENER_TARGET_DIR}/${listener_name}.json" \
        "${GATEWAY_LISTENER_TARGET_DIR}/${listener_name}-https.json" \
        "${GATEWAY_LISTENER_TARGET_DIR}/${listener_name}-listener.json"; do
        if [[ -f "${candidate}" ]]; then
            printf '%s\n' "${candidate}"
            return 0
        fi
    done

    return 1
}

ensure_gateway_listener() {
    local gateway_name="$1"
    local gateway_namespace="$2"
    local listener_file="$3"
    local listener_name
    local desired_listener
    local existing_listener
    local gateway_json
    local existing_index
    local patch_file

    command -v jq >/dev/null 2>&1 || {
        echo "WARNING: jq is not available; cannot ensure Gateway listener from ${listener_file}"
        return 0
    }

    if ! kubectl -n "${gateway_namespace}" get gateway "${gateway_name}" \
        >/dev/null 2>&1; then
        echo "Gateway ${gateway_namespace}/${gateway_name} does not exist yet; listener will not be patched."
        return 0
    fi

    listener_name="$(jq -r '.[0].value.name // ""' "${listener_file}")"
    [[ -n "${listener_name}" ]] || return 0

    desired_listener="$(
        jq -c '.[0].value | {name, port, protocol, hostname, tls, allowedRoutes}' \
            "${listener_file}"
    )"
    gateway_json="$(
        kubectl -n "${gateway_namespace}" get gateway "${gateway_name}" -o json
    )"
    existing_listener="$(
        jq -c --arg name "${listener_name}" \
            '.spec.listeners[]? |
             select(.name == $name) |
             {name, port, protocol, hostname, tls, allowedRoutes}' \
            <<< "${gateway_json}"
    )"

    if [[ -n "${existing_listener}" ]]; then
        if [[ "${existing_listener}" != "${desired_listener}" ]]; then
            echo "WARNING: Gateway listener ${gateway_namespace}/${gateway_name}:${listener_name}"
            echo "already exists and differs from ${listener_file}; leaving the live listener unchanged."
        else
            echo "Gateway listener ${gateway_namespace}/${gateway_name}:${listener_name} already present."
        fi
        return 0
    fi

    # Preserve the special handling used by the Genestack gateway setup:
    # http-wildcard-listener replaces the legacy cluster-http listener.
    if [[ "${listener_name}" == "http-wildcard-listener" ]]; then
        existing_index="$(
            jq -r '
                .spec.listeners
                | to_entries[]
                | select(.value.name == "cluster-http")
                | .key
            ' <<< "${gateway_json}"
        )"

        if [[ -n "${existing_index}" ]]; then
            patch_file="$(mktemp)"
            jq -n \
                --argjson index "${existing_index}" \
                --argjson listener "${desired_listener}" \
                '[{"op":"replace","path":("/spec/listeners/" + ($index|tostring)),"value":$listener}]' \
                > "${patch_file}"

            echo "Replacing cluster-http with ${listener_name} on ${gateway_namespace}/${gateway_name}"
            kubectl -n "${gateway_namespace}" patch gateway "${gateway_name}" \
                --type='json' \
                --patch-file "${patch_file}"
            rm -f "${patch_file}"
            return 0
        fi
    fi

    echo "Adding Gateway listener ${listener_name} to ${gateway_namespace}/${gateway_name}"
    kubectl -n "${gateway_namespace}" patch gateway "${gateway_name}" \
        --type='json' \
        --patch-file "${listener_file}"
}

ensure_route_listeners() {
    local route_file="$1"
    local parent_ref
    local gateway_name
    local gateway_namespace
    local listener_name
    local listener_file

    while IFS=$'\t' read -r gateway_name gateway_namespace listener_name; do
        [[ -n "${gateway_name}" && -n "${listener_name}" ]] || continue
        gateway_namespace="${gateway_namespace:-envoy-gateway}"

        listener_file="$(listener_file_for_section "${listener_name}" || true)"
        [[ -n "${listener_file}" ]] || continue

        ensure_gateway_listener \
            "${gateway_name}" \
            "${gateway_namespace}" \
            "${listener_file}"
    done < <(
        yq eval -r '
            .spec.parentRefs[]? |
            [
                (.name // ""),
                (.namespace // "envoy-gateway"),
                (.sectionName // "")
            ] |
            @tsv
        ' "${route_file}" 2>/dev/null || true
    )
}

apply_observability_routes() {
    local route_file
    local route_namespace
    local applied=0

    if gateway_config_mode_enabled; then
        echo "Envoy multi-gateway config mode detected; skipping legacy route apply."
        return 0
    fi

    if ! command -v kubectl >/dev/null 2>&1; then
        echo "WARNING: kubectl is not available; skipping observability route apply."
        return 0
    fi

    if ! kubectl get crd httproutes.gateway.networking.k8s.io \
        >/dev/null 2>&1; then
        echo "Gateway API HTTPRoute CRD is not installed; skipping observability route apply."
        return 0
    fi

    [[ -d "${GATEWAY_ROUTE_TARGET_DIR}" ]] || return 0

    while IFS= read -r -d '' route_file; do
        route_is_observability "${route_file}" || continue

        route_namespace="$(
            yq eval -r '.metadata.namespace // "default"' \
                "${route_file}" 2>/dev/null || true
        )"

        if ! kubectl get namespace "${route_namespace}" >/dev/null 2>&1; then
            echo "Route namespace ${route_namespace} does not exist yet; skipping:"
            echo "  ${route_file}"
            continue
        fi

        ensure_route_listeners "${route_file}"

        echo "Applying observability route: ${route_file}"
        kubectl apply -f "${route_file}"
        applied=$((applied + 1))
    done < <(
        find "${GATEWAY_ROUTE_TARGET_DIR}" \
            -maxdepth 1 \
            -type f \
            \( -name '*.yaml' -o -name '*.yml' \) \
            -print0 |
        sort -z
    )

    if [[ "${applied}" -eq 0 ]]; then
        echo "No observability Gateway API routes were applied."
    fi
}

if [[ "${MANAGE_ROUTES}" == "true" ]]; then
    echo
    echo "Preparing observability Gateway API routes..."
    seed_observability_routes
fi

echo
echo "Observability repository:"
echo "  ${GENESTACK_OBSERVABILITY_DIR}"
echo
echo "Genestack links:"
echo "  ${HELM_TARGET} -> $(readlink "${HELM_TARGET}")"
echo "  ${KUSTOMIZE_TARGET} -> $(readlink "${KUSTOMIZE_TARGET}")"
echo

if [[ "${RUN_INSTALL}" == "true" ]]; then
    INSTALL_SCRIPT="${GENESTACK_OBSERVABILITY_DIR}/bin/install-observability.sh"

    if [[ ! -x "${INSTALL_SCRIPT}" ]]; then
        echo "ERROR: Unified observability installer is missing or not executable:"
        echo "  ${INSTALL_SCRIPT}"
        exit 1
    fi

    "${INSTALL_SCRIPT}"
else
    echo "Skipping observability installation (--no-install)."
fi

if [[ "${MANAGE_ROUTES}" == "true" ]]; then
    echo
    echo "Applying observability Gateway API routes..."
    apply_observability_routes
else
    echo "Skipping observability Gateway API routes (--no-routes)."
fi
