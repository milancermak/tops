import XCTest
@testable import Tops

@MainActor
final class CollectionStoreTests: XCTestCase {
    private func item(_ id: String) -> MusicItem {
        MusicItem(id: "spotify:playlist:\(id)", title: id, subtitle: "", imageURL: nil, kind: "playlist")
    }

    private func page(_ selected: MusicItem, offset: Int = 0, title: String = "Track") -> MusicCollection {
        MusicCollection(item: selected,
                        tracks: [CollectionTrack(id: "\(selected.id):\(offset)", uri: "spotify:track:\(title)",
                                                 title: title, artist: "Artist", durationMS: 100,
                                                 imageURL: nil, isPlayable: true)],
                        totalCount: 100, nextOffset: offset == 0 ? 50 : nil)
    }

    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("TopsCollectionTests-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testFreshHitMakesNoRequestAndStalePageSurvivesFailedRefreshUntilExpiry() async throws {
        let selected = item("one")
        var time = Date(timeIntervalSince1970: 10_000)
        var calls = 0
        let store = CollectionStore(directory: nil, now: { time }, freshness: 10, retention: 100) { item, offset in
            calls += 1
            if calls > 1 { throw TopsError(message: "Offline") }
            return self.page(item, offset: offset)
        }
        _ = try await store.collection(selected)
        _ = try await store.collection(selected)
        XCTAssertEqual(calls, 1)
        XCTAssertTrue(store.isFresh(for: selected))
        time = time.addingTimeInterval(11)
        XCTAssertFalse(store.isFresh(for: selected))
        XCTAssertNotNil(store.cachedCollection(for: selected))
        do { _ = try await store.collection(selected); XCTFail("Expected refresh failure") }
        catch { XCTAssertEqual(error.localizedDescription, "Offline") }
        XCTAssertEqual(store.cachedCollection(for: selected)?.tracks.first?.title, "Track")
        time = time.addingTimeInterval(90)
        XCTAssertNil(store.cachedCollection(for: selected))
    }

    func testHydratesAllPagesAndUsesHashedAccountFile() async throws {
        let location = try directory()
        let selected = item("one")
        let store = CollectionStore(directory: location) { self.page($0, offset: $1) }
        await store.activate(accountID: "private-account-name")
        _ = try await store.collection(selected)
        _ = try await store.collection(selected, offset: 50)
        await store.flushPersistence()
        let files = try FileManager.default.contentsOfDirectory(at: location, includingPropertiesForKeys: nil)
        XCTAssertEqual(files.count, 1)
        XCTAssertEqual(files[0].deletingPathExtension().lastPathComponent.count, 64)
        XCTAssertFalse(files[0].lastPathComponent.contains("private-account-name"))
        var requests = 0
        let restored = CollectionStore(directory: location) { item, offset in
            requests += 1
            return self.page(item, offset: offset)
        }
        await restored.activate(accountID: "private-account-name")
        XCTAssertEqual(restored.cachedCollection(for: selected)?.tracks.count, 1)
        XCTAssertEqual(restored.cachedCollection(for: selected, offset: 50)?.tracks.first?.id, "\(selected.id):50")
        _ = try await restored.collection(selected)
        _ = try await restored.collection(selected, offset: 50)
        XCTAssertEqual(requests, 0)
    }

