#!/usr/bin/env bash

set -euo pipefail

GENESTACK_OBSERVABILITY_DIR="${GENESTACK_OBSERVABILITY_DIR:-/opt/genestack-observability}"

LOKI_RULE_DIR="${LOKI_RULE_DIR:-${GENESTACK_OBSERVABILITY_DIR}/alerts/loki-alerts}"

LOKI_ROUTE_NAMESPACE="${LOKI_ROUTE_NAMESPACE:-monitoring}"
LOKI_ROUTE_NAME="${LOKI_ROUTE_NAME:-internal-loki-gateway-route}"

LOKI_TENANT_ID="${LOKI_TENANT_ID:-fake}"
LOKI_NAMESPACES_REGEX="${LOKI_NAMESPACES_REGEX:-^genestack-}"

# Optional explicit endpoint override.
#
# When set, HTTPRoute discovery and automatic port-forward fallback are
# skipped entirely.
#
# Example:
#
#   LOKI_ADDRESS=http://127.0.0.1:13101 \
#     bin/install-observability.sh loki-rules
#
LOKI_ADDRESS="${LOKI_ADDRESS:-}"

# Ruler endpoint used to determine whether the selected Loki endpoint is
# usable before invoking lokitool.
LOKI_RULER_API_PATH="${LOKI_RULER_API_PATH:-/loki/api/v1/rules}"

# Lab fallback.
#
# If no explicit LOKI_ADDRESS is supplied and the HTTPRoute/Gateway endpoint
# cannot be discovered or cannot be reached from the overseer, temporarily
# port-forward the Loki gateway service.
LOKI_PORT_FORWARD_NAMESPACE="${LOKI_PORT_FORWARD_NAMESPACE:-${LOKI_ROUTE_NAMESPACE}}"
LOKI_PORT_FORWARD_SERVICE="${LOKI_PORT_FORWARD_SERVICE:-loki-gateway}"
LOKI_PORT_FORWARD_REMOTE_PORT="${LOKI_PORT_FORWARD_REMOTE_PORT:-80}"

# Starting local port. If occupied, subsequent ports are attempted.
LOKI_PORT_FORWARD_LOCAL_PORT="${LOKI_PORT_FORWARD_LOCAL_PORT:-13101}"
LOKI_PORT_FORWARD_PORT_TRIES="${LOKI_PORT_FORWARD_PORT_TRIES:-20}"

# Endpoint probe timeouts.
LOKI_CONNECT_TIMEOUT="${LOKI_CONNECT_TIMEOUT:-5}"
LOKI_REQUEST_TIMEOUT="${LOKI_REQUEST_TIMEOUT:-15}"

PORT_FORWARD_PID=""
PORT_FORWARD_LOG=""
LOKI_ENDPOINT_SOURCE=""

PROBE_HTTP_CODE=""
PROBE_BODY=""
PROBE_ERROR=""

cleanup() {
    if [[ -n "${PORT_FORWARD_PID}" ]]; then
        if kill -0 "${PORT_FORWARD_PID}" >/dev/null 2>&1; then
            echo
            echo "Stopping temporary Loki port-forward..."
            kill "${PORT_FORWARD_PID}" >/dev/null 2>&1 || true
            wait "${PORT_FORWARD_PID}" 2>/dev/null || true
        fi
    fi

    if [[ -n "${PORT_FORWARD_LOG}" ]]; then
        rm -f "${PORT_FORWARD_LOG}"
    fi
}

trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM


error() {
    echo "ERROR: $*" >&2
}


validate_numeric_setting() {
    local name="$1"
    local value="${!name}"

    if ! [[ "${value}" =~ ^[0-9]+$ ]]; then
        error "${name} must be an integer; got '${value}'."
        exit 1
    fi
}


probe_ruler_api() {
    local address="$1"
    local body_file
    local error_file
    local rc=0

    body_file="$(mktemp)"
    error_file="$(mktemp)"

    PROBE_HTTP_CODE=""
    PROBE_BODY=""
    PROBE_ERROR=""

    PROBE_HTTP_CODE="$(
        curl \
            --silent \
            --show-error \
            --connect-timeout "${LOKI_CONNECT_TIMEOUT}" \
            --max-time "${LOKI_REQUEST_TIMEOUT}" \
            --output "${body_file}" \
            --write-out '%{http_code}' \
            -H "X-Scope-OrgID: ${LOKI_TENANT_ID}" \
            "${address}${LOKI_RULER_API_PATH}" \
            2>"${error_file}"
    )" || rc=$?

    PROBE_BODY="$(cat "${body_file}")"
    PROBE_ERROR="$(cat "${error_file}")"

    rm -f "${body_file}" "${error_file}"

    if (( rc != 0 )); then
        return 1
    fi

    return 0
}


