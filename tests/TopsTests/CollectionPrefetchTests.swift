import Combine
import XCTest
@testable import Tops

@MainActor
final class CollectionPrefetchTests: XCTestCase {
    private func item(_ name: String, kind: String = "playlist") -> MusicItem {
        MusicItem(id: "spotify:\(kind):\(name)", title: name, subtitle: "", imageURL: nil, kind: kind)
    }

    private func shelf(_ name: String, title: String? = nil, items: [MusicItem]? = nil) -> Shelf {
        Shelf(id: name, title: title ?? name, items: items ?? [item(name)])
    }

    private func track(_ position: Int, title: String = "Track", uri: String = "spotify:track:repeated") -> CollectionTrack {
        CollectionTrack(id: "row-\(position)", uri: uri, title: title, artist: "Artist",
                        durationMS: 180_000, imageURL: nil, isPlayable: true)
    }

    private func page(_ item: MusicItem, tracks: [CollectionTrack] = [], next: Int? = nil) -> MusicCollection {
        MusicCollection(item: item, tracks: tracks, totalCount: nil, nextOffset: next)
    }

    func testFirstSixDisplayedShelvesPrefetchUniqueCollectionsAndCachedOpeningNeedsNoRequest() async throws {
        let shared = item("shared")
        let expected = [item("discovery"), shared, item("daily"), item("zero"), item("one"), item("two"), item("three")]
        let prefetched = expectation(description: "Every collection in six displayed shelves requested")
        prefetched.expectedFulfillmentCount = expected.count
        var requests: [String] = []
        let store = CollectionStore(directory: nil) { selected, offset in
            XCTAssertEqual(offset, 0, "Home prefetch fetches only the first 50-entry page")
            requests.append(selected.id)
            prefetched.fulfill()
            return self.page(selected, tracks: [self.track(0)])
        }
        let model = AppModel(collectionStore: store)
        defer { model.shutdown() }
        model.connected = true
        model.shelves = [
            shelf("hidden", title: "Watch What You Love"),
            shelf("zero"), shelf("one"), shelf("two"), shelf("three"), shelf("four"),
            shelf("discovery", title: "Discover New Music", items: [item("discovery"), shared, item("song", kind: "track")]),
            shelf("daily", title: "Your Daily Mixes", items: [item("daily"), shared])
        ]
        await fulfillment(of: [prefetched], timeout: 2)
        // Join existing work so all successful results are cached before opening.
        for selected in expected { _ = try await store.collection(selected) }
        XCTAssertEqual(Set(requests), Set(expected.map(\.id)))
        XCTAssertEqual(requests.count, expected.count, "Duplicate cards and track cards must not create extra requests")
        await model.openCollection(shared)
        XCTAssertEqual(model.collection?.item.id, shared.id)
        XCTAssertFalse(model.collectionLoading)
        XCTAssertEqual(requests.count, expected.count, "Opening a prefetched collection must do no content request")
        XCTAssertNil(model.nowPlaying)
    }

    func testScrollingWarmsOneShelfAheadAndNewCardsWithoutRefetchingWarmShelves() async throws {
        let initial = expectation(description: "Initial six shelves requested")
        initial.expectedFulfillmentCount = 6
        let lookahead = expectation(description: "Seventh shelf prefetched before entering it")
        let appended = expectation(description: "Newly added card prefetched")
        var requests: [String] = []
        let store = CollectionStore(directory: nil) { selected, _ in
            requests.append(selected.id)
            if selected.title == "6" { lookahead.fulfill() }
            else if selected.title == "added" { appended.fulfill() }
            else { initial.fulfill() }
            return self.page(selected)
        }
        let model = AppModel(collectionStore: store)
        defer { model.shutdown() }
        model.connected = true
        model.shelves = (0..<8).map { shelf(String($0)) }
        await fulfillment(of: [initial], timeout: 2)
        for index in 0..<6 { _ = try await store.collection(item(String(index))) }
        model.prefetchHomeCollections(approaching: "5")
        model.prefetchHomeCollections(approaching: "5")
        await fulfillment(of: [lookahead], timeout: 2)
        _ = try await store.collection(item("6"))
        model.shelves[6].items.append(item("added"))
        await fulfillment(of: [appended], timeout: 2)
        _ = try await store.collection(item("added"))
        XCTAssertEqual(Set(requests), Set((0...6).map { item(String($0)).id } + [item("added").id]))
        XCTAssertEqual(requests.count, 8)
        XCTAssertNil(store.cachedCollection(for: item("7")), "An unseen shelf beyond lookahead should remain cold")
    }

