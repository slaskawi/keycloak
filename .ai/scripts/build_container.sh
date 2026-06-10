#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<EOF
Usage: $(basename "$0") [ttl.sh/image-name:ttl]

Builds the local Keycloak Quarkus distribution, builds a container image from it,
and pushes the image to ttl.sh.

Environment:
  CONTAINER_RUNTIME  Container CLI to use. Default: docker
  PLATFORMS          buildx platform list. Default: linux/amd64
  TTL                ttl.sh image retention tag when no image is provided. Default: 24h

Examples:
  $0
  TTL=2h $0
  PLATFORMS=linux/amd64,linux/arm64 $0 ttl.sh/my-keycloak-test:24h
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
CONTAINER_DIR="${PROJECT_ROOT}/quarkus/container"
CONTAINER_RUNTIME="${CONTAINER_RUNTIME:-docker}"
PLATFORMS="${PLATFORMS:-linux/amd64}"
TTL="${TTL:-24h}"

log() {
  printf '[build-container] %s\n' "$*"
}

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    printf 'Required command not found: %s\n' "$1" >&2
    exit 1
  fi
}

sanitize_image_part() {
  printf '%s' "$1" \
    | tr '[:upper:]' '[:lower:]' \
    | sed -E 's/[^a-z0-9._-]+/-/g; s/^[._-]+//; s/[._-]+$//'
}

require_command git
require_command sed
require_command tr
require_command "$CONTAINER_RUNTIME"

cd "$PROJECT_ROOT"

if ! "$CONTAINER_RUNTIME" buildx version >/dev/null 2>&1; then
  printf '%s buildx is required to build and push the ttl.sh image.\n' "$CONTAINER_RUNTIME" >&2
  exit 1
fi

VERSION="$(./get-version.sh)"
SAFE_VERSION="$(sanitize_image_part "$VERSION")"
GIT_SHA="$(git rev-parse --short HEAD 2>/dev/null || true)"
GIT_SHA="${GIT_SHA:-nogit}"
TIMESTAMP="$(date -u +%Y%m%d%H%M%S)"
IMAGE_REF="${1:-ttl.sh/keycloak-${SAFE_VERSION}-${GIT_SHA}-${TIMESTAMP}:${TTL}}"

DIST_TAR="${PROJECT_ROOT}/quarkus/dist/target/keycloak-${VERSION}.tar.gz"
STAGED_DIST_NAME="keycloak-${SAFE_VERSION}-${TIMESTAMP}.tar.gz"
STAGED_DIST="${CONTAINER_DIR}/${STAGED_DIST_NAME}"

cleanup() {
  rm -f "$STAGED_DIST"
}
trap cleanup EXIT

log "Building Keycloak server distribution (${VERSION})"
./mvnw -pl quarkus/deployment,quarkus/dist -am -DskipTests clean install

if [[ ! -f "$DIST_TAR" ]]; then
  printf 'Distribution archive not found: %s\n' "$DIST_TAR" >&2
  exit 1
fi

log "Staging distribution archive for container build"
cp "$DIST_TAR" "$STAGED_DIST"

log "Building and pushing ${IMAGE_REF}"
"$CONTAINER_RUNTIME" buildx build \
  --platform "$PLATFORMS" \
  --build-arg "KEYCLOAK_VERSION=${VERSION}" \
  --build-arg "KEYCLOAK_DIST=${STAGED_DIST_NAME}" \
  -t "$IMAGE_REF" \
  --push \
  "$CONTAINER_DIR"

log "Pushed image: ${IMAGE_REF}"
