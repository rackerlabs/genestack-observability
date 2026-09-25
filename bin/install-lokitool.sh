#!/usr/bin/env bash

set -euo pipefail

GENESTACK_OBSERVABILITY_DIR="${GENESTACK_OBSERVABILITY_DIR:-/opt/genestack-observability}"

VERSION_FILE="${GENESTACK_OBSERVABILITY_DIR}/versions/lokitool"
INSTALL_DIR="${LOKITOOL_INSTALL_DIR:-/usr/local/bin}"
INSTALL_PATH="${INSTALL_DIR}/lokitool"

for command in curl unzip install; do
    if ! command -v "${command}" >/dev/null 2>&1; then
        echo "ERROR: Required command not found: ${command}"
        exit 1
    fi
done

if [[ ! -f "${VERSION_FILE}" ]]; then
    echo "ERROR: Missing lokitool version file: ${VERSION_FILE}"
    exit 1
fi

VERSION="$(tr -d '[:space:]' < "${VERSION_FILE}")"

if [[ -z "${VERSION}" ]]; then
    echo "ERROR: lokitool version file is empty: ${VERSION_FILE}"
    exit 1
fi

case "$(uname -m)" in
    x86_64)
        ARCH="amd64"
        ;;
    aarch64|arm64)
        ARCH="arm64"
        ;;
    *)
        echo "ERROR: Unsupported architecture: $(uname -m)"
        exit 1
        ;;
esac

if command -v lokitool >/dev/null 2>&1; then
    if lokitool --version 2>&1 | grep -Fq "${VERSION}"; then
        echo "lokitool ${VERSION} is already installed:"
        echo "  $(command -v lokitool)"
        exit 0
    fi

    echo "Installed lokitool does not match pinned version ${VERSION}; updating."
fi

ASSET="lokitool-linux-${ARCH}.zip"
URL="https://github.com/grafana/loki/releases/download/v${VERSION}/${ASSET}"

TMPDIR="$(mktemp -d)"
trap 'rm -rf "${TMPDIR}"' EXIT

echo "Downloading lokitool ${VERSION} (${ARCH})..."

curl \
    --fail \
    --location \
    --silent \
    --show-error \
    "${URL}" \
    --output "${TMPDIR}/${ASSET}"

mkdir -p "${TMPDIR}/extract"

unzip -q \
    "${TMPDIR}/${ASSET}" \
    -d "${TMPDIR}/extract"

BINARY="$(
    find "${TMPDIR}/extract" \
        -type f \
        -name 'lokitool*' \
        ! -name '*.zip' \
        -print \
        -quit
)"

if [[ -z "${BINARY}" ]]; then
    echo "ERROR: lokitool binary was not found in ${ASSET}"
    exit 1
fi

if [[ "${EUID}" -eq 0 ]]; then
    mkdir -p "${INSTALL_DIR}"

    install \
        -m 0755 \
        "${BINARY}" \
        "${INSTALL_PATH}"
elif [[ -d "${INSTALL_DIR}" && -w "${INSTALL_DIR}" ]]; then
    install \
        -m 0755 \
        "${BINARY}" \
        "${INSTALL_PATH}"
elif command -v sudo >/dev/null 2>&1; then
    echo "Installing lokitool to ${INSTALL_PATH} with sudo..."

    sudo mkdir -p "${INSTALL_DIR}"

    sudo install \
        -m 0755 \
        "${BINARY}" \
        "${INSTALL_PATH}"
else
    echo "ERROR: Cannot install lokitool to ${INSTALL_PATH}." >&2
    echo "The destination requires elevated privileges and sudo is unavailable." >&2
    exit 1
fi

if [[ ! -x "${INSTALL_PATH}" ]]; then
    echo "ERROR: lokitool installation did not create an executable binary:" >&2
    echo "  ${INSTALL_PATH}" >&2
    exit 1
fi

echo "Installed ${INSTALL_PATH}"

"${INSTALL_PATH}" --version
