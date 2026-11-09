---
name: unimacs-scripts
description: Guidance on using the local and remote helper scripts located in the Scripts directory of the Unimacs project.
---

# Unimacs Helper Scripts

This skill documents the usage and purpose of the helper scripts in the [Scripts](Scripts) directory. These scripts simplify local building, VM deployment, SSH setup, and log merging/tailing.

---

## 1. build-debug.sh

**Path**: [build-debug.sh](Scripts/build-debug.sh)  
**Purpose**: A command-line wrapper for building the debug configuration of the Unimacs Xcode project. It automatically refreshes any invalid development certificates (by calling `ensure_development_certificate.sh`) before running the build.

### Usage
```bash
# Basic build using defaults (SCHEME=Unimacs, CONFIGURATION=Debug)
./Scripts/build-debug.sh

# Custom scheme or configuration via environment variables
SCHEME=Unimacs CONFIGURATION=Debug ./Scripts/build-debug.sh

# Passing extra arguments directly to xcodebuild
./Scripts/build-debug.sh -jobs 8
```

---

## 2. ensure_development_certificate.sh

**Path**: [ensure_development_certificate.sh](Scripts/ensure_development_certificate.sh)  
**Purpose**: Checks `Apple Development` signing identities for local Debug + Automatic signing builds. By default (`AUTO_CLEAN_REVOKED_CERTIFICATES = NO` in `Signing.xcconfig`), it runs in **read-only** mode and only prints a warning if a certificate is expired or revoked. When opted in (`AUTO_CLEAN_REVOKED_CERTIFICATES = YES` in `Local.xcconfig`, or invoked manually with `--clean`), it removes revoked/stale Personal Team certificates and stale provisioning profiles so Xcode can provision a fresh certificate automatically.

### Usage
Called automatically by `build-debug.sh` and the `Unimacs` scheme build pre-action, or manually when cleaning a revoked Personal Team certificate:
```bash
./Scripts/ensure_development_certificate.sh --clean
```

---

## 3. setup-ssh-peer.sh

**Path**: [setup-ssh-peer.sh](Scripts/setup-ssh-peer.sh)  
**Purpose**: A one-time setup script to configure passwordless SSH between the Host Mac and a remote Mac (e.g., guest VM or physical machine). This is required for `rebuild-and-deploy.sh` and `unimacs-logs.sh`.

### Usage
```bash
./Scripts/setup-ssh-peer.sh <host-or-ip> [ssh-alias] [user]
```

- **Arguments**:
  - `host-or-ip` (Required): The IP address or hostname of the remote machine.
  - `ssh-alias` (Default: `unimacs-peer`): The host alias name to add to your local `~/.ssh/config`.
  - `user` (Default: `$USER`): The remote username.

### Example
```bash
# Setup passwordless login for a remote Mac or guest VM
./Scripts/setup-ssh-peer.sh 192.168.64.10 unimacs-vm user
```
*Note: You will be prompted once for the remote user password to copy your public key.*

---

## 4. rebuild-and-deploy.sh

**Path**: [rebuild-and-deploy.sh](Scripts/rebuild-and-deploy.sh)  
**Purpose**: Rebuilds Unimacs locally, cleans local logs, and restarts local Unimacs. When one or more remote targets (or `--all`) are provided, it also deploys (syncs, deletes remote logs, and restarts Unimacs) on remote VMs/devices via SSH/rsync.
Specifically, it:
1. Locates the Xcode build settings to determine the local app paths.
2. Stops any running instances of `unimacs` on the local machine.
3. Rebuilds the debug product using `build-debug.sh`.
4. Deletes local logs to facilitate clean log collection.
5. Starts the local Unimacs application.
6. *(When remote targets or `--all` are passed)* Stops the running instance on each remote target, deletes remote logs, syncs the new build, and starts Unimacs there.

If no arguments are provided, it **only** rebuilds, cleans logs, and restarts Unimacs on the local Mac. Remote targets can be passed by alias from `devices.txt` (e.g., `VM1`, `MINI`), as direct SSH targets (`user@host`), or via `-a` / `--all` to deploy to every device in `devices.txt`.

### Usage
```bash
./Scripts/rebuild-and-deploy.sh [options] [<device-alias-or-ssh-target> ...]
```

