import Foundation
import Combine

@MainActor
final class PlaybackState: ObservableObject {
    @Published private(set) var isPlaying = false
    @Published private(set) var positionMS = 0.0
    @Published private(set) var durationMS = 0.0
    @Published private(set) var volume = 0.0
    @Published private(set) var volumeAvailable = false

    func update(isPlaying: Bool? = nil, positionMS: Double? = nil, durationMS: Double? = nil, volume: Double? = nil, volumeAvailable: Bool? = nil) {
        if let isPlaying, self.isPlaying != isPlaying { self.isPlaying = isPlaying }
        if let positionMS, self.positionMS != positionMS { self.positionMS = positionMS }
        if let durationMS, self.durationMS != durationMS { self.durationMS = durationMS }
        if let volume, self.volume != volume { self.volume = volume }
        if let volumeAvailable, self.volumeAvailable != volumeAvailable { self.volumeAvailable = volumeAvailable }
    }
}

@MainActor
final class AppModel: ObservableObject {
    @Published var connected = false
    @Published var busy = false
    @Published var error: String?
    @Published var query = "" {
        didSet {
            if query != oldValue { scheduleSearch() }
        }
    }
    @Published var shelves: [Shelf] = []
    var visibleHomeShelves: [Shelf] { HomeShelves.visible(in: shelves) }
    @Published var results: [MusicItem] = []
    @Published private(set) var searchLoading = false
    @Published var collection: MusicCollection?
    @Published var collectionLoading = false
    @Published var collectionError: String?
    @Published var nowPlaying: MusicItem?
    @Published var status = "Connect to start listening"

    // Progress ticks only invalidate views observing playback, not the library.
    let playback = PlaybackState()

    private let engine = EngineClient()
    private let systemVolume: SystemVolumeControlling
    private lazy var api = SpotifyAPI(engine: engine)
    private var searchRevision = 0
    private var startedSearchRevision: Int?
    private var searchDebounceTask: Task<Void, Never>?
    private var searchTask: Task<[MusicItem], Error>?
    private let searchLoader: ((String) async throws -> [MusicItem])?
    private let searchDelay: () async throws -> Void
    private var collectionRevision = 0
    private var collectionTask: Task<MusicCollection, Error>?
    private let collectionLoader: ((MusicItem, Int) async throws -> MusicCollection)?

    init(
        systemVolume: SystemVolumeControlling? = nil,
        searchLoader: ((String) async throws -> [MusicItem])? = nil,
        searchDelay: @escaping () async throws -> Void = { try await Task.sleep(for: .milliseconds(400)) },
        collectionLoader: ((MusicItem, Int) async throws -> MusicCollection)? = nil
    ) {
        self.searchLoader = searchLoader
        self.searchDelay = searchDelay
        self.collectionLoader = collectionLoader
        self.systemVolume = systemVolume ?? SystemVolume()
        let volume = self.systemVolume.snapshot
        playback.update(volume: volume.percent, volumeAvailable: volume.available)
        self.systemVolume.onChange = { [weak self] volume in
            self?.playback.update(volume: volume.percent, volumeAvailable: volume.available)
        }
        engine.onEvent = { [weak self] event, data in self?.handleEvent(event, data) }
    }

    func connect() async {
        guard !busy else { return }
        if connected { engine.shutdown(); connected = false; playback.update(isPlaying: false) }
        busy = true
        error = nil
        status = "Waiting for Spotify sign-in…"
        defer { busy = false }
        do {
            _ = try await engine.call("authenticate", timeout: 300)
            connected = true
            // System volume is the single gain control; avoid multiplying it by
            // the helper's default 50% software volume.
            _ = try await engine.call("volume", ["percent": 100])
            status = "Connected · this Mac"
            shelves = try await api.madeForYou()
        } catch { self.error = error.localizedDescription; status = connected ? "Connected · feed unavailable" : "Could not connect" }
    }

    func refresh() async {
        guard connected, !busy else { return }
        busy = true
        error = nil
        defer { busy = false }
        do { shelves = try await api.madeForYou(); status = "Connected · this Mac" }
        catch is CancellationError {} catch { self.error = error.localizedDescription }
    }

    func loadMore(_ shelf: Shelf) async {
        guard connected, !busy else { return }
        busy = true
        defer { busy = false }
        do {
            let page = try await api.moreItems(in: shelf)
            guard let index = shelves.firstIndex(where: { $0.id == shelf.id }) else { return }
            var seen = Set(shelves[index].items.map(\.id))
            shelves[index].items += (page?.items ?? []).filter { seen.insert($0.id).inserted }
            let next = page?.nextOffset
            shelves[index].nextOffset = (next ?? 0) > (shelf.nextOffset ?? 0) ? next : nil
        } catch { self.error = error.localizedDescription }
    }

    func search() async {
        searchDebounceTask?.cancel()
        searchDebounceTask = nil
        await performSearch(revision: searchRevision)
    }

    private func scheduleSearch() {
        invalidateSearch()
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard connected, !term.isEmpty else { return }
        searchLoading = true
        let revision = searchRevision
        let delay = searchDelay
        searchDebounceTask = Task { [weak self] in
            guard !Task.isCancelled else { return }
            do { try await delay() } catch { return }
            guard let self, !Task.isCancelled, revision == self.searchRevision else { return }
            self.searchDebounceTask = nil
            await self.performSearch(revision: revision)
        }
    }

