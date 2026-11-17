// Copyright (c) 2025-2026 Benny Huo
// SPDX-License-Identifier: GPL-2.0-only

import Foundation

// MARK: - Lightweight Assertion Helpers

private var totalTestsRun = 0
private var totalAssertions = 0
private var failedTests: [String] = []

private func assertEqual<T: Equatable>(
    _ actual: @autoclosure () -> T,
    _ expected: @autoclosure () -> T,
    _ message: String = "",
    file: StaticString = #filePath,
    line: UInt = #line
) {
    totalAssertions += 1
    let a = actual()
    let e = expected()
    if a != e {
        let failure = "[\(file):\(line)] Assertion failed: expected (\(e)), got (\(a)). \(message)"
        print("  ❌ \(failure)")
        failedTests.append(failure)
    }
}

private func assertTrue(
    _ condition: @autoclosure () -> Bool,
    _ message: String = "",
    file: StaticString = #filePath,
    line: UInt = #line
) {
    totalAssertions += 1
    if !condition() {
        let failure = "[\(file):\(line)] Assertion failed: expected true. \(message)"
        print("  ❌ \(failure)")
        failedTests.append(failure)
    }
}

private func assertFalse(
    _ condition: @autoclosure () -> Bool,
    _ message: String = "",
    file: StaticString = #filePath,
    line: UInt = #line
) {
    totalAssertions += 1
    if condition() {
        let failure = "[\(file):\(line)] Assertion failed: expected false. \(message)"
        print("  ❌ \(failure)")
        failedTests.append(failure)
    }
}

private func assertNotNil<T>(
    _ value: @autoclosure () -> T?,
    _ message: String = "",
    file: StaticString = #filePath,
    line: UInt = #line
) {
    totalAssertions += 1
    if value() == nil {
        let failure = "[\(file):\(line)] Assertion failed: expected non-nil. \(message)"
        print("  ❌ \(failure)")
        failedTests.append(failure)
    }
}

private func runTest(_ name: String, _ block: () throws -> Void) {
    totalTestsRun += 1
    print("Running \(name)...")
    do {
        try block()
    } catch {
        let failure = "[\(name)] Uncaught error: \(error)"
        print("  ❌ \(failure)")
        failedTests.append(failure)
    }
}

// MARK: - Command Runner & Helpers

private struct CommandResult {
    let status: Int32
    let stdout: String
    let stderr: String
}

private let repoRoot: URL = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()

@discardableResult
private func runShell(
    _ executable: String,
    arguments: [String] = [],
    workingDirectory: URL = repoRoot
) throws -> CommandResult {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.currentDirectoryURL = workingDirectory

    let stdoutPipe = Pipe()
    let stderrPipe = Pipe()
    process.standardOutput = stdoutPipe
    process.standardError = stderrPipe

    var stdoutData = Data()
    var stderrData = Data()
    let group = DispatchGroup()

    group.enter()
    DispatchQueue.global(qos: .userInitiated).async {
        stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        group.leave()
    }

    group.enter()
    DispatchQueue.global(qos: .userInitiated).async {
        stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        group.leave()
    }

    try process.run()
    process.waitUntilExit()
    group.wait()

    let stdout = String(data: stdoutData, encoding: .utf8) ?? ""
    let stderr = String(data: stderrData, encoding: .utf8) ?? ""
    return CommandResult(status: process.terminationStatus, stdout: stdout, stderr: stderr)
}

private func occurrenceCount(of substring: String, in text: String) -> Int {
    guard !substring.isEmpty else { return 0 }
    var count = 0
    var searchRange = text.startIndex..<text.endIndex
    while let range = text.range(of: substring, range: searchRange) {
        count += 1
        searchRange = range.upperBound..<text.endIndex
    }
    return count
}