    func testAccountIsolationAndUnidentifiedSessionNeverWritesDisk() async throws {
        let location = try directory()
        let selected = item("one")
        var responseTitle = "Unidentified"
        let store = CollectionStore(directory: location) { self.page($0, offset: $1, title: responseTitle) }
        _ = try await store.collection(selected)
        await store.flushPersistence()
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: location.path).isEmpty)
        await store.activate(accountID: "alice")
        XCTAssertNil(store.cachedCollection(for: selected))
        responseTitle = "Alice"
        _ = try await store.collection(selected)
        await store.flushPersistence()
        await store.activate(accountID: "bob")
        XCTAssertNil(store.cachedCollection(for: selected))
        responseTitle = "Bob"
        _ = try await store.collection(selected)
        await store.flushPersistence()
        await store.activate(accountID: "alice")
        XCTAssertEqual(store.cachedCollection(for: selected)?.tracks.first?.title, "Alice")
        store.reset()
        XCTAssertNil(store.cachedCollection(for: selected))
    }

    func testExplicitInvalidationPersistsStaleMarkerAndClearsContinuationOnRefresh() async throws {
        let location = try directory()
        let selected = item("one")
        let store = CollectionStore(directory: location) { self.page($0, offset: $1) }
        await store.activate(accountID: "alice")
        _ = try await store.collection(selected)
        _ = try await store.collection(selected, offset: 50)
        let generation = store.generation(for: selected)
        store.invalidate()
        XCTAssertFalse(store.isFresh(for: selected))
        XCTAssertNotNil(store.cachedCollection(for: selected))
        await store.flushPersistence()
        let restored = CollectionStore(directory: location) { self.page($0, offset: $1) }
        await restored.activate(accountID: "alice")
        XCTAssertFalse(restored.isFresh(for: selected))
        XCTAssertNotNil(restored.cachedCollection(for: selected, offset: 50))
        _ = try await store.collection(selected)
        XCTAssertGreaterThan(store.generation(for: selected), generation)
        XCTAssertNil(store.cachedCollection(for: selected, offset: 50))
        XCTAssertTrue(store.isFresh(for: selected))
    }

    func testRefreshRejectsLateContinuationEvenWhenTotalCountIsUnchanged() async throws {
        let selected = item("one")
        let loader = ControlledCollectionLoader()
        let store = CollectionStore(directory: nil, loader: loader.load)
        defer { store.reset(); loader.failAll() }
        let first = Task { try await store.collection(selected) }
        await loader.waitForStarts(1, test: self)
        loader.succeed(selected, offset: 0, page: page(selected))
        _ = try await first.value
        let next = Task { try await store.collection(selected, offset: 50) }
        await loader.waitForStarts(2, test: self)
        let refresh = Task { try await store.collection(selected, forceRefresh: true) }
        await loader.waitForStarts(3, test: self)
        loader.succeed(selected, offset: 0, page: page(selected, title: "New"))
        _ = try await refresh.value
        do { _ = try await next.value; XCTFail("An old page must be canceled") }
        catch { XCTAssertTrue(error is CancellationError) }
        loader.succeed(selected, offset: 50, page: page(selected, offset: 50, title: "Old"))
        // The next foreground operation is a main-actor barrier after the old
        // loader's completion; the generation guard must leave its page absent.
        let other = item("other")
        let barrier = Task { try await store.collection(other) }
        await loader.waitForStarts(4, test: self)
        loader.succeed(other, offset: 0, page: page(other))
        _ = try await barrier.value
        XCTAssertNil(store.cachedCollection(for: selected, offset: 50))
        XCTAssertEqual(store.cachedCollection(for: selected)?.tracks.first?.title, "New")
    }

    func testPrefetchIsDeduplicatedBoundedAndForegroundOutranksQueuedWork() async throws {
        let items = [item("a"), item("b"), item("c"), item("d")]
        let foregroundItem = item("clicked")
        let loader = ControlledCollectionLoader()
        let store = CollectionStore(directory: nil, loader: loader.load)
        defer { store.reset(); loader.failAll() }
        store.prefetch(items + items)
        await loader.waitForStarts(2, test: self)
        XCTAssertEqual(loader.starts.map(\.id), [items[0].id, items[1].id])
        let enqueued = expectation(description: "Foreground enqueued")
        let foreground = Task {
            enqueued.fulfill()
            return try await store.collection(foregroundItem)
        }
        await fulfillment(of: [enqueued], timeout: 2)
        loader.succeed(items[0], offset: 0, page: page(items[0]))
        await loader.waitForStarts(3, test: self)
        XCTAssertEqual(loader.starts[2].id, foregroundItem.id)
        loader.succeed(foregroundItem, offset: 0, page: page(foregroundItem))
        _ = try await foreground.value
        await loader.waitForStarts(4, test: self)
        XCTAssertEqual(loader.starts[3].id, items[2].id)
        loader.succeed(items[1], offset: 0, page: page(items[1]))
        await loader.waitForStarts(5, test: self)
        XCTAssertEqual(loader.starts[4].id, items[3].id)
        loader.succeed(items[2], offset: 0, page: page(items[2]))
        loader.succeed(items[3], offset: 0, page: page(items[3]))
        _ = try await store.collection(items[2])
        _ = try await store.collection(items[3])
        XCTAssertEqual(loader.starts.count, 5)
        XCTAssertEqual(loader.maximumActive, 2)
    }

    func testCancelingDetailDoesNotCancelSharedPrefetchOrOtherWaiters() async throws {
        let selected = item("one")
        let loader = ControlledCollectionLoader()
        let store = CollectionStore(directory: nil, loader: loader.load)
        defer { store.reset(); loader.failAll() }
        store.prefetch([selected, selected])
        await loader.waitForStarts(1, test: self)
        let waiting = expectation(description: "Detail waiting")
        let detail = Task {
            waiting.fulfill()
            return try await store.collection(selected)
        }
        await fulfillment(of: [waiting], timeout: 2)
        detail.cancel()
        do { _ = try await detail.value; XCTFail("Detail must observe cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        loader.succeed(selected, offset: 0, page: page(selected))
        _ = try await store.collection(selected)
        XCTAssertEqual(loader.starts.count, 1)
        XCTAssertNotNil(store.cachedCollection(for: selected))
    }

    func testAccountResetRejectsLateRequestWithoutExceedingConcurrencyLimit() async throws {
        let old = item("old"), current = item("current")
        let loader = ControlledCollectionLoader()
        let store = CollectionStore(directory: nil, loader: loader.load)
        defer { store.reset(); loader.failAll() }
        await store.activate(accountID: "alice")
        let oldRequest = Task { try await store.collection(old) }
        await loader.waitForStarts(1, test: self)
        await store.activate(accountID: "bob")
        do { _ = try await oldRequest.value; XCTFail("Old account request must be canceled") }
        catch { XCTAssertTrue(error is CancellationError) }
        let currentRequest = Task { try await store.collection(current) }
        await loader.waitForStarts(2, test: self)
        loader.succeed(old, offset: 0, page: page(old))
        loader.succeed(current, offset: 0, page: page(current))
        _ = try await currentRequest.value
        XCTAssertNil(store.cachedCollection(for: old))
        XCTAssertNotNil(store.cachedCollection(for: current))
        XCTAssertEqual(loader.maximumActive, 2)
    }

    func testBackgroundFailureBacksOffButExplicitForegroundRetryWorks() async throws {
        let selected = item("one"), barrierItem = item("barrier")
        var time = Date(timeIntervalSince1970: 10_000)
        var calls = 0
        let store = CollectionStore(directory: nil, now: { time }) { item, offset in
            if item.id == selected.id { calls += 1; throw TopsError(message: "Offline") }
            return self.page(item, offset: offset)
        }
        do { _ = try await store.collection(selected); XCTFail("Expected failure") } catch {}
        store.prefetch([selected])
        _ = try await store.collection(barrierItem, forceRefresh: true)
        XCTAssertEqual(calls, 1)
        do { _ = try await store.collection(selected); XCTFail("Foreground can retry") } catch {}
        XCTAssertEqual(calls, 2)
        time = time.addingTimeInterval(121)
        store.prefetch([selected])
        // Joining a pending background request also makes its completion deterministic.
        do { _ = try await store.collection(selected); XCTFail("Expected failure") } catch {}
        XCTAssertEqual(calls, 3)
    }

    func testRateLimitPausesQueuedBackgroundWork() async throws {
        var time = Date(timeIntervalSince1970: 10_000)
        let items = [item("a"), item("b"), item("c")]
        let loader = ControlledCollectionLoader()
        let store = CollectionStore(directory: nil, now: { time }, loader: loader.load)
        defer { store.reset(); loader.failAll() }
        store.prefetch(items)
        await loader.waitForStarts(2, test: self)
        let rateLimited = Task { try await store.collection(items[0]) }
        loader.fail(items[0], offset: 0, error: SpotifyRateLimited(retryAfter: 60))
        do { _ = try await rateLimited.value; XCTFail("Expected cooldown") } catch {}
        loader.succeed(items[1], offset: 0, page: page(items[1]))
        _ = try await store.collection(items[1])
        XCTAssertEqual(loader.starts.count, 2)
        time = time.addingTimeInterval(61)
        store.prefetch([])
        await loader.waitForStarts(3, test: self)
        XCTAssertEqual(loader.starts.last?.id, items[2].id)
        loader.succeed(items[2], offset: 0, page: page(items[2]))
        _ = try await store.collection(items[2])
    }

    func testLeastRecentlyUsedPageIsEvictedAndUnavailableCollectionIsRemoved() async throws {
        var time = Date(timeIntervalSince1970: 10_000)
        var unavailable = false
        let items = [item("a"), item("b"), item("c")]
        let store = CollectionStore(directory: nil, now: { time }, capacity: 2) { item, offset in
            if unavailable { throw SpotifyCollectionUnavailable() }
            return self.page(item, offset: offset)
        }
        _ = try await store.collection(items[0])
        time = time.addingTimeInterval(1)
        _ = try await store.collection(items[1])
        time = time.addingTimeInterval(1)
        _ = store.cachedCollection(for: items[0])
        time = time.addingTimeInterval(1)
        _ = try await store.collection(items[2])
        XCTAssertNotNil(store.cachedCollection(for: items[0]))
        XCTAssertNil(store.cachedCollection(for: items[1]))
        XCTAssertNotNil(store.cachedCollection(for: items[2]))
        unavailable = true
        do { _ = try await store.collection(items[0], forceRefresh: true); XCTFail("Expected unavailable") }
        catch { XCTAssertTrue(error is SpotifyCollectionUnavailable) }
        XCTAssertNil(store.cachedCollection(for: items[0]))
    }

    func testCorruptOrUnknownSchemaDiskCacheIsIgnored() async throws {
        let location = try directory()
        let selected = item("one")
        let store = CollectionStore(directory: location) { self.page($0, offset: $1) }
        await store.activate(accountID: "alice")
        _ = try await store.collection(selected)
        await store.flushPersistence()
        let file = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: location, includingPropertiesForKeys: nil).first)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        json["schemaVersion"] = 999
        try JSONSerialization.data(withJSONObject: json).write(to: file)
        let unknown = CollectionStore(directory: location) { self.page($0, offset: $1) }
        await unknown.activate(accountID: "alice")
        XCTAssertNil(unknown.cachedCollection(for: selected))
        try Data("corrupt".utf8).write(to: file)
        let corrupt = CollectionStore(directory: location) { self.page($0, offset: $1) }
        await corrupt.activate(accountID: "alice")
        XCTAssertNil(corrupt.cachedCollection(for: selected))
    }
}

