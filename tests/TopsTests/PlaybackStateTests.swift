import Combine
import Foundation
import XCTest
@testable import Tops

@MainActor
final class PlaybackStateTests: XCTestCase {
    func testProgressSnapshotsDoNotInvalidateTheLibrary() {
        let model = AppModel()
        var snapshot: [String: Any] = [
            "track_uri": "spotify:track:one",
            "title": "One", "artist": "Artist",
            "image_url": "https://example.com/one.jpg",
            "is_playing": true, "position_ms": 1_000.0,
            "duration_ms": 180_000.0, "volume_percent": 25.0,
        ]
        model.handleEvent("playback", snapshot)

        var libraryChanges = 0
        var playbackChanges = 0
        let librarySubscription = model.objectWillChange.sink { libraryChanges += 1 }
        let playbackSubscription = model.playback.objectWillChange.sink { playbackChanges += 1 }
        withExtendedLifetime((librarySubscription, playbackSubscription)) {
            snapshot["position_ms"] = 2_000.0
            model.handleEvent("playback", snapshot)
            XCTAssertEqual(model.playback.positionMS, 2_000)
            XCTAssertEqual(libraryChanges, 0)
            XCTAssertEqual(playbackChanges, 1)

            model.handleEvent("playback", snapshot)
            XCTAssertEqual(libraryChanges, 0)
            XCTAssertEqual(playbackChanges, 1, "An identical engine snapshot needs no view update")

            snapshot["track_uri"] = "spotify:track:two"
            snapshot["title"] = "Two"
            model.handleEvent("playback", snapshot)
            XCTAssertEqual(model.nowPlaying?.id, "spotify:track:two")
            XCTAssertEqual(model.nowPlaying?.title, "Two")
            XCTAssertEqual(libraryChanges, 1, "A track change still updates library highlights")
        }
    }

    func testMetadataChangesAndMissingMetadataKeepCorrectTrack() {
        let model = AppModel()
        let known = MusicItem(id: "spotify:track:known", title: "Known", subtitle: "Artist", imageURL: nil, kind: "track")
        model.shelves = [Shelf(id: "shelf", title: "Shelf", items: [known])]
        model.handleEvent("playback", ["track_uri": known.id])
        XCTAssertEqual(model.nowPlaying, known)

        model.handleEvent("playback", ["track_uri": known.id, "title": "Updated", "artist": "New artist"])
        XCTAssertEqual(model.nowPlaying?.title, "Updated")
        XCTAssertEqual(model.nowPlaying?.subtitle, "New artist")

        model.handleEvent("playback", ["track_uri": known.id, "position_ms": 3_000.0])
        XCTAssertEqual(model.nowPlaying?.title, "Updated", "A position event must not replace engine metadata with a library item")

        model.handleEvent("playback", ["track_uri": "spotify:track:unknown", "is_playing": true])
        XCTAssertEqual(model.nowPlaying?.id, "spotify:track:unknown")
        XCTAssertEqual(model.nowPlaying?.title, "Playing on this Mac")
        model.handleEvent("disconnected", [:])
        XCTAssertFalse(model.playback.isPlaying)
    }
}
