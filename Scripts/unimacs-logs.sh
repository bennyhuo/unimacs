#!/bin/bash
#
# unimacs-logs.sh — Merge this Mac's Unimacs logs with remote Macs' logs, into a
# single timeline tagged [L] (local) / [alias] (remote).
#
# Why: when diagnosing multi-Mac control and cursor synchronization issues, a common
# failure mode is "one end can't initiate/accept control", which is best analyzed
# by lining up both ends' logs by timestamp. This tool ships logs over SSH so it
# keeps working even when the Unimacs network connection itself is unavailable.
#
# How it works: FileLogger writes per-day files under a Unimacs log directory.
# Sandboxed app builds (unimacs / unimacs-dev) store them at:
#   ~/Library/Containers/com.*.unimacs*/Data/Library/Logs/Unimacs/
# Non-sandbox / legacy fallback:
#   ~/Library/Logs/Unimacs/
# Every line starts with "yyyy-MM-dd HH:mm:ss.SSS", so lines from all hosts can
# be merged and sorted into one chronological stream.
#
# Usage:
#   Scripts/unimacs-logs.sh [options] [<remote-ssh-target-or-alias> ...]
#
#   [<remote-ssh-target-or-alias> ...] Defaults to all devices in devices.txt
#
# Options:
#   -f, --follow          Live-follow logs (best-effort interleave, not re-sorted).
#   -d, --date  <date>    Day to pull, yyyy-MM-dd. Default: today (local clock).
#   -g, --grep  <regex>   Only show lines matching this extended regex (applied per side).
#   -o, --out   <file>    Snapshot mode: also write merged output to <file>.
#   -h, --help            Show this help.
#
# Examples:
#   Scripts/unimacs-logs.sh                           # Fetch logs from all devices in devices.txt
#   Scripts/unimacs-logs.sh VM1                       # Fetch logs from VM1
#   Scripts/unimacs-logs.sh -d 2026-06-30 VM1 MINI    # Fetch logs from VM1 and MINI on 2026-06-30
#   Scripts/unimacs-logs.sh -f VM1                    # Live tail logs from local and VM1
#
# Prerequisites:
#   - Remote Login (SSH) enabled on the remote Macs.
#   - All Macs' clocks NTP-synced (macOS default).
#   - Set Unimacs's log level to Debug on all ends for full detail.

set -euo pipefail

FOLLOW=0
DATE="$(date +%Y-%m-%d)"
GREP_RE=""
OUT_FILE=""
TARGETS=()

print_help() {
  sed -n '2,/^set -euo/p' "$0" | sed 's/^# \{0,1\}//; s/^#//' | sed '$d'
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -f|--follow) FOLLOW=1; shift ;;
    -d|--date)   DATE="${2:?--date needs a value}"; shift 2 ;;
    -g|--grep)   GREP_RE="${2:?--grep needs a value}"; shift 2 ;;
    -o|--out)    OUT_FILE="${2:?--out needs a value}"; shift 2 ;;
    -h|--help)   print_help; exit 0 ;;
    -*)          echo "Unknown option: $1" >&2; echo "Try: $0 --help" >&2; exit 2 ;;
    *)           TARGETS+=("$1"); shift ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEVICES_FILE="${SCRIPT_DIR}/devices.txt"

