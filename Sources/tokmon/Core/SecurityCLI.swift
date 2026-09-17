import Foundation

/// Keychain access via the Apple-signed `security` CLI rather than
/// Security.framework: Keychain ACL grants are keyed to the caller's code
/// signature, and `swift build` re-signs ad-hoc on every rebuild, so a
/// framework-based read would prompt after every build forever. The CLI's
/// grant is stable, and Claude Code wrote its item through it. Its process is
/// awaited asynchronously so a stalled Keychain lookup neither blocks a Swift
/// cooperative-pool thread nor prevents task cancellation.
enum SecurityCLI {
    struct CommandError: LocalizedError {
        let status: Int32
        let stderr: String

        var errorDescription: String? {
            "security exited \(status): \(stderr.trimmingCharacters(in: .whitespacesAndNewlines))"
        }
    }

    static func findGenericPassword(service: String, account: String? = nil) async throws -> String {
        var arguments = ["find-generic-password", "-s", service]
        if let account {
            arguments += ["-a", account]
        }
        arguments.append("-w")
        return try await run(arguments)
    }

    private static func run(_ arguments: [String]) async throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = arguments

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        let state = CommandState(
            process: process,
            stdout: stdout.fileHandleForReading,
            stderr: stderr.fileHandleForReading
        )
        process.terminationHandler = { process in
            state.didTerminate(status: process.terminationStatus)
        }
        stdout.fileHandleForReading.readabilityHandler = { handle in
            state.drain(handle, stream: .stdout)
        }
        stderr.fileHandleForReading.readabilityHandler = { handle in
            state.drain(handle, stream: .stderr)
        }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                state.install(continuation)
                do {
                    try process.run()
                    state.didStart()
                } catch {
                    state.didFailToStart(error)
                }
            }
        } onCancel: {
            state.cancel()
        }
    }

    private final class CommandState: @unchecked Sendable {
        enum Stream {
            case stdout
            case stderr
        }

        private let lock = NSLock()
        private let process: Process
        private let stdoutHandle: FileHandle
        private let stderrHandle: FileHandle

        private var stdout = Data()
        private var stderr = Data()
        private var stdoutClosed = false
        private var stderrClosed = false
        private var terminationStatus: Int32?
        private var continuation: CheckedContinuation<String, Error>?
        private var started = false
        private var cancelled = false
        private var completed = false

        init(process: Process, stdout: FileHandle, stderr: FileHandle) {
            self.process = process
            stdoutHandle = stdout
            stderrHandle = stderr
        }

        func install(_ continuation: CheckedContinuation<String, Error>) {
            lock.lock()
            self.continuation = continuation
            lock.unlock()
        }

        func didStart() {
            lock.lock()
            started = true
            let shouldTerminate = cancelled
            lock.unlock()

            if shouldTerminate {
                process.terminate()
            }
        }

        func didFailToStart(_ error: Error) {
            complete(.failure(error))
        }

        func didTerminate(status: Int32) {
            lock.lock()
            terminationStatus = status
            let completion = completionIfReady()
            lock.unlock()
            if let completion {
                finish(completion.result, continuation: completion.continuation)
            }
        }

        func drain(_ handle: FileHandle, stream: Stream) {
            let data = handle.availableData

            lock.lock()
            if data.isEmpty {
                switch stream {
                case .stdout:
                    stdoutClosed = true
                case .stderr:
                    stderrClosed = true
                }
            } else {
                switch stream {
                case .stdout:
                    stdout.append(data)
                case .stderr:
                    stderr.append(data)
                }
            }
            let completion = completionIfReady()
            lock.unlock()

            if data.isEmpty {
                handle.readabilityHandler = nil
            }
            if let completion {
                finish(completion.result, continuation: completion.continuation)
            }
        }

        func cancel() {
            lock.lock()
            cancelled = true
            let shouldTerminate = started && terminationStatus == nil
            lock.unlock()

            if shouldTerminate {
                process.terminate()
            }
        }

        private func completionIfReady() -> (result: Result<String, Error>, continuation: CheckedContinuation<String, Error>)? {
            guard !completed,
                  let status = terminationStatus,
                  stdoutClosed,
                  stderrClosed,
                  let continuation
            else {
                return nil
            }

            completed = true
            self.continuation = nil

            if cancelled {
                return (.failure(CancellationError()), continuation)
            }
            guard status == 0,
                  let output = String(data: stdout, encoding: .utf8)
            else {
                return (
                    .failure(CommandError(
                        status: status,
                        stderr: String(data: stderr, encoding: .utf8) ?? ""
                    )),
                    continuation
                )
            }
            return (
                .success(output.trimmingCharacters(in: .whitespacesAndNewlines)),
                continuation
            )
        }

        private func complete(_ result: Result<String, Error>) {
            lock.lock()
            guard !completed, let continuation else {
                lock.unlock()
                return
            }
            completed = true
            self.continuation = nil
            lock.unlock()
            finish(result, continuation: continuation)
        }

        private func finish(_ result: Result<String, Error>, continuation: CheckedContinuation<String, Error>) {
            stdoutHandle.readabilityHandler = nil
            stderrHandle.readabilityHandler = nil
            process.terminationHandler = nil
            continuation.resume(with: result)
        }
    }
}
