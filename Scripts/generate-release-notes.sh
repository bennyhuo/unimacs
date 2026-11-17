#!/bin/bash
#
# generate-release-notes.sh — Generate GitHub Release notes for ad-hoc signed
# Unimacs Distribute builds, including Gatekeeper bypass and Accessibility setup
# instructions, or run version/prerelease tag helpers for CI workflows.
#
# Usage:
#   ./Scripts/generate-release-notes.sh --tag <tag> [options]
#   ./Scripts/generate-release-notes.sh --normalize-version <tag>
#   ./Scripts/generate-release-notes.sh --is-prerelease <tag>
#
# Options:
#   -t, --tag <tag>                   Release tag (e.g. v1.4.0) [required for notes]
#   -a, --asset <filename>            Zip asset filename (default: unimacs-<tag>-macos-universal.zip)
#   -s, --sha256 <hash>               SHA-256 checksum of the zip asset
#   -c, --changelog-file <path>       Auto-generated changelog markdown file
#   -e, --existing-notes-file <path>  Existing release body markdown file (idempotent update)
#   -o, --out <path>                  Output markdown file path (default: stdout)
#       --normalize-version <tag>     Print normalized version (strip leading 'v'/'V' before digits)
#       --is-prerelease <tag>         Print 'true' or 'false' based on tag prerelease suffix
#   -h, --help                        Show this help message
#

set -euo pipefail

usage() {
  cat <<EOF
Usage: $(basename "$0") --tag <tag> [options]
       $(basename "$0") --normalize-version <tag>
       $(basename "$0") --is-prerelease <tag>

Generate GitHub Release notes for an ad-hoc signed Unimacs Distribute build.

Options:
  -t, --tag <tag>                   Release tag (required for generating notes)
  -a, --asset <filename>            Asset filename (default: unimacs-<tag>-macos-universal.zip)
  -s, --sha256 <hash>               SHA-256 hex digest of the zip asset
  -c, --changelog-file <path>       Path to auto-generated changelog markdown
  -e, --existing-notes-file <path>  Path to existing release body markdown
  -o, --out <path>                  Write output to file instead of stdout
      --normalize-version <tag>     Normalize a git tag to CFBundleShortVersionString
      --is-prerelease <tag>         Detect whether a git tag represents a pre-release
  -h, --help                        Show this help message
EOF
}

trim_whitespace() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "${s}"
}

normalize_version() {
  local raw
  raw="$(trim_whitespace "$1")"
  if [[ -z "${raw}" ]]; then
    echo "error: Tag/version cannot be empty." >&2
    return 1
  fi
  if [[ "${raw}" =~ ^[vV]([0-9].*)$ ]]; then
    printf '%s\n' "${BASH_REMATCH[1]}"
  else
    printf '%s\n' "${raw}"
  fi
}

is_prerelease_tag() {
  local raw lower
  raw="$(trim_whitespace "$1")"
  if [[ -z "${raw}" ]]; then
    echo "error: Tag cannot be empty." >&2
    return 1
  fi
  lower="$(printf '%s' "${raw}" | tr '[:upper:]' '[:lower:]')"
  case "${lower}" in
    *-*)
      printf 'true\n'
      ;;
    *)
      printf 'false\n'
      ;;
  esac
}

