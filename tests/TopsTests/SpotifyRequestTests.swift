import XCTest
@testable import Tops

final class SpotifyRequestTests: XCTestCase {
    func testPathfinderUsesDesktopIdentityAndKeepsSecretsOutOfPayload() throws {
        let request = try SpotifyRequest.make(operation: "browsePage", hash: String(repeating: "a", count: 64), variables: ["uri": "spotify:page:example"], accessToken: "fixture-bearer", clientToken: "fixture-client")
        XCTAssertEqual(request.url?.absoluteString, "https://api-partner.spotify.com/pathfinder/v2/query")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fixture-bearer")
        XCTAssertEqual(request.value(forHTTPHeaderField: "client-token"), "fixture-client")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Origin"), "https://xpui.app.spotify.com")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Referer"), "https://xpui.app.spotify.com")
        XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), "Spotify/1.2.52.442 OSX/0 (Tops/0.1)")
        XCTAssertTrue(request.value(forHTTPHeaderField: "App-Platform")?.hasPrefix("OSX") == true)
        let body = try XCTUnwrap(request.httpBody)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(object["operationName"] as? String, "browsePage")
        XCTAssertFalse(String(decoding: body, as: UTF8.self).contains("fixture-bearer"))
        XCTAssertFalse(String(decoding: body, as: UTF8.self).contains("fixture-client"))
    }

    func testForbiddenIsNotMisreportedAsExpiredLogin() {
        XCTAssertEqual(SpotifyAPIError.authorizationFailure(status: 403, operation: "browsePage"), .forbidden(operation: "browsePage"))
        XCTAssertEqual(SpotifyAPIError.authorizationFailure(status: 401, operation: "browsePage"), .expiredSession)
        XCTAssertNil(SpotifyAPIError.authorizationFailure(status: 200, operation: "browsePage"))
    }
}
