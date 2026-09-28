import Foundation

/// Home presentation preferences leave Spotify's shelf data and paging intact.
enum HomeShelves {
    static func visible(in shelves: [Shelf]) -> [Shelf] {
        var discovery: [Shelf] = []
        var dailyMixes: [Shelf] = []
        var remaining: [Shelf] = []

        for shelf in shelves {
            // Match headings while preserving Spotify's URIs for pagination.
            let title = shelf.title.split(whereSeparator: \.isWhitespace)
                .joined(separator: " ").lowercased()
            switch title {
            case "watch what you love": continue
            case "discover new music": discovery.append(shelf)
            case "your daily mixes": dailyMixes.append(shelf)
            default: remaining.append(shelf)
            }
        }

        return discovery + dailyMixes + remaining
    }
}
