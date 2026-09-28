import Foundation

/// Pathfinder checks the client context as well as the bearer token.
/// Keep the desktop identity consistent with the engine's desktop OAuth grant.
enum SpotifyRequest {
    static func make(operation: String, hash: String, variables: [String: Any], accessToken: String, clientToken: String) throws -> URLRequest {
        var request = URLRequest(url: URL(string: "https://api-partner.spotify.com/pathfinder/v2/query")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(clientToken, forHTTPHeaderField: "client-token")
        #if arch(arm64)
        request.setValue("OSX_ARM64", forHTTPHeaderField: "App-Platform")
        #else
        request.setValue("OSX", forHTTPHeaderField: "App-Platform")
        #endif
        request.setValue("https://xpui.app.spotify.com", forHTTPHeaderField: "Origin")
        request.setValue("https://xpui.app.spotify.com", forHTTPHeaderField: "Referer")
        // Pathfinder rejects generic URLSession/Python clients with 403 even for
        // a valid grant. This desktop UA was verified against the live hub.
        request.setValue("Spotify/1.2.52.442 OSX/0 (Tops/0.1)", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(Locale.preferredLanguages.first ?? "en", forHTTPHeaderField: "Accept-Language")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "operationName": operation, "variables": variables,
            "extensions": ["persistedQuery": ["version": 1, "sha256Hash": hash]]
        ])
        return request
    }
}

enum SpotifyAPIError: LocalizedError, Equatable {
    case expiredSession
    case forbidden(operation: String)

    var errorDescription: String? {
        switch self {
        case .expiredSession:
            return "Spotify no longer accepts this session (401). Reconnect to continue."
        case .forbidden(let operation):
            let feature = operation == "searchDesktop" ? "search" : "recommendations"
            return "Spotify refused the \(feature) request (403). Your sign-in is saved; signing in again may not resolve this request error."
        }
    }

    static func authorizationFailure(status: Int, operation: String) -> SpotifyAPIError? {
        switch status {
        case 401: return .expiredSession
        case 403: return .forbidden(operation: operation)
        default: return nil
        }
    }
}
