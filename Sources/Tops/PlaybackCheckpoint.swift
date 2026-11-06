import CryptoKit
import Foundation

struct PlaybackCheckpoint: Codable, Equatable {
    var track: MusicItem
    var collection: MusicItem?
    var contextURI: String?
    var positionMS: UInt32
    var durationMS: UInt32

    static func file(in directory: URL, accountID: String) -> URL {
        let hash = SHA256.hash(data: Data(accountID.utf8)).map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent("Playback", isDirectory: true)
            .appendingPathComponent("\(hash).json")
    }

    static func read(from url: URL) -> Self? {
        guard let data = try? Data(contentsOf: url), let checkpoint = try? JSONDecoder().decode(Self.self, from: data),
              checkpoint.durationMS > 0, checkpoint.positionMS <= checkpoint.durationMS,
              checkpoint.track.id.hasPrefix("spotify:track:") || checkpoint.track.id.hasPrefix("spotify:episode:") else { return nil }
        return checkpoint
    }

    func write(to url: URL) throws {
        let data = try JSONEncoder().encode(self)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
