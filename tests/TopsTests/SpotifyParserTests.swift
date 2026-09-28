import XCTest
@testable import Tops

final class SpotifyParserTests: XCTestCase {
    // Small synthetic fixtures exercise the structures observed in Spotify's current web player.
    // They contain no account data and do not claim an authenticated integration test.
    func testBrowseShelfPreservesActualSpotifyOrderAndPagination() {
        let playlist: [String: Any] = ["__typename": "Playlist", "uri": "spotify:playlist:mix1", "name": "Your mix", "description": "For <b>you</b>", "images": ["items": [["sources": [["url": "https://i.scdn.co/image/example", "width": 300]]]]]]
        let album: [String: Any] = ["__typename": "Album", "uri": "spotify:album:album1", "name": "Album"]
        let section: [String: Any] = [
            "uri": "spotify:section:mixes",
            "data": ["title": ["transformedLabel": "Your mixes"]],
            "sectionItems": ["items": [["content": ["data": playlist]], ["content": ["data": album]]], "pagingInfo": ["nextOffset": 10]]
        ]
        let response: [String: Any] = ["data": ["browse": ["__typename": "BrowseSectionContainer", "sections": ["items": [section]]]]]
        let shelves = SpotifyParser.shelves(response)
        XCTAssertEqual(shelves.count, 1)
        XCTAssertEqual(shelves[0].title, "Your mixes")
        XCTAssertEqual(shelves[0].items.map(\.id), ["spotify:playlist:mix1", "spotify:album:album1"])
        XCTAssertEqual(shelves[0].items[0].subtitle, "For you")
        XCTAssertEqual(shelves[0].nextOffset, 10)
        XCTAssertEqual(shelves[0].items[0].imageURL?.host, "i.scdn.co")
    }

    func testCurrentSearchWrappersAndAlbumV2() {
        let response: [String: Any] = ["data": ["searchV2": [
            "tracksV2": ["items": [["item": ["data": ["uri": "spotify:track:track1", "name": "Song", "artists": ["items": [["profile": ["name": "Artist"]]]]]]]]],
            "albumsV2": ["items": [["data": ["uri": "spotify:album:album1", "name": "Album"]]]],
            "playlists": ["items": [["data": ["uri": "spotify:playlist:mix1", "name": "Mix"]]]]
        ]]]
        let items = SpotifyParser.search(response)
        XCTAssertEqual(items.map(\.kind), ["track", "album", "playlist"])
        XCTAssertEqual(items[0].subtitle, "Artist")
    }

    func testUnknownAndUnavailableContentDoesNotBecomeRecommendations() {
        XCTAssertNil(SpotifyParser.item(["__typename": "NotFound", "uri": "spotify:playlist:missing"]))
        XCTAssertNil(SpotifyParser.item(["uri": "spotify:episode:podcast", "name": "Podcast"]))
        XCTAssertNil(SpotifyParser.item(["uri": "https://example.com", "name": "External"]))
        XCTAssertEqual(SpotifyParser.shelves(["data": ["browse": NSNull()]]).count, 0)
        XCTAssertNil(SpotifyParser.imageURL(["url": "http://example.com/image.jpg"]))
    }

    func testHomeSectionUsesHomePaginationAndLegacyTitle() {
        let response: [String: Any] = ["data": ["homeSections": ["sections": [["uri": "spotify:section:made-for", "data": ["title": ["text": "Made for you"]], "sectionItems": ["items": [["content": ["data": ["uri": "spotify:playlist:mix1", "name": "Mix"]]]], "pagingInfo": ["nextOffset": 0]]]]]]]
        let shelf = SpotifyParser.shelves(response).first
        XCTAssertEqual(shelf?.title, "Made for you")
        XCTAssertEqual(shelf?.pagingKind, "home")
        XCTAssertNil(shelf?.nextOffset)
    }
}