    func testExpiredPageDisplaysDuringRefreshAndFailureRetriesFirstPageWithoutLosingRows() async throws {
        let selected = item("stale")
        let original = track(0, title: "Cached")
        let replacement = track(0, title: "Updated")
        let started = expectation(description: "Expired page refresh started")
        var now = Date(timeIntervalSince1970: 1_000)
        var response: CheckedContinuation<MusicCollection, Error>?
        var offsets: [Int] = []
        let store = CollectionStore(directory: nil, now: { now }, freshness: 60) { item, offset in
            offsets.append(offset)
            switch offsets.count {
            case 1: return self.page(item, tracks: [original], next: 50)
            case 2:
                return try await withCheckedThrowingContinuation {
                    response = $0
                    started.fulfill()
                }
            default: return self.page(item, tracks: [replacement])
            }
        }
        _ = try await store.collection(selected)
        now.addTimeInterval(61)
        let model = AppModel(collectionStore: store)
        defer { model.shutdown() }
        model.connected = true
        let opening = Task { await model.openCollection(selected) }
        await fulfillment(of: [started], timeout: 2)
        XCTAssertEqual(model.collection?.tracks, [original], "The HTTP response must not gate cached rows")
        XCTAssertFalse(model.collectionLoading, "Stale rows should remain usable without an initial-loading spinner")
        response?.resume(throwing: TopsError(message: "Temporary failure"))
        await opening.value
        XCTAssertEqual(model.collection?.tracks, [original])
        XCTAssertEqual(model.collectionError, "Temporary failure")
        await model.retryCollection(selected)
        XCTAssertEqual(offsets, [0, 0, 0], "Retry after a stale first-page failure must not append page 50")
        XCTAssertEqual(model.collection?.tracks, [replacement])
        XCTAssertNil(model.collectionError)
    }

    func testManualRefreshReplacesFreshPageAndRejectsLatePagination() async {
        let selected = item("refreshed")
        let original = track(0, title: "Before refresh")
        let replacement = track(0, title: "After refresh")
        let obsolete = track(50, title: "Obsolete continuation")
        let pagingStarted = expectation(description: "Old continuation started")
        let refreshed = expectation(description: "Fresh first page replaced visible collection")
        let lateReturned = expectation(description: "Noncooperative old continuation returned")
        var pageResponse: CheckedContinuation<MusicCollection, Error>?
        var offsets: [Int] = []
        let store = CollectionStore(directory: nil) { item, offset in
            offsets.append(offset)
            if offset == 50 {
                let result = try await withCheckedThrowingContinuation { continuation in
                    pageResponse = continuation
                    pagingStarted.fulfill()
                }
                lateReturned.fulfill()
                return result
            }
            return self.page(item, tracks: [offsets.count == 1 ? original : replacement], next: offsets.count == 1 ? 50 : nil)
        }
        var feedRequests = 0
        let model = AppModel(collectionStore: store, feedLoader: {
            feedRequests += 1
            return []
        })
        defer { model.shutdown() }
        model.connected = true
        await model.openCollection(selected)
        let paging = Task { await model.loadMoreCollection() }
        await fulfillment(of: [pagingStarted], timeout: 2)
        let subscription = model.$collection.sink { value in
            if value?.tracks == [replacement] { refreshed.fulfill() }
        }
        await model.refresh()
        await fulfillment(of: [refreshed], timeout: 2)
        XCTAssertEqual(feedRequests, 1)
        XCTAssertEqual(offsets, [0, 50, 0], "Explicit Refresh must bypass a still-fresh first page")
        pageResponse?.resume(returning: page(selected, tracks: [obsolete]))
        await paging.value
        await fulfillment(of: [lateReturned], timeout: 2)
        XCTAssertEqual(model.collection?.tracks, [replacement])
        XCTAssertNil(store.cachedCollection(for: selected, offset: 50))
        XCTAssertNil(model.collection?.nextOffset)
        XCTAssertNil(model.collectionError)
        withExtendedLifetime(subscription) {}
    }

