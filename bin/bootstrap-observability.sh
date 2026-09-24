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

DEFAULT_COMPONENTS_FILE="${GENESTACK_OBSERVABILITY_DIR}/observability-components.yaml"
SITE_COMPONENTS_FILE="${GENESTACK_CONFIG_DIR}/observability-components.yaml"

RUN_INSTALL=true
UPDATE_REPO=true

usage() {
    cat <<EOF
Usage: $0 [OPTIONS]

Bootstrap genestack-observability on a Genestack overseer.

Options:
  --no-install    Configure the repository and links but do not install services.
  --no-update     Do not git pull when the repository already exists.
  -h, --help      Show this help.

Environment:
  GENESTACK_DIR                  Default: /opt/genestack
  GENESTACK_OBSERVABILITY_DIR    Default: /opt/genestack-observability
  GENESTACK_CONFIG_DIR           Default: /etc/genestack
  GENESTACK_OBSERVABILITY_REPO   Default:
                                 git@github.com:rackerlabs/genestack-observability.git
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