TAG=""
ASSET_NAME=""
SHA256=""
CHANGELOG_FILE=""
EXISTING_NOTES_FILE=""
OUT_FILE=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --normalize-version)
      if [[ $# -lt 2 ]]; then
        echo "error: Missing argument for $1" >&2
        exit 1
      fi
      normalize_version "$2"
      exit $?
      ;;
    --is-prerelease)
      if [[ $# -lt 2 ]]; then
        echo "error: Missing argument for $1" >&2
        exit 1
      fi
      is_prerelease_tag "$2"
      exit $?
      ;;
    -t|--tag)
      if [[ $# -lt 2 ]]; then
        echo "error: Missing argument for $1" >&2
        exit 1
      fi
      TAG="$(trim_whitespace "$2")"
      shift 2
      ;;
    -a|--asset)
      if [[ $# -lt 2 ]]; then
        echo "error: Missing argument for $1" >&2
        exit 1
      fi
      ASSET_NAME="$(trim_whitespace "$2")"
      shift 2
      ;;
    -s|--sha256)
      if [[ $# -lt 2 ]]; then
        echo "error: Missing argument for $1" >&2
        exit 1
      fi
      SHA256="$(trim_whitespace "$2")"
      shift 2
      ;;
    -c|--changelog-file)
      if [[ $# -lt 2 ]]; then
        echo "error: Missing argument for $1" >&2
        exit 1
      fi
      CHANGELOG_FILE="$2"
      shift 2
      ;;
    -e|--existing-notes-file)
      if [[ $# -lt 2 ]]; then
        echo "error: Missing argument for $1" >&2
        exit 1
      fi
      EXISTING_NOTES_FILE="$2"
      shift 2
      ;;
    -o|--out)
      if [[ $# -lt 2 || -z "$2" ]]; then
        echo "error: Missing argument for $1" >&2
        exit 1
      fi
      OUT_FILE="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "error: Unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

if [[ -z "${TAG}" ]]; then
  echo "error: --tag <tag> is required." >&2
  exit 1
fi

if [[ -z "${ASSET_NAME}" ]]; then
  ASSET_NAME="unimacs-${TAG}-macos-universal.zip"
fi

TMP_DIR="$(mktemp -d -t unimacs-release-notes-XXXXXX)"
trap 'rm -rf "${TMP_DIR}"' EXIT

GUIDE_FILE="${TMP_DIR}/guide.md"
RENDERED_FILE="${TMP_DIR}/rendered.md"

cat > "${GUIDE_FILE}" <<EOF
<!-- unimacs-adhoc-install-guide -->
## Installation & How to Run (Ad-Hoc Signed Build)

> [!IMPORTANT]
> **No Apple Developer Certificate / Notarization:** \`unimacs.app\` is currently built with the \`Distribute\` configuration using **ad-hoc signing (\`-\`)** and is **not signed or notarized with an Apple Developer ID certificate**. Because macOS Gatekeeper quarantines downloaded archives by default, opening \`unimacs.app\` directly may show *"Apple could not verify “unimacs” is free of malware"* or *"“unimacs” is damaged and can’t be opened"*. Follow the steps below to run it.

1. **Download & Install**: Download \`${ASSET_NAME}\` (Universal Binary \`arm64\` + \`x86_64\`, requires macOS 13.5+), unzip it, and drag \`unimacs.app\` into \`/Applications\`.
2. **Clear macOS Gatekeeper Quarantine** before launching:
   \`\`\`bash
   xattr -cr /Applications/unimacs.app
   \`\`\`
   *Alternative (GUI)*: Try opening \`unimacs.app\` once, dismiss the warning, then go to **System Settings → Privacy & Security**, scroll down to the Security section, and click **Open Anyway**.
3. **Launch & Grant Accessibility Permission**: Open \`/Applications/unimacs.app\` (it runs in the macOS menu bar), then grant **Accessibility** permission in **System Settings → Privacy & Security → Accessibility** on each Mac.
   * *Note when upgrading*: Because ad-hoc builds have no persistent Team ID, if keyboard/mouse sharing stops working after replacing an older build, remove \`unimacs\` (\`-\`) from **Accessibility** and re-add \`/Applications/unimacs.app\`.

<details>
<summary><strong>🇨🇳 中文安装与运行说明（无开发者证书 / Ad-hoc 签名）</strong></summary>

> 本应用当前通过 \`Distribute\` 配置使用 **Ad-hoc 签名（\`-\`）** 构建，**尚未使用 Apple Developer ID 证书签名和公证**。直接从浏览器下载解压后，macOS Gatekeeper 会拦截运行并提示“无法验证开发者”、“Apple 无法检查其是否包含恶意软件”或“已损坏，无法打开”。请按以下步骤运行：

1. **下载并安装**：下载 \`${ASSET_NAME}\`（Universal 通用二进制 \`arm64\` + \`x86_64\`，需 macOS 13.5 及以上），解压后将 \`unimacs.app\` 拖入 \`/Applications\`（应用程序）目录。
2. **移除系统隔离（Quarantine）属性**：在终端执行以下命令：
   \`\`\`bash
   xattr -cr /Applications/unimacs.app
   \`\`\`
   *图形界面备选方式*：先双击尝试打开一次 \`unimacs.app\` 并关闭弹窗，随后打开 **系统设置 → 隐私与安全性**，在页面下方找到拦截提示并点击 **仍要打开（Open Anyway）**。
3. **启动并授予辅助功能权限**：运行 \`/Applications/unimacs.app\`（启动后图标位于顶部菜单栏），并在所有需要共享键鼠的 Mac 上前往 **系统设置 → 隐私与安全性 → 辅助功能** 勾选允许 \`unimacs\`。
   * *更新版本提示*：由于没有开发者证书，每次覆盖更新 ad-hoc 版本后如遇键鼠无法控制，请在 **辅助功能** 列表中选中 \`unimacs\` 点 \`-\` 移除后重新添加一次。

</details>
EOF

if [[ -n "${SHA256}" ]]; then
  cat >> "${GUIDE_FILE}" <<EOF

### Package Checksum

| File | Architecture | SHA-256 |
| --- | --- | --- |
| \`${ASSET_NAME}\` | Universal (\`arm64\` + \`x86_64\`) | \`${SHA256}\` |
EOF
fi

printf '\n<!-- /unimacs-adhoc-install-guide -->\n' >> "${GUIDE_FILE}"

/usr/bin/perl -e '
  use strict;
  use warnings;

  my ($guide_path, $existing_path, $changelog_path) = @ARGV;

  sub slurp {
    my ($path) = @_;
    return "" unless defined($path) && length($path) && -f $path;
    open my $fh, "<", $path or die "Failed to open $path: $!\n";
    local $/;
    my $data = <$fh>;
    close $fh;
    return defined($data) ? $data : "";
  }

  my $guide = slurp($guide_path);
  $guide =~ s/[ \t\r\n]+\z//;

  my $existing = slurp($existing_path);
  if ($existing =~ /\S/) {
    my $start_marker = "<!-- unimacs-adhoc-install-guide -->";
    my $end_marker   = "<!-- /unimacs-adhoc-install-guide -->";
    my $s = index($existing, $start_marker);
    my $e = ($s >= 0) ? index($existing, $end_marker, $s) : -1;

    if ($s >= 0 && $e >= 0) {
      my $before = substr($existing, 0, $s);
      my $after  = substr($existing, $e + length($end_marker));
      $before =~ s/[ \t]+\z//;
      $after  =~ s/\A[ \t]*\r?\n?//;
      my $out = $before . $guide;
      $out .= "\n" . $after if length($after);
      $out .= "\n" unless $out =~ /\n\z/;
      print $out;
    } else {
      $existing =~ s/[ \t\r\n]+\z//;
      print $existing . "\n\n---\n\n" . $guide . "\n";
    }
    exit 0;
  }

  my $out = $guide;
  my $changelog = slurp($changelog_path);
  $changelog =~ s/\A[ \t\r\n]+//;
  $changelog =~ s/[ \t\r\n]+\z//;
  if (length($changelog)) {
    if ($changelog =~ /^## /) {
      $out .= "\n\n" . $changelog;
    } else {
      $out .= "\n\n## What\x27s Changed\n\n" . $changelog;
    }
  }
  print $out . "\n";
' "${GUIDE_FILE}" "${EXISTING_NOTES_FILE}" "${CHANGELOG_FILE}" > "${RENDERED_FILE}"

if [[ -n "${OUT_FILE}" ]]; then
  mkdir -p "$(dirname "${OUT_FILE}")"
  cp "${RENDERED_FILE}" "${OUT_FILE}"
else
  cat "${RENDERED_FILE}"
fi
