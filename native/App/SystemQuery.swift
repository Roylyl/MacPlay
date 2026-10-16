import Foundation
import Darwin

struct SystemQueryResult: Sendable {
    let data: Data
    let status: Int32?
    let error: String?
}

/// Run on a worker task. Both process execution and output collection are bounded.
enum BoundedSystemQuery {
    static func run(executable: String, arguments: [String], timeout: TimeInterval = 4) -> SystemQueryResult {
        let process = Process(), pipe = Pipe(), exited = DispatchSemaphore(value: 0)
        let output = QueryOutput()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { _ in exited.signal() }
        do { try process.run() }
        catch { return SystemQueryResult(data: Data(), status: nil, error: "LAUNCH_FAILED") }
        let collected = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            output.set(pipe.fileHandleForReading.readDataToEndOfFile())
            try? pipe.fileHandleForReading.close()
            collected.signal()
        }
        guard exited.wait(timeout: .now() + timeout) == .success else {
            if process.isRunning {
                process.terminate()
                if exited.wait(timeout: .now() + 0.2) == .timedOut, process.isRunning {
                    kill(process.processIdentifier, SIGKILL)
                }
            }
            return SystemQueryResult(data: Data(), status: nil, error: "TIMEOUT")
        }
        guard collected.wait(timeout: .now() + 0.5) == .success else {
            return SystemQueryResult(data: Data(), status: process.terminationStatus, error: "OUTPUT_TIMEOUT")
        }
        return SystemQueryResult(data: output.get(), status: process.terminationStatus,
                                 error: process.terminationStatus == 0 ? nil : "PROCESS_FAILED")
    }
}

private final class QueryOutput: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    func set(_ value: Data) { lock.lock(); defer { lock.unlock() }; data = value }
    func get() -> Data { lock.lock(); defer { lock.unlock() }; return data }
}