    func testDisconnectClearsAccountContentAndLateResponseCannotPopulateNewAccount() async {
        let selected = item("same-uri")
        let oldTrack = track(0, title: "Old account")
        let newTrack = track(0, title: "New account")
        let started = expectation(description: "Old account load started")
        let lateReturned = expectation(description: "Old account load returned after switching")
        var response: CheckedContinuation<MusicCollection, Error>?
        var requests = 0
        let store = CollectionStore(directory: nil) { item, _ in
            requests += 1
            if requests == 1 {
                let result = try await withCheckedThrowingContinuation { continuation in
                    response = continuation
                    started.fulfill()
                }
                lateReturned.fulfill()
                return result
            }
            return self.page(item, tracks: [newTrack])
        }
        let model = AppModel(collectionStore: store)
        defer { model.shutdown() }
        await model.activateCollectionAccount("first-account")
        model.connected = true
        model.results = [selected]
        model.nowPlaying = selected
        let opening = Task { await model.openCollection(selected) }
        await fulfillment(of: [started], timeout: 2)
        model.shelves = [shelf("old", items: [selected])]
        model.handleEvent("disconnected", [:])
        await opening.value
        XCTAssertFalse(model.connected)
        XCTAssertTrue(model.shelves.isEmpty)
        XCTAssertTrue(model.results.isEmpty)
        XCTAssertNil(model.nowPlaying)
        XCTAssertNil(model.collection)
        XCTAssertFalse(model.collectionLoading)
        await model.activateCollectionAccount("second-account")
        model.connected = true
        await model.openCollection(selected)
        XCTAssertEqual(model.collection?.tracks, [newTrack])
        response?.resume(returning: page(selected, tracks: [oldTrack]))
        await fulfillment(of: [lateReturned], timeout: 2)
        XCTAssertEqual(model.collection?.tracks, [newTrack])
        XCTAssertEqual(store.cachedCollection(for: selected)?.tracks, [newTrack])
        XCTAssertEqual(requests, 2)
    }

    func testNearEndPaginationKeepsRowsOnFailureAndRetryUsesFailedOffset() async {
        let selected = item("paging")
        let first = (0..<30).map { track($0) }
        let last = track(50)
        var offsets: [Int] = []
        let store = CollectionStore(directory: nil) { item, offset in
            offsets.append(offset)
            if offset == 0 { return self.page(item, tracks: first, next: 50) }
            if offsets.count == 2 { throw TopsError(message: "Page failed") }
            return self.page(item, tracks: [last])
        }
        let model = AppModel(collectionStore: store)
        defer { model.shutdown() }
        model.connected = true
        await model.openCollection(selected)
        await model.loadMoreCollectionIfNeeded(near: first[0].id)
        XCTAssertEqual(offsets, [0])
        await model.loadMoreCollectionIfNeeded(near: first[20].id)
        XCTAssertEqual(model.collection?.tracks, first)
        XCTAssertEqual(model.collectionError, "Page failed")
        await model.retryCollection(selected)
        XCTAssertEqual(offsets, [0, 50, 50])
        XCTAssertEqual(model.collection?.tracks, first + [last], "Repeated track URIs keep their individual position identities")
        XCTAssertNil(model.collection?.nextOffset)
        XCTAssertNil(model.collectionError)
        await model.loadMoreCollectionIfNeeded(near: last.id)
        XCTAssertEqual(offsets, [0, 50, 50], "The final page must stop automatic pagination")
    }

    func testBackgroundFirstPageRefreshReplacesOpenSnapshotBeforeLoadingItsContinuation() async throws {
        let selected = item("background-refresh")
        let original = track(0, title: "Old first page")
        let replacement = track(0, title: "New first page")
        let continuation = track(100, title: "New continuation")
        var offsets: [Int] = []
        let store = CollectionStore(directory: nil) { item, offset in
            offsets.append(offset)
            if offset == 0 {
                return self.page(item, tracks: [offsets.count == 1 ? original : replacement],
                                 next: offsets.count == 1 ? 50 : 100)
            }
            return self.page(item, tracks: [continuation])
        }
        let model = AppModel(collectionStore: store)
        defer { model.shutdown() }
        model.connected = true
        await model.openCollection(selected)
        _ = try await store.collection(selected, forceRefresh: true)
        XCTAssertEqual(model.collection?.tracks, [original], "Background work has not yet replaced the open view")
        await model.loadMoreCollection()
        XCTAssertEqual(model.collection?.tracks, [replacement])
        XCTAssertEqual(model.collection?.nextOffset, 100)
        XCTAssertEqual(offsets, [0, 0], "The stale view's old offset must not be requested")
        await model.loadMoreCollection()
        XCTAssertEqual(offsets, [0, 0, 100])
        XCTAssertEqual(model.collection?.tracks, [replacement, continuation])
        XCTAssertNil(model.collection?.nextOffset)
    }

