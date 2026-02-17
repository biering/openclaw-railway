#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Build and push this repo's Docker image to Docker Hub.

Usage:
  scripts/dockerhub-build-push.sh [tag]

Environment:
  DOCKERHUB_IMAGE       Full image repo (e.g. "myuser/openclaw-railway"). Takes precedence.
  DOCKERHUB_NAMESPACE   Docker Hub namespace/user/org (e.g. "myuser"). Used if DOCKERHUB_IMAGE is unset.
  TAG                   Image tag (default: "latest"). Can also be provided as the first argument.
  OPENCLAW_GIT_REF      Optional Docker build arg for OPENCLAW_GIT_REF.
  PUSH_LATEST           If "1" and TAG != latest, also tags/pushes ":latest".

Examples:
  DOCKERHUB_NAMESPACE=myuser scripts/dockerhub-build-push.sh
  DOCKERHUB_NAMESPACE=myuser scripts/dockerhub-build-push.sh v0.1.0
  DOCKERHUB_IMAGE=myorg/openclaw-railway TAG=dev scripts/dockerhub-build-push.sh
  DOCKERHUB_NAMESPACE=myuser TAG=v0.1.0 PUSH_LATEST=1 scripts/dockerhub-build-push.sh

Notes:
  - You must be logged in first: docker login
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

TAG="${1:-${TAG:-latest}}"

IMAGE_REPO="${DOCKERHUB_IMAGE:-}"
if [[ -z "$IMAGE_REPO" ]]; then
  if [[ -n "${DOCKERHUB_NAMESPACE:-}" ]]; then
    IMAGE_REPO="${DOCKERHUB_NAMESPACE}/openclaw-railway"
  else
    echo "error: set DOCKERHUB_IMAGE (e.g. \"myuser/openclaw-railway\") or DOCKERHUB_NAMESPACE (e.g. \"myuser\")." >&2
    echo "" >&2
    usage >&2
    exit 2
  fi
fi

if [[ "$IMAGE_REPO" != */* ]]; then
  echo "error: DOCKERHUB_IMAGE must include a namespace, like \"myuser/openclaw-railway\" (got: \"$IMAGE_REPO\")." >&2
  exit 2
fi

FULL_TAG="${IMAGE_REPO}:${TAG}"

echo "Building ${FULL_TAG}"

BUILD_ARGS=()
if [[ -n "${OPENCLAW_GIT_REF:-}" ]]; then
  BUILD_ARGS+=(--build-arg "OPENCLAW_GIT_REF=${OPENCLAW_GIT_REF}")
fi

docker build -f Dockerfile -t "${FULL_TAG}" "${BUILD_ARGS[@]}" .

if [[ "${PUSH_LATEST:-0}" == "1" && "${TAG}" != "latest" ]]; then
  docker tag "${FULL_TAG}" "${IMAGE_REPO}:latest"
fi

echo "Pushing ${FULL_TAG}"
docker push "${FULL_TAG}"

if [[ "${PUSH_LATEST:-0}" == "1" && "${TAG}" != "latest" ]]; then
  echo "Pushing ${IMAGE_REPO}:latest"
  docker push "${IMAGE_REPO}:latest"
fi

echo "Done: ${FULL_TAG}"