/// Deliberately ignores cancellation to verify late-response guards and the
/// actual request limit rather than depending on URLSession cancellation timing.
@MainActor
private final class ControlledCollectionLoader {
    struct Start { var id: String; var offset: Int }
    var starts: [Start] = []
    var maximumActive = 0
    private var pending: [String: CheckedContinuation<MusicCollection, Error>] = [:]
    private var onStart: (() -> Void)?

    func load(_ item: MusicItem, _ offset: Int) async throws -> MusicCollection {
        try await withCheckedThrowingContinuation { continuation in
            pending[key(item, offset)] = continuation
            starts.append(Start(id: item.id, offset: offset))
            maximumActive = max(maximumActive, pending.count)
            onStart?()
        }
    }

    func waitForStarts(_ count: Int, test: XCTestCase) async {
        if starts.count >= count { return }
        let started = test.expectation(description: "Started \(count) requests")
        onStart = { [weak self] in
            if self?.starts.count == count { self?.onStart = nil; started.fulfill() }
        }
        await test.fulfillment(of: [started], timeout: 2)
        onStart = nil
    }

    func succeed(_ item: MusicItem, offset: Int, page: MusicCollection) {
        pending.removeValue(forKey: key(item, offset))?.resume(returning: page)
    }

    func fail(_ item: MusicItem, offset: Int, error: Error) {
        pending.removeValue(forKey: key(item, offset))?.resume(throwing: error)
    }

    func failAll() {
        for continuation in pending.values { continuation.resume(throwing: CancellationError()) }
        pending.removeAll()
    }

    private func key(_ item: MusicItem, _ offset: Int) -> String { "\(item.id)/\(offset)" }
}
