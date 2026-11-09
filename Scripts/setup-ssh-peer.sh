#!/bin/bash
#
# One-time SSH key setup for Unimacs log merging (unimacs-logs.sh).
# Installs your public key on the remote Mac and adds a ~/.ssh/config alias.
#
# Usage:
#   Scripts/setup-ssh-peer.sh [host-or-ip] [ssh-alias] [user]
#
# Defaults:
#   host-or-ip  192.168.1.100
#   ssh-alias   unimacs-peer
#   user        $(whoami)
#
# You will be prompted for the REMOTE password once. After that:
#   ssh unimacs-peer
#   Scripts/unimacs-logs.sh unimacs-peer

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEVICES_FILE="${SCRIPT_DIR}/devices.txt"

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

# Resolve target from devices.txt if possible
RESOLVED_USER=""
RESOLVED_HOST=""
RESOLVED_ALIAS=""

if [[ $# -gt 0 ]]; then
  RESOLVED=$(find_alias "$1" || true)
  if [[ -n "${RESOLVED}" ]]; then
    if [[ "${RESOLVED}" =~ @ ]]; then
      RESOLVED_USER="${RESOLVED%%@*}"
      RESOLVED_HOST="${RESOLVED#*@}"
    else
      RESOLVED_HOST="${RESOLVED}"
    fi
    RESOLVED_ALIAS="$1"
    echo "Resolved alias '$1' to '${RESOLVED}' via devices.txt" >&2
  fi
fi

PEER_HOST="${RESOLVED_HOST:-${1:-192.168.1.100}}"
PEER_ALIAS="${2:-${RESOLVED_ALIAS:-unimacs-peer}}"
PEER_USER="${3:-${RESOLVED_USER:-$(whoami)}}"
SSH_CONFIG="${HOME}/.ssh/config"
if [[ -n "${SSH_KEY:-}" ]]; then
  KEY="${SSH_KEY}"
elif [[ -f "${HOME}/.ssh/id_ed25519.pub" ]]; then
  KEY="${HOME}/.ssh/id_ed25519"
else
  KEY="${HOME}/.ssh/id_rsa"
fi
PUB="${KEY}.pub"

MARKER="# unimacs-logs peer — managed by Scripts/setup-ssh-peer.sh"

if [[ ! -f "$PUB" ]]; then
  echo "error: public key not found: $PUB" >&2
  echo "       Generate one with: ssh-keygen -t ed25519 -f ~/.ssh/id_ed25519" >&2
  exit 1
fi

mkdir -p "${HOME}/.ssh"
chmod 700 "${HOME}/.ssh"

if ! grep -qF "Host ${PEER_ALIAS}" "$SSH_CONFIG" 2>/dev/null; then
  cat >> "$SSH_CONFIG" <<EOF

${MARKER}
Host ${PEER_ALIAS}
  HostName ${PEER_HOST}
  User ${PEER_USER}
  IdentityFile ${KEY}
  IdentitiesOnly yes
  StrictHostKeyChecking accept-new
  ServerAliveInterval 30
EOF
  echo "Added SSH config alias: ${PEER_ALIAS} → ${PEER_USER}@${PEER_HOST}" >&2
else
  echo "SSH config alias '${PEER_ALIAS}' already exists (skipped append)." >&2
fi

echo "Installing public key on ${PEER_USER}@${PEER_HOST} …" >&2
echo "→ Enter the REMOTE Mac password when prompted (last time)." >&2

if ! ssh-copy-id -i "$PUB" "${PEER_USER}@${PEER_HOST}"; then
  echo "error: ssh-copy-id failed." >&2
  exit 1
fi

echo "Verifying passwordless login …" >&2
if ssh -o BatchMode=yes -o ConnectTimeout=8 "${PEER_ALIAS}" "echo ok" >/dev/null 2>&1; then
  echo "Done. Use:" >&2
  echo "  ssh ${PEER_ALIAS}" >&2
  echo "  Scripts/unimacs-logs.sh ${PEER_ALIAS}" >&2
else
  echo "warning: key installed but BatchMode test failed for alias '${PEER_ALIAS}'." >&2
  echo "         Try: ssh -v ${PEER_ALIAS}" >&2
  exit 1
fi
