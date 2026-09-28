import Foundation
import XCTest
@testable import Tops

final class SpotifyCollectionParserTests: XCTestCase {
    private func item(_ kind: String) -> MusicItem {
        MusicItem(id: "spotify:\(kind):fixture", title: "Fixture", subtitle: "", imageURL: URL(string: "https://artwork.test/collection.jpg"), kind: kind)
    }

    private func track(_ title: String = "Song", playable: Bool = true) -> [String: Any] {
        ["uri": "spotify:track:repeated", "name": title,
         "artists": ["items": [["profile": ["name": "Artist"]]]],
         "duration": ["totalMilliseconds": 123_456], "playability": ["playable": playable]]
    }

    func testPlaylistPreservesDuplicatesUnavailableRowsAndRawPagination() throws {
        var song = track()
        song["__typename"] = "Track"
        song["duration"] = nil
        song["trackDuration"] = ["totalMilliseconds": 210_000]
        var unavailable = song
        unavailable["playability"] = ["playable": false]
        let rows: [Any] = [
            ["itemV2": ["__typename": "TrackResponseWrapper", "data": song]],
            NSNull(),
            ["itemV2": ["__typename": "TrackResponseWrapper", "data": unavailable]],
            ["itemV2": ["data": ["__typename": "Episode", "uri": "spotify:episode:ignored", "name": "Podcast"]]],
        ]
        let response: [String: Any] = ["data": ["playlistV2": [
            "__typename": "Playlist", "uri": "spotify:playlist:fixture", "name": "Live name",
            "content": ["items": rows, "totalCount": 80, "pagingInfo": ["offset": 50, "limit": 50]]
        ]]]
        let result = try SpotifyParser.collection(response, for: item("playlist"), offset: 50)
        XCTAssertEqual(result.item.title, "Live name")
        XCTAssertEqual(result.tracks.map(\.uri), ["spotify:track:repeated", "spotify:track:repeated"])
        XCTAssertEqual(result.tracks.map(\.id), ["spotify:playlist:fixture:50", "spotify:playlist:fixture:52"])
        XCTAssertEqual(result.tracks.map(\.isPlayable), [true, false])
        XCTAssertEqual(result.tracks.first?.durationMS, 210_000)
        XCTAssertEqual(result.tracks.first?.musicItem.subtitle, "Artist")
        XCTAssertEqual(result.totalCount, 80)
        XCTAssertEqual(result.nextOffset, 54, "Pagination advances by raw rows, including omitted unsupported rows")
    }

    func testAlbumTrackObjectsWithoutTypenameUseAlbumArtworkAndDuration() throws {
        let response: [String: Any] = ["data": ["albumUnion": [
            "__typename": "Album", "uri": "spotify:album:fixture", "name": "Album",
            "tracksV2": ["items": [["track": track()]], "totalCount": 1]
        ]]]
        let result = try SpotifyParser.collection(response, for: item("album"), offset: 0)
        XCTAssertEqual(result.tracks.count, 1)
        XCTAssertEqual(result.tracks[0].durationMS, 123_456)
        XCTAssertEqual(result.tracks[0].imageURL, item("album").imageURL)
        XCTAssertNil(result.nextOffset)
    }

    func testArtistTopTracksAreBoundedAndDoNotInventTotalOrPagination() throws {
        let response: [String: Any] = ["data": ["artistUnion": [
            "__typename": "Artist", "uri": "spotify:artist:fixture", "profile": ["name": "Artist"],
            "discography": ["topTracks": ["items": [["track": track()]]]]
        ]]]
        let result = try SpotifyParser.collection(response, for: item("artist"), offset: 0)
        XCTAssertEqual(result.tracks.count, 1)
        XCTAssertEqual(result.item.title, "Artist")
        XCTAssertNil(result.totalCount)
        XCTAssertNil(result.nextOffset)
    }

