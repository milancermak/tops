import Foundation

@MainActor
final class SpotifyAPI {
    private let authorization: (Bool) async throws -> [String: Any]
    private let operationOverrides: [String: String]?
    private let session: URLSession
    private var cooldownUntil = Date.distantPast

    init(engine: EngineClient) {
        self.authorization = { forceRefresh in
            try await engine.call("partnerAuthContext", ["force_refresh": forceRefresh])
        }
        self.operationOverrides = nil
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 25
        config.timeoutIntervalForResource = 40
        config.httpMaximumConnectionsPerHost = 2
        config.urlCache = nil
        self.session = URLSession(configuration: config)
    }

    init(session: URLSession, operations: [String: String], authorization: @escaping (Bool) async throws -> [String: Any]) {
        self.session = session
        self.operationOverrides = operations
        self.authorization = authorization
    }

    func madeForYou() async throws -> [Shelf] {
        // The legacy /genre/made-for-x-hub route redirects to this current hub.
        // Read its actual personalized sections; never infer them from playlist names.
        var result: [Shelf] = []
        var seen = Set<String>()
        var offset = 0
        for _ in 0..<5 {
            let response = try await request("browsePage", variables: [
                "uri": "spotify:page:0JQ5DAt0tbjZptfcdMSKl3",
                "pagePagination": ["offset": offset, "limit": 10],
                "sectionPagination": ["offset": 0, "limit": 10],
                "browseEndUserIntegration": "INTEGRATION_WEB_PLAYER",
                "includeEpisodeContentRatingsV2": false
            ])
            result += SpotifyParser.shelves(response).filter { seen.insert($0.id).inserted }
            let data = response["data"] as? [String: Any]
            let browse = data?["browse"] as? [String: Any]
            let sections = browse?["sections"] as? [String: Any]
            let paging = sections?["pagingInfo"] as? [String: Any]
            guard let next = paging?["nextOffset"] as? Int, next > offset else { break }
            offset = next
        }
        if result.isEmpty {
            // Some account variants expose the shelf but not the browse hub.
            let response = try await request("homeSection", variables: [
                "uri": "spotify:section:0JQ5DAUnp4wcj0bCb3wh3S",
                "homeEndUserIntegration": "INTEGRATION_WEB_PLAYER",
                "timeZone": TimeZone.current.identifier,
                "sp_t": "", "sectionItemsOffset": 0, "sectionItemsLimit": 50,
                "includeEpisodeContentRatingsV2": false
            ])
            result = SpotifyParser.shelves(response)
        }
        guard !result.isEmpty else {
            throw TopsError(message: "Spotify returned no readable Made for You music. This private API may have changed; no substitute recommendations are shown.")
        }
        return result
    }

    func search(_ query: String) async throws -> [MusicItem] {
        let response = try await request("searchDesktop", variables: [
            "searchTerm": query, "offset": 0, "limit": 20,
            "numberOfTopResults": 5, "includeAudiobooks": false,
            "includeArtistHasConcertsField": false, "includePreReleases": false,
            "includeLocalConcertsField": false, "includeAuthors": false,
            "includeAlbumPreReleases": false, "includeEpisodeContentRatingsV2": false,
            "isPrefix": NSNull(), "sectionFilters": ["GENERIC"]
        ])
        return SpotifyParser.search(response)
    }

    func collection(_ item: MusicItem, offset: Int = 0) async throws -> MusicCollection {
        guard ["playlist", "album", "artist"].contains(item.kind),
              item.id.hasPrefix("spotify:\(item.kind):"), offset >= 0 else {
            throw TopsError(message: "This item does not have a supported track list in Tops.")
        }
        let limit = 50
        let operation: String
        let variables: [String: Any]
        switch item.kind {
        case "playlist":
            operation = "fetchPlaylist"
            variables = ["uri": item.id, "offset": offset, "limit": limit,
                         "enableWatchFeedEntrypoint": false, "includeEpisodeContentRatingsV2": false]
        case "album":
            operation = "getAlbum"
            variables = ["uri": item.id, "offset": offset, "limit": limit, "locale": ""]
        default:
            guard offset == 0 else { throw TopsError(message: "The artist's top tracks do not have another page.") }
            operation = "queryArtistOverview"
            variables = ["uri": item.id, "locale": "", "preReleaseV2": false]
        }
        let response = try await request(operation, variables: variables)
        return try SpotifyParser.collection(response, for: item, offset: offset)
    }

