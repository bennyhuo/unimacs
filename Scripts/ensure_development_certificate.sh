#!/bin/bash
#
# Checks (and optionally cleans up) revoked or expired Apple Development
# identities before Debug builds when using Automatic code signing.
#
# By default (AUTO_CLEAN_REVOKED_CERTIFICATES=NO), this script runs in read-only
# mode and never deletes identities or provisioning profiles from your Mac.
#
# Free Apple ID / Personal Team users whose 7-day development certificates
# frequently expire or get superseded can opt into automatic cleanup by setting:
#   AUTO_CLEAN_REVOKED_CERTIFICATES = YES
# in their untracked `Local.xcconfig`, or by invoking this script with `--clean`.

set -uo pipefail

FORCE_CLEAN=false
if [[ "${1:-}" == "--clean" ]]; then
  FORCE_CLEAN=true
fi

CONFIGURATION="${CONFIGURATION:-Debug}"
CODE_SIGN_STYLE="${CODE_SIGN_STYLE:-}"
DEVELOPMENT_TEAM="${DEVELOPMENT_TEAM:-}"
PRODUCT_BUNDLE_IDENTIFIER="${PRODUCT_BUNDLE_IDENTIFIER:-}"
AUTO_CLEAN="${AUTO_CLEAN_REVOKED_CERTIFICATES:-NO}"

if [[ "${FORCE_CLEAN}" == true ]]; then
  AUTO_CLEAN="YES"
fi

if [[ "${CONFIGURATION}" != "Debug" && "${FORCE_CLEAN}" != true ]]; then
  exit 0
fi

if [[ "${CODE_SIGN_STYLE}" != "Automatic" && "${FORCE_CLEAN}" != true ]]; then
  exit 0
fi

if [[ -z "${DEVELOPMENT_TEAM}" ]]; then
  exit 0
fi

LOGIN_KEYCHAIN="${HOME}/Library/Keychains/login.keychain-db"

log() {
  echo "note: [ensure_development_certificate] $*"
}

warn() {
  echo "warning: [ensure_development_certificate] $*"
}

parse_identity_line() {
  local line="$1"
  [[ "${line}" =~ ^[[:space:]]+[0-9]+\)[[:space:]]+([A-F0-9]{40})[[:space:]]+\"([^\"]+)\"(.*)$ ]] || return 1
  IDENTITY_HASH="${BASH_REMATCH[1]}"
  IDENTITY_LABEL="${BASH_REMATCH[2]}"
  IDENTITY_STATUS="${BASH_REMATCH[3]}"
  return 0
}

TMP_DIR="$(mktemp -d -t unimacs-cert-check-XXXXXX)"
trap 'rm -rf "${TMP_DIR}"' EXIT

extract_team_certs() {
  security find-certificate -a -Z -c "Apple Development:" -p "${LOGIN_KEYCHAIN}" 2>/dev/null \
    | awk -v outdir="${TMP_DIR}" '
      /^SHA-1 hash:/ { hash = $3 }
      /^-----BEGIN CERTIFICATE-----/ {
        if (hash != "") {
          file = outdir "/cert_" hash ".pem"
          in_cert = 1
        }
      }
      in_cert { print > file }
      /^-----END CERTIFICATE-----/ {
        if (in_cert) {
          close(file)
          in_cert = 0
        }
      }
    ' || true

  security find-certificate -c "Apple Worldwide Developer Relations Certification Authority" \
    -p /System/Library/Keychains/SystemRootCertificates.keychain \
       "${LOGIN_KEYCHAIN}" \
       /Library/Keychains/System.keychain \
    > "${TMP_DIR}/wwdr.pem" 2>/dev/null || true
}

cert_belongs_to_team() {
  local cert_file="$1"
  local team="$2"
  [[ -f "${cert_file}" ]] || return 1
  local subject=""
  subject="$(openssl x509 -in "${cert_file}" -noout -subject 2>/dev/null || true)"
  [[ "${subject}" == *"OU=${team}"* ]]
}

is_cert_revoked_via_ocsp() {
  local cert_file="$1"
  local wwdr_file="${TMP_DIR}/wwdr.pem"
  [[ -f "${cert_file}" && -s "${wwdr_file}" ]] || return 1

  local ocsp_url=""
  ocsp_url="$(openssl x509 -in "${cert_file}" -noout -ocsp_uri 2>/dev/null || true)"
  [[ -n "${ocsp_url}" ]] || return 1

  local ocsp_out=""
  ocsp_out="$(
    openssl ocsp -issuer "${wwdr_file}" -cert "${cert_file}" \
      -url "${ocsp_url}" -CAfile "${wwdr_file}" -noverify -timeout 5 2>&1 || true
  )"

  [[ "${ocsp_out}" == *": revoked"* ]]
}

