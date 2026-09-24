#!/usr/bin/env bash

set -euo pipefail

GENESTACK_DIR="${GENESTACK_DIR:-/opt/genestack}"
GENESTACK_OBSERVABILITY_DIR="${GENESTACK_OBSERVABILITY_DIR:-/opt/genestack-observability}"
GENESTACK_CONFIG_DIR="${GENESTACK_CONFIG_DIR:-/etc/genestack}"

DEFAULT_COMPONENTS_FILE="${GENESTACK_OBSERVABILITY_DIR}/bin/observability-components.yaml"
SITE_COMPONENTS_FILE="${GENESTACK_CONFIG_DIR}/observability-components.yaml"

if [[ -n "${OBSERVABILITY_COMPONENTS_FILE:-}" ]]; then
    COMPONENTS_FILE="${OBSERVABILITY_COMPONENTS_FILE}"
elif [[ -f "${SITE_COMPONENTS_FILE}" ]]; then
    COMPONENTS_FILE="${SITE_COMPONENTS_FILE}"
else
    COMPONENTS_FILE="${DEFAULT_COMPONENTS_FILE}"
fi

usage() {
    cat <<EOF
Usage:
  $0
  $0 <component> [component...]
  $0 --list
  $0 -h|--help

Behavior:
  No component arguments:
    Install all components enabled in the component configuration, using
    install_order.

  One or more component arguments:
    Install only the named components, in the order provided. Explicitly
    requested components are installed even if disabled in the component
    configuration.

Examples:
  $0
  $0 loki
  $0 prometheus-rules loki-rules
  $0 grafana tempo
  $0 --list

Environment:
  GENESTACK_DIR
    Default: /opt/genestack

  GENESTACK_OBSERVABILITY_DIR
    Default: /opt/genestack-observability

  GENESTACK_CONFIG_DIR
    Default: /etc/genestack

  OBSERVABILITY_COMPONENTS_FILE
    Optional explicit component configuration file.
EOF
}

command -v yq >/dev/null 2>&1 || {
    echo "ERROR: yq is required but was not found in PATH."
    exit 1
}

if [[ ! -d "${GENESTACK_OBSERVABILITY_DIR}" ]]; then
    echo "ERROR: genestack-observability is not installed:"
    echo "  ${GENESTACK_OBSERVABILITY_DIR}"
    echo "Run bootstrap-observability.sh first."
    exit 1
fi

if [[ ! -f "${COMPONENTS_FILE}" ]]; then
    echo "ERROR: Observability components file not found:"
    echo "  ${COMPONENTS_FILE}"
    exit 1
fi

mapfile -t CONFIGURED_COMPONENTS < <(
    yq eval -r '.components | keys | .[]' "${COMPONENTS_FILE}"
)

mapfile -t INSTALL_ORDER < <(
    yq eval -r '.install_order[]' "${COMPONENTS_FILE}"
)

if [[ "${#CONFIGURED_COMPONENTS[@]}" -eq 0 ]]; then
    echo "ERROR: No components are defined in ${COMPONENTS_FILE}"
    exit 1
fi

if [[ "${#INSTALL_ORDER[@]}" -eq 0 ]]; then
    echo "ERROR: install_order is empty in ${COMPONENTS_FILE}"
    exit 1
fi

component_exists() {
    local requested="$1"
    local component

    for component in "${CONFIGURED_COMPONENTS[@]}"; do
        if [[ "${component}" == "${requested}" ]]; then
            return 0
        fi
    done

    return 1
}

component_enabled() {
    local component="$1"
    local enabled

    enabled="$(
        yq eval -r \
            ".components.\"${component}\" // false" \
            "${COMPONENTS_FILE}"
    )"

    [[ "${enabled}" == "true" ]]
}

component_script() {
    local component="$1"

    # All actual service installers live in genestack-observability.
    # install-observability.sh itself may be shipped from either Genestack
    # or genestack-observability.
    case "${component}" in
        monitoring-rgw-storage)
            printf '%s\n' \
                "${GENESTACK_OBSERVABILITY_DIR}/bin/setup-monitoring-rgw-storage.sh"
            ;;
        loki-rules)
            printf '%s\n' \
                "${GENESTACK_OBSERVABILITY_DIR}/bin/loki-sync-rules.sh"
            ;;
        *)
            printf '%s\n' \
                "${GENESTACK_OBSERVABILITY_DIR}/bin/install-${component}.sh"
            ;;
    esac
}

ensure_component_dependencies() {
    local component="$1"

    case "${component}" in
        loki-rules)
            if ! command -v lokitool >/dev/null 2>&1; then
                local installer="${GENESTACK_OBSERVABILITY_DIR}/bin/install-lokitool.sh"

                if [[ ! -x "${installer}" ]]; then
                    echo "ERROR: lokitool is required for loki-rules and the installer is missing:"
                    echo "  ${installer}"
                    exit 1
                fi

                echo "lokitool not found; installing the pinned version..."
                "${installer}"
            fi
            ;;
    esac
}

list_components() {
    local component
    local state

    printf '%-32s %s\n' "COMPONENT" "ENABLED"
    printf '%-32s %s\n' "--------------------------------" "-------"

    for component in "${INSTALL_ORDER[@]}"; do
        if component_enabled "${component}"; then
            state="true"
        else
            state="false"
        fi

        printf '%-32s %s\n' "${component}" "${state}"
    done
}

install_component() {
    local component="$1"
    local script

    if ! component_exists "${component}"; then
        echo "ERROR: Unknown observability component: ${component}"
        echo
        list_components
        exit 1
    fi

    script="$(component_script "${component}")"

    if [[ ! -x "${script}" ]]; then
        echo "ERROR: Component '${component}' has no executable implementation:"
        echo "  ${script}"
        exit 1
    fi

    ensure_component_dependencies "${component}"

    echo
    echo "============================================================"
    echo "Installing observability component: ${component}"
    echo "Implementation: ${script}"
    echo "============================================================"
    echo

    "${script}"
}

if [[ $# -gt 0 ]]; then
    case "$1" in
        -h|--help)
            usage
            exit 0
            ;;
        --list)
            if [[ $# -ne 1 ]]; then
                echo "ERROR: --list cannot be combined with component names."
                exit 1
            fi

            list_components
            exit 0
            ;;
        --*)
            echo "ERROR: Unknown option: $1"
            usage
            exit 1
            ;;
    esac
fi

echo "Genestack Observability"
echo "  Repository: ${GENESTACK_OBSERVABILITY_DIR}"
echo "  Components: ${COMPONENTS_FILE}"
echo

if [[ $# -gt 0 ]]; then
    echo "Installing explicitly requested component(s): $*"

    for component in "$@"; do
        install_component "${component}"
    done
else
    echo "Installing enabled components in configured install order."

    for component in "${INSTALL_ORDER[@]}"; do
        if ! component_enabled "${component}"; then
            echo "Skipping disabled observability component: ${component}"
            continue
        fi

        install_component "${component}"
    done
fi

echo
echo "Requested observability installation completed successfully."
