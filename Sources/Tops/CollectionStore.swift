import CryptoKit
import Foundation

/// Account-scoped track pages. A view may use a stale page immediately while
/// `collection` refreshes it through the shared, bounded request queue.
@MainActor
final class CollectionStore {
    typealias Loader = (MusicItem, Int) async throws -> MusicCollection

    nonisolated static var defaultDirectory: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Tops/Collections", isDirectory: true)
    }

    private struct Key: Hashable, Codable, Sendable {
        var id: String
        var offset: Int
    }

    private struct Entry: Codable, Sendable {
        var key: Key
        var collection: MusicCollection
        var fetchedAt: Date
        var accessedAt: Date
        var invalidated = false
    }

    private struct Snapshot: Codable, Sendable {
        var schemaVersion = 1
        var entries: [Entry]
    }

    private final class Request {
        let id = UUID()
        let key: Key
        let item: MusicItem
        let session: UUID
        let generation: Int
        var foreground: Bool
        var waiters: [UUID: CheckedContinuation<MusicCollection, Error>] = [:]

        init(key: Key, item: MusicItem, session: UUID, generation: Int, foreground: Bool) {
            self.key = key
            self.item = item
            self.session = session
            self.generation = generation
            self.foreground = foreground
        }
    }

    private let directory: URL?
    private let now: () -> Date
    private let loader: Loader
    private let freshness: TimeInterval
    private let retention: TimeInterval
    private let capacity: Int
    private let disk = CollectionDiskIO()
    private var session = UUID()
    private var accountID: String?
    private var entries: [Key: Entry] = [:]
    private var generations: [String: Int] = [:]
    private var requests: [Key: Request] = [:]
    private var queue: [Request] = []
    private var running: [UUID: Task<Void, Never>] = [:]
    private var retryAfter: [Key: (date: Date, failures: Int)] = [:]
    private var persistenceTask: Task<Void, Never>?
    private var backgroundPausedUntil: Date?
    private var resumeBackgroundTask: Task<Void, Never>?

    init(directory: URL? = CollectionStore.defaultDirectory,
         now: @escaping () -> Date = Date.init,
         freshness: TimeInterval = 15 * 60,
         retention: TimeInterval = 7 * 24 * 60 * 60,
         capacity: Int = 500,
         loader: @escaping Loader) {
        self.directory = directory
        self.now = now
        self.freshness = freshness
        self.retention = retention
        self.capacity = max(1, capacity)
        self.loader = loader
    }

    /// Hydration is off the main actor. A late read cannot populate a different
    /// account, nor overwrite pages already fetched while that read was running.
    func activate(accountID: String) async {
        if self.accountID == accountID { return }
        reset()
        guard !accountID.isEmpty else { return }
        self.accountID = accountID
        let expectedSession = session
        guard let url = cacheURL else { return }
        await persistenceTask?.value
        let data = await disk.read(url)
        guard expectedSession == session, let data else { return }
        // Decode together with disk IO rather than parsing up to 500 track pages
        // on the UI thread.
        let restored = await Task.detached(priority: .utility) {
            try? JSONDecoder().decode(Snapshot.self, from: data)
        }.value
        guard expectedSession == session, let restored, restored.schemaVersion == 1 else { return }
        for entry in restored.entries where entries[entry.key] == nil && isUsable(entry) {
            // A successful first-page fetch may have invalidated disk pages while
            // hydration was suspended. Never restore those obsolete continuations.
            guard generations[entry.key.id, default: 0] == 0 else { continue }
            entries[entry.key] = entry
        }
        prune()
    }

    /// Retain account files for a future login, but discard all session state.
    func reset() {
        session = UUID()
        accountID = nil
        cancelRequests()
        entries.removeAll()
        generations.removeAll()
        retryAfter.removeAll()
        backgroundPausedUntil = nil
        resumeBackgroundTask?.cancel()
        resumeBackgroundTask = nil
    }

    func cachedCollection(for item: MusicItem, offset: Int = 0) -> MusicCollection? {
        let key = Key(id: item.id, offset: offset)
        guard var entry = entries[key] else { return nil }
        guard isUsable(entry) else {
            entries.removeValue(forKey: key)
            persist()
            return nil
        }
        entry.accessedAt = now()
        entries[key] = entry
        return entry.collection
    }

    func isFresh(for item: MusicItem, offset: Int = 0) -> Bool {
        guard let entry = entries[Key(id: item.id, offset: offset)] else { return false }
        return isUsable(entry) && !entry.invalidated && now().timeIntervalSince(entry.fetchedAt) < freshness
    }

    /// Lets an open detail reject pages belonging to a newly refreshed first page.
    func generation(for item: MusicItem) -> Int { generations[item.id, default: 0] }

    func collection(_ item: MusicItem, offset: Int = 0, forceRefresh: Bool = false) async throws -> MusicCollection {
        try Task.checkCancellation()
        if !forceRefresh, isFresh(for: item, offset: offset),
           let cached = cachedCollection(for: item, offset: offset) { return cached }
        let key = Key(id: item.id, offset: offset)
        let waiterID = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                // onCancel can run before this continuation is registered.
                guard !Task.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                let request = request(for: item, key: key, foreground: true)
                request.waiters[waiterID] = continuation
                drain()
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.requests[key]?.waiters.removeValue(forKey: waiterID)?.resume(throwing: CancellationError())
            }
        }
    }

    /// Prefetch only the first API page (50 tracks). Repeated visibility events
    /// reuse pending requests, and a failure backs off instead of creating a loop.
    func prefetch(_ items: [MusicItem]) {
        for item in items where ["playlist", "album", "artist"].contains(item.kind) {
            let key = Key(id: item.id, offset: 0)
            guard !isFresh(for: item), retryAfter[key].map({ $0.date <= now() }) ?? true else { continue }
            _ = request(for: item, key: key, foreground: false)
        }
        drain()
    }

    /// Explicit refresh invalidates freshness immediately; stale rows survive a
    /// temporary failure. Changing the session also rejects noncooperative loaders.
    func invalidate() {
        session = UUID()
        cancelRequests()
        for key in entries.keys { entries[key]?.invalidated = true }
        retryAfter.removeAll()
        persist()
    }

    func remove(_ item: MusicItem) {
        generations[item.id, default: 0] += 1
        for key in entries.keys where key.id == item.id { entries.removeValue(forKey: key) }
        for pending in Array(requests.values) where pending.key.id == item.id { cancel(pending) }
        persist()
        drain()
    }

    func flushPersistence() async { await persistenceTask?.value }

    private func request(for item: MusicItem, key: Key, foreground: Bool) -> Request {
        if let existing = requests[key] {
            existing.foreground = existing.foreground || foreground
            return existing
        }
        let request = Request(key: key, item: item, session: session,
                              generation: generations[key.id, default: 0], foreground: foreground)
        requests[key] = request
        queue.append(request)
        return request
    }

    private func drain() {
        while running.count < 2, !queue.isEmpty {
            let foreground = queue.firstIndex(where: { $0.foreground })
            if foreground == nil, let deadline = backgroundPausedUntil, deadline > now() { return }
            let index = foreground ?? 0
            let request = queue.remove(at: index)
            let loader = loader
            running[request.id] = Task(priority: request.foreground ? .userInitiated : .utility) { [weak self] in
                let result: Result<MusicCollection, Error>
                do {
                    try Task.checkCancellation()
                    result = .success(try await loader(request.item, request.key.offset))
                } catch { result = .failure(error) }
                self?.finish(request, result: result)
            }
        }
    }

    private func finish(_ request: Request, result: Result<MusicCollection, Error>) {
        running.removeValue(forKey: request.id)
        defer { drain() }
        guard request.session == session, requests[request.key]?.id == request.id,
              request.generation == generations[request.key.id, default: 0] else { return }
        requests.removeValue(forKey: request.key)
        switch result {
        case .success(let collection):
            if request.key.offset == 0 {
                generations[request.key.id, default: 0] += 1
                // Without a verified revision identifier, every refreshed first
                // page starts a new sequence. Never combine it with old offsets.
                for key in entries.keys where key.id == request.key.id && key.offset != 0 {
                    entries.removeValue(forKey: key)
                }
                for pending in Array(requests.values) where pending.key.id == request.key.id && pending.key.offset != 0 {
                    cancel(pending)
                }
            }
            entries[request.key] = Entry(key: request.key, collection: collection, fetchedAt: now(), accessedAt: now())
            retryAfter.removeValue(forKey: request.key)
            prune()
            persist()
        case .failure(let error):
            if error is SpotifyCollectionUnavailable {
                remove(request.item)
                retryAfter[request.key] = (now().addingTimeInterval(15 * 60), 5)
            } else if !(error is CancellationError) {
                let failures = min(5, (retryAfter[request.key]?.failures ?? 0) + 1)
                retryAfter[request.key] = (now().addingTimeInterval(min(15 * 60, 60 * pow(2, Double(failures - 1)))), failures)
            }
            if let error = error as? SpotifyRateLimited { pauseBackground(for: error.retryAfter) }
        }
        for waiter in request.waiters.values { waiter.resume(with: result) }
        request.waiters.removeAll()
    }

    private func cancel(_ request: Request) {
        requests.removeValue(forKey: request.key)
        queue.removeAll { $0.id == request.id }
        running[request.id]?.cancel()
        for waiter in request.waiters.values { waiter.resume(throwing: CancellationError()) }
        request.waiters.removeAll()
    }

    private func cancelRequests() {
        for request in Array(requests.values) { cancel(request) }
        // Keep canceled tasks in `running` until they actually return, so a slow
        // cancellation never allows the two-request concurrency limit to grow.
    }

    private func pauseBackground(for interval: TimeInterval) {
        let delay = max(1, interval)
        let deadline = now().addingTimeInterval(delay)
        guard backgroundPausedUntil.map({ $0 < deadline }) ?? true else { return }
        backgroundPausedUntil = deadline
        resumeBackgroundTask?.cancel()
        resumeBackgroundTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) }
            catch { return }
            self?.drain()
        }
    }

    private func isUsable(_ entry: Entry) -> Bool {
        let age = now().timeIntervalSince(entry.fetchedAt)
        return age >= 0 && age < retention
    }

    private func prune() {
        entries = entries.filter { isUsable($0.value) }
        if entries.count > capacity {
            let oldest = entries.values.sorted {
                if $0.accessedAt != $1.accessedAt { return $0.accessedAt < $1.accessedAt }
                if $0.key.id != $1.key.id { return $0.key.id < $1.key.id }
                return $0.key.offset < $1.key.offset
            }.prefix(entries.count - capacity)
            for entry in oldest { entries.removeValue(forKey: entry.key) }
        }
    }

    private var cacheURL: URL? {
        guard let directory, let accountID else { return nil }
        let name = SHA256.hash(data: Data(accountID.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent("\(name).json")
    }

    private func persist() {
        guard let url = cacheURL else { return }
        let snapshot = Snapshot(entries: Array(entries.values))
        let previous = persistenceTask
        let disk = disk
        persistenceTask = Task.detached(priority: .utility) {
            // Preserve snapshot ordering, including across account switches.
            await previous?.value
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            await disk.write(data, to: url)
        }
    }
}

/// File operations run on this actor, never on MainActor. Cache corruption or
/// removal is harmless: the next content fetch repopulates the file.
private actor CollectionDiskIO {
    func read(_ url: URL) -> Data? { try? Data(contentsOf: url) }

    func write(_ data: Data, to url: URL) {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            try data.write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch { /* A cache write must never interrupt playback or navigation. */ }
    }
}