validate_ruler_response() {
    case "${PROBE_HTTP_CODE}" in
        2??)
            return 0
            ;;

        404)
            # An empty Loki Ruler can legitimately return 404 before the
            # first rule group has been synchronized.
            if grep \
                --quiet \
                --ignore-case \
                --fixed-strings \
                "no rule groups found" \
                <<<"${PROBE_BODY}"
            then
                return 0
            fi
            ;;
    esac

    error "Loki Ruler API returned HTTP ${PROBE_HTTP_CODE}."

    if [[ -n "${PROBE_BODY}" ]]; then
        echo >&2
        echo "Response:" >&2
        printf '%s\n' "${PROBE_BODY}" >&2
    fi

    return 1
}


discover_loki_address() {
    local route_json
    local gateway_json
    local loki_hostname
    local gateway_name
    local gateway_namespace
    local gateway_section
    local gateway_protocol
    local gateway_port
    local loki_scheme
    local default_port

    if ! route_json="$(
        kubectl \
            -n "${LOKI_ROUTE_NAMESPACE}" \
            get httproute "${LOKI_ROUTE_NAME}" \
            -o json \
            2>/dev/null
    )"; then
        return 1
    fi

    loki_hostname="$(
        jq -r \
            '.spec.hostnames[0] // empty' \
            <<<"${route_json}"
    )"

    gateway_name="$(
        jq -r '
            [
                (.spec.parentRefs // [])[]
                | select(
                    (.kind // "Gateway") == "Gateway"
                    and
                    (.group // "gateway.networking.k8s.io") == "gateway.networking.k8s.io"
                )
            ][0].name // empty
        ' <<<"${route_json}"
    )"

    gateway_namespace="$(
        jq -r \
            --arg default_namespace "${LOKI_ROUTE_NAMESPACE}" '
                [
                    (.spec.parentRefs // [])[]
                    | select(
                        (.kind // "Gateway") == "Gateway"
                        and
                        (.group // "gateway.networking.k8s.io") == "gateway.networking.k8s.io"
                    )
                ][0].namespace // $default_namespace
            ' <<<"${route_json}"
    )"

    gateway_section="$(
        jq -r '
            [
                (.spec.parentRefs // [])[]
                | select(
                    (.kind // "Gateway") == "Gateway"
                    and
                    (.group // "gateway.networking.k8s.io") == "gateway.networking.k8s.io"
                )
            ][0].sectionName // empty
        ' <<<"${route_json}"
    )"

    if [[ -z "${loki_hostname}" ]]; then
        return 1
    fi

    if [[ -z "${gateway_name}" ]]; then
        return 1
    fi

    if [[ -z "${gateway_section}" ]]; then
        return 1
    fi

    if ! gateway_json="$(
        kubectl \
            -n "${gateway_namespace}" \
            get gateway "${gateway_name}" \
            -o json \
            2>/dev/null
    )"; then
        return 1
    fi

    gateway_protocol="$(
        jq -r \
            --arg section "${gateway_section}" '
                [
                    .spec.listeners[]
                    | select(.name == $section)
                    | .protocol
                ][0] // empty
            ' <<<"${gateway_json}"
    )"

    gateway_port="$(
        jq -r \
            --arg section "${gateway_section}" '
                [
                    .spec.listeners[]
                    | select(.name == $section)
                    | .port
                ][0] // empty
            ' <<<"${gateway_json}"
    )"

    if [[ -z "${gateway_protocol}" || -z "${gateway_port}" ]]; then
        return 1
    fi

    case "${gateway_protocol}" in
        HTTP)
            loki_scheme="http"
            default_port="80"
            ;;

        HTTPS)
            loki_scheme="https"
            default_port="443"
            ;;

        *)
            return 1
            ;;
    esac

    if [[ "${gateway_port}" == "${default_port}" ]]; then
        printf '%s://%s\n' \
            "${loki_scheme}" \
            "${loki_hostname}"
    else
        printf '%s://%s:%s\n' \
            "${loki_scheme}" \
            "${loki_hostname}" \
            "${gateway_port}"
    fi
}


