#!/bin/bash
set -euo pipefail

if [[ ! "${RAW_TAG:-}" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo 'Release tag must have the form vMAJOR.MINOR.PATCH' >&2
    exit 1
fi
TAG_COMMIT="$(git rev-parse --verify "refs/tags/${RAW_TAG}^{commit}")"
git checkout --detach "$TAG_COMMIT"
printf 'tag=%s\nversion=%s\n' "$RAW_TAG" "${RAW_TAG#v}" >> "$GITHUB_OUTPUT"
