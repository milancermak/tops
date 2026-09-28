import Foundation

struct MusicItem: Identifiable, Hashable {
    var id: String
    var title: String
    var subtitle: String
    var imageURL: URL?
    var kind: String
}

struct Shelf: Identifiable {
    var id: String
    var title: String
    var items: [MusicItem]
    var nextOffset: Int? = nil
    var pagingKind: String = "browse"
}

struct MusicCollection {
    var item: MusicItem
    var tracks: [CollectionTrack]
    var totalCount: Int?
    var nextOffset: Int?
}

struct CollectionTrack: Identifiable, Hashable {
    var id: String
    var uri: String
    var title: String
    var artist: String
    var durationMS: Int?
    var imageURL: URL?
    var isPlayable: Bool

    var musicItem: MusicItem {
        MusicItem(id: uri, title: title, subtitle: artist, imageURL: imageURL, kind: "track")
    }
}

/// Only render Spotify entities that the current response actually contains.
/// Private API schemas change; missing fields must not become invented recommendations.
enum SpotifyParser {
    static func text(_ value: Any?) -> String? {
        if let s = value as? String, !s.isEmpty { return s }
        guard let object = value as? [String: Any] else { return nil }
        return text(object["transformedLabel"]) ?? text(object["text"]) ?? text(object["name"])
    }

    static func item(_ raw: [String: Any]) -> MusicItem? {
        let object: [String: Any]
        if let content = raw["content"] as? [String: Any], let data = content["data"] as? [String: Any] {
            object = data
        } else if let data = raw["data"] as? [String: Any] {
            object = data
        } else if let track = raw["item"] as? [String: Any], let data = track["data"] as? [String: Any] {
            object = data
        } else { object = raw }
        guard let uri = object["uri"] as? String ?? raw["uri"] as? String,
              let kind = uri.split(separator: ":").dropFirst().first.map(String.init),
              ["playlist", "album", "track", "artist"].contains(kind) else { return nil }
        let profile = object["profile"] as? [String: Any]
        guard let title = text(object["name"]) ?? text(profile?["name"]) else { return nil }
        let artists = object["artists"] as? [String: Any]
        let names = (artists?["items"] as? [[String: Any]] ?? []).compactMap { artist -> String? in
            text((artist["profile"] as? [String: Any])?["name"]) ?? text(artist["name"])
        }
        let description = text(object["description"]) ?? kind.capitalized
        let subtitle = names.isEmpty ? cleanDescription(description) : names.joined(separator: ", ")
        let images = object["images"] ?? object["coverArt"] ?? (object["albumOfTrack"] as? [String: Any])?["coverArt"] ?? (object["visuals"] as? [String: Any])?["avatarImage"]
        return MusicItem(id: uri, title: title, subtitle: subtitle, imageURL: imageURL(images), kind: kind)
    }

    static func imageURL(_ value: Any?) -> URL? {
        if let object = value as? [String: Any] {
            if let url = object["url"] as? String, let parsed = URL(string: url), parsed.scheme == "https" { return parsed }
            for key in ["sources", "items"] {
                if let result = imageURL(object[key]) { return result }
            }
        }
        if let array = value as? [Any] {
            // Spotify source lists commonly start small. Choose a bounded thumbnail.
            let sources = array.compactMap { $0 as? [String: Any] }
            let suitable = sources.filter { ($0["width"] as? Int ?? 300) >= 160 && ($0["width"] as? Int ?? 300) <= 640 }
            for child in suitable.isEmpty ? sources : suitable {
                if let url = imageURL(child) { return url }
            }
        }
        return nil
    }

    static func shelves(_ root: [String: Any]) -> [Shelf] {
        let data = root["data"] as? [String: Any] ?? [:]
        let home = data["home"] as? [String: Any]
        let container = home?["sectionContainer"] as? [String: Any]
        let homeSections = data["homeSections"] as? [String: Any]
        let browse = data["browse"] as? [String: Any]
        let browseSection = data["browseSection"] as? [String: Any]
        let sections: [[String: Any]]
        if let browseSection { sections = [browseSection] }
        else if let list = homeSections?["sections"] as? [[String: Any]] { sections = list }
        else if let list = (browse?["sections"] as? [String: Any])?["items"] as? [[String: Any]] { sections = list }
        else { sections = (container?["sections"] as? [String: Any])?["items"] as? [[String: Any]] ?? [] }
        return sections.enumerated().compactMap { index, section in
            let metadata = section["data"] as? [String: Any]
            let content = section["sectionItems"] as? [String: Any]
            let items = unique((content?["items"] as? [[String: Any]] ?? []).compactMap(item))
            guard !items.isEmpty else { return nil }
            let next = (content?["pagingInfo"] as? [String: Any])?["nextOffset"] as? Int
            return Shelf(id: section["uri"] as? String ?? "section-\(index)", title: text(metadata?["title"]) ?? "For you", items: items, nextOffset: next.flatMap { $0 > 0 ? $0 : nil }, pagingKind: homeSections != nil ? "home" : "browse")
        }
    }