cert_not_before_epoch() {
  local cert_file="$1"
  local raw_date=""
  raw_date="$(openssl x509 -in "${cert_file}" -noout -startdate 2>/dev/null | sed 's/^notBefore=//' || true)"
  if [[ -n "${raw_date}" ]]; then
    date -j -f "%b %e %T %Y %Z" "${raw_date}" "+%s" 2>/dev/null || echo 0
  else
    echo 0
  fi
}

delete_identity() {
  local hash="$1"
  security delete-identity -Z "${hash}" "${LOGIN_KEYCHAIN}" >/dev/null 2>&1 \
    || security delete-identity -Z "${hash}" >/dev/null 2>&1 \
    || true
  rm -f "${TMP_DIR}/cert_${hash}.pem"
}

has_valid_team_identity() {
  local line=""
  local seen_hashes=" "

  while IFS= read -r line; do
    parse_identity_line "${line}" || continue
    [[ "${IDENTITY_LABEL}" == Apple\ Development:* ]] || continue
    [[ "${IDENTITY_STATUS}" == *CSSMERR_* ]] && continue
    [[ "${seen_hashes}" == *" ${IDENTITY_HASH} "* ]] && continue
    seen_hashes="${seen_hashes}${IDENTITY_HASH} "
    local cert_file="${TMP_DIR}/cert_${IDENTITY_HASH}.pem"
    cert_belongs_to_team "${cert_file}" "${DEVELOPMENT_TEAM}" || continue
    is_cert_revoked_via_ocsp "${cert_file}" && continue
    return 0
  done < <(security find-identity -v -p codesigning "${LOGIN_KEYCHAIN}" 2>/dev/null || true)

  return 1
}

# Read-only mode (default): warn if stale/revoked certificates are blocking signing, never mutate Keychain.
if [[ "${AUTO_CLEAN}" != "YES" ]]; then
  extract_team_certs
  if ! has_valid_team_identity; then
    warn "No valid Apple Development certificate found for team ${DEVELOPMENT_TEAM} (existing certificate may be expired or revoked)."
    warn "To clean revoked Personal Team certificates automatically, set AUTO_CLEAN_REVOKED_CERTIFICATES = YES in Local.xcconfig or run Scripts/ensure_development_certificate.sh --clean."
  fi
  exit 0
fi