start_loki_port_forward() {
    local offset
    local local_port
    local pid
    local log_file
    local ready
    local check

    echo
    echo "Starting temporary Loki gateway port-forward:"
    echo "  Namespace:   ${LOKI_PORT_FORWARD_NAMESPACE}"
    echo "  Service:     ${LOKI_PORT_FORWARD_SERVICE}"
    echo "  Remote port: ${LOKI_PORT_FORWARD_REMOTE_PORT}"

    for ((
        offset = 0;
        offset < LOKI_PORT_FORWARD_PORT_TRIES;
        offset++
    )); do
        local_port="$((LOKI_PORT_FORWARD_LOCAL_PORT + offset))"
        log_file="$(mktemp)"
        ready="false"

        kubectl \
            -n "${LOKI_PORT_FORWARD_NAMESPACE}" \
            port-forward \
            --address 127.0.0.1 \
            "svc/${LOKI_PORT_FORWARD_SERVICE}" \
            "${local_port}:${LOKI_PORT_FORWARD_REMOTE_PORT}" \
            >"${log_file}" 2>&1 &

        pid=$!

        # Wait for kubectl to establish the listener. This also catches the
        # common case where the requested local port is already occupied.
        for ((check = 0; check < 40; check++)); do
            if grep \
                --quiet \
                --fixed-strings \
                "Forwarding from 127.0.0.1:${local_port}" \
                "${log_file}"
            then
                ready="true"
                break
            fi

            if ! kill -0 "${pid}" >/dev/null 2>&1; then
                break
            fi

            sleep 0.25
        done

        if [[ "${ready}" == "true" ]]; then
            PORT_FORWARD_PID="${pid}"
            PORT_FORWARD_LOG="${log_file}"

            LOKI_ADDRESS="http://127.0.0.1:${local_port}"
            LOKI_ENDPOINT_SOURCE="temporary port-forward"

            echo "  Local port:  ${local_port}"
            echo "  Address:     ${LOKI_ADDRESS}"

            return 0
        fi

        if kill -0 "${pid}" >/dev/null 2>&1; then
            kill "${pid}" >/dev/null 2>&1 || true
        fi

        wait "${pid}" 2>/dev/null || true

        if grep \
            --quiet \
            --ignore-case \
            "address already in use" \
            "${log_file}"
        then
            echo "  Local port ${local_port} is already in use; trying the next port."
            rm -f "${log_file}"
            continue
        fi

        error "Unable to establish Loki gateway port-forward."

        if [[ -s "${log_file}" ]]; then
            echo >&2
            cat "${log_file}" >&2
        fi

        rm -f "${log_file}"
        return 1
    done

    error \
        "Unable to find a usable local port starting at " \
        "${LOKI_PORT_FORWARD_LOCAL_PORT} after " \
        "${LOKI_PORT_FORWARD_PORT_TRIES} attempts."

    return 1
}


if [[ ! -d "${GENESTACK_OBSERVABILITY_DIR}" ]]; then
    error "genestack-observability is not installed:"
    echo "  ${GENESTACK_OBSERVABILITY_DIR}" >&2
    exit 1
fi

if [[ ! -d "${LOKI_RULE_DIR}" ]]; then
    error "Loki rule directory does not exist:"
    echo "  ${LOKI_RULE_DIR}" >&2
    exit 1
fi

for command in kubectl jq curl grep mktemp; do
    if ! command -v "${command}" >/dev/null 2>&1; then
        error "Required command not found: ${command}"
        exit 1
    fi
done

validate_numeric_setting LOKI_PORT_FORWARD_LOCAL_PORT
validate_numeric_setting LOKI_PORT_FORWARD_REMOTE_PORT
validate_numeric_setting LOKI_PORT_FORWARD_PORT_TRIES
validate_numeric_setting LOKI_CONNECT_TIMEOUT
validate_numeric_setting LOKI_REQUEST_TIMEOUT

LOKITOOL_INSTALLER="${GENESTACK_OBSERVABILITY_DIR}/bin/install-lokitool.sh"

if ! command -v lokitool >/dev/null 2>&1; then
    if [[ ! -x "${LOKITOOL_INSTALLER}" ]]; then
        error "lokitool is required and its installer was not found:"
        echo "  ${LOKITOOL_INSTALLER}" >&2
        exit 1
    fi

    echo "lokitool not found; installing the pinned version..."
    "${LOKITOOL_INSTALLER}"