    func moreItems(in shelf: Shelf) async throws -> Shelf? {
        guard let offset = shelf.nextOffset else { return nil }
        let variables: [String: Any]
        let operation: String
        if shelf.pagingKind == "home" {
            operation = "homeSection"
            variables = ["uri": shelf.id, "sectionItemsOffset": offset, "sectionItemsLimit": 20,
                         "homeEndUserIntegration": "INTEGRATION_WEB_PLAYER", "timeZone": TimeZone.current.identifier,
                         "sp_t": "", "includeEpisodeContentRatingsV2": false]
        } else {
            operation = "browseSection"
            variables = ["uri": shelf.id, "pagination": ["offset": offset, "limit": 20],
                         "browseEndUserIntegration": "INTEGRATION_WEB_PLAYER", "includeEpisodeContentRatingsV2": false]
        }
        return SpotifyParser.shelves(try await request(operation, variables: variables)).first
    }

    private func operationHash(_ operation: String) throws -> String {
        if let hash = operationOverrides?[operation] { return hash }
        let paths = [
            ProcessInfo.processInfo.environment["TOPS_OPERATIONS"],
            Bundle.main.resourceURL?.appendingPathComponent("operations.json").path,
            FileManager.default.currentDirectoryPath + "/config/operations.json"
        ].compactMap { $0 }
        for path in paths {
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
                  let config = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let operations = config["operations"] as? [String: Any] else { continue }
            let entry = operations[operation]
            let hash = (entry as? [String: Any])?["hash"] as? String ?? entry as? String
            if let hash, hash.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil { return hash }
        }
        throw TopsError(message: "Missing Spotify query definition for \(operation). Run tools/refresh_operations.py and rebuild the app.")
    }

    private func request(_ operation: String, variables: [String: Any], forceRefresh: Bool = false) async throws -> [String: Any] {
        if cooldownUntil > Date() {
            throw TopsError(message: "Spotify asked us to slow down. Try again in \(Int(ceil(cooldownUntil.timeIntervalSinceNow))) seconds.")
        }
        let hash = try operationHash(operation)
        try Task.checkCancellation()
        let auth = try await authorization(forceRefresh)
        guard let access = auth["access_token"] as? String else { throw TopsError(message: "Connect your Spotify account first.") }
        guard let clientToken = auth["client_token"] as? String, !clientToken.isEmpty else {
            throw TopsError(message: "Spotify client authorization is unavailable. Reconnect to continue.")
        }
        let urlRequest = try SpotifyRequest.make(operation: operation, hash: hash, variables: variables, accessToken: access, clientToken: clientToken)
        let (data, response) = try await session.data(for: urlRequest)
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse else { throw TopsError(message: "Spotify returned an invalid response.") }
        if http.statusCode == 429 {
            let seconds = max(1, Double(http.value(forHTTPHeaderField: "Retry-After") ?? "60") ?? 60)
            cooldownUntil = Date().addingTimeInterval(seconds)
            throw TopsError(message: "Spotify is rate limiting requests. Please wait \(Int(seconds)) seconds.")
        }
        if http.statusCode == 401 && !forceRefresh {
            // Retry this read once with a fresh grant; a 403 never clears a valid sign-in.
            return try await request(operation, variables: variables, forceRefresh: true)
        }
        if let failure = SpotifyAPIError.authorizationFailure(status: http.statusCode, operation: operation) {
            throw failure
        }
        guard (200..<300).contains(http.statusCode) else { throw TopsError(message: "Spotify request failed (HTTP \(http.statusCode)).") }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw TopsError(message: "Spotify returned an unreadable response.") }
        if let errors = object["errors"] as? [[String: Any]], !errors.isEmpty {
            let messages = errors.compactMap { $0["message"] as? String }.joined(separator: "; ")
            if messages.localizedCaseInsensitiveContains("persistedquery") {
                throw TopsError(message: "Spotify changed its query definitions. Run tools/refresh_operations.py and rebuild Tops.")
            }
            // Do not log raw authenticated responses or headers.
            throw TopsError(message: "Spotify could not load \(operation). The private API response needs checking.")
        }
        return object
    }
}
