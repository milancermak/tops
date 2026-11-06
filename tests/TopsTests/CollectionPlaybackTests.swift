import Foundation
import XCTest
@testable import Tops

@MainActor
final class CollectionPlaybackTests: XCTestCase {
    private func item(_ name: String, kind: String = "playlist") -> MusicItem {
        MusicItem(id: "spotify:\(kind):\(name)", title: name, subtitle: "Artist", imageURL: nil, kind: kind)
    }

    private func fixture(
        collectionLoader: ((MusicItem, Int) async throws -> MusicCollection)? = nil,
        restartingIn existingDirectory: URL? = nil
    ) throws -> (AppModel, URL) {
        let directory = existingDirectory ?? FileManager.default.temporaryDirectory
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
                case "$request" in
                    *'"method":"authenticate"'*)
                        account=fixture-account
                        if [ -f account ]; then read -r account < account; fi
                        printf '{"id":%s,"result":{"username":"%s"}}\n' "$id" "$account" ;;
                    *'"method":"restore"'*)
                        printf '{"id":%s,"result":{"context_restored":true}}\n' "$id" ;;
                    *) printf '{"id":%s,"result":{}}\n' "$id" ;;
                esac
            fi
        done
        """#.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let engine = EngineClient(executableURL: executable, dataDirectoryURL: directory)
        let defaultLoader: (MusicItem, Int) async throws -> MusicCollection = { selected, _ in
            let track = CollectionTrack(id: "\(selected.id):0", uri: "spotify:track:first", title: "First",
                                        artist: "Artist", durationMS: 180_000, imageURL: nil, isPlayable: true)
            return MusicCollection(item: selected, tracks: [track], totalCount: 1, nextOffset: nil)
        }
        let model = AppModel(engine: engine, systemVolume: CollectionPlaybackVolume(),
                             collectionLoader: collectionLoader ?? defaultLoader, feedLoader: { [] })
        model.connected = existingDirectory == nil
        return (model, directory)
    }

    private struct Request: Decodable {
        struct Params: Decodable {
            var uri: String?
            var contextURI: String?
            var trackURI: String?
            var positionMS: Int?
            var startPlaying: Bool?

            enum CodingKeys: String, CodingKey {
                case uri, contextURI = "context_uri", trackURI = "track_uri"
                case positionMS = "position_ms", startPlaying = "start_playing"
            }
        }
        var method: String
        var params: Params
    }

    func testRestartRestoresLatestConfirmedPlaylistPositionWithoutStartingAudio() async throws {
        let (first, directory) = try fixture()
        defer { first.shutdown(); try? FileManager.default.removeItem(at: directory) }
        let playlist = item("saved-playlist")
        let track = item("second", kind: "track")
        await first.activateCollectionAccount("fixture-account")
        await first.play(playlist)
        for position in [20_000.0, 21_500.0] {
            first.handleEvent("playback", ["track_uri": track.id, "title": track.title, "artist": track.subtitle,
                                           "position_ms": position, "duration_ms": 180_000.0,
                                           "is_playing": true, "position_confirmed": true])
        }
        first.handleEvent("playback", ["track_uri": "spotify:track:loading", "position_ms": 0.0,
                                       "is_playing": false, "position_confirmed": false])
        first.shutdown()

        let (reopened, _) = try fixture(restartingIn: directory)
        defer { reopened.shutdown() }
        await reopened.connect()
        XCTAssertEqual(reopened.nowPlaying, track)
        XCTAssertEqual(reopened.playbackCollection, playlist)
        XCTAssertEqual(reopened.playback.positionMS, 21_500)
        XCTAssertFalse(reopened.playback.isPlaying)
        XCTAssertEqual(try requests(in: directory).map(\.method), ["play", "authenticate"])

        await reopened.seek(23_000)
        XCTAssertEqual(reopened.playback.positionMS, 23_000)
        XCTAssertEqual(try requests(in: directory).count, 2)
        await reopened.togglePlayback()
        let restore = try XCTUnwrap(requests(in: directory).last)
        XCTAssertEqual(restore.method, "restore")
        XCTAssertEqual(restore.params.contextURI, playlist.id)
        XCTAssertEqual(restore.params.trackURI, track.id)
        XCTAssertEqual(restore.params.positionMS, 23_000)
        XCTAssertEqual(restore.params.startPlaying, true)
        await reopened.next()
        XCTAssertEqual(try requests(in: directory).last?.method, "next")
    }

    func testRestartKeepsStandaloneTrackSeparateFromItsSourceAndOtherAccounts() async throws {
        let (first, directory) = try fixture()
        defer { first.shutdown(); try? FileManager.default.removeItem(at: directory) }
        let source = item("source"), track = item("track", kind: "track")
        await first.activateCollectionAccount("fixture-account")
        await first.play(track, context: source)
        first.handleEvent("playback", ["track_uri": track.id, "title": track.title, "duration_ms": 90_000.0,
                                       "position_ms": 5_000.0, "position_confirmed": true])
        first.shutdown()

        let (reopened, _) = try fixture(restartingIn: directory)
        await reopened.connect()
        XCTAssertEqual(reopened.playbackCollection, source)
        await reopened.togglePlayback()
        let restore = try XCTUnwrap(requests(in: directory).last)
        XCTAssertEqual(restore.method, "restore")
        XCTAssertNil(restore.params.contextURI)
        XCTAssertEqual(restore.params.trackURI, track.id)
        reopened.shutdown()

        try "other-account\n".write(to: directory.appendingPathComponent("account"), atomically: true, encoding: .utf8)
        let (other, _) = try fixture(restartingIn: directory)
        defer { other.shutdown() }
        await other.connect()
        XCTAssertTrue(other.connected)
        XCTAssertNil(other.nowPlaying)
        XCTAssertNil(other.playbackCollection)
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

    func testFooterFollowsPlaybackWhileBrowsingAnotherCollection() async throws {
        let (model, directory) = try fixture()
        defer { model.shutdown(); try? FileManager.default.removeItem(at: directory) }
        let playing = item("search-playlist")
        model.results = [playing]
        await model.play(playing, context: playing)
        model.clearSearch()
        await model.openCollection(item("another-playlist"))
        XCTAssertEqual(model.playbackCollection, playing)

        model.handleEvent("playback", ["track_uri": "spotify:track:first", "title": "First", "is_playing": true])
        await model.togglePlayback()
        await model.next()
        await model.previous()
        XCTAssertEqual(try requests(in: directory).map(\.method), ["play", "pause", "next", "previous"])
        model.handleEvent("disconnected", [:])
        XCTAssertNil(model.playbackCollection)
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

    func testSameTrackEventBeforeCollectionPlayAcknowledgementKeepsActualTrackMetadata() async throws {
        let (model, directory) = try fixture()
        defer { model.shutdown(); try? FileManager.default.removeItem(at: directory) }
        let previous = item("previous-context"), selected = item("new-context")
        await model.toggleCollectionPlayback(previous)
        model.handleEvent("playback", [
            "track_uri": "spotify:track:shared", "title": "Shared song", "artist": "Shared artist",
            "is_playing": true, "position_ms": 12_000.0, "duration_ms": 180_000.0,
        ])
        // The next collection starts with the exact same song. Its engine event
        // arrives before the command acknowledgement, without changing the URI.
        try #"{"event":"playback","data":{"track_uri":"spotify:track:shared","title":"Shared song","artist":"Shared artist","is_playing":true,"position_ms":250,"duration_ms":180000}}"#
            .appending("\n").write(to: directory.appendingPathComponent("event-before-ack"), atomically: true, encoding: .utf8)
        await model.toggleCollectionPlayback(selected)
        XCTAssertEqual(try requests(in: directory).compactMap(\.params.uri), [previous.id, selected.id])
        XCTAssertEqual(model.playbackCollectionID, selected.id)
        XCTAssertEqual(model.nowPlaying?.id, "spotify:track:shared")
        XCTAssertEqual(model.nowPlaying?.kind, "track", "The acknowledgement must not replace the actual song with playlist metadata")
        XCTAssertEqual(model.nowPlaying?.title, "Shared song")
        XCTAssertEqual(model.nowPlaying?.subtitle, "Shared artist")
        XCTAssertEqual(model.playback.positionMS, 250)
        XCTAssertEqual(model.playback.durationMS, 180_000)
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

    func testKeyboardToggleStartsSelectedCollectionWhileLoadingThenTogglesSameContext() async throws {
        let started = expectation(description: "Selected collection is still loading")
        var response: CheckedContinuation<MusicCollection, Error>?
        let (model, directory) = try fixture(collectionLoader: { _, _ in
            try await withCheckedThrowingContinuation {
                response = $0
                started.fulfill()
            }
        })
        defer { model.shutdown(); try? FileManager.default.removeItem(at: directory) }
        let selected = item("selected-before-content")
        let opening = Task { await model.openCollection(selected) }
        await fulfillment(of: [started], timeout: 2)
        XCTAssertNil(model.collection)
        XCTAssertNil(model.nowPlaying)
        XCTAssertTrue(model.canTogglePlayback, "Selecting a collection must enable Space before its tracks arrive")
        await model.togglePlaybackFromSelection()
        XCTAssertEqual(try requests(in: directory).compactMap(\.params.uri), [selected.id])
        model.handleEvent("playback", ["track_uri": "spotify:track:first", "is_playing": true])
        await model.togglePlaybackFromSelection()
        model.handleEvent("playback", ["is_playing": false])
        await model.togglePlaybackFromSelection()
        XCTAssertEqual(try requests(in: directory).map(\.method), ["play", "pause", "resume"])
        response?.resume(returning: MusicCollection(item: selected, tracks: [], totalCount: 0, nextOffset: nil))
        await opening.value
        XCTAssertTrue(model.canTogglePlayback, "Current-context playback must remain resumable even if metadata becomes empty")
        await model.togglePlaybackFromSelection()
        XCTAssertEqual(try requests(in: directory).map(\.method), ["play", "pause", "resume", "resume"])
    }

    func testKeyboardToggleStartsDifferentSelectionAndFallsBackToCurrentAfterClosing() async throws {
        let (model, directory) = try fixture()
        defer { model.shutdown(); try? FileManager.default.removeItem(at: directory) }
        let old = item("old-context"), selected = item("new-selection")
        let song = item("current-song", kind: "track")
        await model.play(song, context: old)
        model.handleEvent("playback", ["track_uri": song.id, "is_playing": true])
        await model.openCollection(selected)
        XCTAssertEqual(model.nowPlaying?.id, song.id, "Browsing must leave the actual playing song untouched")
        await model.togglePlaybackFromSelection()
        XCTAssertEqual(try requests(in: directory).compactMap(\.params.uri), [song.id, selected.id])
        XCTAssertEqual(model.playbackCollectionID, selected.id)
        model.handleEvent("playback", ["track_uri": "spotify:track:new-song", "is_playing": false])
        model.closeCollection()
        XCTAssertTrue(model.canTogglePlayback)
        await model.togglePlaybackFromSelection()
        XCTAssertEqual(try requests(in: directory).map(\.method), ["play", "play", "resume"])
        model.handleEvent("disconnected", [:])
        XCTAssertFalse(model.canTogglePlayback)
        await model.togglePlaybackFromSelection()
        XCTAssertEqual(try requests(in: directory).count, 3)
    }

    func testKnownEmptyOrUnplayableSelectionDoesNotStartUnrelatedCurrentPlayback() async throws {
        let (model, directory) = try fixture(collectionLoader: { selected, _ in
            let tracks = selected.title == "empty" ? [] : [
                CollectionTrack(id: "\(selected.id):0", uri: "spotify:track:unavailable", title: "Unavailable",
                                artist: "Artist", durationMS: nil, imageURL: nil, isPlayable: false)
            ]
            return MusicCollection(item: selected, tracks: tracks, totalCount: tracks.count, nextOffset: nil)
        })
        defer { model.shutdown(); try? FileManager.default.removeItem(at: directory) }
        for selected in [item("empty"), item("unplayable")] {
            await model.openCollection(selected)
            XCTAssertFalse(model.canTogglePlayback)
            await model.togglePlaybackFromSelection()
        }
        XCTAssertTrue(try requests(in: directory).isEmpty)
        model.handleEvent("playback", ["track_uri": "spotify:track:actual", "title": "Actual", "is_playing": true])
        XCTAssertFalse(model.canTogglePlayback, "An invalid selection must not make Space control an unrelated collection")
        await model.togglePlaybackFromSelection()
        XCTAssertTrue(try requests(in: directory).isEmpty)
        XCTAssertEqual(model.nowPlaying?.id, "spotify:track:actual")
        model.closeCollection()
        XCTAssertTrue(model.canTogglePlayback)
        await model.togglePlaybackFromSelection()
        XCTAssertEqual(try requests(in: directory).map(\.method), ["pause"])
    }

    func testClosingSelectionDisablesKeyboardWhenNothingHasPlayed() async throws {
        let (model, directory) = try fixture()
        defer { model.shutdown(); try? FileManager.default.removeItem(at: directory) }
        await model.openCollection(item("selected"))
        XCTAssertTrue(model.canTogglePlayback)
        XCTAssertNil(model.nowPlaying)
        model.closeCollection()
        XCTAssertFalse(model.canTogglePlayback)
        await model.togglePlaybackFromSelection()
        XCTAssertTrue(try requests(in: directory).isEmpty)
    }

    func testUnplayableFirstPageWithContinuationStillAllowsStartingCollection() async throws {
        let (model, directory) = try fixture(collectionLoader: { selected, _ in
            let unavailable = CollectionTrack(id: "\(selected.id):0", uri: "spotify:track:unavailable", title: "Unavailable",
                                              artist: "Artist", durationMS: nil, imageURL: nil, isPlayable: false)
            return MusicCollection(item: selected, tracks: [unavailable], totalCount: 100, nextOffset: 50)
        })
        defer { model.shutdown(); try? FileManager.default.removeItem(at: directory) }
        let selected = item("more-pages")
        await model.openCollection(selected)
        XCTAssertTrue(model.canTogglePlayback, "An incomplete first page cannot establish the entire collection is unplayable")
        await model.togglePlaybackFromSelection()
        XCTAssertEqual(try requests(in: directory).compactMap(\.params.uri), [selected.id])
    }
}

@MainActor
private final class CollectionPlaybackVolume: SystemVolumeControlling {
    var snapshot = SystemVolumeSnapshot(percent: 50, available: true)
    var onChange: ((SystemVolumeSnapshot) -> Void)?
    func setVolume(_ percent: Double) throws {}
    func stop() {}
}
