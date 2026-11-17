#!/bin/bash
#
# package-distribute.sh — Build Unimacs with Ad-hoc signing (Distribute configuration,
# Universal Binary arm64 + x86_64) and package it into a redistributable .zip archive.
#
# Usage:
#   ./Scripts/package-distribute.sh [options] [-- <xcodebuild-args>...]
#
# Options:
#   -o, --out <path>       Output .zip file path or directory (default: <build-dir>/unimacs.zip)
#   -v, --version <ver>    Release version string (e.g. v1.4.0 or 1.4.0); sets CURRENT_PROJECT_VERSION
#   -c, --clean            Clean before building
#   -h, --help             Show this help message
#

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCHEME="${SCHEME:-Unimacs}"
CONFIGURATION="${CONFIGURATION:-Distribute}"
ARCHS="${ARCHS:-arm64 x86_64}"

OUT_PATH=""
VERSION_ARG=""
VERSION_PROVIDED=false
NORMALIZED_VERSION=""
CLEAN_BUILD=false
EXTRA_ARGS=()

usage() {
  cat <<EOF
Usage: $(basename "$0") [options] [-- <xcodebuild-args>...]

Build Unimacs using the '${SCHEME}' scheme / '${CONFIGURATION}' configuration
(Ad-hoc signed, Universal Binary) and package the resulting .app bundle into a .zip archive.

Options:
  -o, --out <path>       Destination .zip file path or directory
                         (default: Build/Products/${CONFIGURATION}/unimacs.zip)
  -v, --version <ver>    Set CFBundleShortVersionString / CFBundleVersion (leading 'v' is stripped)
  -c, --clean            Run 'xcodebuild clean' before building
  -h, --help             Show this help message

Examples:
  ./Scripts/package-distribute.sh
  ./Scripts/package-distribute.sh -c -v v1.4.0 -o ~/Desktop/unimacs.zip
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -o|--out)
      if [[ $# -lt 2 || -z "$2" ]]; then
        echo "error: Missing argument for $1" >&2
        exit 1
      fi
      OUT_PATH="$2"
      shift 2
      ;;
    -v|--version)
      if [[ $# -lt 2 ]]; then
        echo "error: Missing argument for $1" >&2
        exit 1
      fi
      VERSION_PROVIDED=true
      VERSION_ARG="$2"
      shift 2
      ;;
    -c|--clean)
      CLEAN_BUILD=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --)
      shift
      EXTRA_ARGS+=("$@")
      break
      ;;
    *)
      EXTRA_ARGS+=("$1")
      shift
      ;;
  esac
done

XCODEBUILD_VERSION_ARGS=()
if [[ "${VERSION_PROVIDED}" == true ]]; then
  trimmed_version="${VERSION_ARG#"${VERSION_ARG%%[![:space:]]*}"}"
  trimmed_version="${trimmed_version%"${trimmed_version##*[![:space:]]}"}"
  if [[ -z "${trimmed_version}" ]]; then
    echo "error: Version specified for -v/--version cannot be empty." >&2
    exit 1
  fi
  if [[ "${trimmed_version}" =~ ^[vV]([0-9].*)$ ]]; then
    NORMALIZED_VERSION="${BASH_REMATCH[1]}"
  else
    NORMALIZED_VERSION="${trimmed_version}"
  fi
  XCODEBUILD_VERSION_ARGS+=("CURRENT_PROJECT_VERSION=${NORMALIZED_VERSION}")
fi

cd "${ROOT_DIR}"

echo "=== 1. Resolving Xcode Build Settings (${SCHEME} / ${CONFIGURATION}) ==="
BUILD_SETTINGS="$(
  xcodebuild \
    -scheme "${SCHEME}" \
    -configuration "${CONFIGURATION}" \
    "${XCODEBUILD_VERSION_ARGS[@]+"${XCODEBUILD_VERSION_ARGS[@]}"}" \
    "${EXTRA_ARGS[@]+"${EXTRA_ARGS[@]}"}" \
    -showBuildSettings 2>/dev/null
)"

APP_PATH="$(echo "${BUILD_SETTINGS}" | awk -F ' = ' '$1 ~ /^[[:space:]]*CODESIGNING_FOLDER_PATH$/ {print $2; exit}')"
EXECUTABLE_NAME="$(echo "${BUILD_SETTINGS}" | awk -F ' = ' '$1 ~ /^[[:space:]]*EXECUTABLE_NAME$/ {print $2; exit}')"

