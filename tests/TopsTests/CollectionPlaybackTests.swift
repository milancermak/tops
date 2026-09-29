import Foundation
import XCTest
@testable import Tops

@MainActor
final class CollectionPlaybackTests: XCTestCase {
    private func item(_ name: String, kind: String = "playlist") -> MusicItem {
        MusicItem(id: "spotify:\(kind):\(name)", title: name, subtitle: "Artist", imageURL: nil, kind: kind)
    }

    private func fixture() throws -> (AppModel, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tops-collection-playback-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let executable = directory.appendingPathComponent("engine")
        try #"""
        #!/bin/sh
        cd -- "$(dirname -- "$0")"
        id=0
        while IFS= read -r request; do
            printf '%s\n' "$request" >> requests.jsonl
            id=$((id + 1))
            if [ -f event-before-ack ]; then
                cat event-before-ack
                rm event-before-ack
            fi
            if [ -f fail-next ]; then
                rm fail-next
                printf '{"id":%s,"error":"Fixture play failure"}\n' "$id"
            else
                printf '{"id":%s,"result":{}}\n' "$id"
            fi
        done
        """#.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let engine = EngineClient(executableURL: executable, dataDirectoryURL: directory)
        let model = AppModel(engine: engine, systemVolume: CollectionPlaybackVolume(), collectionLoader: { selected, _ in
            let track = CollectionTrack(id: "\(selected.id):0", uri: "spotify:track:first", title: "First",
                                        artist: "Artist", durationMS: 180_000, imageURL: nil, isPlayable: true)
            return MusicCollection(item: selected, tracks: [track], totalCount: 1, nextOffset: nil)
        })
        model.connected = true
        return (model, directory)
    }

    private struct Request: Decodable {
        struct Params: Decodable { var uri: String? }
        var method: String
        var params: Params
    }

    private func requests(in directory: URL) throws -> [Request] {
        let url = directory.appendingPathComponent("requests.jsonl")
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        return try String(contentsOf: url, encoding: .utf8).split(separator: "\n").map {
            try JSONDecoder().decode(Request.self, from: Data($0.utf8))
        }
    }

    func testCollectionToggleStartsCollectionQueueThenPausesAndResumesSameContext() async throws {
        let (model, directory) = try fixture()
        defer { model.shutdown(); try? FileManager.default.removeItem(at: directory) }
        let selected = item("selected")
        await model.openCollection(selected)
        await model.toggleCollectionPlayback(selected)
        XCTAssertEqual(try requests(in: directory).map(\.params.uri), [selected.id],
                       "Collection Play must load its URI, preserving Spotify's queue even when the first song is cached")
        XCTAssertTrue(model.isCurrentPlaybackContext(collection: selected))

        model.handleEvent("playback", ["track_uri": "spotify:track:first", "is_playing": true])
        await model.toggleCollectionPlayback(selected)
        XCTAssertTrue(model.playback.isPlaying, "The engine event confirms pause, not the command acknowledgement")
        model.handleEvent("playback", ["is_playing": false])
        await model.toggleCollectionPlayback(selected)
        XCTAssertEqual(try requests(in: directory).map(\.method), ["play", "pause", "resume"])
        XCTAssertEqual(model.playbackCollectionID, selected.id)
    }

    func testBrowsingAndSwitchingCollectionsDoNotConfuseSelectionWithPlaybackContext() async throws {
        let (model, directory) = try fixture()
        defer { model.shutdown(); try? FileManager.default.removeItem(at: directory) }
        let playing = item("playing"), browsing = item("browsing")
        await model.toggleCollectionPlayback(playing)
        model.handleEvent("playback", ["track_uri": "spotify:track:first", "is_playing": true])
        await model.openCollection(browsing)
        XCTAssertEqual(model.collection?.item.id, browsing.id)
        XCTAssertTrue(model.isCurrentPlaybackContext(collection: playing))
        XCTAssertFalse(model.isCurrentPlaybackContext(collection: browsing))
        model.closeCollection()
        XCTAssertTrue(model.isCurrentPlaybackContext(collection: playing))

        await model.toggleCollectionPlayback(browsing)
        XCTAssertEqual(try requests(in: directory).map(\.method), ["play", "play"])
        XCTAssertEqual(try requests(in: directory).compactMap(\.params.uri), [playing.id, browsing.id])
        XCTAssertTrue(model.isCurrentPlaybackContext(collection: browsing))
        XCTAssertFalse(model.isCurrentPlaybackContext(collection: playing))
    }

    func testDetailTrackRetainsCollectionContextAcrossProgressAndUncachedNextSongs() async throws {
        let (model, directory) = try fixture()
        defer { model.shutdown(); try? FileManager.default.removeItem(at: directory) }
        let selected = item("selected"), song = item("clicked", kind: "track")
        await model.play(song, context: selected)
        XCTAssertEqual(try requests(in: directory).compactMap(\.params.uri), [song.id])
        XCTAssertTrue(model.isCurrentPlaybackContext(collection: selected))
        model.handleEvent("playback", ["track_uri": song.id, "position_ms": 3_000.0, "is_playing": true])
        XCTAssertEqual(model.playbackCollectionID, selected.id)
        model.handleEvent("playback", ["track_uri": "spotify:track:beyond-cached-page", "is_playing": true])
        XCTAssertEqual(model.playbackCollectionID, selected.id,
                       "Track-only engine events cannot distinguish queue advancement from an external takeover")
        await model.play(item("independent", kind: "track"))
        XCTAssertNil(model.playbackCollectionID)
        XCTAssertFalse(model.isCurrentPlaybackContext(collection: selected))
    }

    func testClassicCollectionPlayInfersContextAndMissingCurrentItemCannotPause() async throws {
        let (model, directory) = try fixture()
        defer { model.shutdown(); try? FileManager.default.removeItem(at: directory) }
        let selected = item("album", kind: "album")
        await model.play(selected)
        XCTAssertEqual(model.playbackCollectionID, selected.id)
        model.nowPlaying = nil
        XCTAssertFalse(model.isCurrentPlaybackContext(collection: selected))
        await model.toggleCollectionPlayback(selected)
        XCTAssertEqual(try requests(in: directory).map(\.method), ["play", "play"])
        model.handleEvent("disconnected", [:])
        XCTAssertNil(model.playbackCollectionID)
        XCTAssertFalse(model.isCurrentPlaybackContext(collection: selected))
        await model.toggleCollectionPlayback(selected)
        XCTAssertEqual(try requests(in: directory).count, 2, "Disconnected controls must not issue commands")
    }

    func testFailedPlayPreservesPriorPlaybackContext() async throws {
        let (model, directory) = try fixture()
        defer { model.shutdown(); try? FileManager.default.removeItem(at: directory) }
        let previous = item("previous"), next = item("next")
        await model.play(previous)
        try Data().write(to: directory.appendingPathComponent("fail-next"))
        await model.play(next)
        XCTAssertEqual(model.playbackCollectionID, previous.id)
        XCTAssertEqual(model.nowPlaying?.id, previous.id)
        XCTAssertEqual(model.error, "Fixture play failure")
    }

    func testEngineTrackBeforePlayAcknowledgementKeepsItsMetadataAndPosition() async throws {
        let (model, directory) = try fixture()
        defer { model.shutdown(); try? FileManager.default.removeItem(at: directory) }
        let selected = item("selected")
        try #"{"event":"playback","data":{"track_uri":"spotify:track:resolved","title":"Resolved song","artist":"Resolved artist","is_playing":true,"position_ms":1200,"duration_ms":180000}}"#
            .appending("\n").write(to: directory.appendingPathComponent("event-before-ack"), atomically: true, encoding: .utf8)
        await model.toggleCollectionPlayback(selected)
        XCTAssertEqual(model.nowPlaying?.id, "spotify:track:resolved")
        XCTAssertEqual(model.nowPlaying?.title, "Resolved song")
        XCTAssertEqual(model.playback.positionMS, 1_200)
        XCTAssertEqual(model.playback.durationMS, 180_000)
        XCTAssertEqual(model.playbackCollectionID, selected.id)
    }

    func testDisconnectBeforePlayAcknowledgementCannotRestoreClearedContext() async throws {
        let (model, directory) = try fixture()
        defer { model.shutdown(); try? FileManager.default.removeItem(at: directory) }
        try #"{"event":"disconnected","data":{}}"#.appending("\n")
            .write(to: directory.appendingPathComponent("event-before-ack"), atomically: true, encoding: .utf8)
        await model.toggleCollectionPlayback(item("selected"))
        XCTAssertFalse(model.connected)
        XCTAssertNil(model.nowPlaying)
        XCTAssertNil(model.playbackCollectionID)
        XCTAssertNil(model.error)
    }
}

@MainActor
private final class CollectionPlaybackVolume: SystemVolumeControlling {
    var snapshot = SystemVolumeSnapshot(percent: 50, available: true)
    var onChange: ((SystemVolumeSnapshot) -> Void)?
    func setVolume(_ percent: Double) throws {}
    func stop() {}
}
