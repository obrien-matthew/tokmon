import Foundation

/// Keychain access via the Apple-signed `security` CLI rather than
/// Security.framework: Keychain ACL grants are keyed to the caller's code
/// signature, and `swift build` re-signs ad-hoc on every rebuild, so a
/// framework-based read would prompt after every build forever. The CLI's
/// grant is stable, and Claude Code wrote its item through it.
enum SecurityCLI {
    struct CommandError: LocalizedError {
        let status: Int32
        let stderr: String

        var errorDescription: String? {
            "security exited \(status): \(stderr.trimmingCharacters(in: .whitespacesAndNewlines))"
        }
    }

    static func findGenericPassword(service: String, account: String? = nil) throws -> String {
        var arguments = ["find-generic-password", "-s", service]
        if let account {
            arguments += ["-a", account]
        }
        arguments.append("-w")
        return try run(arguments)
    }

    private static func run(_ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = arguments
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        let outData = stdout.fileHandleForReading.readDataToEndOfFile()
        let errData = stderr.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0,
              let output = String(data: outData, encoding: .utf8)
        else {
            throw CommandError(
                status: process.terminationStatus,
                stderr: String(data: errData, encoding: .utf8) ?? ""
            )
        }
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
