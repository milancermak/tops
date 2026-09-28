import Foundation
import XCTest
@testable import Tops

private final class SpotifyStubProtocol: URLProtocol {
    static let lock = NSLock()
    static var statuses: [Int] = []
    static var requestCount = 0

    static func reset(_ values: [Int]) {
        lock.lock(); defer { lock.unlock() }
        statuses = values
        requestCount = 0
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock()
        let status = Self.statuses.isEmpty ? 500 : Self.statuses.removeFirst()
        Self.requestCount += 1
        Self.lock.unlock()
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        let body = Data("{\"data\":{\"searchV2\":{\"tracksV2\":{\"items\":[]}}}}".utf8)
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@MainActor
final class SpotifyAuthorizationTests: XCTestCase {
    private func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SpotifyStubProtocol.self]
        return URLSession(configuration: config)
    }

    func testExpiredBearerRefreshesOnceAndRetriesOriginalRead() async throws {
        SpotifyStubProtocol.reset([401, 200])
        let session = session()
        defer { session.invalidateAndCancel() }
        var refreshes: [Bool] = []
        let api = SpotifyAPI(session: session, operations: ["searchDesktop": String(repeating: "a", count: 64)]) { force in
            refreshes.append(force)
            return ["access_token": force ? "new-fixture" : "old-fixture", "client_token": "client-fixture"]
        }
        let items = try await api.search("fixture")
        XCTAssertTrue(items.isEmpty)
        XCTAssertEqual(refreshes, [false, true])
        XCTAssertEqual(SpotifyStubProtocol.requestCount, 2)
    }

    func testRepeatedUnauthorizedStopsAfterOneRefresh() async {
        SpotifyStubProtocol.reset([401, 401, 200])
        let session = session()
        defer { session.invalidateAndCancel() }
        var refreshes: [Bool] = []
        let api = SpotifyAPI(session: session, operations: ["searchDesktop": String(repeating: "a", count: 64)]) { force in
            refreshes.append(force)
            return ["access_token": "fixture", "client_token": "fixture"]
        }
        do { _ = try await api.search("fixture"); XCTFail("Expected authorization failure") }
        catch { XCTAssertEqual(error as? SpotifyAPIError, .expiredSession) }
        XCTAssertEqual(refreshes, [false, true])
        XCTAssertEqual(SpotifyStubProtocol.requestCount, 2)
    }

    func testForbiddenPreservesGrantAndDoesNotRetryOrAskForRefresh() async {
        SpotifyStubProtocol.reset([403, 200])
        let session = session()
        defer { session.invalidateAndCancel() }
        var refreshes: [Bool] = []
        let api = SpotifyAPI(session: session, operations: ["searchDesktop": String(repeating: "a", count: 64)]) { force in
            refreshes.append(force)
            return ["access_token": "fixture", "client_token": "fixture"]
        }
        do { _ = try await api.search("fixture"); XCTFail("Expected permission failure") }
        catch { XCTAssertEqual(error as? SpotifyAPIError, .forbidden(operation: "searchDesktop")) }
        XCTAssertEqual(refreshes, [false])
        XCTAssertEqual(SpotifyStubProtocol.requestCount, 1)
    }

    func testRateLimitIsTypedAndCooldownPreventsAnotherRequest() async {
        SpotifyStubProtocol.reset([429, 200])
        let session = session()
        defer { session.invalidateAndCancel() }
        let api = SpotifyAPI(session: session, operations: ["searchDesktop": String(repeating: "a", count: 64)]) { _ in
            ["access_token": "fixture", "client_token": "fixture"]
        }
        for _ in 0..<2 {
            do { _ = try await api.search("fixture"); XCTFail("Expected rate limit") }
            catch {
                XCTAssertNotNil(error as? SpotifyRateLimited)
                XCTAssertGreaterThan((error as? SpotifyRateLimited)?.retryAfter ?? 0, 0)
            }
        }
        XCTAssertEqual(SpotifyStubProtocol.requestCount, 1, "A cooling-down prefetch must not hit Spotify again")
    }

    func testMissingCollectionHasTypedUnavailability() async {
        SpotifyStubProtocol.reset([404])
        let session = session()
        defer { session.invalidateAndCancel() }
        let api = SpotifyAPI(session: session, operations: ["fetchPlaylist": String(repeating: "a", count: 64)]) { _ in
            ["access_token": "fixture", "client_token": "fixture"]
        }
        let item = MusicItem(id: "spotify:playlist:gone", title: "Gone", subtitle: "", imageURL: nil, kind: "playlist")
        do { _ = try await api.collection(item); XCTFail("Expected unavailable collection") }
        catch { XCTAssertTrue(error is SpotifyCollectionUnavailable) }
    }
}
