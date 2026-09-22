//
//  DevRebuilder.swift
//  Sorty
//
//  Debug-only utility that rebuilds and relaunches the app from source
//  using `make now`. Triggered by "Check for Updates" or the traffic light
//  button in local debug builds.
//

import AppKit
import Foundation

#if DEBUG
@MainActor
public final class DevRebuilder {
    public static let shared = DevRebuilder()

    @Published public private(set) var isRebuilding = false

    private init() {}

    /// Kick off `make now` in the project root, which rebuilds and reopens the app.
    public func rebuild() {
        guard !isRebuilding else {
            HapticFeedbackManager.shared.selection()
            return
        }
        isRebuilding = true

        LogManager.shared.log("Dev rebuild triggered", category: "DevRebuilder")

        // Find the project root by walking up from the app bundle
        guard let projectRoot = findProjectRoot() else {
            LogManager.shared.log("Could not locate project root for rebuild", level: .error, category: "DevRebuilder")
            presentFailureAlert(
                title: "Rebuild Could Not Start",
                info: "Sorty could not locate your project root (Makefile). Open Sorty from your local source checkout or set SORTY_PROJECT_ROOT."
            )
            isRebuilding = false
            return
        }

        Task.detached(priority: .background) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/make")
            process.arguments = ["now"]
            process.currentDirectoryURL = URL(fileURLWithPath: projectRoot)
            process.qualityOfService = .background

            // Inherit the user's shell environment so toolchain paths resolve
            var env = ProcessInfo.processInfo.environment
            // Ensure /usr/local/bin and Homebrew paths are available
            let extraPaths = ["/usr/local/bin", "/opt/homebrew/bin", "/opt/homebrew/sbin"]
            if let existing = env["PATH"] {
                env["PATH"] = (extraPaths + [existing]).joined(separator: ":")
            }
            env["TERM"] = env["TERM"] ?? "xterm-256color"
            process.environment = env

            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe

            do {
                try process.run()
            } catch {
                await MainActor.run {
                    LogManager.shared.log("Rebuild launch failed: \(error.localizedDescription)", level: .error, category: "DevRebuilder")
                    DevRebuilder.shared.presentFailureAlert(
                        title: "Rebuild Launch Failed",
                        info: error.localizedDescription
                    )
                    DevRebuilder.shared.isRebuilding = false
                }
                return
            }

            // Wait for build completion without blocking the cooperative pool.
            // waitUntilExit() parks a pool thread; terminationHandler suspends instead.
            let status: Int32 = await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    if !process.isRunning {
                        continuation.resume(returning: process.terminationStatus)
                        return
                    }
                    process.terminationHandler = { proc in
                        continuation.resume(returning: proc.terminationStatus)
                    }
                }
            } onCancel: {
                process.terminate()
            }
            process.terminationHandler = nil
            guard !Task.isCancelled else { return }

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let output = String(data: data, encoding: .utf8) ?? ""
            if status != 0 {
                await MainActor.run {
                    LogManager.shared.log("Rebuild failed (exit \(status)): \(output.suffix(500))", level: .error, category: "DevRebuilder")
                    DevRebuilder.shared.presentFailureAlert(
                        title: "Rebuild Failed",
                        info: "make now exited with status \(status). Check Console logs for details."
                    )
                    DevRebuilder.shared.isRebuilding = false
                }
            } else {
                let appBundlePath = URL(fileURLWithPath: projectRoot)
                    .appendingPathComponent("releases")
                    .appendingPathComponent("Sorty.app")
                    .path

                let delayedRelaunch = Process()
                delayedRelaunch.executableURL = URL(fileURLWithPath: "/bin/zsh")
                delayedRelaunch.arguments = [
                    "-lc",
                    "sleep 0.9; /usr/bin/open \(DevRebuilder.shellQuoted(appBundlePath))",
                ]

                do {
                    try delayedRelaunch.run()
                } catch {
                    await MainActor.run {
                        LogManager.shared.log("Relaunch helper failed: \(error.localizedDescription)", level: .error, category: "DevRebuilder")
                        DevRebuilder.shared.presentFailureAlert(
                            title: "Rebuild Succeeded But Relaunch Failed",
                            info: error.localizedDescription
                        )
                        DevRebuilder.shared.isRebuilding = false
                    }
                    return
                }

                // Relaunch is scheduled out-of-process; terminate this instance now.
                await MainActor.run {
                    LogManager.shared.log("Rebuild succeeded, scheduled relaunch helper (pid: \(delayedRelaunch.processIdentifier))", category: "DevRebuilder")
                    NSApplication.shared.terminate(nil)
                }
            }
        }
    }

    @MainActor
    private func presentFailureAlert(title: String, info: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = info
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private nonisolated static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Find the directory containing the Makefile using several launch-context fallbacks.
    private func findProjectRoot() -> String? {
        if let configuredRoot = ProcessInfo.processInfo.environment["SORTY_PROJECT_ROOT"],
           FileManager.default.fileExists(atPath: "\(configuredRoot)/Makefile") {
            return configuredRoot
        }

        let sourcePath = URL(fileURLWithPath: #filePath)
        let searchRoots: [URL] = [
            sourcePath.deletingLastPathComponent(),
            Bundle.main.bundleURL,
            Bundle.main.executableURL?.deletingLastPathComponent(),
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true),
        ].compactMap { $0 }

        var seen = Set<String>()
        for start in searchRoots {
            var cursor = start
            for _ in 0..<20 {
                let normalized = cursor.standardizedFileURL.path
                if !seen.insert(normalized).inserted {
                    break
                }

                let makefile = cursor.appendingPathComponent("Makefile").path
                if FileManager.default.fileExists(atPath: makefile) {
                    return cursor.path
                }

                let parent = cursor.deletingLastPathComponent()
                if parent.path == cursor.path { break }
                cursor = parent
            }
        }

        return nil
    }
}
#endif
