#!/bin/bash
#
# Debug build wrapper: optionally refresh invalid development certificates (when
# AUTO_CLEAN_REVOKED_CERTIFICATES=YES), then invoke xcodebuild.
# Use this when building from the command line (scheme pre-actions cover Xcode GUI builds).

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCHEME="${SCHEME:-Unimacs}"
CONFIGURATION="${CONFIGURATION:-Debug}"

cd "${ROOT_DIR}"

while IFS='=' read -r key value; do
  case "${key}" in
    DEVELOPMENT_TEAM|PRODUCT_BUNDLE_IDENTIFIER|CODE_SIGN_STYLE|CONFIGURATION|AUTO_CLEAN_REVOKED_CERTIFICATES)
      export "${key}=${value}"
      ;;
  esac
done < <(
  xcodebuild -scheme "${SCHEME}" -configuration "${CONFIGURATION}" -showBuildSettings 2>/dev/null \
    | awk -F ' = ' '$1 ~ /^[[:space:]]*(DEVELOPMENT_TEAM|PRODUCT_BUNDLE_IDENTIFIER|CODE_SIGN_STYLE|CONFIGURATION|AUTO_CLEAN_REVOKED_CERTIFICATES)$/ {gsub(/^[[:space:]]+/, "", $1); print $1 "=" $2}'
)

"${ROOT_DIR}/Scripts/ensure_development_certificate.sh"

BUILD_FLAGS=(-scheme "${SCHEME}" -configuration "${CONFIGURATION}")
if [[ "${CODE_SIGN_STYLE:-}" == "Automatic" && -n "${DEVELOPMENT_TEAM:-}" ]]; then
  BUILD_FLAGS+=(-allowProvisioningUpdates)
fi

xcodebuild "${BUILD_FLAGS[@]}" build "$@"

# If Xcode.app was open in the background while a missing certificate was being provisioned,
# Xcode.app and xcodebuild may race and create two certificates where Xcode.app supersedes
# xcodebuild's newly created certificate. Run a post-build check and re-sign if needed.
if [[ "${AUTO_CLEAN_REVOKED_CERTIFICATES:-NO}" == "YES" ]]; then
  POST_CHECK_OUT="$("${ROOT_DIR}/Scripts/ensure_development_certificate.sh" 2>&1 || true)"
  if [[ -n "${POST_CHECK_OUT}" ]]; then
    echo "${POST_CHECK_OUT}"
  fi
  if [[ "${POST_CHECK_OUT}" == *"Removing "* ]]; then
    echo "note: [build-debug] Certificate was superseded during build; re-running xcodebuild to sign with the active identity..."
    xcodebuild "${BUILD_FLAGS[@]}" build "$@"
  fi
fi
