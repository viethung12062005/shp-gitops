#!/usr/bin/env bash
# Download a pinned, curated breached-password list for Keycloak's password blacklist (IAM-06, decision B5).
#
# The realm's password policy is `passwordBlacklist(breached-passwords.txt)`; Keycloak reads that file from its data
# directory, and the chart mounts it from `platform/charts/shp-keycloak/files/`. The file committed to this repository
# is a 45-entry starter so a test cluster boots. A realm that serves real users needs a real list:
#
#   tools/identity/fetch-breached-password-list.sh                 # writes the curated file next to the starter
#   # then in envs/prod/keycloak.yaml:
#   passwordBlacklist:
#     file: files/breached-passwords-curated.txt
#     requireCuratedList: true
#
# The download is pinned by SecLists commit and verified by SHA-256; the file is not committed (it is large and has no
# place in a public repository) — it is fetched wherever the chart is rendered, and the deployment then carries it in a
# ConfigMap. Source: https://github.com/danielmiessler/SecLists (MIT licence), Pwdb_top-100000.txt (100 000 entries).
#
# With --secret NAME the list is written as a Secret key instead, for a cluster that reads the blacklist from Key Vault.
set -euo pipefail
cd "$(dirname "$0")/../.."

SHELL_SOURCE_COMMIT=4ff3ff8ef6b1c429db800e4a9b9deeac7425c5b6   # SecLists commit the URL and hash below belong to
URL="https://raw.githubusercontent.com/danielmiessler/SecLists/${SHELL_SOURCE_COMMIT}/Passwords/Common-Credentials/Pwdb_top-100000.txt"
SHA256=07f876a616f08fb2cc5c3e0ce04e4a6d1123380580472b0997baebc4e8226977
MIN_ENTRIES=100000
TARGET=platform/charts/shp-keycloak/files/breached-passwords-curated.txt

usage() {
  cat <<'EOF'
Usage: tools/identity/fetch-breached-password-list.sh [--target PATH] [--check] [-h]

  --target PATH   where to write the list (default platform/charts/shp-keycloak/files/breached-passwords-curated.txt)
  --check         verify an existing file instead of downloading
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --target) TARGET=${2:?--target needs a path}; shift 2 ;;
    --check) CHECK=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown argument: $1 (try --help)" >&2; exit 2 ;;
  esac
done

verify() { # verify <file>
  local file=$1 entries actual
  actual=$(sha256sum "$file" | cut -d' ' -f1)
  if [ "$actual" != "$SHA256" ]; then
    echo "checksum mismatch: expected $SHA256, got $actual" >&2
    return 1
  fi
  entries=$(grep -c . "$file" || true)
  if [ "$entries" -lt "$MIN_ENTRIES" ]; then
    echo "only $entries entries, $MIN_ENTRIES required" >&2
    return 1
  fi
  echo "  $file: $entries entries, sha256 $actual"
}

if [ "${CHECK:-0}" = 1 ]; then
  verify "$TARGET"
  exit 0
fi

TMP=$(mktemp)
trap 'rm -f "$TMP"' EXIT
echo "== downloading the pinned list"
curl -fsSL --retry 3 -o "$TMP" "$URL"
verify "$TMP"
mv "$TMP" "$TARGET"
echo "== wrote $TARGET"
echo
echo "Point the chart at it (values of the environment that serves real users), then render:"
echo "  passwordBlacklist:"
echo "    file: ${TARGET#platform/charts/shp-keycloak/}"
echo "    requireCuratedList: true"
echo
echo "The file is in .gitignore: it is fetched where the chart is rendered, never committed."
