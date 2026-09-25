#!/usr/bin/env bash

set -euo pipefail

GENESTACK_OBSERVABILITY_DIR="${GENESTACK_OBSERVABILITY_DIR:-/opt/genestack-observability}"

LOKI_RULE_DIR="${LOKI_RULE_DIR:-${GENESTACK_OBSERVABILITY_DIR}/alerts/loki-alerts}"

LOKI_ROUTE_NAMESPACE="${LOKI_ROUTE_NAMESPACE:-monitoring}"
LOKI_ROUTE_NAME="${LOKI_ROUTE_NAME:-internal-loki-gateway-route}"

LOKI_TENANT_ID="${LOKI_TENANT_ID:-fake}"
LOKI_NAMESPACES_REGEX="${LOKI_NAMESPACES_REGEX:-^genestack-}"

# Optional override. When unset, discover the regional endpoint from the
# configured HTTPRoute and its referenced Gateway listener.
LOKI_ADDRESS="${LOKI_ADDRESS:-}"

if [[ ! -d "${GENESTACK_OBSERVABILITY_DIR}" ]]; then
    echo "ERROR: genestack-observability is not installed:"
    echo "  ${GENESTACK_OBSERVABILITY_DIR}"
    exit 1
fi

if [[ ! -d "${LOKI_RULE_DIR}" ]]; then
    echo "ERROR: Loki rule directory does not exist:"
    echo "  ${LOKI_RULE_DIR}"
    exit 1
fi

for command in kubectl jq curl; do
    if ! command -v "${command}" >/dev/null 2>&1; then
        echo "ERROR: Required command not found: ${command}"
        exit 1
    fi
done

if ! command -v lokitool >/dev/null 2>&1; then
    LOKITOOL_INSTALLER="${GENESTACK_OBSERVABILITY_DIR}/bin/install-lokitool.sh"

    if [[ ! -x "${LOKITOOL_INSTALLER}" ]]; then
        echo "ERROR: lokitool is required and its installer was not found:"
        echo "  ${LOKITOOL_INSTALLER}"
        exit 1
    fi

    echo "lokitool not found; installing the pinned version..."
    "${LOKITOOL_INSTALLER}"
fi

if ! command -v lokitool >/dev/null 2>&1; then
    echo "ERROR: lokitool installation completed but lokitool is still not available in PATH." >&2
    exit 1
fi

echo "Using lokitool:"
echo "  $(command -v lokitool)"
lokitool --version

