#!/bin/bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../resolve-version.sh"
TEST_DIR="$(mktemp -d)"
trap 'rm -rf "$TEST_DIR"' EXIT
mkdir -p "$TEST_DIR/bin"
export RELEASE_TEST_LOG="$TEST_DIR/git.log"
export RELEASE_TEST_COMMIT=0123456789abcdef0123456789abcdef01234567
cat > "$TEST_DIR/bin/git" <<'MOCK'
#!/bin/bash
printf '%s\n' "$*" >> "$RELEASE_TEST_LOG"
case "$1" in
    tag) printf '%s\n' "${RELEASE_TEST_TAGS:-}" ;;
    rev-parse)
        if [ "${RELEASE_TEST_MISSING:-0}" = 1 ]; then exit 1; fi
        printf '%s\n' "$RELEASE_TEST_COMMIT" ;;
    checkout) [ "$2" = --detach ] && [ "$3" = "$RELEASE_TEST_COMMIT" ] ;;
    *) exit 1 ;;
esac
MOCK
chmod +x "$TEST_DIR/bin/git"
export PATH="$TEST_DIR/bin:$PATH"
unset APP_VERSION VERSION GITHUB_REF_NAME
export RELEASE_TEST_TAGS=$'invalid-tag\nv1.4.2\nv1.3.8'
assert_version() {
    local actual
    actual="$(resolve_app_version)"
    if [ "$actual" != "$1" ]; then
        printf 'Expected version %s, got %s\n' "$1" "$actual" >&2
        exit 1
    fi
}
assert_version 1.4.2
export GITHUB_REF_NAME=codex/privacy-and-sync
assert_version 1.4.2
export GITHUB_REF_NAME=v2.3.4
assert_version 2.3.4
export VERSION=3.4.5
assert_version 3.4.5
export APP_VERSION=v4.5.6
assert_version 4.5.6
export APP_VERSION=not-a-version
if resolve_app_version > /dev/null 2>&1; then echo 'Invalid explicit version accepted' >&2; exit 1; fi
export APP_VERSION='$(touch '"$TEST_DIR"'/injected)'
if resolve_app_version > /dev/null 2>&1; then echo 'Shell expression accepted as version' >&2; exit 1; fi
[ ! -e "$TEST_DIR/injected" ]
unset APP_VERSION VERSION
export GITHUB_REF_NAME=main RELEASE_TEST_TAGS=invalid-tag
assert_version 1.2.0
export GITHUB_OUTPUT="$TEST_DIR/output"
: > "$RELEASE_TEST_LOG"
export RAW_TAG=v1.3.8
bash "$SCRIPT_DIR/../resolve-release-tag.sh"
[ "$(cat "$GITHUB_OUTPUT")" = $'tag=v1.3.8\nversion=1.3.8' ]
[ "$(cat "$RELEASE_TEST_LOG")" = "rev-parse --verify refs/tags/v1.3.8^{commit}"$'\n'"checkout --detach $RELEASE_TEST_COMMIT" ]
rm "$GITHUB_OUTPUT"
: > "$RELEASE_TEST_LOG"
export RAW_TAG='v1.3.8; touch '"$TEST_DIR"'/injected'
if bash "$SCRIPT_DIR/../resolve-release-tag.sh" > /dev/null 2>&1; then echo 'Invalid release tag accepted' >&2; exit 1; fi
[ ! -e "$TEST_DIR/injected" ]
[ ! -s "$RELEASE_TEST_LOG" ]
[ ! -e "$GITHUB_OUTPUT" ]
export RAW_TAG=v9.9.9 RELEASE_TEST_MISSING=1
if bash "$SCRIPT_DIR/../resolve-release-tag.sh" > /dev/null 2>&1; then echo 'Missing release tag accepted' >&2; exit 1; fi
[ "$(cat "$RELEASE_TEST_LOG")" = 'rev-parse --verify refs/tags/v9.9.9^{commit}' ]
[ ! -e "$GITHUB_OUTPUT" ]
printf 'Release script regression tests passed.\n'