    func testManualRefreshRestartsInitialDetailLoadBeforeAnyRowsExist() async {
        let selected = item("initial-refresh")
        let obsolete = track(0, title: "Canceled initial result")
        let replacement = track(0, title: "Refreshed result")
        let started = expectation(description: "Initial detail request started")
        let refreshed = expectation(description: "Refresh restarted and populated the same detail")
        let lateReturned = expectation(description: "Initial request returned after replacement")
        var response: CheckedContinuation<MusicCollection, Error>?
        var requests = 0
        let store = CollectionStore(directory: nil) { item, offset in
            XCTAssertEqual(offset, 0)
            requests += 1
            if requests == 1 {
                let result = try await withCheckedThrowingContinuation { continuation in
                    response = continuation
                    started.fulfill()
                }
                lateReturned.fulfill()
                return result
            }
            return self.page(item, tracks: [replacement])
        }
        let model = AppModel(collectionStore: store, feedLoader: { [] })
        defer { model.shutdown() }
        model.connected = true
        let opening = Task { await model.openCollection(selected) }
        await fulfillment(of: [started], timeout: 2)
        XCTAssertNil(model.collection)
        XCTAssertTrue(model.collectionLoading)
        let subscription = model.$collection.sink { value in
            if value?.tracks == [replacement] { refreshed.fulfill() }
        }
        await model.refresh()
        await opening.value
        await fulfillment(of: [refreshed], timeout: 2)
        XCTAssertEqual(requests, 2)
        XCTAssertEqual(model.collection?.item.id, selected.id)
        response?.resume(returning: page(selected, tracks: [obsolete]))
        await fulfillment(of: [lateReturned], timeout: 2)
        XCTAssertEqual(model.collection?.tracks, [replacement])
        XCTAssertEqual(store.cachedCollection(for: selected)?.tracks, [replacement])
        XCTAssertFalse(model.collectionLoading)
        XCTAssertNil(model.collectionError)
        withExtendedLifetime(subscription) {}
    }

    func testBackgroundRefreshCancelsPendingContinuationAndReconcilesVisibleRows() async throws {
        let selected = item("concurrent-refresh")
        let original = track(0, title: "Old first page")
        let replacement = track(0, title: "New first page")
        let started = expectation(description: "Old continuation started")
        let lateReturned = expectation(description: "Canceled continuation returned")
        var pending: CheckedContinuation<MusicCollection, Error>?
        var firstPages = 0
        let store = CollectionStore(directory: nil) { item, offset in
            if offset == 0 {
                firstPages += 1
                return self.page(item, tracks: [firstPages == 1 ? original : replacement], next: firstPages == 1 ? 50 : nil)
            }
            let result = try await withCheckedThrowingContinuation { continuation in
                pending = continuation
                started.fulfill()
            }
            lateReturned.fulfill()
            return result
        }
        let model = AppModel(collectionStore: store)
        defer { model.shutdown() }
        model.connected = true
        await model.openCollection(selected)
        let pagination = Task { await model.loadMoreCollection() }
        await fulfillment(of: [started], timeout: 2)
        _ = try await store.collection(selected, forceRefresh: true)
        await pagination.value
        XCTAssertEqual(model.collection?.tracks, [replacement])
        XCTAssertNil(model.collection?.nextOffset)
        XCTAssertNil(model.collectionError)
        XCTAssertFalse(model.collectionLoading)
        pending?.resume(returning: page(selected, tracks: [track(50, title: "Obsolete")]))
        await fulfillment(of: [lateReturned], timeout: 2)
        XCTAssertEqual(model.collection?.tracks, [replacement])
    }

    func testUnavailableContinuationClearsRowsAndRetryStartsFirstPage() async {
        let selected = item("temporarily-unavailable")
        let restored = track(0, title: "Restored access")
        var offsets: [Int] = []
        let store = CollectionStore(directory: nil) { item, offset in
            offsets.append(offset)
            if offset == 50 { throw SpotifyCollectionUnavailable() }
            return self.page(item, tracks: [restored], next: offsets.count == 1 ? 50 : nil)
        }
        let model = AppModel(collectionStore: store)
        defer { model.shutdown() }
        model.connected = true
        await model.openCollection(selected)
        await model.loadMoreCollection()
        XCTAssertNil(model.collection, "An authoritative unavailable result must stop displaying cached rows")
        XCTAssertNotNil(model.collectionError)
        XCTAssertNil(store.cachedCollection(for: selected))
        await model.retryCollection(selected)
        XCTAssertEqual(offsets, [0, 50, 0], "Retry must restart from page zero after the old collection was removed")
        XCTAssertEqual(model.collection?.tracks, [restored])
        XCTAssertNil(model.collectionError)
    }
}
