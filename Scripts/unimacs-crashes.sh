#!/bin/bash
#
# unimacs-crashes.sh — Fetch, parse, and export Unimacs crash logs (.ips/.crash)
# from local or remote Macs.
#
# Usage:
#   Scripts/unimacs-crashes.sh [options] [<remote-ssh-target-or-alias> ...]
#
#   [<remote-ssh-target-or-alias> ...] Target device aliases (from devices.txt) or SSH targets.
#                                      Use "local" for the current machine.
#                                      Defaults to "local" and all devices in devices.txt.
#
# Options:
#   -n, --count <num>    Number of recent crash reports to inspect per target (default: 1).
#   -o, --out   <dir>    Download/export crash log files to <dir>.
#   -r, --raw            Output raw file content instead of formatted backtrace summary.
#   -l, --local-only     Only inspect the local machine.
#   -h, --help           Show this help message.
#
# Examples:
#   Scripts/unimacs-crashes.sh                      # Inspect latest crash on local & all devices
#   Scripts/unimacs-crashes.sh MINI                 # Inspect latest crash on Mac mini
#   Scripts/unimacs-crashes.sh -n 3 MINI            # Inspect top 3 recent crashes on Mac mini
#   Scripts/unimacs-crashes.sh -o /tmp/crashes MINI # Export crash logs from Mac mini to /tmp/crashes
#   Scripts/unimacs-crashes.sh --raw local          # Output raw content of latest local crash log

set -euo pipefail

COUNT=1
OUT_DIR=""
RAW=0
LOCAL_ONLY=0
TARGETS=()

print_help() {
  sed -n '2,/^set -euo/p' "$0" | sed 's/^# \{0,1\}//; s/^#//' | sed '$d'
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -n|--count)      COUNT="${2:?--count needs a number}"; shift 2 ;;
    -o|--out)        OUT_DIR="${2:?--out needs a directory}"; shift 2 ;;
    -r|--raw)        RAW=1; shift ;;
    -l|--local-only) LOCAL_ONLY=1; shift ;;
    -h|--help)       print_help; exit 0 ;;
    -*)              echo "Unknown option: $1" >&2; echo "Try: $0 --help" >&2; exit 2 ;;
    *)               TARGETS+=("$1"); shift ;;
  esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEVICES_FILE="${SCRIPT_DIR}/devices.txt"

