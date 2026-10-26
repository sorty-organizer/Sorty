import Foundation
import SortyFileSystem

package enum TCCPermissionResetter {
    package struct Result: Sendable {
        package let succeeded: Bool
        package let message: String

        package init(succeeded: Bool, message: String) {
            self.succeeded = succeeded
            self.message = message
        }
    }

    package static func reset(
        services: [String],
        bundleIdentifier: String
    ) async -> Result {
        await Task.detached(priority: .userInitiated) {
            var failures: [String] = []

            for service in services {
                if let failure = reset(
                    service: service,
                    bundleIdentifier: bundleIdentifier
                ) {
                    failures.append(failure)
                }
            }

            if failures.isEmpty {
                return Result(succeeded: true, message: "")
            }

            return Result(
                succeeded: false,
                message: failures.joined(separator: "\n")
            )
        }.value
    }

    private static func reset(
        service: String,
        bundleIdentifier: String
    ) -> String? {
        let process = Process()
        let errorPipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        process.arguments = ["reset", service, bundleIdentifier]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = errorPipe

        do {
            try process.run()
            process.waitUntilExit()

            guard process.terminationStatus != 0 else { return nil }
            let data = errorPipe.fileHandleForReading.readDataToEndOfFile()
            let detail = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return detail?.isEmpty == false
                ? detail!
                : "macOS couldn’t reset \(service)."
        } catch {
            return "macOS couldn’t run the permission reset: \(error.userFacingMessage)"
        }
    }
}
