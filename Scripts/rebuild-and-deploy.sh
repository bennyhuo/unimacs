#!/bin/bash
#
# rebuild-and-deploy.sh — Rebuild Unimacs locally, clean local logs, and restart
# locally. If remote targets (or --all) are specified, sequentially syncs the
# build to remote Macs/VMs, cleans remote logs, and restarts Unimacs there.
#
# Usage:
#   Scripts/rebuild-and-deploy.sh [options] [<device-alias-or-ssh-target> ...]
#
# Options:
#   -a, --all    Also deploy to all devices listed in Scripts/devices.txt
#   -h, --help   Show this help message
#
# Examples:
#   Scripts/rebuild-and-deploy.sh                      # Rebuild & restart locally only
#   Scripts/rebuild-and-deploy.sh VM1                  # Rebuild locally + deploy to VM1
#   Scripts/rebuild-and-deploy.sh user@192.168.1.100   # Rebuild locally + deploy via SSH
#   Scripts/rebuild-and-deploy.sh --all                # Rebuild locally + deploy to all in devices.txt
#

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${ROOT_DIR}"

SSH_TIMEOUT=30

DEVICES_FILE="${ROOT_DIR}/Scripts/devices.txt"
SCHEME="${SCHEME:-Unimacs}"
CONFIGURATION="${CONFIGURATION:-Debug}"

print_help() {
  sed -n '2,/^set -euo/p' "$0" | sed 's/^# \{0,1\}//; s/^#//' | sed '$d'
}

# Helper function to find a target's ssh_target in devices.txt
find_alias() {
  local target_alias="$1"
  if [[ -f "${DEVICES_FILE}" ]]; then
    while read -r line || [[ -n "${line}" ]]; do
      line=$(echo "${line}" | tr -d '\r')
      if [[ -z "${line}" || "${line}" =~ ^[[:space:]]*# ]]; then
        continue
      fi
      read -r dev_alias ssh_target <<< "${line}"
      if [[ "${dev_alias}" == "${target_alias}" ]]; then
        echo "${ssh_target}"
        return 0
      fi
    done < "${DEVICES_FILE}"
  fi
  return 1
}

# 1. Determine optional remote targets to deploy to
REMOTES=()
DEPLOY_ALL=false
TARGET_ARGS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    -a|--all)
      DEPLOY_ALL=true
      shift
      ;;
    -h|--help)
      print_help
      exit 0
      ;;
    -*)
      echo "error: Unknown option: $1" >&2
      echo "Try: $0 --help" >&2
      exit 2
      ;;
    *)
      TARGET_ARGS+=("$1")
      shift
      ;;
  esac
done