resolve_target() {
  local query="$1"
  if [[ "${query}" == "local" || "${query}" == "localhost" || "${query}" == "127.0.0.1" ]]; then
    echo "LOCAL local"
    return 0
  fi
  if [[ -f "${DEVICES_FILE}" ]]; then
    while read -r line || [[ -n "${line}" ]]; do
      line=$(echo "${line}" | tr -d '\r')
      if [[ -z "${line}" || "${line}" =~ ^[[:space:]]*# ]]; then
        continue
      fi
      dev_alias=""
      ssh_target=""
      read -r dev_alias ssh_target <<< "${line}"
      if [[ "${dev_alias}" == "${query}" || "${ssh_target}" == "${query}" ]]; then
        echo "${dev_alias} ${ssh_target}"
        return 0
      fi
    done < "${DEVICES_FILE}"
  fi
  echo "${query} ${query}"
}

RESOLVED_TARGETS=()

if [[ ${LOCAL_ONLY} -eq 1 ]]; then
  RESOLVED_TARGETS=("LOCAL local")
elif [[ ${#TARGETS[@]} -gt 0 ]]; then
  for t in "${TARGETS[@]}"; do
    RESOLVED_TARGETS+=("$(resolve_target "$t")")
  done
else
  # Default: local + all from devices.txt
  RESOLVED_TARGETS+=("LOCAL local")
  if [[ -f "${DEVICES_FILE}" ]]; then
    while read -r line || [[ -n "${line}" ]]; do
      line=$(echo "${line}" | tr -d '\r')
      if [[ -z "${line}" || "${line}" =~ ^[[:space:]]*# ]]; then
        continue
      fi
      dev_alias=""
      ssh_target=""
      read -r dev_alias ssh_target <<< "${line}"
      RESOLVED_TARGETS+=("${dev_alias} ${ssh_target}")
    done < "${DEVICES_FILE}"
  fi
fi

# Python parser script embedded to format .ips / .crash files cleanly
parse_crash_content() {
  python3 -c '
import sys, json

content = sys.stdin.read()
if not content.strip():
    print("Empty crash content.")
    sys.exit(0)

# Try JSON / IPS parsing
try:
    first_newline = content.find("\n")
    if first_newline != -1 and content[:first_newline].strip().startswith("{"):
        header = json.loads(content[:first_newline])
        main_data = json.loads(content[first_newline+1:])
    else:
        header = {}
        main_data = json.loads(content)

    print("\033[1;36m=== CRASH REPORT SUMMARY ===\033[0m")
    if "bug_type" in header:
        print("Bug Type:        {}".format(header.get("bug_type")))
    if "timestamp" in header:
        print("Timestamp:       {}".format(header.get("timestamp")))
    
    proc_name = main_data.get("procName") or main_data.get("process", {}).get("procName")
    pid = main_data.get("pid")
    if proc_name:
        print("Process:         {} [{}]".format(proc_name, pid if pid else "unknown"))

    exc = main_data.get("exception", {})
    if exc:
        print("Exception Type:  \033[1;31m{}\033[0m ({})".format(exc.get("type", "N/A"), exc.get("signal", "N/A")))
        if "subtype" in exc:
            print("Subtype:         {}".format(exc.get("subtype")))

    term = main_data.get("termination", {})
    if term:
        print("Termination:     {} (code {})".format(term.get("indicator", "N/A"), term.get("code", "N/A")))

    ft = main_data.get("faultingThread")
    threads = main_data.get("threads", [])
    images = main_data.get("usedImages", [])

    if ft is not None and ft < len(threads):
        t = threads[ft]
        q_name = t.get("queue", "N/A")
        t_name = t.get("name", "")
        name_info = f", Name: {t_name}" if t_name else ""
        print(f"\n\033[1;33m=== FAULTING THREAD #{ft} (Queue: {q_name}{name_info}) ===\033[0m")
        print("Backtrace:")
        for i, fr in enumerate(t.get("frames", [])):
            img_idx = fr.get("imageIndex")
            img_name = images[img_idx].get("name", "unknown") if img_idx is not None and img_idx < len(images) else "unknown"
            sym = fr.get("symbol", "")
            loc = fr.get("symbolLocation", 0)
            offset = fr.get("imageOffset", 0)
            if sym:
                print(f"  #{i:<2d} {img_name:<32} {sym} + {loc}")
            else:
                print(f"  #{i:<2d} {img_name:<32} 0x{offset:x}")
    else:
        print("\nNo faulting thread stack trace found in JSON.")

except Exception as e:
    # Fallback to plain text .crash parser
    print("\033[1;36m=== RAW TEXT CRASH REPORT ===\033[0m")
    lines = content.splitlines()
    # Print header & backtrace lines
    in_crashed_thread = False
    printed_lines = 0
    for line in lines:
        if any(k in line for k in ["Process:", "Path:", "Identifier:", "Version:", "Code Type:", "Exception Type:", "Exception Codes:", "Crashed Thread:"]):
            print(line)
        elif "Crashed:" in line or "State when crashed:" in line:
            in_crashed_thread = True
            print("\n" + line)
        elif in_crashed_thread:
            if line.startswith("Thread ") or line.startswith("Binary Images:"):
                in_crashed_thread = False
            else:
                print(line)
                printed_lines += 1
                if printed_lines > 40:
                    print("  ... [backtrace truncated]")
                    break
'
}

process_target() {
  local dev_alias="$1"
  local ssh_target="$2"

  echo -e "\n========================================================"
  echo -e "\033[1;32mTarget: [${dev_alias}] (${ssh_target})\033[0m"
  echo -e "========================================================"

  local find_cmd="find ~/Library/Logs/DiagnosticReports/ -maxdepth 1 -type f \( -iname '*unimacs*' -o -iname '*Unimacs*' \) 2>/dev/null | xargs ls -t 2>/dev/null | head -n ${COUNT}"
  local files=()

  if [[ "${dev_alias}" == "LOCAL" ]]; then
    while IFS= read -r f; do
      [[ -n "${f}" ]] && files+=("${f}")
    done < <(eval "${find_cmd}") || true
  else
    while IFS= read -r f; do
      [[ -n "${f}" ]] && files+=("${f}")
    done < <(ssh -o ConnectTimeout=5 "${ssh_target}" "${find_cmd}") || true
  fi

  if [[ ${#files[@]} -eq 0 || -z "${files[0]:-}" ]]; then
    echo "No unimacs crash reports found on ${dev_alias}."
    return 0
  fi

  for file_path in "${files[@]}"; do
    [[ -z "${file_path}" ]] && continue
    local file_name
    file_name="$(basename "${file_path}")"
    echo -e "\n\033[1;34mReport: ${file_path}\033[0m"

    local content=""
    if [[ "${dev_alias}" == "LOCAL" ]]; then
      content="$(cat "${file_path}")"
    else
      content="$(ssh "${ssh_target}" "cat '${file_path}'")"
    fi

    if [[ -n "${OUT_DIR}" ]]; then
      mkdir -p "${OUT_DIR}"
      local dest_path="${OUT_DIR}/${dev_alias}_${file_name}"
      if [[ "${dev_alias}" == "LOCAL" ]]; then
        cp "${file_path}" "${dest_path}"
      else
        scp -q "${ssh_target}:${file_path}" "${dest_path}"
      fi
      echo "Saved crash log to: ${dest_path}"
    fi

    if [[ ${RAW} -eq 1 ]]; then
      echo "${content}"
    else
      echo "${content}" | parse_crash_content
    fi
  done
}

for item in "${RESOLVED_TARGETS[@]}"; do
  dev_alias=$(echo "${item}" | awk '{print $1}')
  ssh_target=$(echo "${item}" | awk '{print $2}')
  process_target "${dev_alias}" "${ssh_target}"
done