    private func invalidateSearch() {
        searchRevision += 1
        searchDebounceTask?.cancel()
        searchDebounceTask = nil
        searchTask?.cancel()
        searchTask = nil
        startedSearchRevision = nil
        searchLoading = false
        results = []
        error = nil
    }

    private func performSearch(revision: Int) async {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard connected, !term.isEmpty, revision == searchRevision,
              startedSearchRevision != revision else { return }
        startedSearchRevision = revision
        searchLoading = true
        let loader = searchLoader
        let api = self.api
        let task = Task {
            if let loader { return try await loader(term) }
            return try await api.search(term)
        }
        searchTask = task
        defer {
            if revision == searchRevision {
                searchTask = nil
                searchLoading = false
            }
        }
        do {
            let found = try await task.value
            guard revision == searchRevision, !task.isCancelled else { return }
            results = found
            error = nil
        } catch {
            guard revision == searchRevision, !task.isCancelled else { return }
            startedSearchRevision = nil
            if error is CancellationError { return }
            self.error = error.localizedDescription
        }
    }

    func clearSearch() {
        if query.isEmpty { invalidateSearch() }
        else { query = "" }
    }

    func openCollection(_ item: MusicItem) async {
        closeCollection()
        guard connected else { return }
        collectionLoading = true
        let revision = collectionRevision
        let task = makeCollectionTask(item, offset: 0)
        collectionTask = task
        defer {
            if revision == collectionRevision {
                collectionLoading = false
                collectionTask = nil
            }
        }
        do {
            let result = try await task.value
            guard revision == collectionRevision, !task.isCancelled else { return }
            collection = result
        } catch is CancellationError {} catch {
            guard revision == collectionRevision, !task.isCancelled else { return }
            collectionError = error.localizedDescription
        }
    }

    func closeCollection() {
        collectionRevision += 1
        collectionTask?.cancel()
        collectionTask = nil
        collection = nil
        collectionLoading = false
        collectionError = nil
    }

    func loadMoreCollection() async {
        guard connected, !collectionLoading, let current = collection,
              let offset = current.nextOffset else { return }
        collectionLoading = true
        collectionError = nil
        let revision = collectionRevision
        let task = makeCollectionTask(current.item, offset: offset)
        collectionTask = task
        defer {
            if revision == collectionRevision {
                collectionLoading = false
                collectionTask = nil
            }
        }
        do {
            let page = try await task.value
            guard revision == collectionRevision, !task.isCancelled else { return }
            var merged = current
            var seen = Set(current.tracks.map(\.id))
            merged.tracks += page.tracks.filter { seen.insert($0.id).inserted }
            merged.totalCount = page.totalCount ?? current.totalCount
            merged.nextOffset = page.nextOffset.flatMap { $0 > offset ? $0 : nil }
            collection = merged
        } catch is CancellationError {} catch {
            guard revision == collectionRevision, !task.isCancelled else { return }
            collectionError = error.localizedDescription
        }
    }

    private func makeCollectionTask(_ item: MusicItem, offset: Int) -> Task<MusicCollection, Error> {
        let loader = collectionLoader
        let api = self.api
        return Task {
            if let loader { return try await loader(item, offset) }
            return try await api.collection(item, offset: offset)
        }
    }

    func play(_ item: MusicItem) async {
        guard connected else { return }
        do {
            _ = try await engine.call("play", ["uri": item.id])
            if nowPlaying != item { nowPlaying = item }
            playback.update(positionMS: 0, durationMS: 0)
            error = nil
        } catch { self.error = error.localizedDescription }
    }

    func togglePlayback() async { await command(playback.isPlaying ? "pause" : "resume") }
    func previous() async { await command("previous") }
    func next() async { await command("next") }
    func seek(_ ms: Double) async { await command("seek", ["position_ms": max(0, Int(ms))]) }
    func setVolume(_ value: Double) {
        do { try systemVolume.setVolume(value) }
        catch { self.error = error.localizedDescription }
    }

    private func command(_ method: String, _ params: [String: Any] = [:]) async {
        guard connected else { return }
        do { _ = try await engine.call(method, params); error = nil }
        catch { self.error = error.localizedDescription }
    }

    func handleEvent(_ event: String, _ data: [String: Any]) {
        if event == "disconnected" || (event == "connection" && data["connected"] as? Bool == false) {
            connected = false
            playback.update(isPlaying: false)
            status = "Disconnected"
        }
        if event == "playback" {
            playback.update(
                isPlaying: data["is_playing"] as? Bool,
                positionMS: data["position_ms"] as? Double,
                durationMS: data["duration_ms"] as? Double
            )
            if let uri = data["track_uri"] as? String {
                if let title = data["title"] as? String {
                    let artist = data["artist"] as? String ?? ""
                    let image = data["image_url"] as? String
                    if nowPlaying?.id != uri || nowPlaying?.title != title || nowPlaying?.subtitle != artist || nowPlaying?.imageURL?.absoluteString != image {
                        nowPlaying = MusicItem(id: uri, title: title, subtitle: artist, imageURL: image.flatMap(URL.init(string:)), kind: "track")
                    }
                } else if nowPlaying?.id != uri {
                    nowPlaying = results.first { $0.id == uri }
                        ?? shelves.lazy.compactMap { $0.items.first { $0.id == uri } }.first
                        ?? MusicItem(id: uri, title: "Playing on this Mac", subtitle: "Spotify", imageURL: nil, kind: "track")
                }
            }
        }
        if event == "error", let message = data["message"] as? String { error = message }
    }

    func shutdown() { invalidateSearch(); closeCollection(); systemVolume.stop(); engine.shutdown() }
}