fi

if ! command -v lokitool >/dev/null 2>&1; then
    error \
        "lokitool installation completed but lokitool is still not " \
        "available in PATH."
    exit 1
fi

echo "Using lokitool:"
echo "  $(command -v lokitool)"
lokitool version

# The Genestack synchronization model depends on namespace-regex ownership.
# Fail clearly if an older lokitool is still installed.
LOKITOOL_DIFF_HELP="$(lokitool rules diff --help 2>&1 || true)"

if ! grep \
    --quiet \
    --fixed-strings \
    -- "--namespaces-regex" \
    <<<"${LOKITOOL_DIFF_HELP}"
then
    error \
        "The installed lokitool does not support --namespaces-regex."
    echo "Install the version pinned by:" >&2
    echo "  ${GENESTACK_OBSERVABILITY_DIR}/versions/lokitool" >&2
    echo "using:" >&2
    echo "  ${LOKITOOL_INSTALLER}" >&2
    exit 1
fi


#
# Resolve the Loki endpoint.
#
# Precedence:
#
#   1. Explicit LOKI_ADDRESS
#   2. HTTPRoute/Gateway discovery
#   3. Temporary kubectl port-forward
#

if [[ -n "${LOKI_ADDRESS}" ]]; then
    LOKI_ENDPOINT_SOURCE="LOKI_ADDRESS override"

else
    echo
    echo "Discovering Loki endpoint from HTTPRoute:"
    echo "  ${LOKI_ROUTE_NAMESPACE}/${LOKI_ROUTE_NAME}"

    DISCOVERED_LOKI_ADDRESS=""

    if DISCOVERED_LOKI_ADDRESS="$(discover_loki_address)"; then
        echo "Discovered Loki endpoint:"
        echo "  ${DISCOVERED_LOKI_ADDRESS}"
        echo
        echo "Checking whether the discovered endpoint is reachable..."

        # At this stage we care about transport reachability only.
        #
        # Any actual HTTP response proves the route is reachable. A bad HTTP
        # status is validated later and deliberately does NOT trigger a
        # port-forward fallback, because that would hide a real production
        # Loki/Gateway failure.
        if probe_ruler_api "${DISCOVERED_LOKI_ADDRESS}"; then
            LOKI_ADDRESS="${DISCOVERED_LOKI_ADDRESS}"
            LOKI_ENDPOINT_SOURCE="HTTPRoute/Gateway"

            echo "Discovered endpoint is reachable."
        else
            echo "Discovered endpoint is not reachable from this host."

            if [[ -n "${PROBE_ERROR}" ]]; then
                echo "  ${PROBE_ERROR}"
            fi

            echo "Falling back to a temporary Loki gateway port-forward."

            start_loki_port_forward
        fi

    else
        echo "A usable HTTPRoute/Gateway endpoint could not be discovered."
        echo "Falling back to a temporary Loki gateway port-forward."

        start_loki_port_forward
    fi
fi

LOKI_ADDRESS="${LOKI_ADDRESS%/}"

export LOKI_ADDRESS
export LOKI_TENANT_ID

echo
echo "Loki rule synchronization:"
echo "  Address:      ${LOKI_ADDRESS}"
echo "  Endpoint:     ${LOKI_ENDPOINT_SOURCE}"
echo "  Tenant:       ${LOKI_TENANT_ID}"
echo "  Rule dir:     ${LOKI_RULE_DIR}"
echo "  Namespace RE: ${LOKI_NAMESPACES_REGEX}"
echo

echo "Checking Loki Ruler API..."

if ! probe_ruler_api "${LOKI_ADDRESS}"; then
    error "Unable to reach Loki Ruler API at:"
    echo "  ${LOKI_ADDRESS}${LOKI_RULER_API_PATH}" >&2

    if [[ -n "${PROBE_ERROR}" ]]; then
        echo >&2
        echo "curl error:" >&2
        echo "  ${PROBE_ERROR}" >&2
    fi

    exit 1
fi

if ! validate_ruler_response; then
    exit 1
fi

if [[ "${PROBE_HTTP_CODE}" == "404" ]]; then
    echo "Loki Ruler API is reachable; no rule groups are currently stored."
else
    echo "Loki Ruler API is reachable."
fi

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