    func testEmptyPageIsDifferentFromUnreadableOrUnavailableCollection() throws {
        let empty: [String: Any] = ["data": ["playlistV2": ["__typename": "Playlist", "content": ["items": [], "totalCount": 0]]]]
        XCTAssertTrue(try SpotifyParser.collection(empty, for: item("playlist"), offset: 0).tracks.isEmpty)
        for typename in ["NotFound", "GenericError", "DJ"] {
            let unavailable: [String: Any] = ["data": ["playlistV2": ["__typename": typename]]]
            XCTAssertThrowsError(try SpotifyParser.collection(unavailable, for: item("playlist"), offset: 0))
        }
    }

    func testExplicitEndOfPagePreventsFurtherPagingDespiteTotalCount() throws {
        let response: [String: Any] = ["data": ["albumUnion": [
            "__typename": "Album", "tracksV2": ["items": [["track": track()]], "totalCount": 9, "pagingInfo": ["nextOffset": NSNull()]]
        ]]]
        XCTAssertNil(try SpotifyParser.collection(response, for: item("album"), offset: 0).nextOffset)
    }
}

private final class CollectionStubProtocol: URLProtocol {
    static let lock = NSLock()
    static var requests: [[String: Any]] = []

    static func reset() { lock.lock(); defer { lock.unlock() }; requests = [] }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var body = request.httpBody ?? Data()
        if body.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                guard count > 0 else { break }
                body.append(contentsOf: buffer.prefix(count))
            }
        }
        let payload = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
        Self.lock.lock(); Self.requests.append(payload); Self.lock.unlock()
        let operation = payload["operationName"] as? String
        let key = operation == "fetchPlaylist" ? "playlistV2" : operation == "getAlbum" ? "albumUnion" : "artistUnion"
        let kind = operation == "fetchPlaylist" ? "Playlist" : operation == "getAlbum" ? "Album" : "Artist"
        let page: [String: Any] = ["items": [], "totalCount": 0]
        let content: [String: Any] = kind == "Artist" ? ["__typename": kind, "discography": ["topTracks": page]]
            : ["__typename": kind, kind == "Playlist" ? "content" : "tracksV2": page]
        let data = try! JSONSerialization.data(withJSONObject: ["data": [key: content]])
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@MainActor
final class SpotifyCollectionRequestTests: XCTestCase {
    func testCollectionRequestsUseVerifiedVariablesAndDoNotPlay() async throws {
        CollectionStubProtocol.reset()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CollectionStubProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let operations = Dictionary(uniqueKeysWithValues: ["fetchPlaylist", "getAlbum", "queryArtistOverview"].map { ($0, String(repeating: "a", count: 64)) })
        var authorizations = 0
        let api = SpotifyAPI(session: session, operations: operations) { _ in
            authorizations += 1
            return ["access_token": "fixture", "client_token": "fixture"]
        }
        for kind in ["playlist", "album", "artist"] {
            let item = MusicItem(id: "spotify:\(kind):fixture", title: "Fixture", subtitle: "", imageURL: nil, kind: kind)
            _ = try await api.collection(item, offset: kind == "playlist" ? 50 : 0)
        }
        XCTAssertEqual(authorizations, 3)
        XCTAssertEqual(CollectionStubProtocol.requests.compactMap { $0["operationName"] as? String }, ["fetchPlaylist", "getAlbum", "queryArtistOverview"])
        let variables = CollectionStubProtocol.requests.compactMap { $0["variables"] as? [String: Any] }
        XCTAssertEqual(variables[0]["offset"] as? Int, 50)
        XCTAssertEqual(variables[0]["limit"] as? Int, 50)
        XCTAssertEqual(variables[0]["enableWatchFeedEntrypoint"] as? Bool, false)
        XCTAssertEqual(variables[0]["includeEpisodeContentRatingsV2"] as? Bool, false)
        XCTAssertEqual(variables[1]["locale"] as? String, "")
        XCTAssertEqual(variables[2]["preReleaseV2"] as? Bool, false)

        let unsupported = MusicItem(id: "spotify:genre:DJ", title: "DJ", subtitle: "", imageURL: nil, kind: "genre")
        do { _ = try await api.collection(unsupported); XCTFail("DJ must not become playback or an unrelated collection") }
        catch {}
        XCTAssertEqual(authorizations, 3, "Unsupported items fail before authentication or a network request")
    }
}