sanitize_team_identities() {
  local removed=false
  local line=""
  local seen_hashes=" "
  local valid_hashes=()

  extract_team_certs

  while IFS= read -r line; do
    parse_identity_line "${line}" || continue
    [[ "${IDENTITY_LABEL}" == Apple\ Development:* ]] || continue
    [[ "${seen_hashes}" == *" ${IDENTITY_HASH} "* ]] && continue
    seen_hashes="${seen_hashes}${IDENTITY_HASH} "

    local cert_file="${TMP_DIR}/cert_${IDENTITY_HASH}.pem"
    cert_belongs_to_team "${cert_file}" "${DEVELOPMENT_TEAM}" || continue

    if [[ "${IDENTITY_STATUS}" == *CSSMERR_* ]]; then
      log "Removing invalid identity (${IDENTITY_STATUS}): ${IDENTITY_LABEL} [${IDENTITY_HASH}]"
      delete_identity "${IDENTITY_HASH}"
      removed=true
      continue
    fi

    if is_cert_revoked_via_ocsp "${cert_file}"; then
      log "Removing OCSP-revoked identity: ${IDENTITY_LABEL} [${IDENTITY_HASH}]"
      delete_identity "${IDENTITY_HASH}"
      removed=true
      continue
    fi

    valid_hashes+=("${IDENTITY_HASH}")
  done < <(security find-identity -p codesigning "${LOGIN_KEYCHAIN}" 2>/dev/null || true)

  # If multiple valid identities exist for the same Personal Team on this machine,
  # keep only the newest one so codesign never picks a superseded identity.
  if [[ ${#valid_hashes[@]} -gt 1 ]]; then
    local newest_hash=""
    local newest_epoch=-1
    local h=""
    for h in "${valid_hashes[@]}"; do
      local epoch
      epoch="$(cert_not_before_epoch "${TMP_DIR}/cert_${h}.pem")"
      if [[ "${epoch}" -gt "${newest_epoch}" ]]; then
        newest_epoch="${epoch}"
        newest_hash="${h}"
      fi
    done

    for h in "${valid_hashes[@]}"; do
      if [[ "${h}" != "${newest_hash}" ]]; then
        log "Removing older duplicate identity [${h}] in favor of newest [${newest_hash}]"
        delete_identity "${h}"
        removed=true
      fi
    done
  fi

  [[ "${removed}" == true ]]
}

remove_stale_team_identities() {
  local line=""
  local seen_hashes=" "

  while IFS= read -r line; do
    parse_identity_line "${line}" || continue
    [[ "${IDENTITY_LABEL}" == Apple\ Development:* ]] || continue
    [[ "${seen_hashes}" == *" ${IDENTITY_HASH} "* ]] && continue
    seen_hashes="${seen_hashes}${IDENTITY_HASH} "
    cert_belongs_to_team "${TMP_DIR}/cert_${IDENTITY_HASH}.pem" "${DEVELOPMENT_TEAM}" || continue

    log "Removing stale identity for team ${DEVELOPMENT_TEAM}: ${IDENTITY_LABEL} [${IDENTITY_HASH}]"
    delete_identity "${IDENTITY_HASH}"
  done < <(security find-identity -p codesigning "${LOGIN_KEYCHAIN}" 2>/dev/null || true)
}

clean_provisioning_profiles() {
  local bundle_id="$1"
  local profile_dirs=(
    "${HOME}/Library/MobileDevice/Provisioning Profiles"
    "${HOME}/Library/Developer/Xcode/UserData/Provisioning Profiles"
  )
  local dir=""
  local profile=""

  [[ -n "${bundle_id}" ]] || return 0

  for dir in "${profile_dirs[@]}"; do
    [[ -d "${dir}" ]] || continue
    for profile in "${dir}"/*.mobileprovision "${dir}"/*.provisionprofile; do
      [[ -f "${profile}" ]] || continue
      if grep -aq "<string>${DEVELOPMENT_TEAM}\.${bundle_id}</string>" "${profile}" 2>/dev/null \
        || grep -aq "${bundle_id}" "${profile}" 2>/dev/null; then
        log "Removing stale provisioning profile: $(basename "${profile}")"
        rm -f "${profile}"
      fi
    done
  done
}

log "Checking Apple Development certificate for team ${DEVELOPMENT_TEAM} (auto-clean enabled)..."

if sanitize_team_identities; then
  clean_provisioning_profiles "${PRODUCT_BUNDLE_IDENTIFIER}"
fi

if has_valid_team_identity; then
  log "Valid Apple Development identity found."
  exit 0
fi

log "No valid Apple Development identity for team ${DEVELOPMENT_TEAM}; clearing stale identities."
remove_stale_team_identities
clean_provisioning_profiles "${PRODUCT_BUNDLE_IDENTIFIER}"
log "Xcode will create a new certificate during code signing."
log "Command-line builds: use Scripts/build-debug.sh or pass -allowProvisioningUpdates to xcodebuild."

exit 0