- **Options**:
  - `-a, --all`: Also deploy to all devices listed in `Scripts/devices.txt`.
  - `-h, --help`: Show help text.

### Examples
```bash
# Rebuild, clean local logs, and restart locally only (default when no arguments are passed)
./Scripts/rebuild-and-deploy.sh

# Rebuild locally and also deploy to a specific device alias
./Scripts/rebuild-and-deploy.sh VM1

# Rebuild locally and deploy to all devices in devices.txt
./Scripts/rebuild-and-deploy.sh --all

# Rebuild locally and deploy to multiple specific devices or direct SSH targets
./Scripts/rebuild-and-deploy.sh VM1 MINI user@192.168.64.10
```

---

## 5. unimacs-logs.sh

**Path**: [unimacs-logs.sh](Scripts/unimacs-logs.sh)  
**Purpose**: Merges and sorts local Unimacs logs with one or more remote Macs' Unimacs logs into a single, unified, chronological timeline. It tags local lines with `[L]` and remote lines with `[<alias>]` (e.g., `[VM1]`, `[MINI]`). This is especially useful when diagnosing issues across interacting Unimacs instances (e.g., cursor handoffs or connection state transitions).

### Usage
```bash
./Scripts/unimacs-logs.sh [options] [<remote-ssh-target-or-alias> ...]
```

- **Options**:
  - `-f, --follow`: Live-follow both logs simultaneously (interleaves lines in real-time).
  - `-d, --date <date>`: Date to pull logs for in `yyyy-MM-dd` format. Defaults to today's date.
  - `-g, --grep <regex>`: Filter log lines matching the specified extended regex.
  - `-o, --out <file>`: Snapshot mode only: saves the merged logs to the specified file path.
  - `-h, --help`: Show help text.

### Examples
```bash
# Live tail and merge logs from local and VM1
./Scripts/unimacs-logs.sh -f VM1

# Query logs from a specific date, filter for connection-related events, and output to a file
./Scripts/unimacs-logs.sh -d 2026-07-05 -g "Network|Connection" -o /tmp/merged-connection.log VM1
```

---

## 6. unimacs-crashes.sh

**Path**: [unimacs-crashes.sh](Scripts/unimacs-crashes.sh)  
**Purpose**: Fetches, parses, and exports Unimacs crash log reports (`.ips` / `.crash`) from local or remote Macs configured in `devices.txt`. It automatically extracts and formats the crash header, exception type, signal, faulting thread, and thread backtrace.

### Usage
```bash
./Scripts/unimacs-crashes.sh [options] [<remote-ssh-target-or-alias> ...]
```

- **Options**:
  - `-n, --count <num>`: Number of recent crash reports to inspect per target (default: 1).
  - `-o, --out <dir>`: Download/export crash log files to `<dir>`.
  - `-r, --raw`: Output raw file content instead of formatted backtrace summary.
  - `-l, --local-only`: Only inspect the local machine.
  - `-h, --help`: Show help text.

### Examples
```bash
# Inspect latest crash on local machine and all remote targets
./Scripts/unimacs-crashes.sh

# Inspect latest crash report on Mac mini
./Scripts/unimacs-crashes.sh MINI

# Export recent crash reports from Mac mini to a local directory
./Scripts/unimacs-crashes.sh -n 3 -o /tmp/crashes MINI
```

---

## 7. package-distribute.sh

**Path**: [package-distribute.sh](Scripts/package-distribute.sh)  
**Purpose**: Builds Unimacs using the `Distribute` configuration (Universal Binary `arm64` + `x86_64`, Ad-hoc signed with `-` and no Apple Developer Team requirement), verifies the code signature and architectures, and packages `unimacs.app` into a redistributable `.zip` archive.

### Usage
```bash
./Scripts/package-distribute.sh [options] [-- <xcodebuild-args>...]
```

- **Options**:
  - `-o, --out <path>`: Output `.zip` file path or destination directory (default: `Build/Products/Distribute/unimacs.zip`).
  - `-c, --clean`: Run `xcodebuild clean` before building.
  - `-h, --help`: Show help text.

### Examples
```bash
# Build and package to default path (Build/Products/Distribute/unimacs.zip)
./Scripts/package-distribute.sh

# Clean build and output zip to Desktop
./Scripts/package-distribute.sh -c -o ~/Desktop/unimacs.zip
```
