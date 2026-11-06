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
    @Published var connected = false {
        didSet {
            if oldValue && !connected { clearAccountContent() }
            updateMediaControls()
        }
    }
    @Published var busy = false
    @Published var error: String?
    @Published var query = "" {
        didSet {
            if query != oldValue { scheduleSearch() }
        }
    }
    @Published var shelves: [Shelf] = [] {
        didSet { prefetchHomeCollections() }
    }
    var visibleHomeShelves: [Shelf] { HomeShelves.visible(in: shelves) }
    @Published var results: [MusicItem] = []
    @Published private(set) var searchLoading = false
    @Published var collection: MusicCollection? {
        didSet { updateMediaControls() }
    }
    @Published var collectionLoading = false
    @Published var collectionError: String?
    @Published var nowPlaying: MusicItem? {
        didSet { updateMediaControls() }
    }
    @Published private(set) var playbackCollection: MusicItem?
    var playbackCollectionID: String? { playbackCollection?.id }
    @Published var status = "Connect to start listening"

    // Progress ticks only invalidate views observing playback, not the library.
    let playback = PlaybackState()

    private let engine: EngineClient
    private var mediaControls: MediaControlSystem?
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
    private let suppliedCollectionStore: CollectionStore?
    private let feedLoader: (() async throws -> [Shelf])?
    private var accountRevision = 0
    private var prefetchShelfCount = 6
    private var collectionRefreshing = false
    private var collectionFailedOffset: Int?
    private var collectionSnapshot = 0
    @Published private var collectionItem: MusicItem? {
        didSet { updateMediaControls() }
    }
    private var playbackRequestRevision = 0
    private var playbackTrackRevision = 0
    private var playRequestInFlight = false
    private var playbackPositionConfirmed = false
    private var playbackContextURI: String?
    private var checkpointURL: URL?
    private var latestCheckpoint: PlaybackCheckpoint?
    private var writtenCheckpoint: PlaybackCheckpoint?
    private var pendingRestore: PlaybackCheckpoint?
    private var restoringPlayback = false
    private lazy var collectionStore: CollectionStore = {
        if let suppliedCollectionStore { return suppliedCollectionStore }
        if let collectionLoader { return CollectionStore(directory: nil, loader: collectionLoader) }
        let api = self.api
        return CollectionStore { item, offset in try await api.collection(item, offset: offset) }
    }()

    init(
        engine: EngineClient? = nil,
        systemVolume: SystemVolumeControlling? = nil,
        searchLoader: ((String) async throws -> [MusicItem])? = nil,
        searchDelay: @escaping () async throws -> Void = { try await Task.sleep(for: .milliseconds(400)) },
        collectionLoader: ((MusicItem, Int) async throws -> MusicCollection)? = nil,
        collectionStore: CollectionStore? = nil,
        feedLoader: (() async throws -> [Shelf])? = nil
    ) {
        self.engine = engine ?? EngineClient()
        self.searchLoader = searchLoader
        self.searchDelay = searchDelay
        self.collectionLoader = collectionLoader
        self.suppliedCollectionStore = collectionStore
        self.feedLoader = feedLoader
        self.systemVolume = systemVolume ?? SystemVolume()
        let volume = self.systemVolume.snapshot
        playback.update(volume: volume.percent, volumeAvailable: volume.available)
        self.systemVolume.onChange = { [weak self] volume in
            self?.playback.update(volume: volume.percent, volumeAvailable: volume.available)
        }
        self.engine.onEvent = { [weak self] event, data in self?.handleEvent(event, data) }
    }

    func startMediaControls(system: MediaControlSystem? = nil) {
        guard mediaControls == nil else { return }
        let controls = system ?? NativeMediaControlSystem()
        mediaControls = controls
        controls.onCommand = { [weak self] action in
            guard let self, self.connected else { return }
            switch action {
            case .play: await self.playFromSelection()
            case .togglePlayPause: await self.togglePlaybackFromSelection()
            case .pause:
                if self.nowPlaying != nil { await self.command("pause") }
            case .previous:
                if self.nowPlaying != nil { await self.previous() }
            case .next:
                if self.nowPlaying != nil { await self.next() }
            }
        }
        updateMediaControls()
    }

    private func updateMediaControls() {
        guard connected, let item = nowPlaying ?? (canTogglePlayback ? collectionItem : nil) else {
            mediaControls?.update(nil)
            return
        }
        let hasPlayback = nowPlaying != nil
        mediaControls?.update(.init(item: item, isPlaying: hasPlayback && playback.isPlaying,
                                   positionMS: hasPlayback ? playback.positionMS : 0,
                                   durationMS: hasPlayback ? playback.durationMS : 0,
                                   hasCurrentPlayback: hasPlayback, canPlay: canTogglePlayback))
    }

    func connect() async {
        guard !busy else { return }
        if connected { engine.shutdown(); connected = false; playback.update(isPlaying: false) }
        busy = true
        error = nil
        status = "Waiting for Spotify sign-in…"
        defer { busy = false }
        let connectionRevision = accountRevision
        do {
            let account = try await engine.call("authenticate", timeout: 300)
            guard connectionRevision == accountRevision else { return }
            await activateCollectionAccount(account["username"] as? String)
            // activateCollectionAccount advances once. A disconnect while the
            // disk cache is loading advances again and must abort this connect.
            guard accountRevision == connectionRevision + 1 else { return }
            connected = true
            if nowPlaying == nil, let checkpointURL, let checkpoint = PlaybackCheckpoint.read(from: checkpointURL) {
                pendingRestore = checkpoint
                latestCheckpoint = checkpoint
                writtenCheckpoint = checkpoint
                playbackContextURI = checkpoint.contextURI
                nowPlaying = checkpoint.track
                playback.update(isPlaying: false, positionMS: Double(checkpoint.positionMS),
                                durationMS: Double(checkpoint.durationMS))
                setPlaybackContext(checkpoint.collection)
            }
            status = "Connected · this Mac"
            let revision = accountRevision
            let loaded = try await loadFeed()
            guard connected, revision == accountRevision else { return }
            shelves = loaded
        } catch { self.error = error.localizedDescription; status = connected ? "Connected · feed unavailable" : "Could not connect" }
    }

    func refresh() async {
        guard connected, !busy else { return }
        busy = true
        error = nil
        defer { busy = false }
        let revision = accountRevision
        collectionStore.invalidate()
        // Keep visible rows while replacing the first page. Never append to an
        // old playlist snapshot after an explicit refresh.
        let selected = collectionItem
        cancelCollectionRequest()
        let detailRevision = collectionRevision
        if let selected {
            Task { [weak self] in
                guard let self, self.connected, revision == self.accountRevision,
                      detailRevision == self.collectionRevision,
                      self.collectionItem?.id == selected.id else { return }
                await self.loadCollection(selected)
            }
        }
        prefetchHomeCollections()
        do {
            let loaded = try await loadFeed()
            guard connected, revision == accountRevision else { return }
            shelves = loaded
            status = "Connected · this Mac"
        } catch is CancellationError {} catch {
            guard connected, revision == accountRevision else { return }
            self.error = error.localizedDescription
        }
    }

    private func loadFeed() async throws -> [Shelf] {
        if let feedLoader { return try await feedLoader() }
        return try await api.madeForYou()
    }

    func activateCollectionAccount(_ accountID: String?) async {
        clearAccountContent()
        if let accountID, !accountID.isEmpty {
            checkpointURL = PlaybackCheckpoint.file(in: engine.dataDirectory, accountID: accountID)
            await collectionStore.activate(accountID: accountID)
        }
    }

    private func clearAccountContent() {
        writePlaybackCheckpoint()
        accountRevision += 1
        playbackRequestRevision += 1
        playRequestInFlight = false
        playbackPositionConfirmed = false
        playbackContextURI = nil
        checkpointURL = nil
        latestCheckpoint = nil
        writtenCheckpoint = nil
        pendingRestore = nil
        restoringPlayback = false
        setPlaybackContext(nil)
        collectionStore.reset()
        invalidateSearch()
        query = ""
        closeCollection()
        prefetchShelfCount = 6
        shelves = []
        nowPlaying = nil
        playback.update(isPlaying: false, positionMS: 0, durationMS: 0)
        updateMediaControls()
    }

    /// Warm the first six displayed shelves, then one shelf ahead of scrolling.
    func prefetchHomeCollections(approaching shelfID: String? = nil) {
        guard connected else { return }
        let visible = visibleHomeShelves
        if let shelfID, let index = visible.firstIndex(where: { $0.id == shelfID }) {
            prefetchShelfCount = max(prefetchShelfCount, index + 2)
        }
        collectionStore.prefetch(visible.prefix(prefetchShelfCount).flatMap(\.items))
    }

    func prefetchCollections(_ items: [MusicItem]) {
        guard connected else { return }
        collectionStore.prefetch(items)
    }

    func loadMore(_ shelf: Shelf) async {
        guard connected, !busy else { return }
        busy = true
        defer { busy = false }
        let revision = accountRevision
        do {
            let page = try await api.moreItems(in: shelf)
            guard connected, revision == accountRevision else { return }
            guard let index = shelves.firstIndex(where: { $0.id == shelf.id }) else { return }
            var seen = Set(shelves[index].items.map(\.id))
            shelves[index].items += (page?.items ?? []).filter { seen.insert($0.id).inserted }
            let next = page?.nextOffset
            shelves[index].nextOffset = (next ?? 0) > (shelf.nextOffset ?? 0) ? next : nil
        } catch {
            guard connected, revision == accountRevision else { return }
            self.error = error.localizedDescription
        }
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
        collectionItem = item
        // This assignment happens before any suspension or network request.
        collection = collectionStore.cachedCollection(for: item)
        collectionSnapshot = collectionStore.generation(for: item)
        if collection != nil, collectionStore.isFresh(for: item) { return }
        await loadCollection(item)
    }

    private func loadCollection(_ item: MusicItem) async {
        guard connected, collectionItem?.id == item.id else { return }
        collectionLoading = collection == nil
        collectionRefreshing = true
        collectionError = nil
        collectionFailedOffset = nil
        let revision = collectionRevision
        let task = makeCollectionTask(item, offset: 0)
        collectionTask = task
        defer {
            if revision == collectionRevision {
                collectionLoading = false
                collectionRefreshing = false
                collectionTask = nil
            }
        }
        do {
            let result = try await task.value
            guard revision == collectionRevision, !task.isCancelled else { return }
            collection = result
            collectionSnapshot = collectionStore.generation(for: item)
        } catch is CancellationError {} catch {
            guard revision == collectionRevision, !task.isCancelled else { return }
            if error is SpotifyCollectionUnavailable { collection = nil }
            collectionError = error.localizedDescription
            collectionFailedOffset = 0
        }
    }

    private func cancelCollectionRequest() {
        collectionRevision += 1
        collectionTask?.cancel()
        collectionTask = nil
        collectionLoading = false
        collectionRefreshing = false
    }

    func closeCollection() {
        cancelCollectionRequest()
        collectionItem = nil
        collection = nil
        collectionError = nil
        collectionFailedOffset = nil
    }

    func retryCollection(_ item: MusicItem) async {
        guard connected, collectionItem?.id == item.id else { return }
        if let offset = collectionFailedOffset, offset > 0, collection != nil {
            await loadMoreCollection()
        } else {
            cancelCollectionRequest()
            await loadCollection(item)
        }
    }

    func loadMoreCollectionIfNeeded(near trackID: String) async {
        guard collectionError == nil, let current = collection,
              current.tracks.suffix(10).contains(where: { $0.id == trackID }) else { return }
        await loadMoreCollection()
    }

    func loadMoreCollection() async {
        guard connected, !collectionLoading, !collectionRefreshing, let current = collection,
              let offset = current.nextOffset else { return }
        // Offsets from an old first page cannot safely be combined with fresh
        // continuation pages. Revalidate before proceeding after the TTL.
        if !collectionStore.isFresh(for: current.item)
            || collectionSnapshot != collectionStore.generation(for: current.item) {
            await loadCollection(current.item)
            return
        }
        collectionLoading = true
        collectionError = nil
        collectionFailedOffset = nil
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
            if reconcileCollectionSnapshot(for: current.item) { return }
            var merged = current
            var seen = Set(current.tracks.map(\.id))
            merged.tracks += page.tracks.filter { seen.insert($0.id).inserted }
            merged.totalCount = page.totalCount ?? current.totalCount
            merged.nextOffset = page.nextOffset.flatMap { $0 > offset ? $0 : nil }
            collection = merged
        } catch is CancellationError {
            guard revision == collectionRevision, !task.isCancelled else { return }
            // A refreshed first page cancels older continuation requests. Its
            // cancellation is also a signal to replace the visible snapshot.
            _ = reconcileCollectionSnapshot(for: current.item)
        } catch {
            guard revision == collectionRevision, !task.isCancelled else { return }
            if error is SpotifyCollectionUnavailable { collection = nil }
            collectionError = error.localizedDescription
            collectionFailedOffset = offset
        }
    }

    private func reconcileCollectionSnapshot(for item: MusicItem) -> Bool {
        let generation = collectionStore.generation(for: item)
        guard collectionSnapshot != generation else { return false }
        collection = collectionStore.cachedCollection(for: item)
        collectionSnapshot = generation
        return true
    }

    private func makeCollectionTask(_ item: MusicItem, offset: Int) -> Task<MusicCollection, Error> {
        let store = collectionStore
        return Task {
            try await store.collection(item, offset: offset)
        }
    }

    func isCurrentPlaybackContext(collection item: MusicItem) -> Bool {
        connected && nowPlaying != nil && playbackCollectionID == item.id
    }

    private var canStartSelectedCollection: Bool {
        guard let item = collectionItem, ["playlist", "album", "artist"].contains(item.kind) else { return false }
        // Playback resolves the URI itself, so a cold or failed content fetch
        // must not delay the keyboard. Only a known exhausted list can rule it out.
        guard let collection, collection.item.id == item.id else { return true }
        return collection.nextOffset != nil || collection.tracks.contains(where: \.isPlayable)
    }

    var canTogglePlayback: Bool {
        guard connected else { return false }
        if let item = collectionItem {
            return isCurrentPlaybackContext(collection: item) || canStartSelectedCollection
        }
        return nowPlaying != nil
    }

    /// Space and media toggle use the selected collection, then the current song
    /// when browsing the library without a selection.
    func togglePlaybackFromSelection() async {
        guard canTogglePlayback else { return }
        if let item = collectionItem { await toggleCollectionPlayback(item) }
        else { await togglePlayback() }
    }

    private func playFromSelection() async {
        guard canTogglePlayback else { return }
        if let item = collectionItem, !isCurrentPlaybackContext(collection: item) {
            await play(item, context: item)
        } else {
            // An explicit Play command must never pause an already-playing song.
            await command("resume")
        }
    }

    func toggleCollectionPlayback(_ item: MusicItem) async {
        guard connected else { return }
        if isCurrentPlaybackContext(collection: item) {
            await togglePlayback()
        } else {
            // Loading the collection URI keeps Spotify's continuous queue.
            // Loading its first track would create a one-song queue instead.
            await play(item, context: item)
        }
    }

    private func setPlaybackContext(_ item: MusicItem?) {
        if playbackCollection != item { playbackCollection = item }
        updateMediaControls()
    }

    func play(_ item: MusicItem, context: MusicItem? = nil) async {
        guard connected, !restoringPlayback else { return }
        playbackRequestRevision += 1
        let requestRevision = playbackRequestRevision
        let account = accountRevision
        let trackRevision = playbackTrackRevision
        let playsCollection = ["playlist", "album", "artist"].contains(item.kind)
        let context = context ?? (playsCollection ? item : nil)
        playRequestInFlight = true
        defer { if requestRevision == playbackRequestRevision { playRequestInFlight = false } }
        do {
            _ = try await engine.call("play", ["uri": item.id])
            guard connected, account == accountRevision, requestRevision == playbackRequestRevision else { return }
            let trackChanged = trackRevision != playbackTrackRevision
            pendingRestore = nil
            playbackContextURI = playsCollection ? item.id : nil
            if !trackChanged {
                if nowPlaying != item { nowPlaying = item }
                playback.update(positionMS: 0, durationMS: 0)
            }
            setPlaybackContext(context)
            if trackChanged { recordPlaybackCheckpoint() }
            updateMediaControls()
            error = nil
        } catch {
            guard connected, account == accountRevision, requestRevision == playbackRequestRevision else { return }
            self.error = error.localizedDescription
        }
    }

    func togglePlayback() async { await command(playback.isPlaying ? "pause" : "resume") }
    func previous() async { await command("previous") }
    func next() async { await command("next") }
    func seek(_ ms: Double) async {
        guard connected, !restoringPlayback, let position = UInt32(exactly: max(0, ms.rounded(.towardZero))) else { return }
        if var checkpoint = pendingRestore {
            checkpoint.positionMS = min(position, checkpoint.durationMS)
            pendingRestore = checkpoint
            latestCheckpoint = checkpoint
            playback.update(positionMS: Double(checkpoint.positionMS))
            updateMediaControls()
            writePlaybackCheckpoint()
        } else {
            await command("seek", ["position_ms": position])
        }
    }
    func setVolume(_ value: Double) {
        do { try systemVolume.setVolume(value) }
        catch { self.error = error.localizedDescription }
    }

    private func command(_ method: String, _ params: [String: Any] = [:]) async {
        guard connected, !restoringPlayback else { return }
        let revision = accountRevision
        do {
            if let checkpoint = pendingRestore {
                guard !playRequestInFlight, ["resume", "previous", "next"].contains(method) else { return }
                restoringPlayback = true
                defer { if revision == accountRevision { restoringPlayback = false } }
                var restoreParams: [String: Any] = ["track_uri": checkpoint.track.id,
                                                     "position_ms": checkpoint.positionMS,
                                                     "start_playing": method == "resume"]
                restoreParams["context_uri"] = checkpoint.contextURI
                let result = try await engine.call("restore", restoreParams)
                guard connected, revision == accountRevision else { return }
                pendingRestore = nil
                if result["context_restored"] as? Bool != true { playbackContextURI = nil }
                recordPlaybackCheckpoint()
                if method == "resume" { error = nil; return }
            }
            _ = try await engine.call(method, params)
            if revision == accountRevision { error = nil }
        } catch {
            if revision == accountRevision { self.error = error.localizedDescription }
        }
    }

    private func recordPlaybackCheckpoint() {
        guard checkpointURL != nil, pendingRestore == nil, playbackPositionConfirmed, let track = nowPlaying,
              let duration = UInt32(exactly: playback.durationMS), duration > 0,
              let position = UInt32(exactly: playback.positionMS) else { return }
        let checkpoint = PlaybackCheckpoint(track: track, collection: playbackCollection, contextURI: playbackContextURI,
                                            positionMS: min(position, duration), durationMS: duration)
        latestCheckpoint = checkpoint
        let savedPosition = writtenCheckpoint?.positionMS ?? 0
        if !playback.isPlaying || writtenCheckpoint?.track.id != track.id || writtenCheckpoint?.contextURI != playbackContextURI
            || checkpoint.positionMS < savedPosition || checkpoint.positionMS - savedPosition >= 5_000 {
            writePlaybackCheckpoint()
        }
    }

    private func writePlaybackCheckpoint() {
        guard let checkpointURL, let latestCheckpoint, latestCheckpoint != writtenCheckpoint else { return }
        if (try? latestCheckpoint.write(to: checkpointURL)) != nil { writtenCheckpoint = latestCheckpoint }
    }

    func handleEvent(_ event: String, _ data: [String: Any]) {
        if event == "disconnected" || (event == "connection" && data["connected"] as? Bool == false) {
            if !connected { clearAccountContent() }
            connected = false
            playback.update(isPlaying: false)
            status = "Disconnected"
        }
        if event == "playback" {
            let uri = data["track_uri"] as? String
            if let checkpoint = pendingRestore {
                guard uri != nil, !restoringPlayback || uri == checkpoint.track.id else { return }
                if !restoringPlayback, !playRequestInFlight, data["position_confirmed"] as? Bool == true {
                    pendingRestore = nil
                    playbackContextURI = nil
                    setPlaybackContext(nil)
                }
            }
            playbackPositionConfirmed = data["position_confirmed"] as? Bool == true
            playback.update(
                isPlaying: data["is_playing"] as? Bool,
                positionMS: data["position_ms"] as? Double,
                durationMS: data["duration_ms"] as? Double
            )
            if let uri {
                // Even the same song is authoritative: another collection can
                // start with it before its play request returns.
                playbackTrackRevision += 1
                // The helper has no context ID. A next track may be beyond the
                // cached page, so track changes cannot reliably clear context.
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
            if !playRequestInFlight { recordPlaybackCheckpoint() }
            updateMediaControls()
        }
        if event == "error", let message = data["message"] as? String { error = message }
    }

    func shutdown() {
        mediaControls?.stop()
        mediaControls = nil
        connected = false
        clearAccountContent()
        systemVolume.stop()
        engine.shutdown()
    }
}