private func makeTempDirectory() throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("unimacs-release-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

// MARK: - Tests

@main
struct ReleasePipelineTests {
    static func main() {
        let generateNotesScript = repoRoot.appendingPathComponent("Scripts/generate-release-notes.sh").path
        let packageScript = repoRoot.appendingPathComponent("Scripts/package-distribute.sh").path
        let workflowFile = repoRoot.appendingPathComponent(".github/workflows/release.yml").path
        let unimacsSchemeFile = repoRoot.appendingPathComponent("Unimacs.xcodeproj/xcshareddata/xcschemes/Unimacs.xcscheme").path
        let distributeSchemeFile = repoRoot.appendingPathComponent("Unimacs.xcodeproj/xcshareddata/xcschemes/Distribute.xcscheme").path

        // 1. Version normalization & prerelease detection
        runTest("testVersionNormalizationAndPrereleaseDetection") {
            let normCases: [(String, String)] = [
                ("v1.4.0", "1.4.0"),
                ("V2.0.1", "2.0.1"),
                ("1.3.5", "1.3.5"),
                ("v261110", "261110"),
                ("v1.3.5-pre", "1.3.5-pre")
            ]

            for (input, expected) in normCases {
                let res = try runShell(generateNotesScript, arguments: ["--normalize-version", input])
                assertEqual(res.status, 0, "Expected exit 0 for --normalize-version \(input), stderr: \(res.stderr)")
                assertEqual(
                    res.stdout.trimmingCharacters(in: .whitespacesAndNewlines),
                    expected,
                    "Normalized version mismatch for \(input)"
                )
            }

            let prereleaseCases: [(String, String)] = [
                ("v1.3.5-pre", "true"),
                ("v2.0.0-rc.1", "true"),
                ("v1.0.0-beta", "true"),
                ("v1.0.0-alpha.2", "true"),
                ("v1.4.0", "false"),
                ("v261110", "false")
            ]

            for (input, expected) in prereleaseCases {
                let res = try runShell(generateNotesScript, arguments: ["--is-prerelease", input])
                assertEqual(res.status, 0, "Expected exit 0 for --is-prerelease \(input), stderr: \(res.stderr)")
                assertEqual(
                    res.stdout.trimmingCharacters(in: .whitespacesAndNewlines),
                    expected,
                    "Prerelease detection mismatch for \(input)"
                )
            }

            // Error branches: missing or empty values
            let missingNorm = try runShell(generateNotesScript, arguments: ["--normalize-version"])
            assertTrue(missingNorm.status != 0, "--normalize-version without argument must fail")

            let emptyNorm = try runShell(generateNotesScript, arguments: ["--normalize-version", "   "])
            assertTrue(emptyNorm.status != 0, "--normalize-version with empty string must fail")

            let missingPre = try runShell(generateNotesScript, arguments: ["--is-prerelease"])
            assertTrue(missingPre.status != 0, "--is-prerelease without argument must fail")

            let emptyPre = try runShell(generateNotesScript, arguments: ["--is-prerelease", ""])
            assertTrue(emptyPre.status != 0, "--is-prerelease with empty string must fail")
        }

        // 2. Fresh release notes generation & boundary/error handling
        runTest("testGenerateReleaseNotesFreshAndEmptyChangelog") {
            let tempDir = try makeTempDirectory()
            defer { try? FileManager.default.removeItem(at: tempDir) }

            let changelogFile = tempDir.appendingPathComponent("changelog.md")
            let changelogText = "* feat: support automated releases (#42)\n* fix: preserve cursor position\n"
            try changelogText.write(to: changelogFile, atomically: true, encoding: .utf8)

            let outFile = tempDir.appendingPathComponent("notes.md")
            let sampleHash = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
            let customAsset = "unimacs-v1.4.0-custom.zip"

            let freshRes = try runShell(
                generateNotesScript,
                arguments: [
                    "--tag", "v1.4.0",
                    "--asset", customAsset,
                    "--sha256", sampleHash,
                    "--changelog-file", changelogFile.path,
                    "--out", outFile.path
                ]
            )
            assertEqual(freshRes.status, 0, "Expected fresh generation to succeed, stderr: \(freshRes.stderr)")

            let rendered = try String(contentsOf: outFile, encoding: .utf8)
            assertTrue(rendered.contains("<!-- unimacs-adhoc-install-guide -->"))
            assertTrue(rendered.contains("<!-- /unimacs-adhoc-install-guide -->"))
            assertTrue(rendered.contains("xattr -cr /Applications/unimacs.app"))
            assertTrue(rendered.contains("Open Anyway"))
            assertTrue(rendered.contains("中文安装与运行说明"))
            assertTrue(rendered.contains(customAsset))
            assertTrue(rendered.contains("### Package Checksum"))
            assertTrue(rendered.contains(sampleHash))
            assertTrue(rendered.contains("## What's Changed"))
            assertTrue(rendered.contains("support automated releases (#42)"))

            // Boundary case: missing/empty changelog and omitted --sha256
            let emptyChangelogFile = tempDir.appendingPathComponent("empty-changelog.md")
            try "   \n\n".write(to: emptyChangelogFile, atomically: true, encoding: .utf8)

            let minimalRes = try runShell(
                generateNotesScript,
                arguments: [
                    "--tag", "v1.4.0",
                    "--changelog-file", emptyChangelogFile.path
                ]
            )
            assertEqual(minimalRes.status, 0, "Expected generation without sha256/changelog to succeed")
            assertFalse(minimalRes.stdout.contains("### Package Checksum"), "Should omit Package Checksum without --sha256")
            assertFalse(minimalRes.stdout.contains("## What's Changed"), "Should omit What's Changed when changelog is empty")
            assertTrue(minimalRes.stdout.contains("xattr -cr /Applications/unimacs.app"))
            assertTrue(minimalRes.stdout.contains("中文安装与运行说明"))
            assertTrue(minimalRes.stdout.contains("unimacs-v1.4.0-macos-universal.zip"))

            // Non-existent changelog path should also be treated gracefully
            let missingChangelogRes = try runShell(
                generateNotesScript,
                arguments: [
                    "--tag", "v1.4.0",
                    "--changelog-file", tempDir.appendingPathComponent("does-not-exist.md").path
                ]
            )
            assertEqual(missingChangelogRes.status, 0)
            assertFalse(missingChangelogRes.stdout.contains("## What's Changed"))

            // Error branches: missing --tag, unknown flag, missing --out value
            let noTagRes = try runShell(generateNotesScript, arguments: ["--asset", "foo.zip"])
            assertTrue(noTagRes.status != 0, "Missing --tag must exit non-zero")

            let unknownFlagRes = try runShell(generateNotesScript, arguments: ["--tag", "v1.4.0", "--unknown"])
            assertTrue(unknownFlagRes.status != 0, "Unknown flag must exit non-zero")

            let missingOutRes = try runShell(generateNotesScript, arguments: ["--tag", "v1.4.0", "--out"])
            assertTrue(missingOutRes.status != 0, "Missing value after --out must exit non-zero")
        }

        // 3. Existing notes merging and idempotency
        runTest("testGenerateReleaseNotesExistingBodyMergeAndIdempotency") {
            let tempDir = try makeTempDirectory()
            defer { try? FileManager.default.removeItem(at: tempDir) }

            let handwrittenFile = tempDir.appendingPathComponent("existing.md")
            let handwrittenNotes = """
            ### Highlights

            - Added screen auto-unlock support across paired Macs.
            """
            try handwrittenNotes.write(to: handwrittenFile, atomically: true, encoding: .utf8)

            let firstSha = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
            let firstMerge = try runShell(
                generateNotesScript,
                arguments: [
                    "--tag", "v1.5.0",
                    "--sha256", firstSha,
                    "--existing-notes-file", handwrittenFile.path
                ]
            )
            assertEqual(firstMerge.status, 0, "First merge failed: \(firstMerge.stderr)")
            assertTrue(firstMerge.stdout.contains("### Highlights"))
            assertTrue(firstMerge.stdout.contains("Added screen auto-unlock support across paired Macs."))
            assertTrue(firstMerge.stdout.contains(firstSha))
            assertEqual(occurrenceCount(of: "<!-- unimacs-adhoc-install-guide -->", in: firstMerge.stdout), 1)

            // Re-run against the already merged notes with a new SHA-256
            let secondInputFile = tempDir.appendingPathComponent("second-input.md")
            try firstMerge.stdout.write(to: secondInputFile, atomically: true, encoding: .utf8)

            let secondSha = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
            let secondMerge = try runShell(
                generateNotesScript,
                arguments: [
                    "--tag", "v1.5.0",
                    "--sha256", secondSha,
                    "--existing-notes-file", secondInputFile.path
                ]
            )
            assertEqual(secondMerge.status, 0, "Second idempotent merge failed: \(secondMerge.stderr)")
            assertTrue(secondMerge.stdout.contains("### Highlights"), "Custom header must remain preserved")
            assertTrue(secondMerge.stdout.contains("Added screen auto-unlock support across paired Macs."))
            assertFalse(secondMerge.stdout.contains(firstSha), "Old SHA-256 must be replaced")
            assertTrue(secondMerge.stdout.contains(secondSha), "New SHA-256 must be present")
            assertEqual(occurrenceCount(of: "<!-- unimacs-adhoc-install-guide -->", in: secondMerge.stdout), 1)
            assertEqual(occurrenceCount(of: "<!-- /unimacs-adhoc-install-guide -->", in: secondMerge.stdout), 1)
            assertEqual(occurrenceCount(of: "## Installation & How to Run (Ad-Hoc Signed Build)", in: secondMerge.stdout), 1)
            assertEqual(
                occurrenceCount(of: "xattr -cr /Applications/unimacs.app", in: secondMerge.stdout),
                occurrenceCount(of: "xattr -cr /Applications/unimacs.app", in: firstMerge.stdout)
            )
        }

        // 4. Workflow, Xcode scheme, and package-distribute argument validation
        runTest("testWorkflowAndSchemeConfigurationValidation") {
            // Validate YAML syntax and key workflow settings
            let yamlCheck = try runShell(
                "/usr/bin/ruby",
                arguments: ["-ryaml", "-e", "YAML.load_file(ARGV[0])", workflowFile]
            )
            assertEqual(yamlCheck.status, 0, "Workflow YAML must parse cleanly: \(yamlCheck.stderr)")

            let workflowText = try String(contentsOfFile: workflowFile, encoding: .utf8)
            assertTrue(workflowText.contains("contents: write"))
            assertTrue(workflowText.contains("'v*'"))
            assertTrue(workflowText.contains("workflow_dispatch:"))
            assertTrue(workflowText.contains("./Scripts/package-distribute.sh"))
            assertTrue(workflowText.contains("./Scripts/generate-release-notes.sh"))

            // Validate Unimacs.xcscheme exists & parses, Distribute.xcscheme does not exist,
            // and xcodebuild -list exposes scheme Unimacs + configuration Distribute
            assertFalse(
                FileManager.default.fileExists(atPath: distributeSchemeFile),
                "Distribute.xcscheme must not exist"
            )
            let xmlCheck = try runShell("/usr/bin/xmllint", arguments: ["--noout", unimacsSchemeFile])
            assertEqual(xmlCheck.status, 0, "Unimacs.xcscheme XML invalid: \(xmlCheck.stderr)")

            let listCheck = try runShell("/usr/bin/xcodebuild", arguments: ["-list"])
            assertEqual(listCheck.status, 0, "xcodebuild -list failed: \(listCheck.stderr)")

            var buildConfigurations: [String] = []
            var schemes: [String] = []
            var section = ""
            for rawLine in listCheck.stdout.components(separatedBy: .newlines) {
                let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
                if trimmed == "Build Configurations:" {
                    section = "configs"
                    continue
                } else if trimmed == "Schemes:" {
                    section = "schemes"
                    continue
                } else if trimmed.isEmpty || trimmed.hasPrefix("If no build configuration") {
                    section = ""
                    continue
                }
                if section == "configs" {
                    buildConfigurations.append(trimmed)
                } else if section == "schemes" {
                    schemes.append(trimmed)
                }
            }

            assertTrue(buildConfigurations.contains("Distribute"), "Distribute build configuration must appear in xcodebuild -list")
            assertTrue(schemes.contains("Unimacs"), "Unimacs scheme must appear in xcodebuild -list")
            assertFalse(schemes.contains("Distribute"), "Distribute must not appear as a separate scheme in xcodebuild -list")

            // Validate package-distribute.sh error handling for invalid/missing options
            let missingOut = try runShell(packageScript, arguments: ["-o"])
            assertTrue(missingOut.status != 0, "package-distribute.sh -o without path must fail")

            let missingVer = try runShell(packageScript, arguments: ["-v"])
            assertTrue(missingVer.status != 0, "package-distribute.sh -v without version must fail")

            let emptyVer = try runShell(packageScript, arguments: ["-v", ""])
            assertTrue(emptyVer.status != 0, "package-distribute.sh -v \"\" must fail")
        }

        // 5. End-to-end Distribute packaging and artifact verification
        runTest("testEndToEndDistributePackageOutputVerification") {
            let tempDir = try makeTempDirectory()
            defer { try? FileManager.default.removeItem(at: tempDir) }

            let zipFile = tempDir.appendingPathComponent("unimacs-test.zip")
            let unpackedDir = tempDir.appendingPathComponent("unpacked")
            try FileManager.default.createDirectory(at: unpackedDir, withIntermediateDirectories: true)

            let pkgRes = try runShell(
                packageScript,
                arguments: ["-v", "v1.9.9-test", "-o", zipFile.path]
            )
            assertEqual(pkgRes.status, 0, "package-distribute.sh failed:\n\(pkgRes.stdout)\n\(pkgRes.stderr)")
            assertTrue(FileManager.default.fileExists(atPath: zipFile.path), "Output zip file should exist")

            let unzipRes = try runShell("/usr/bin/ditto", arguments: ["-x", "-k", zipFile.path, unpackedDir.path])
            assertEqual(unzipRes.status, 0, "Failed to unpack zip: \(unzipRes.stderr)")

            let appPath = unpackedDir.appendingPathComponent("unimacs.app").path
            var isDir: ObjCBool = false
            assertTrue(FileManager.default.fileExists(atPath: appPath, isDirectory: &isDir) && isDir.boolValue)

            let embeddedProfilePath = "\(appPath)/Contents/embedded.provisionprofile"
            assertFalse(FileManager.default.fileExists(atPath: embeddedProfilePath), "Must not embed provisioning profile")

            let codesignRes = try runShell(
                "/usr/bin/codesign",
                arguments: ["--verify", "--deep", "--strict", "--verbose=2", appPath]
            )
            assertEqual(codesignRes.status, 0, "codesign verify failed: \(codesignRes.stderr)")

            let lipoRes = try runShell("/usr/bin/lipo", arguments: ["-archs", "\(appPath)/Contents/MacOS/unimacs"])
            assertEqual(lipoRes.status, 0, "lipo -archs failed: \(lipoRes.stderr)")
            let archTokens = lipoRes.stdout
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .split(separator: " ")
                .map(String.init)
            assertTrue(archTokens.contains("arm64"), "Universal binary must contain arm64 (got: \(archTokens))")
            assertTrue(archTokens.contains("x86_64"), "Universal binary must contain x86_64 (got: \(archTokens))")

            let plistURL = URL(fileURLWithPath: "\(appPath)/Contents/Info.plist")
            let plistData = try Data(contentsOf: plistURL)
            let plistObj = try PropertyListSerialization.propertyList(from: plistData, format: nil) as? [String: Any]
            assertNotNil(plistObj, "Info.plist must deserialize as dictionary")

            if let plist = plistObj {
                assertEqual(plist["CFBundleIdentifier"] as? String ?? "", "com.bennyhuo.unimacs")
                assertEqual(plist["CFBundleShortVersionString"] as? String ?? "", "1.9.9-test")
                assertEqual(plist["CFBundleVersion"] as? String ?? "", "1.9.9-test")

                let revision = plist["UMRevision"] as? String ?? ""
                assertFalse(revision.isEmpty, "UMRevision must not be empty")
                assertFalse(revision.hasSuffix("\n"), "UMRevision must not have a trailing newline")
            }
        }

        print("=== Test Summary: \(totalTestsRun) tests (\(totalAssertions) assertions), \(failedTests.count) failures ===")
        if !failedTests.isEmpty {
            exit(1)
        }
    }
}