    static func search(_ root: [String: Any]) -> [MusicItem] {
        let data = root["data"] as? [String: Any] ?? [:]
        let search = data["searchV2"] as? [String: Any] ?? data["search"] as? [String: Any] ?? [:]
        var result: [MusicItem] = []
        for key in ["tracksV2", "tracks", "albumsV2", "albums", "artists", "playlists"] {
            let collection = search[key] as? [String: Any] ?? [:]
            result += (collection["items"] as? [[String: Any]] ?? []).compactMap(item)
        }
        return unique(result)
    }

    static func collection(_ root: [String: Any], for requested: MusicItem, offset: Int) throws -> MusicCollection {
        let data = root["data"] as? [String: Any] ?? [:]
        let node: [String: Any]
        let page: [String: Any]
        switch requested.kind {
        case "playlist":
            node = data["playlistV2"] as? [String: Any] ?? [:]
            page = node["content"] as? [String: Any] ?? [:]
        case "album":
            node = data["albumUnion"] as? [String: Any] ?? [:]
            page = node["tracksV2"] as? [String: Any] ?? [:]
        case "artist":
            node = data["artistUnion"] as? [String: Any] ?? [:]
            page = (node["discography"] as? [String: Any])?["topTracks"] as? [String: Any] ?? [:]
        default:
            throw TopsError(message: "This item does not have a supported track list in Tops.")
        }
        let expectedType = requested.kind.prefix(1).uppercased() + requested.kind.dropFirst()
        guard node["__typename"] as? String == expectedType,
              let rawItems = page["items"] as? [Any] else {
            throw TopsError(message: "Spotify did not return a readable \(requested.kind) track list. This item may be unavailable or unsupported.")
        }
        var metadata = item(node) ?? requested
        metadata.imageURL = metadata.imageURL ?? requested.imageURL
        let tracks = rawItems.enumerated().compactMap { index, raw -> CollectionTrack? in
            guard let row = raw as? [String: Any] else { return nil }
            let track: [String: Any]
            if let wrapper = row["itemV2"] as? [String: Any], let object = wrapper["data"] as? [String: Any] {
                track = object
            } else if let object = row["track"] as? [String: Any] {
                track = object
            } else { return nil }
            guard track["__typename"] == nil || track["__typename"] as? String == "Track",
                  let uri = track["uri"] as? String, uri.hasPrefix("spotify:track:"),
                  let title = text(track["name"]) else { return nil }
            let artists = (track["artists"] as? [String: Any])?["items"] as? [[String: Any]] ?? []
            let artist = artists.compactMap { text(($0["profile"] as? [String: Any])?["name"]) ?? text($0["name"]) }.joined(separator: ", ")
            let duration = track["trackDuration"] as? [String: Any] ?? track["duration"] as? [String: Any]
            let milliseconds = duration?["totalMilliseconds"] as? Int
            let album = track["albumOfTrack"] as? [String: Any]
            let artwork = imageURL(album?["coverArt"] ?? track["coverArt"]) ?? (requested.kind == "album" ? metadata.imageURL : nil)
            // A playlist can contain the same URI more than once. Preserve every
            // occurrence and its position rather than deduplicating by track URI.
            return CollectionTrack(id: "\(requested.id):\(offset + index)", uri: uri, title: title,
                                   artist: artist, durationMS: milliseconds.flatMap { $0 >= 0 ? $0 : nil },
                                   imageURL: artwork, isPlayable: (track["playability"] as? [String: Any])?["playable"] as? Bool ?? true)
        }
        let total = (page["totalCount"] as? Int).flatMap { $0 >= 0 ? $0 : nil }
        let paging = page["pagingInfo"] as? [String: Any] ?? [:]
        var next: Int?
        if requested.kind != "artist", !rawItems.isEmpty {
            if let explicit = paging["nextOffset"] as? Int, explicit > offset {
                next = explicit
            } else if paging["nextOffset"] == nil, let total, offset + rawItems.count < total {
                next = offset + rawItems.count
            }
        }
        return MusicCollection(item: metadata, tracks: tracks, totalCount: total, nextOffset: next)
    }

    private static func unique(_ items: [MusicItem]) -> [MusicItem] {
        var seen = Set<String>()
        return items.filter { seen.insert($0.id).inserted }
    }

    private static func cleanDescription(_ string: String) -> String {
        string.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
    }
}
