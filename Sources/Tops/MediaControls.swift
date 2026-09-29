import Foundation
import MediaPlayer

enum MediaCommand: CaseIterable, Sendable {
    case play, pause, togglePlayPause, previous, next
}

struct MediaPlaybackSnapshot: Equatable {
    var item: MusicItem
    var isPlaying: Bool
    var positionMS: Double
    var durationMS: Double

    var nowPlayingInfo: [String: Any] {
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: item.title,
            MPMediaItemPropertyArtist: item.subtitle,
            MPNowPlayingInfoPropertyExternalContentIdentifier: item.id,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.audio.rawValue,
            MPNowPlayingInfoPropertyIsLiveStream: false,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: max(0, positionMS) / 1_000,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
            MPNowPlayingInfoPropertyDefaultPlaybackRate: 1.0,
        ]
        if durationMS > 0 { info[MPMediaItemPropertyPlaybackDuration] = durationMS / 1_000 }
        return info
    }
}

@MainActor
protocol MediaControlSystem: AnyObject {
    var onCommand: (@MainActor (MediaCommand) async -> Void)? { get set }
    func update(_ snapshot: MediaPlaybackSnapshot?)
    func stop()
}

/// Public macOS media controls work in the background without intercepting keys
/// or requiring Accessibility/Input Monitoring permission.
@MainActor
final class NativeMediaControlSystem: MediaControlSystem {
    var onCommand: (@MainActor (MediaCommand) async -> Void)?
    private let center = MPNowPlayingInfoCenter.default()
    private var targets: [(MPRemoteCommand, Any)] = []
    private var snapshot: MediaPlaybackSnapshot?
    private var publishedAt = ProcessInfo.processInfo.systemUptime
    private var stopped = false

    init() {
        let commands = MPRemoteCommandCenter.shared()
        for command in [
            commands.stopCommand, commands.changePlaybackRateCommand,
            commands.changeRepeatModeCommand, commands.changeShuffleModeCommand,
            commands.skipForwardCommand, commands.skipBackwardCommand,
            commands.seekForwardCommand, commands.seekBackwardCommand,
            commands.changePlaybackPositionCommand, commands.ratingCommand,
            commands.likeCommand, commands.dislikeCommand, commands.bookmarkCommand,
            commands.enableLanguageOptionCommand, commands.disableLanguageOptionCommand,
        ] { command.isEnabled = false }
        for (command, action): (MPRemoteCommand, MediaCommand) in [
            (commands.playCommand, .play),
            (commands.pauseCommand, .pause),
            (commands.togglePlayPauseCommand, .togglePlayPause),
            (commands.previousTrackCommand, .previous),
            (commands.nextTrackCommand, .next),
        ] {
            command.isEnabled = false
            let handler: @Sendable (MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus = { [weak self] _ in
                // MediaPlayer may call from a background queue. Acknowledgement
                // means queued; engine events remain the playback source of truth.
                Task { @MainActor [weak self] in
                    guard let self, !self.stopped, self.snapshot != nil else { return }
                    await self.onCommand?(action)
                }
                return .success
            }
            let target = command.addTarget(handler: handler)
            targets.append((command, target))
        }
    }

    func update(_ newSnapshot: MediaPlaybackSnapshot?) {
        guard !stopped else { return }
        for (command, _) in targets { command.isEnabled = newSnapshot != nil }
        guard let newSnapshot else {
            if snapshot != nil {
                center.playbackState = .stopped
                center.nowPlayingInfo = nil
            }
            snapshot = nil
            return
        }

        let now = ProcessInfo.processInfo.systemUptime
        if let previous = snapshot,
           previous.item == newSnapshot.item,
           previous.isPlaying == newSnapshot.isPlaying,
           previous.durationMS == newSnapshot.durationMS {
            // macOS extrapolates elapsed time itself. Publish seeks/corrections,
            // not every one-second progress tick from the engine.
            let expected = previous.positionMS + (previous.isPlaying ? (now - publishedAt) * 1_000 : 0)
            if abs(newSnapshot.positionMS - expected) < 1_500 { return }
        }
        center.nowPlayingInfo = newSnapshot.nowPlayingInfo
        // On macOS this is required even when audio is produced by a helper.
        center.playbackState = newSnapshot.isPlaying ? .playing : .paused
        snapshot = newSnapshot
        publishedAt = now
    }

    func stop() {
        guard !stopped else { return }
        update(nil)
        stopped = true
        onCommand = nil
        for (command, target) in targets {
            command.removeTarget(target)
            command.isEnabled = false
        }
        targets.removeAll()
    }

    deinit {
        for (command, target) in targets { command.removeTarget(target) }
    }
}