if [[ -z "${APP_PATH}" ]]; then
  echo "error: Failed to determine CODESIGNING_FOLDER_PATH from xcodebuild." >&2
  exit 1
fi

APP_NAME="$(basename "${APP_PATH}")"
APP_BASENAME="${APP_NAME%.app}"
BUILD_DIR="$(dirname "${APP_PATH}")"

if [[ -z "${OUT_PATH}" ]]; then
  OUTPUT_ZIP="${BUILD_DIR}/${APP_BASENAME}.zip"
elif [[ -d "${OUT_PATH}" ]]; then
  OUTPUT_ZIP="${OUT_PATH%/}/${APP_BASENAME}.zip"
else
  OUTPUT_ZIP="${OUT_PATH}"
fi

# Convert OUTPUT_ZIP to an absolute path
mkdir -p "$(dirname "${OUTPUT_ZIP}")"
OUTPUT_ZIP="$(cd "$(dirname "${OUTPUT_ZIP}")" && pwd)/$(basename "${OUTPUT_ZIP}")"

BUILD_ACTIONS=(build)
if [[ "${CLEAN_BUILD}" == true ]]; then
  BUILD_ACTIONS=(clean build)
fi

echo "=== 2. Building ${APP_NAME} (ARCHS: ${ARCHS}, Ad-hoc Signed) ==="
xcodebuild \
  -scheme "${SCHEME}" \
  -configuration "${CONFIGURATION}" \
  ARCHS="${ARCHS}" \
  ONLY_ACTIVE_ARCH=NO \
  CODE_SIGN_IDENTITY="-" \
  CODE_SIGN_STYLE=Manual \
  DEVELOPMENT_TEAM="" \
  PROVISIONING_PROFILE_SPECIFIER="" \
  "${XCODEBUILD_VERSION_ARGS[@]+"${XCODEBUILD_VERSION_ARGS[@]}"}" \
  "${BUILD_ACTIONS[@]}" \
  "${EXTRA_ARGS[@]+"${EXTRA_ARGS[@]}"}"

if [[ ! -d "${APP_PATH}" ]]; then
  echo "error: Expected app bundle not found at: ${APP_PATH}" >&2
  exit 1
fi

# Ensure no machine-specific provisioning profile is embedded
if [[ -f "${APP_PATH}/Contents/embedded.provisionprofile" ]]; then
  echo "Removing embedded provisioning profile from ${APP_NAME}..."
  rm -f "${APP_PATH}/Contents/embedded.provisionprofile"
  codesign --force --deep --sign - "${APP_PATH}"
fi

echo "=== 3. Verifying App Bundle Signature & Architectures ==="
codesign --verify --deep --strict --verbose=2 "${APP_PATH}"

EXEC_BIN="${APP_PATH}/Contents/MacOS/${EXECUTABLE_NAME}"
if [[ ! -f "${EXEC_BIN}" ]]; then
  echo "error: Expected executable binary not found at: ${EXEC_BIN}" >&2
  exit 1
fi

BUILT_ARCHS="$(lipo -archs "${EXEC_BIN}")"
echo "Built architectures: ${BUILT_ARCHS}"

for expected_arch in ${ARCHS}; do
  case " ${BUILT_ARCHS} " in
    *" ${expected_arch} "*) ;;
    *)
      echo "error: Missing expected architecture '${expected_arch}' in ${EXEC_BIN} (found: ${BUILT_ARCHS})." >&2
      exit 1
      ;;
  esac
done

echo "=== 4. Packaging ${APP_NAME} -> ${OUTPUT_ZIP} ==="
rm -f "${OUTPUT_ZIP}"
ditto -c -k --sequesterRsrc --keepParent "${APP_PATH}" "${OUTPUT_ZIP}"

ZIP_SIZE="$(du -h "${OUTPUT_ZIP}" | awk '{print $1}')"

echo ""
echo "=== Package Ready ==="
echo "  App Bundle : ${APP_PATH}"
echo "  Output Zip : ${OUTPUT_ZIP} (${ZIP_SIZE})"
echo ""
echo "Installation Steps:"
echo "  1. Unzip and move '${APP_NAME}' to /Applications"
echo "  2. Run in Terminal to bypass macOS Gatekeeper quarantine:"
echo "     xattr -cr /Applications/${APP_NAME}"
echo "  3. Open /Applications/${APP_NAME} and grant Accessibility permission in System Settings."