if [[ "${DEPLOY_ALL}" == true ]]; then
  if [[ ! -f "${DEVICES_FILE}" ]]; then
    echo "error: --all specified, but ${DEVICES_FILE} does not exist." >&2
    exit 1
  fi
  while read -r line || [[ -n "${line}" ]]; do
    line=$(echo "${line}" | tr -d '\r')
    if [[ -z "${line}" || "${line}" =~ ^[[:space:]]*# ]]; then
      continue
    fi
    read -r dev_alias ssh_target <<< "${line}"
    if [[ -n "${ssh_target}" ]]; then
      echo "Adding device alias '${dev_alias}' (${ssh_target}) from devices.txt"
      REMOTES+=("${ssh_target}")
    fi
  done < "${DEVICES_FILE}"

  if [[ ${#REMOTES[@]} -eq 0 && ${#TARGET_ARGS[@]} -eq 0 ]]; then
    echo "error: --all specified, but no devices were found in ${DEVICES_FILE}." >&2
    exit 1
  fi
fi

if [[ ${#TARGET_ARGS[@]} -gt 0 ]]; then
  for arg in "${TARGET_ARGS[@]}"; do
    resolved="$(find_alias "${arg}" || true)"
    if [[ -n "${resolved}" ]]; then
      echo "Resolved alias '${arg}' to '${resolved}' via devices.txt"
      REMOTES+=("${resolved}")
    else
      echo "Using direct target: ${arg}"
      REMOTES+=("${arg}")
    fi
  done
fi

echo "=== 1. Locating Xcode Build Product ==="
# Retrieve CODESIGNING_FOLDER_PATH from xcodebuild build settings
LOCAL_APP=$(xcodebuild -scheme "${SCHEME}" -configuration "${CONFIGURATION}" -showBuildSettings 2>/dev/null | awk -F ' = ' '$1 ~ /^[[:space:]]*CODESIGNING_FOLDER_PATH$/ {print $2}')

if [[ -z "${LOCAL_APP}" ]]; then
  echo "error: Could not determine build directory from xcodebuild." >&2
  exit 1
fi

APP_NAME=$(basename "${LOCAL_APP}")
APP_EXEC_NAME="${APP_NAME%.app}"

echo "=== 2. Stopping Local Unimacs ==="
killall "${APP_EXEC_NAME}" unimacs unimacs-dev 2>/dev/null || true

echo "=== 3. Rebuilding Debug Product ==="
"${ROOT_DIR}/Scripts/build-debug.sh"

if [[ ! -d "${LOCAL_APP}" ]]; then
  echo "error: Xcode build product not found at: ${LOCAL_APP}" >&2
  exit 1
fi

echo "=== 4. Deleting Local Logs ==="
rm -f ~/Library/Containers/com.*.unimacs*/Data/Library/Logs/Unimacs/*.log 2>/dev/null || true
rm -f ~/Library/Logs/Unimacs/*.log 2>/dev/null || true

echo "=== 5. Starting Local Unimacs ==="
open "${LOCAL_APP}"

if [[ ${#REMOTES[@]} -eq 0 ]]; then
  echo "=== Done ==="
  echo "Successfully rebuilt, cleaned logs, and restarted Unimacs on local host."
  exit 0
fi

echo "=== 6. Deploying to Remote Targets ==="
DEPLOYED_REMOTES=()
SKIPPED_REMOTES=()

for REMOTE in "${REMOTES[@]}"; do
  echo "--- Processing ${REMOTE} ---"
  
  # Check if remote is reachable via ssh
  echo "Checking connection to ${REMOTE}..."
  if ! ssh -o ConnectTimeout=$SSH_TIMEOUT -o ConnectionAttempts=1 "${REMOTE}" "true" 2>/dev/null; then
    echo "warning: SSH connection to ${REMOTE} timed out or failed. Skipping this target." >&2
    SKIPPED_REMOTES+=("${REMOTE}")
    continue
  fi

  REMOTE_PATH="Desktop/${APP_NAME}"

  echo "Stopping any running unimacs on remote..."
  ssh -o ConnectTimeout=$SSH_TIMEOUT "${REMOTE}" "killall \"${APP_EXEC_NAME}\" unimacs unimacs-dev 2>/dev/null || true"

  echo "Deleting remote logs..."
  ssh -o ConnectTimeout=$SSH_TIMEOUT "${REMOTE}" "bash -c 'rm -f ~/Library/Containers/com.*.unimacs*/Data/Library/Logs/Unimacs/*.log ~/Library/Logs/Unimacs/*.log 2>/dev/null || true'"

  echo "Syncing ${APP_NAME} to remote Desktop..."
  rsync -avz -e "ssh -o ConnectTimeout=$SSH_TIMEOUT" --delete "${LOCAL_APP}/" "${REMOTE}:${REMOTE_PATH}/"

  echo "Starting ${APP_EXEC_NAME} on remote..."
  ssh -o ConnectTimeout=$SSH_TIMEOUT "${REMOTE}" "open ~/Desktop/\"${APP_NAME}\""
  
  DEPLOYED_REMOTES+=("${REMOTE}")
done

echo "=== Done ==="
if [[ ${#DEPLOYED_REMOTES[@]} -gt 0 ]]; then
  echo "Successfully rebuilt, cleaned logs, and restarted Unimacs on local host and targets:"
  for REMOTE in "${DEPLOYED_REMOTES[@]}"; do
    echo "  - ${REMOTE}"
  done
fi

if [[ ${#SKIPPED_REMOTES[@]} -gt 0 ]]; then
  echo "Skipped targets (unreachable/timed out):"
  for REMOTE in "${SKIPPED_REMOTES[@]}"; do
    echo "  - ${REMOTE}"
  done
fi
