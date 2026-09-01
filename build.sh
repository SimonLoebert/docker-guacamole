#!/bin/bash
### Local build helper. Publishing is handled by .github/workflows/docker.yml.
###
### Usage: ./build.sh [repository] [version]
set -euo pipefail

REPOSITORY="${1:-local}"
VERSION="${2:-$(awk -F= '/^ARG GUAC_VER=/{print $2; exit}' Dockerfile)}"

docker build --rm --target nomariadb -t "${REPOSITORY}/guacamole:${VERSION}-nomariadb" .
docker build --rm --target mariadb   -t "${REPOSITORY}/guacamole:${VERSION}" .
