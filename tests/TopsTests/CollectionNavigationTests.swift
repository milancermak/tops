import XCTest
@testable import Tops

@MainActor
final class CollectionNavigationTests: XCTestCase {
    private func item(_ id: String) -> MusicItem {
        MusicItem(id: "spotify:playlist:\(id)", title: id, subtitle: "", imageURL: nil, kind: "playlist")
    }

    private func track(_ index: Int, uri: String = "spotify:track:repeated") -> CollectionTrack {
        CollectionTrack(id: "row-\(index)", uri: uri, title: "Track \(index)", artist: "Artist",
                        durationMS: 180_000, imageURL: nil, isPlayable: true)
    }

    func testLeavingDetailDiscardsItsLateResponse() async {
        let started = expectation(description: "Collection request started")
        var response: CheckedContinuation<MusicCollection, Error>?
        let selected = item("first")
        let model = AppModel(collectionLoader: { _, _ in
            try await withCheckedThrowingContinuation {
                response = $0
                started.fulfill()
            }
        })
        model.connected = true
        let request = Task { await model.openCollection(selected) }
        await fulfillment(of: [started], timeout: 2)
        XCTAssertTrue(model.collectionLoading)
        model.closeCollection()
        response?.resume(returning: MusicCollection(item: selected, tracks: [], totalCount: 0, nextOffset: nil))
        await request.value
        XCTAssertNil(model.collection)
        XCTAssertNil(model.collectionError)
        XCTAssertFalse(model.collectionLoading)
        XCTAssertNil(model.nowPlaying, "Opening a collection must not start playback")
    }

    func testOlderRequestCannotReplaceNewDetailOrClearItsSpinner() async {
        let firstStarted = expectation(description: "First started")
        let secondStarted = expectation(description: "Second started")
        let first = item("first"), second = item("second")
        var responses: [String: CheckedContinuation<MusicCollection, Error>] = [:]
        let model = AppModel(collectionLoader: { selected, _ in
            try await withCheckedThrowingContinuation {
                responses[selected.id] = $0
                (selected.id == first.id ? firstStarted : secondStarted).fulfill()
            }
        })
        model.connected = true
        let old = Task { await model.openCollection(first) }
        await fulfillment(of: [firstStarted], timeout: 2)
        let current = Task { await model.openCollection(second) }
        await fulfillment(of: [secondStarted], timeout: 2)
        responses[first.id]?.resume(throwing: TopsError(message: "Old request failed"))
        await old.value
        XCTAssertTrue(model.collectionLoading)
        XCTAssertNil(model.collectionError)
        responses[second.id]?.resume(returning: MusicCollection(item: second, tracks: [], totalCount: 0, nextOffset: nil))
        await current.value
        XCTAssertEqual(model.collection?.item.id, second.id)
        XCTAssertFalse(model.collectionLoading)
    }

    func testPaginationKeepsRepeatedSongsAndStopsOnNonadvancingOffset() async {
        let selected = item("playlist")
        let first = track(0), second = track(1)
        var offsets: [Int] = []
        let model = AppModel(collectionLoader: { _, offset in
            offsets.append(offset)
            return offset == 0
                ? MusicCollection(item: selected, tracks: [first], totalCount: 2, nextOffset: 1)
                : MusicCollection(item: selected, tracks: [first, second], totalCount: 2, nextOffset: 1)
        })
        model.connected = true
        await model.openCollection(selected)
        await model.loadMoreCollection()
        await model.loadMoreCollection()
        XCTAssertEqual(offsets, [0, 1])
        XCTAssertEqual(model.collection?.tracks.map(\.id), [first.id, second.id])
        XCTAssertNil(model.collection?.nextOffset)
    }

    func testFailedNextPageKeepsTracksAndCanBeRetried() async {
        let selected = item("playlist")
        let first = track(0), second = track(1)
        var nextAttempts = 0
        let model = AppModel(collectionLoader: { _, offset in
            if offset == 0 {
                return MusicCollection(item: selected, tracks: [first], totalCount: 2, nextOffset: 1)
            }
            nextAttempts += 1
            if nextAttempts == 1 { throw TopsError(message: "Temporary failure") }
            return MusicCollection(item: selected, tracks: [second], totalCount: 2, nextOffset: nil)
        })
        model.connected = true
        await model.openCollection(selected)
        await model.loadMoreCollection()
        XCTAssertEqual(model.collection?.tracks.count, 1)
        XCTAssertEqual(model.collection?.nextOffset, 1)
        XCTAssertEqual(model.collectionError, "Temporary failure")
        XCTAssertFalse(model.collectionLoading)
        await model.loadMoreCollection()
        XCTAssertEqual(model.collection?.tracks.count, 2)
        XCTAssertNil(model.collectionError)
    }
}
