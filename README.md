# Unimacs
## A Modern Virtual KVM for macOS

Use one keyboard and pointing device to control multiple Macs.

Unimacs is a modernized, peer-to-peer virtual KVM that enables seamless cursor transitioning, clipboard synchronization, and audio/microphone streaming across Mac computers.

---

### Key Features

* 💻 **Bilateral Keyboard & Mouse Sharing** - Control another Mac seamlessly when your mouse cursor crosses the edge of your screen.
* 📋 **Pasteboard Synchronization** - Copy and paste text, images, and files across Macs with adaptive polling and content hashing to prevent redundant sync.
* 🎙️ **Audio & Mic Sharing** - Stream system audio and microphone input dynamically across connected devices.
* 🎛️ **Modern SwiftUI Interface** - A clean, native sidebar-based preference settings window matching macOS Ventura+ styles.
* 🔒 **Secure Connectivity** - Peer-to-peer SSL/TLS encryption with Trust-On-First-Use (TOFU) certificate validation.
* 📐 **Unified Canvas Layout** - Drag-and-drop screen layout management with boundary snapping to organize your virtual desktop.

---

### Prerequisites & Permissions

Because Unimacs intercepts and simulates low-level user input and streams audio, it requires the following permissions in macOS **System Settings**:

1. **Accessibility**: Required on both Macs to capture/intercept local input events and simulate them on the remote machine.
2. **Screen Recording**: Required if using the Audio & Mic Sharing features (relies on `ScreenCaptureKit` for system audio routing; screen video is never recorded).
3. **BlackHole 2ch (Optional, for Virtual Microphone Routing)**: Required on the receiving Mac if routing local microphone audio to a remote Mac. You can install [BlackHole 2ch](https://existential.audio/blackhole/) via Homebrew (`brew install blackhole-2ch`) or via the one-click installer in **Settings > Audio & Mic Sync** (which downloads and verifies the signed official package from Existential Audio).
4. **Local Network / Wi-Fi**: Both Macs must be on the same local network segment for Bonjour discovery.

---

### Getting Started

1. **Build & Run**:
   * By default, [Signing.xcconfig](Signing.xcconfig) configures ad-hoc signing (`-`) so Unimacs builds out of the box with zero Apple Developer account setup.
   * Open [Unimacs.xcodeproj](Unimacs.xcodeproj) in Xcode and run the `Unimacs` target, or compile via command line:
     ```bash
     ./Scripts/build-debug.sh
     ```
   * *(Optional)* To sign local builds with your own `Apple Development` certificate so macOS Accessibility/TCC permissions persist across rebuilds, create an untracked `Local.xcconfig` in the repository root (see [Signing.xcconfig](Signing.xcconfig) for template settings).
2. **Pairing**:
   * Open Unimacs on both Mac computers.
   * Navigate to the **Devices** tab in the sidebar.
   * Under **Nearby Devices** (discovered automatically via Bonjour `_unimacs._tcp`), locate the target Mac.
   * Click **Pair** to exchange certificates and authorize control.
3. **Configure Layout**:
   * Go to the **Layout** tab.
   * Drag the remote screen (purple) to snap it next to the desired edge of your local screen (blue).
   * Move your cursor past the configured screen edge to control the other Mac.

---

### Developer & Debugging Scripts

Unimacs includes a suite of helper scripts in the [Scripts](Scripts) directory to streamline development and multi-Mac troubleshooting:

* **[build-debug.sh](Scripts/build-debug.sh)**: Compiles the Debug build of Unimacs from the command line.
* **[package-distribute.sh](Scripts/package-distribute.sh)**: Builds an ad-hoc signed Universal Binary (`arm64` + `x86_64`) using the `Distribute` configuration and packages `unimacs.app` into a `.zip` archive.
* **[setup-ssh-peer.sh](Scripts/setup-ssh-peer.sh)**: Configures passwordless SSH keys with a remote Mac (e.g., test machine or VM) for deployment and log collection.
* **[rebuild-and-deploy.sh](Scripts/rebuild-and-deploy.sh)**: Rebuilds Unimacs, clears logs, and restarts the app locally; when given remote targets (or `--all` with `Scripts/devices.txt`, see [devices.txt.example](Scripts/devices.txt.example)), also syncs and restarts builds on remote Macs/VMs.
* **[unimacs-logs.sh](Scripts/unimacs-logs.sh)**: Fetches and merges log files from local and remote hosts over SSH into a single chronological timeline (tagged `[L]` and `[<alias>]`) for diagnosing cursor handoffs and network state transitions.
* **[unimacs-crashes.sh](Scripts/unimacs-crashes.sh)**: Collects and formats recent `.ips`/`.crash` reports from local and remote Macs.

---

### Acknowledgments & License

Unimacs is forked from **[johndbritton/teleport: Virtual KVM for macOS](https://github.com/johndbritton/teleport)** (maintained by John Britton) and evolved through a comprehensive Swift rewrite and architectural modernization of the original **[Teleport](https://github.com/abyssoft/teleport)** project created by Julien Robert ([Abyssoft](http://www.abyssoft.com/software/teleport/)).

Optional virtual microphone routing integrates with **[BlackHole](https://github.com/ExistentialAudio/BlackHole)** by [Existential Audio Inc.](https://existential.audio/blackhole/) (licensed separately under GPLv3 and installed as an independent macOS CoreAudio HAL driver).

In compliance with the upstream license, Unimacs is distributed under the **[GNU General Public License v2.0 (GPLv2)](LICENSE)**.