if [[ -z "${LOKI_ADDRESS}" ]]; then
    echo "Discovering Loki endpoint from HTTPRoute ${LOKI_ROUTE_NAMESPACE}/${LOKI_ROUTE_NAME}..."

    ROUTE_JSON="$(
        kubectl \
            -n "${LOKI_ROUTE_NAMESPACE}" \
            get httproute "${LOKI_ROUTE_NAME}" \
            -o json
    )"

    LOKI_HOSTNAME="$(
        jq -r '.spec.hostnames[0] // empty' <<<"${ROUTE_JSON}"
    )"

    GATEWAY_NAME="$(
        jq -r '
            [
                .spec.parentRefs[]
                | select(
                    (.kind // "Gateway") == "Gateway"
                    and
                    (.group // "gateway.networking.k8s.io") == "gateway.networking.k8s.io"
                )
            ][0].name // empty
        ' <<<"${ROUTE_JSON}"
    )"

    GATEWAY_NAMESPACE="$(
        jq -r \
            --arg default_namespace "${LOKI_ROUTE_NAMESPACE}" '
                [
                    .spec.parentRefs[]
                    | select(
                        (.kind // "Gateway") == "Gateway"
                        and
                        (.group // "gateway.networking.k8s.io") == "gateway.networking.k8s.io"
                    )
                ][0].namespace // $default_namespace
            ' <<<"${ROUTE_JSON}"
    )"

    GATEWAY_SECTION="$(
        jq -r '
            [
                .spec.parentRefs[]
                | select(
                    (.kind // "Gateway") == "Gateway"
                    and
                    (.group // "gateway.networking.k8s.io") == "gateway.networking.k8s.io"
                )
            ][0].sectionName // empty
        ' <<<"${ROUTE_JSON}"
    )"

    if [[ -z "${LOKI_HOSTNAME}" ]]; then
        echo "ERROR: HTTPRoute has no hostname."
        exit 1
    fi

    if [[ -z "${GATEWAY_NAME}" ]]; then
        echo "ERROR: HTTPRoute has no Gateway parentRef."
        exit 1
    fi

    if [[ -z "${GATEWAY_SECTION}" ]]; then
        echo "ERROR: HTTPRoute Gateway parentRef has no sectionName."
        exit 1
    fi

    GATEWAY_JSON="$(
        kubectl \
            -n "${GATEWAY_NAMESPACE}" \
            get gateway "${GATEWAY_NAME}" \
            -o json
    )"

    GATEWAY_PROTOCOL="$(
        jq -r \
            --arg section "${GATEWAY_SECTION}" '
                .spec.listeners[]
                | select(.name == $section)
                | .protocol
            ' <<<"${GATEWAY_JSON}"
    )"

    GATEWAY_PORT="$(
        jq -r \
            --arg section "${GATEWAY_SECTION}" '
                .spec.listeners[]
                | select(.name == $section)
                | .port
            ' <<<"${GATEWAY_JSON}"
    )"

    if [[ -z "${GATEWAY_PROTOCOL}" || -z "${GATEWAY_PORT}" ]]; then
        echo "ERROR: Could not resolve Gateway listener '${GATEWAY_SECTION}'."
        exit 1
    fi

    case "${GATEWAY_PROTOCOL}" in
        HTTP)
            LOKI_SCHEME="http"
            DEFAULT_PORT="80"
            ;;
        HTTPS)
            LOKI_SCHEME="https"
            DEFAULT_PORT="443"
            ;;
        *)
            echo "ERROR: Unsupported Gateway listener protocol: ${GATEWAY_PROTOCOL}"
            exit 1
            ;;
    esac

    if [[ "${GATEWAY_PORT}" == "${DEFAULT_PORT}" ]]; then
        LOKI_ADDRESS="${LOKI_SCHEME}://${LOKI_HOSTNAME}"
    else
        LOKI_ADDRESS="${LOKI_SCHEME}://${LOKI_HOSTNAME}:${GATEWAY_PORT}"
    fi
fi

LOKI_ADDRESS="${LOKI_ADDRESS%/}"

export LOKI_ADDRESS
export LOKI_TENANT_ID

echo
echo "Loki rule synchronization:"
echo "  Address:      ${LOKI_ADDRESS}"
echo "  Tenant:       ${LOKI_TENANT_ID}"
echo "  Rule dir:     ${LOKI_RULE_DIR}"
echo "  Namespace RE: ${LOKI_NAMESPACES_REGEX}"
echo

echo "Checking Loki Ruler API..."

curl \
    --fail \
    --silent \
    --show-error \
    -H "X-Scope-OrgID: ${LOKI_TENANT_ID}" \
    "${LOKI_ADDRESS}/loki/api/v1/rules" \
    >/dev/null

echo "Loki Ruler API is reachable."

echo
echo "Diffing Loki rules..."

lokitool rules diff \
    --rule-dirs="${LOKI_RULE_DIR}" \
    --namespaces-regex="${LOKI_NAMESPACES_REGEX}" \
    --verbose

echo
echo "Synchronizing Loki rules..."

lokitool rules sync \
    --rule-dirs="${LOKI_RULE_DIR}" \
    --namespaces-regex="${LOKI_NAMESPACES_REGEX}"

echo
echo "Loki rules synchronized successfully."