# Helper function to resolve target alias/ssh target
resolve_target() {
  local query="$1"
  if [[ -f "${DEVICES_FILE}" ]]; then
    while read -r line || [[ -n "${line}" ]]; do
      line=$(echo "${line}" | tr -d '\r')
      if [[ -z "${line}" || "${line}" =~ ^[[:space:]]*# ]]; then
        continue
      fi
      local dev_alias ssh_target
      read -r dev_alias ssh_target <<< "${line}"
      if [[ "${dev_alias}" == "${query}" || "${ssh_target}" == "${query}" ]]; then
        echo "${dev_alias} ${ssh_target}"
        return 0
      fi
    done < "${DEVICES_FILE}"
  fi
  echo "${query} ${query}"
}

RESOLVED_REMOTES=()
if [[ ${#TARGETS[@]} -gt 0 ]]; then
  for t in "${TARGETS[@]}"; do
    res=$(resolve_target "$t")
    RESOLVED_REMOTES+=("$res")
  done
else
  # No targets specified. Read all from devices.txt
  if [[ -f "${DEVICES_FILE}" ]]; then
    while read -r line || [[ -n "${line}" ]]; do
      line=$(echo "${line}" | tr -d '\r')
      if [[ -z "${line}" || "${line}" =~ ^[[:space:]]*# ]]; then
        continue
      fi
      local dev_alias ssh_target
      read -r dev_alias ssh_target <<< "${line}"
      if [[ -n "${ssh_target}" ]]; then
        RESOLVED_REMOTES+=("${dev_alias} ${ssh_target}")
      fi
    done < "${DEVICES_FILE}"
  fi
fi

if [[ ${#RESOLVED_REMOTES[@]} -eq 0 ]]; then
  echo "error: No target specified, and no devices found in devices.txt" >&2
  echo "usage: $0 [options] [<device-alias-or-ssh-target> ...]" >&2
  exit 1
fi

REMOTE_ALIASES=()
REMOTE_TARGETS=()
for item in "${RESOLVED_REMOTES[@]}"; do
  read -r r_alias r_target <<< "${item}"
  REMOTE_ALIASES+=("${r_alias}")
  REMOTE_TARGETS+=("${r_target}")
done

# Resolve unimacs-<date>.log on THIS machine. Prefers the newest file if several
# bundle containers exist (e.g. .dev vs release).
resolve_local_log_file() {
  local date="$1"
  local name="unimacs-${date}.log"
  local best="" best_mtime=0 f m

  for f in \
    "${HOME}"/Library/Containers/com.*.unimacs*/Data/Library/Logs/Unimacs/"${name}" \
    "${HOME}"/Library/Logs/Unimacs/"${name}"; do
    [[ -f "$f" ]] || continue
    if stat -c %Y "$f" >/dev/null 2>&1; then
      m=$(stat -c %Y "$f" 2>/dev/null || echo 0)
    else
      m=$(stat -f %m "$f" 2>/dev/null || echo 0)
    fi
    if [[ -z "$best" || "$m" -gt "$best_mtime" ]]; then
      best="$f"
      best_mtime="$m"
    fi
  done
  [[ -n "$best" ]] && echo "$best"
}

# Remote resolver (bash snippet run over SSH). Uses $HOME on the remote host.
REMOTE_RESOLVE_SNIPPET='
resolve_log_file() {
  local date="$1"
  local name="unimacs-${date}.log"
  local best="" best_mtime=0 f m
  for f in \
    "$HOME"/Library/Containers/com.*.unimacs*/Data/Library/Logs/Unimacs/"${name}" \
    "$HOME"/Library/Logs/Unimacs/"${name}"; do
    [[ -f "$f" ]] || continue
    if stat -c %Y "$f" >/dev/null 2>&1; then
      m=$(stat -c %Y "$f" 2>/dev/null || echo 0)
    else
      m=$(stat -f %m "$f" 2>/dev/null || echo 0)
    fi
    if [[ -z "$best" || "$m" -gt "$best_mtime" ]]; then
      best="$f"
      best_mtime="$m"
    fi
  done
  [[ -n "$best" ]] && echo "$best"
}

list_log_dirs() {
  ls -la "$HOME"/Library/Containers/com.*.unimacs*/Data/Library/Logs/Unimacs 2>/dev/null \
    || ls -la "$HOME"/Library/Logs/Unimacs 2>/dev/null \
    || echo "(no Unimacs log dirs found — has the app logged on the remote?)"
}
'

# Optional per-side filter. Empty pattern => pass everything through.
filter() {
  if [[ -n "$GREP_RE" ]]; then grep -E -- "$GREP_RE"; else cat; fi
}

LOCAL_FILE="$(resolve_local_log_file "$DATE" || true)"

if [[ "$FOLLOW" -eq 1 ]]; then
  if [[ -z "$LOCAL_FILE" ]]; then
    echo "warning: local log not found yet for date=${DATE} (will wait once the app logs)" >&2
    echo "         searched: ~/Library/Containers/com.*.unimacs*/Data/Library/Logs/Unimacs/" >&2
  else
    echo "── local log: ${LOCAL_FILE} ──" >&2
  fi
  echo "── live: [L] $(scutil --get ComputerName 2>/dev/null || hostname -s)   date=${DATE} ──" >&2
  NUM_REMOTES=${#REMOTE_ALIASES[@]}
  for ((i=0; i<NUM_REMOTES; i++)); do
    echo "       - [${REMOTE_ALIASES[i]}] ${REMOTE_TARGETS[i]}" >&2
  done
  echo "   (Ctrl-C to stop)" >&2

  PIDS=()
  cleanup() { for p in "${PIDS[@]:-}"; do kill "$p" 2>/dev/null || true; done; }
  trap cleanup EXIT INT TERM

  if [[ -n "$LOCAL_FILE" ]]; then
    ( tail -n +1 -F "$LOCAL_FILE" 2>/dev/null | filter | sed -u 's/^/[L] /' ) &
    PIDS+=($!)
  fi

  for ((i=0; i<NUM_REMOTES; i++)); do
    r_alias="${REMOTE_ALIASES[i]}"
    r_target="${REMOTE_TARGETS[i]}"
    (
      ssh -o ConnectTimeout=30 "${r_target}" "${REMOTE_RESOLVE_SNIPPET}
         f=\$(resolve_log_file '${DATE}')
         if [[ -z \"\$f\" ]]; then echo \"remote log not found on ${r_alias} for date=${DATE}\" >&2; exit 1; fi
         echo \"── [${r_alias}] remote log: \$f ──\" >&2
         tail -n +1 -F \"\$f\"" \
         | filter | sed -u "s/^/[${r_alias}] /"
    ) &
    PIDS+=($!)
  done

  wait
  exit 0
fi

# ---- Snapshot mode ----
TMP_DIR="$(mktemp -d -t unimacs-logs-XXXXXX)"
trap 'rm -rf "$TMP_DIR"' EXIT

if [[ -z "$LOCAL_FILE" ]]; then
  echo "warning: local log not found for date=${DATE}" >&2
  echo "         searched: ~/Library/Containers/com.*.unimacs*/Data/Library/Logs/Unimacs/" >&2
else
  echo "── local log: ${LOCAL_FILE} ──" >&2
fi

PIDS=()
NUM_REMOTES=${#REMOTE_ALIASES[@]}

for ((i=0; i<NUM_REMOTES; i++)); do
  r_alias="${REMOTE_ALIASES[i]}"
  r_target="${REMOTE_TARGETS[i]}"
  (
    if ! ssh -o ConnectTimeout=8 "${r_target}" "${REMOTE_RESOLVE_SNIPPET}
       f=\$(resolve_log_file '${DATE}')
       if [[ -z \"\$f\" ]]; then list_log_dirs; exit 1; fi
       echo \"── [${r_alias}] remote log: \$f ──\" >&2
       cat \"\$f\"" > "${TMP_DIR}/${r_alias}.log" 2> "${TMP_DIR}/${r_alias}.err"; then
      exit 1
    fi
  ) &
  PIDS+=($!)
done

FAILED_REMOTES=()
for ((i=0; i<NUM_REMOTES; i++)); do
  pid="${PIDS[i]}"
  r_alias="${REMOTE_ALIASES[i]}"
  r_target="${REMOTE_TARGETS[i]}"
  
  if ! wait "$pid"; then
    FAILED_REMOTES+=("${r_alias}")
    err_file="${TMP_DIR}/${r_alias}.err"
    echo "error: could not read remote log from ${r_alias} (${r_target}) for date=${DATE}." >&2
    if [[ -f "${err_file}" ]]; then
      echo "       ssh said: $(tr '\n' ' ' < "${err_file}" | sed 's/  */ /g')" >&2
    fi
  else
    err_file="${TMP_DIR}/${r_alias}.err"
    if [[ -f "${err_file}" ]]; then
      cat "${err_file}" >&2
    fi
  fi
done

if [[ ${#FAILED_REMOTES[@]} -gt 0 ]]; then
  echo "error: Failed to fetch logs from one or more remote devices." >&2
  exit 1
fi

merge() {
  {
    [[ -n "$LOCAL_FILE" && -f "$LOCAL_FILE" ]] && filter < "$LOCAL_FILE" | sed 's/^/[L] /'
    for ((i=0; i<NUM_REMOTES; i++)); do
      r_alias="${REMOTE_ALIASES[i]}"
      log_file="${TMP_DIR}/${r_alias}.log"
      [[ -f "$log_file" ]] && filter < "$log_file" | sed "s/^/[${r_alias}] /"
    done
  } | sort -s -k2,3
}

if [[ -n "$OUT_FILE" ]]; then
  merge | tee "$OUT_FILE"
  # Construct a human-readable list of remotes for the summary
  REMOTE_LIST=""
  for ((i=0; i<NUM_REMOTES; i++)); do
    REMOTE_LIST="${REMOTE_LIST} + [${REMOTE_ALIASES[i]}]"
  done
  echo "── merged ${DATE}: [L] local${REMOTE_LIST}  →  ${OUT_FILE} ──" >&2
else
  merge
fi
