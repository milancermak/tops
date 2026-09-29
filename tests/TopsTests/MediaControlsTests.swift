import Foundation
import MediaPlayer
import XCTest
@testable import Tops

@MainActor
final class MediaControlsTests: XCTestCase {
    private func fixture(
        collectionLoader: ((MusicItem, Int) async throws -> MusicCollection)? = nil
    ) throws -> (AppModel, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("tops-media-controls-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let executable = directory.appendingPathComponent("engine")
        // Exercise AppModel -> EngineClient -> JSON IPC, without Spotify or
        // native media-center registration. Log before acknowledging each call.
        try #"""
        #!/bin/sh
        cd -- "$(dirname -- "$0")"
        id=0
        while IFS= read -r request; do
            printf '%s\n' "$request" >> requests.jsonl
            id=$((id + 1))
            printf '{"id":%s,"result":{}}\n' "$id"
        done
        """#.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let engine = EngineClient(executableURL: executable, dataDirectoryURL: directory)
        let model = AppModel(engine: engine, systemVolume: MediaTestVolume(),
                             collectionStore: CollectionStore(directory: nil) { item, offset in
                                 if let collectionLoader { return try await collectionLoader(item, offset) }
                                 throw TopsError(message: "Media controls must not load collections")
                             })
        return (model, directory)
    }

    private func methods(in directory: URL) throws -> [String] {
        let log = directory.appendingPathComponent("requests.jsonl")
        guard FileManager.default.fileExists(atPath: log.path) else { return [] }
        return try String(contentsOf: log, encoding: .utf8).split(separator: "\n").map { line in
            let request = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
            return try XCTUnwrap(request["method"] as? String)
        }
    }

    private func playbackEvent(isPlaying: Bool = true) -> [String: Any] {
        [
            "track_uri": "spotify:track:fixture",
            "title": "Fixture song", "artist": "Fixture artist",
            "image_url": "https://example.com/artwork.jpg",
            "is_playing": isPlaying, "position_ms": 12_345.0,
            "duration_ms": 234_567.0,
        ]
    }

    private func collectionItem(_ name: String) -> MusicItem {
        MusicItem(id: "spotify:playlist:\(name)", title: name, subtitle: "Playlist", imageURL: nil, kind: "playlist")
    }

    private func playablePage(_ item: MusicItem) -> MusicCollection {
        let track = CollectionTrack(id: "\(item.id):0", uri: "spotify:track:first", title: "First",
                                    artist: "Artist", durationMS: 180_000, imageURL: nil, isPlayable: true)
        return MusicCollection(item: item, tracks: [track], totalCount: 1, nextOffset: nil)
    }

    private func playedURIs(in directory: URL) throws -> [String] {
        let log = directory.appendingPathComponent("requests.jsonl")
        guard FileManager.default.fileExists(atPath: log.path) else { return [] }
        return try String(contentsOf: log, encoding: .utf8).split(separator: "\n").compactMap { line in
            let request = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
            guard request["method"] as? String == "play" else { return nil }
            return (request["params"] as? [String: Any])?["uri"] as? String
        }
    }

    func testAllMediaCommandsReachEngineAndExplicitPlayPauseNeverToggle() async throws {
        let (model, directory) = try fixture()
        defer { model.shutdown(); try? FileManager.default.removeItem(at: directory) }
        let controls = MediaControlsStub()
        model.startMediaControls(system: controls)
        model.connected = true
        model.handleEvent("playback", playbackEvent())

        for action: MediaCommand in [.play, .pause, .togglePlayPause, .previous, .next] {
            await controls.onCommand?(action)
            XCTAssertNil(model.error)
        }
        XCTAssertEqual(try methods(in: directory), ["resume", "pause", "pause", "previous", "next"])
        XCTAssertTrue(model.playback.isPlaying, "Commands must wait for engine events to confirm playback state")

        model.handleEvent("playback", ["is_playing": false])
        XCTAssertNotNil(controls.snapshot, "Paused content must retain media controls for resuming")
        for action: MediaCommand in [.pause, .play, .togglePlayPause] {
            await controls.onCommand?(action)
            XCTAssertNil(model.error)
        }
        XCTAssertEqual(try methods(in: directory), ["resume", "pause", "pause", "previous", "next", "pause", "resume", "resume"])
        XCTAssertFalse(model.playback.isPlaying, "A resume acknowledgement is not confirmation that audio is playing")
    }

    func testCommandsWithNoItemOrNoConnectionNeverStartEngine() async throws {
        let (model, directory) = try fixture()
        defer { model.shutdown(); try? FileManager.default.removeItem(at: directory) }
        let controls = MediaControlsStub()
        model.startMediaControls(system: controls)
        for action in MediaCommand.allCases { await controls.onCommand?(action) }

        model.connected = true
        XCTAssertNil(model.nowPlaying)
        for action in MediaCommand.allCases { await controls.onCommand?(action) }

        model.connected = false
        // A late playback event can leave metadata present after disconnection.
        // It must neither republish controls nor permit commands to restart IPC.
        model.handleEvent("playback", playbackEvent())
        XCTAssertNotNil(model.nowPlaying)
        XCTAssertNil(controls.snapshot)
        for action in MediaCommand.allCases { await controls.onCommand?(action) }
        XCTAssertEqual(try methods(in: directory), [])
        XCTAssertNil(model.error)
    }

    func testPlaybackEventsPublishMetadataTimingAndPausedState() throws {
        let (model, directory) = try fixture()
        defer { model.shutdown(); try? FileManager.default.removeItem(at: directory) }
        let controls = MediaControlsStub()
        model.startMediaControls(system: controls)
        model.connected = true
        model.handleEvent("playback", playbackEvent())

        let snapshot = try XCTUnwrap(controls.snapshot)
        XCTAssertEqual(snapshot.item, model.nowPlaying)
        XCTAssertTrue(snapshot.isPlaying)
        XCTAssertTrue(snapshot.hasCurrentPlayback)
        XCTAssertTrue(snapshot.canPlay)
        for action in MediaCommand.allCases { XCTAssertTrue(snapshot.canHandle(action)) }
        XCTAssertEqual(snapshot.positionMS, 12_345)
        XCTAssertEqual(snapshot.durationMS, 234_567)
        let info = snapshot.nowPlayingInfo
        XCTAssertEqual(info[MPMediaItemPropertyTitle] as? String, "Fixture song")
        XCTAssertEqual(info[MPMediaItemPropertyArtist] as? String, "Fixture artist")
        XCTAssertEqual(info[MPNowPlayingInfoPropertyExternalContentIdentifier] as? String, "spotify:track:fixture")
        XCTAssertEqual(info[MPNowPlayingInfoPropertyMediaType] as? UInt, MPNowPlayingInfoMediaType.audio.rawValue)
        XCTAssertEqual(info[MPNowPlayingInfoPropertyIsLiveStream] as? Bool, false)
        XCTAssertEqual(try XCTUnwrap(info[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? Double), 12.345, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(info[MPMediaItemPropertyPlaybackDuration] as? Double), 234.567, accuracy: 0.0001)
        XCTAssertEqual(info[MPNowPlayingInfoPropertyPlaybackRate] as? Double, 1)
        XCTAssertEqual(info[MPNowPlayingInfoPropertyDefaultPlaybackRate] as? Double, 1)

        model.handleEvent("playback", ["is_playing": false, "position_ms": 20_500.0])
        let paused = try XCTUnwrap(controls.snapshot)
        XCTAssertFalse(paused.isPlaying)
        XCTAssertEqual(paused.item, snapshot.item)
        XCTAssertEqual(paused.nowPlayingInfo[MPNowPlayingInfoPropertyPlaybackRate] as? Double, 0)
        XCTAssertEqual(paused.nowPlayingInfo[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? Double, 20.5)

        model.handleEvent("playback", ["track_uri": "spotify:track:next", "title": "Next song", "artist": "Next artist", "position_ms": -10.0, "duration_ms": 0.0])
        let next = try XCTUnwrap(controls.snapshot)
        XCTAssertEqual(next.item.id, "spotify:track:next")
        XCTAssertEqual(next.nowPlayingInfo[MPMediaItemPropertyTitle] as? String, "Next song")
        XCTAssertEqual(next.nowPlayingInfo[MPNowPlayingInfoPropertyElapsedPlaybackTime] as? Double, 0)
        XCTAssertNil(next.nowPlayingInfo[MPMediaItemPropertyPlaybackDuration], "Unknown duration must not advertise a zero-length track")
    }

    func testStartingTwiceKeepsOneControllerAndPublishesExistingPlayback() throws {
        let (model, directory) = try fixture()
        defer { model.shutdown(); try? FileManager.default.removeItem(at: directory) }
        model.connected = true
        model.handleEvent("playback", playbackEvent())
        let controls = MediaControlsStub()
        let duplicate = MediaControlsStub()
        model.startMediaControls(system: controls)
        XCTAssertNotNil(controls.onCommand)
        XCTAssertEqual(controls.snapshot?.item.id, "spotify:track:fixture")
        XCTAssertEqual(controls.updates.count, 1)

        model.startMediaControls(system: controls)
        model.startMediaControls(system: duplicate)
        XCTAssertEqual(controls.updates.count, 1)
        XCTAssertNil(duplicate.onCommand)
        XCTAssertTrue(duplicate.updates.isEmpty)

        model.handleEvent("playback", ["position_ms": 30_000.0])
        XCTAssertEqual(controls.snapshot?.positionMS, 30_000)
        XCTAssertTrue(duplicate.updates.isEmpty)
    }

    func testDisconnectClearsPublishedPlaybackAndShutdownRemovesHandler() async throws {
        let (model, directory) = try fixture()
        defer { model.shutdown(); try? FileManager.default.removeItem(at: directory) }
        let controls = MediaControlsStub()
        model.startMediaControls(system: controls)
        model.connected = true
        model.handleEvent("playback", playbackEvent())
        let queuedCommand = controls.onCommand

        model.handleEvent("connection", ["connected": false])
        XCTAssertNil(controls.snapshot)
        XCTAssertNil(model.nowPlaying)
        XCTAssertFalse(model.playback.isPlaying)
        XCTAssertEqual(controls.stopCount, 0, "Disconnect must allow a later connection to reuse the controller")
        await queuedCommand?(.next)
        XCTAssertEqual(try methods(in: directory), [])

        model.connected = true
        model.handleEvent("playback", playbackEvent(isPlaying: false))
        XCTAssertNotNil(controls.snapshot)
        model.shutdown()
        XCTAssertEqual(controls.stopCount, 1)
        XCTAssertNil(controls.snapshot)
        XCTAssertNil(controls.onCommand)
        await queuedCommand?(.play)
        XCTAssertEqual(try methods(in: directory), [])
        model.shutdown()
        XCTAssertEqual(controls.stopCount, 1, "Repeated shutdown must not tear down a controller twice")
    }

    func testSelectionBeforeFirstPlaybackPublishesEligibilityAndMediaToggleStartsItsURI() async throws {
        let started = expectation(description: "Collection request is pending")
        var response: CheckedContinuation<MusicCollection, Error>?
        let (model, directory) = try fixture(collectionLoader: { _, _ in
            try await withCheckedThrowingContinuation {
                response = $0
                started.fulfill()
            }
        })
        defer { model.shutdown(); try? FileManager.default.removeItem(at: directory) }
        let controls = MediaControlsStub()
        model.startMediaControls(system: controls)
        model.connected = true
        let selected = collectionItem("not-yet-loaded")
        let opening = Task { await model.openCollection(selected) }
        await fulfillment(of: [started], timeout: 2)
        XCTAssertNil(model.nowPlaying, "Selecting content must not pretend a track is already playing")
        XCTAssertNil(model.collection)
        XCTAssertTrue(model.canTogglePlayback)
        let eligible = try XCTUnwrap(controls.snapshot)
        XCTAssertEqual(eligible.item, selected)
        XCTAssertFalse(eligible.hasCurrentPlayback)
        XCTAssertTrue(eligible.canPlay)
        XCTAssertFalse(eligible.isPlaying)
        XCTAssertEqual(eligible.positionMS, 0)
        XCTAssertEqual(eligible.durationMS, 0)
        XCTAssertTrue(eligible.canHandle(.play))
        XCTAssertTrue(eligible.canHandle(.togglePlayPause))
        for action: MediaCommand in [.pause, .previous, .next] {
            XCTAssertFalse(eligible.canHandle(action))
            await controls.onCommand?(action)
        }
        XCTAssertTrue(try methods(in: directory).isEmpty, "Pause and skip cannot start playback from selection alone")
        await controls.onCommand?(.togglePlayPause)
        XCTAssertEqual(try methods(in: directory), ["play"])
        XCTAssertEqual(try playedURIs(in: directory), [selected.id])
        response?.resume(returning: playablePage(selected))
        await opening.value
    }

    func testDifferentSelectionKeepsCurrentMetadataAndExplicitMediaPlayNeverPauses() async throws {
        let (model, directory) = try fixture(collectionLoader: { selected, _ in self.playablePage(selected) })
        defer { model.shutdown(); try? FileManager.default.removeItem(at: directory) }
        let controls = MediaControlsStub()
        model.startMediaControls(system: controls)
        model.connected = true
        model.handleEvent("playback", playbackEvent())
        let actual = try XCTUnwrap(controls.snapshot)
        let selected = collectionItem("different-selection")
        await model.openCollection(selected)
        XCTAssertEqual(controls.snapshot?.item, actual.item)
        XCTAssertEqual(controls.snapshot?.positionMS, actual.positionMS)
        XCTAssertEqual(controls.snapshot?.durationMS, actual.durationMS)
        XCTAssertEqual(model.nowPlaying?.id, "spotify:track:fixture")
        XCTAssertTrue(try XCTUnwrap(controls.snapshot).hasCurrentPlayback)
        await controls.onCommand?(.play)
        XCTAssertEqual(try playedURIs(in: directory), [selected.id], "Explicit Play must start a different selected collection")
        model.handleEvent("playback", ["track_uri": "spotify:track:selected", "title": "Selected song", "is_playing": true])
        await controls.onCommand?(.play)
        await controls.onCommand?(.togglePlayPause)
        XCTAssertEqual(try methods(in: directory), ["play", "resume", "pause"],
                       "Explicit Play resumes an already-current context; only Toggle may pause it")
    }

    func testClosingSelectionBeforeAnyPlaybackRemovesMediaEligibility() async throws {
        let (model, directory) = try fixture(collectionLoader: { selected, _ in self.playablePage(selected) })
        defer { model.shutdown(); try? FileManager.default.removeItem(at: directory) }
        let controls = MediaControlsStub()
        model.startMediaControls(system: controls)
        model.connected = true
        await model.openCollection(collectionItem("selected"))
        XCTAssertNotNil(controls.snapshot)
        XCTAssertFalse(try XCTUnwrap(controls.snapshot).hasCurrentPlayback)
        XCTAssertNil(model.nowPlaying)
        model.closeCollection()
        XCTAssertFalse(model.canTogglePlayback)
        XCTAssertNil(controls.snapshot)
        for action in MediaCommand.allCases { await controls.onCommand?(action) }
        XCTAssertTrue(try methods(in: directory).isEmpty)
    }

    func testKnownEmptySelectionDisablesPlayWithoutHidingActualPauseAndSkipControls() async throws {
        let (model, directory) = try fixture(collectionLoader: { selected, _ in
            MusicCollection(item: selected, tracks: [], totalCount: 0, nextOffset: nil)
        })
        defer { model.shutdown(); try? FileManager.default.removeItem(at: directory) }
        let controls = MediaControlsStub()
        model.startMediaControls(system: controls)
        model.connected = true
        await model.openCollection(collectionItem("empty"))
        XCTAssertFalse(model.canTogglePlayback)
        XCTAssertNotEqual(controls.snapshot?.canHandle(.play), true)
        for action in MediaCommand.allCases { await controls.onCommand?(action) }
        XCTAssertTrue(try methods(in: directory).isEmpty)

        model.handleEvent("playback", playbackEvent())
        let snapshot = try XCTUnwrap(controls.snapshot)
        XCTAssertEqual(snapshot.item.id, "spotify:track:fixture")
        XCTAssertTrue(snapshot.hasCurrentPlayback)
        XCTAssertFalse(snapshot.canPlay)
        for action: MediaCommand in [.play, .togglePlayPause] {
            XCTAssertFalse(snapshot.canHandle(action))
            await controls.onCommand?(action)
        }
        XCTAssertTrue(try methods(in: directory).isEmpty, "Invalid selection must not start or toggle an unrelated playing collection")
        for action: MediaCommand in [.pause, .previous, .next] {
            XCTAssertTrue(snapshot.canHandle(action))
            await controls.onCommand?(action)
        }
        XCTAssertEqual(try methods(in: directory), ["pause", "previous", "next"])
        model.closeCollection()
        XCTAssertTrue(try XCTUnwrap(controls.snapshot).canPlay)
        await controls.onCommand?(.play)
        XCTAssertEqual(try methods(in: directory), ["pause", "previous", "next", "resume"])
    }
}

@MainActor
private final class MediaControlsStub: MediaControlSystem {
    var onCommand: (@MainActor (MediaCommand) async -> Void)?
    var updates: [MediaPlaybackSnapshot?] = []
    var snapshot: MediaPlaybackSnapshot?
    var stopCount = 0

    func update(_ snapshot: MediaPlaybackSnapshot?) {
        self.snapshot = snapshot
        updates.append(snapshot)
    }

    func stop() {
        stopCount += 1
        snapshot = nil
        onCommand = nil
    }
}

@MainActor
private final class MediaTestVolume: SystemVolumeControlling {
    let snapshot = SystemVolumeSnapshot(percent: 50, available: true)
    var onChange: ((SystemVolumeSnapshot) -> Void)?
    func setVolume(_ percent: Double) throws {}
    func stop() {}
}
