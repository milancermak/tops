import Foundation
import Darwin

struct TopsError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Serialize reads with close so a late callback cannot read a reused file descriptor.
private final class EngineOutputPipe {
    let handle: FileHandle
    private let lock = NSLock()
    private var closed = false

    init(_ handle: FileHandle) { self.handle = handle }

    func readAvailable() -> Data? {
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { return nil }
        var data = Data(count: 65_536)
        let count: Int = data.withUnsafeMutableBytes { bytes in
            var result: Int
            repeat {
                result = Darwin.read(handle.fileDescriptor, bytes.baseAddress, bytes.count)
            } while result < 0 && errno == EINTR
            return result
        }
        if count <= 0 {
            handle.readabilityHandler = nil
            return Data()
        }
        data.count = count
        return data
    }

    func close() {
        lock.lock()
        defer { lock.unlock() }
        guard !closed else { return }
        closed = true
        handle.readabilityHandler = nil
        try? handle.close()
    }
}

/// A private child process, using pipes rather than a network-accessible control port.
@MainActor
final class EngineClient {
    var onEvent: ((String, [String: Any]) -> Void)?
    private let executableURL: URL?
    private let dataDirectoryURL: URL?
    private var process: Process?
    private var generation: UUID?
    private var input: FileHandle?
    private var output: EngineOutputPipe?
    private var buffer = Data()
    private var nextID = 0
    private var pending: [Int: CheckedContinuation<[String: Any], Error>] = [:]
    private var timeouts: [Int: Task<Void, Never>] = [:]

    init(executableURL: URL? = nil, dataDirectoryURL: URL? = nil) {
        self.executableURL = executableURL
        self.dataDirectoryURL = dataDirectoryURL
    }

    var dataDirectory: URL {
        if let dataDirectoryURL { return dataDirectoryURL }
        if let path = ProcessInfo.processInfo.environment["TOPS_DATA_DIR"] {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Tops/session", isDirectory: true)
    }

    func start() throws {
        if process?.isRunning == true { return }
        if process != nil {
            stop(error: stoppedError, notify: true)
        }
        let env = ProcessInfo.processInfo.environment
        let candidatePaths: [String?] = [
            executableURL?.path,
            env["TOPS_ENGINE"],
            Bundle.main.resourceURL?.appendingPathComponent("tops-engine").path,
            FileManager.default.currentDirectoryPath + "/engine/target/release/tops-engine",
            FileManager.default.currentDirectoryPath + "/engine/target/debug/tops-engine"
        ]
        let candidates = candidatePaths.compactMap { $0 }
        guard let executable = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw TopsError(message: "The playback engine has not been built. Run scripts/build-app.sh, then open dist/Tops.app.")
        }
        let child = Process()
        let stdin = Pipe(), stdout = Pipe()
        child.executableURL = URL(fileURLWithPath: executable)
        child.arguments = ["--data-dir", dataDirectory.path]
        // librespot creates a second Tokio runtime. Its default otherwise starts
        // one worker per CPU, beyond this small player's networking needs.
        child.environment = env.merging(["TOKIO_WORKER_THREADS": "2"]) { _, bounded in bounded }
        child.standardInput = stdin
        child.standardOutput = stdout
        // Engine errors are returned over IPC. Never forward authentication logs to the UI.
        child.standardError = FileHandle.nullDevice
        let handle = stdout.fileHandleForReading
        let reader = EngineOutputPipe(handle)
        let childGeneration = UUID()
        handle.readabilityHandler = { [weak self, weak reader] _ in
            guard let data = reader?.readAvailable() else { return }
            Task { @MainActor [weak self] in
                self?.receive(data, generation: childGeneration)
            }
        }
        child.terminationHandler = { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, self.generation == childGeneration else { return }
                self.stop(error: self.stoppedError, notify: true)
            }
        }
        generation = childGeneration
        process = child
        input = stdin.fileHandleForWriting
        output = reader
        do { try child.run() }
        catch {
            stop(error: error, notify: false)
            throw error
        }
    }

    func call(_ method: String, _ params: [String: Any] = [:], timeout: Double = 45) async throws -> [String: Any] {
        try start()
        nextID += 1
        let id = nextID
        var frame = try JSONSerialization.data(withJSONObject: ["id": id, "method": method, "params": params])
        frame.append(10)
        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            timeouts[id] = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(timeout)) } catch { return }
                guard let self, let pending = self.pending.removeValue(forKey: id) else { return }
                self.timeouts[id] = nil
                pending.resume(throwing: TopsError(message: method == "authenticate" ? "Sign-in timed out. Try Connect again." : "Spotify did not respond in time. Try again."))
            }
            do { try input?.write(contentsOf: frame) }
            catch {
                pending.removeValue(forKey: id)?.resume(throwing: error)
                timeouts.removeValue(forKey: id)?.cancel()
            }
        }
    }

    private func receive(_ data: Data, generation childGeneration: UUID) {
        guard generation == childGeneration else { return }
        if data.isEmpty {
            stop(error: stoppedError, notify: true)
            return
        }
        buffer.append(data)
        if buffer.count > 2_000_000 {
            stop(error: TopsError(message: "The playback engine sent an oversized response. Connect again to restart it."), notify: true)
            return
        }
        while generation == childGeneration, let end = buffer.firstIndex(of: 10) {
            let line = buffer[..<end]
            buffer.removeSubrange(...end)
            guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
            if let id = object["id"] as? Int, let continuation = pending.removeValue(forKey: id) {
                timeouts.removeValue(forKey: id)?.cancel()
                if let error = object["error"] as? String {
                    continuation.resume(throwing: TopsError(message: error))
                } else {
                    continuation.resume(returning: object["result"] as? [String: Any] ?? [:])
                }
            } else if let event = object["event"] as? String {
                onEvent?(event, object["data"] as? [String: Any] ?? [:])
            }
        }
    }

    private func failPending(_ error: Error) {
        for timeout in timeouts.values { timeout.cancel() }
        timeouts.removeAll()
        let waiting = pending.values
        pending.removeAll()
        for continuation in waiting { continuation.resume(throwing: error) }
    }

    func shutdown() {
        stop(error: TopsError(message: "Player closed."), notify: false)
    }

    private var stoppedError: TopsError {
        TopsError(message: "The playback engine stopped. Connect again to restart it.")
    }

    private func stop(error: Error, notify: Bool) {
        let child = process
        let oldInput = input
        let oldOutput = output
        // Invalidate callbacks before releasing handles or resuming suspended callers.
        generation = nil
        process = nil
        input = nil
        output = nil
        buffer.removeAll()
        child?.terminationHandler = nil
        try? oldInput?.close()
        oldOutput?.close()
        if child?.isRunning == true { child?.terminate() }
        failPending(error)
        if notify { onEvent?("disconnected", [:]) }
    }
}
