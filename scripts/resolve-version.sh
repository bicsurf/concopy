#!/bin/bash

# Keep branch names out of CFBundleShortVersionString. Explicit overrides must be valid.
resolve_app_version() {
    local candidate tag
    candidate="${APP_VERSION:-${VERSION:-}}"
    if [ -n "$candidate" ]; then
        if [[ "$candidate" =~ ^[vV]?([0-9]+\.[0-9]+\.[0-9]+)$ ]]; then
            printf '%s\n' "${BASH_REMATCH[1]}"
            return
        fi
        echo "Invalid app version: expected major.minor.patch" >&2
        return 1
    fi
    candidate="${GITHUB_REF_NAME:-}"
    if [[ "$candidate" =~ ^[vV]?([0-9]+\.[0-9]+\.[0-9]+)$ ]]; then
        printf '%s\n' "${BASH_REMATCH[1]}"
        return
    fi
    while IFS= read -r tag; do
        if [[ "$tag" =~ ^[vV]?([0-9]+\.[0-9]+\.[0-9]+)$ ]]; then
            printf '%s\n' "${BASH_REMATCH[1]}"
            return
        fi
    done < <(git tag --sort=-v:refname 2>/dev/null)
    printf '%s\n' '1.2.0'
}
