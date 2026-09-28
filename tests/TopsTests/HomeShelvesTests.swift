import XCTest
@testable import Tops

final class HomeShelvesTests: XCTestCase {
    func testPreferredSectionsLeadWithoutReorderingOtherShelvesOrCards() {
        let first = shelf("first", title: "Made for you")
        let watch = shelf("watch", title: "Watch What You Love")
        let daily = shelf("daily", title: "Your Daily Mixes")
        let second = shelf("second", title: "Your favourites")
        let discovery = shelf("discovery", title: "Discover new music")
        let input = [first, watch, daily, second, discovery]

        let visible = HomeShelves.visible(in: input)

        XCTAssertEqual(visible.map(\.id), ["discovery", "daily", "first", "second"])
        for actual in visible {
            let original = input.first { $0.id == actual.id }!
            XCTAssertEqual(actual.title, original.title)
            XCTAssertEqual(actual.items, original.items)
            XCTAssertEqual(actual.nextOffset, original.nextOffset)
            XCTAssertEqual(actual.pagingKind, original.pagingKind)
        }
        XCTAssertEqual(input.map(\.id), ["first", "watch", "daily", "second", "discovery"])
    }

    func testTitleMatchingIgnoresCaseAndWhitespaceButNotDistinctSectionNames() {
        let input = [
            shelf("similar", title: "Watch What You Love Again"),
            shelf("daily", title: "\tYOUR  Daily\nMixes  "),
            shelf("watch", title: " \nWATCH what\tYou Love "),
            shelf("discovery", title: "  Discover\nNew  MUSIC\t"),
            shelf("other", title: "Discover new music from your friends"),
        ]

        XCTAssertEqual(HomeShelves.visible(in: input).map(\.id), ["discovery", "daily", "similar", "other"])
        XCTAssertTrue(HomeShelves.visible(in: []).isEmpty)
        XCTAssertTrue(HomeShelves.visible(in: [input[2]]).isEmpty)
    }

    @MainActor
    func testModelPresentationReflectsShelfUpdatesWithoutChangingSourceData() {
        let model = AppModel(systemVolume: HomeShelfTestVolume())
        model.shelves = [
            shelf("watch", title: "Watch What You Love"),
            shelf("other", title: "Made for you"),
            shelf("daily", title: "Your Daily Mixes"),
        ]
        XCTAssertEqual(model.visibleHomeShelves.map(\.id), ["daily", "other"])
        XCTAssertEqual(model.shelves.map(\.id), ["watch", "other", "daily"])

        // Paging still updates the original shelf by ID, and the display sees it.
        let additional = MusicItem(id: "spotify:playlist:next", title: "Next", subtitle: "", imageURL: nil, kind: "playlist")
        model.shelves[2].items.append(additional)
        model.shelves[2].nextOffset = 30
        XCTAssertEqual(model.visibleHomeShelves[0].items.last, additional)
        XCTAssertEqual(model.visibleHomeShelves[0].nextOffset, 30)

        model.shelves = [shelf("discovery", title: "Discover new music")]
        XCTAssertEqual(model.visibleHomeShelves.map(\.id), ["discovery"])
    }

    private func shelf(_ id: String, title: String) -> Shelf {
        Shelf(id: id, title: title, items: ["second", "first"].map {
            MusicItem(id: "spotify:playlist:\(id)-\($0)", title: $0, subtitle: "", imageURL: nil, kind: "playlist")
        }, nextOffset: 20, pagingKind: "home")
    }
}

@MainActor
private final class HomeShelfTestVolume: SystemVolumeControlling {
    var snapshot = SystemVolumeSnapshot(percent: 0, available: false)
    var onChange: ((SystemVolumeSnapshot) -> Void)?
    func setVolume(_ percent: Double) throws {}
    func stop() {}
}
