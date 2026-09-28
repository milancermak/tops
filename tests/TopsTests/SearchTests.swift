import AppKit
import Combine
import SwiftUI
import XCTest
@testable import Tops

@MainActor
final class SearchTests: XCTestCase {
    private func track(_ title: String) -> MusicItem {
        MusicItem(id: "spotify:track:\(title)", title: title, subtitle: "Artist", imageURL: nil, kind: "track")
    }

    func testNativeEditsPublishImmediatelyAndOnlyReturnSubmits() {
        var text = ""
        var submits = 0
        let wrapper = NativeSearchField(
            text: Binding(get: { text }, set: { text = $0 }),
            focusRequest: nil,
            enabled: true,
            onSubmit: { submits += 1 }
        )
        let coordinator = wrapper.makeCoordinator()
        let field = NSSearchField()
        field.stringValue = "Metallica"
        coordinator.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: field))
        XCTAssertEqual(text, "Metallica")
        XCTAssertEqual(submits, 0)
        coordinator.search(field)
        XCTAssertEqual(submits, 0, "Native actions publish edits without bypassing the debounce")
        XCTAssertTrue(coordinator.control(field, textView: NSTextView(), doCommandBy: #selector(NSResponder.insertNewline(_:))))
        XCTAssertEqual(submits, 1)
        field.stringValue = ""
        coordinator.search(field)
        XCTAssertEqual(text, "", "The native cancel button must clear the query")
        XCTAssertTrue(coordinator.control(field, textView: NSTextView(), doCommandBy: #selector(NSResponder.insertNewline(_:))))
        XCTAssertEqual(submits, 1, "Return with an empty query must not submit")
    }

    func testDebounceWaitsAndRestartsAfterEachEdit() async {
        let firstDelay = expectation(description: "First debounce waiting")
        let secondDelay = expectation(description: "Replacement debounce waiting")
        let canceledDelay = expectation(description: "Obsolete debounce canceled")
        let finished = expectation(description: "Latest results received")
        var delays: [CheckedContinuation<Void, Never>] = []
        var terms: [String] = []
        let expected = track("latest")
        let model = AppModel(searchLoader: { term in
            terms.append(term)
            return [expected]
        }, searchDelay: {
            await withCheckedContinuation { continuation in
                delays.append(continuation)
                (delays.count == 1 ? firstDelay : secondDelay).fulfill()
            }
            if Task.isCancelled {
                canceledDelay.fulfill()
                throw CancellationError()
            }
        })
        model.connected = true
        let subscription = model.$results.sink { if $0 == [expected] { finished.fulfill() } }
        model.query = "M"
        await fulfillment(of: [firstDelay], timeout: 2)
        XCTAssertTrue(model.searchLoading)
        XCTAssertTrue(terms.isEmpty, "No request before the quiet interval has elapsed")
        model.query = "Metallica"
        await fulfillment(of: [secondDelay], timeout: 2)
        delays[0].resume()
        await fulfillment(of: [canceledDelay], timeout: 2)
        XCTAssertTrue(terms.isEmpty, "Releasing an obsolete debounce must not submit the new query early")
        delays[1].resume()
        await fulfillment(of: [finished], timeout: 2)
        XCTAssertEqual(terms, ["Metallica"])
        XCTAssertFalse(model.searchLoading)
        withExtendedLifetime(subscription) {}
    }

    func testReturnSubmitsImmediatelyAndDoesNotDuplicateTheDebouncedRequest() async {
        let waiting = expectation(description: "Debounce waiting")
        let canceled = expectation(description: "Debounce canceled after Return")
        var delay: CheckedContinuation<Void, Never>?
        var terms: [String] = []
        let expected = track("result")
        let model = AppModel(searchLoader: { term in
            terms.append(term)
            return [expected]
        }, searchDelay: {
            await withCheckedContinuation { delay = $0; waiting.fulfill() }
            if Task.isCancelled { canceled.fulfill(); throw CancellationError() }
        })
        model.connected = true
        model.query = "  Metallica  "
        await fulfillment(of: [waiting], timeout: 2)
        await model.search()
        XCTAssertEqual(terms, ["Metallica"])
        XCTAssertEqual(model.results, [expected])
        delay?.resume()
        await fulfillment(of: [canceled], timeout: 2)
        await model.search()
        XCTAssertEqual(terms, ["Metallica"], "Return after the automatic search must reuse the current results")
    }

    func testOldSuccessCannotReplaceNewResultsWhenQueryReturnsToTheSameText() async {
        let firstStarted = expectation(description: "First A request started")
        let latestStarted = expectation(description: "Latest A request started")
        var responses: [CheckedContinuation<[MusicItem], Error>] = []
        let model = AppModel(searchLoader: { _ in
            try await withCheckedThrowingContinuation {
                responses.append($0)
                (responses.count == 1 ? firstStarted : latestStarted).fulfill()
            }
        }, searchDelay: { throw CancellationError() })
        model.connected = true
        model.query = "A"
        let firstRequest = Task { await model.search() }
        await fulfillment(of: [firstStarted], timeout: 2)
        model.query = "B"
        model.query = "A"
        let latestRequest = Task { await model.search() }
        await fulfillment(of: [latestStarted], timeout: 2)
        await model.search()
        XCTAssertEqual(responses.count, 2, "Return must not duplicate the request already in flight")
        responses[0].resume(returning: [track("obsolete")])
        await firstRequest.value
        XCTAssertTrue(model.results.isEmpty)
        XCTAssertTrue(model.searchLoading, "An obsolete response must not clear the current spinner")
        responses[1].resume(returning: [track("current")])
        await latestRequest.value
        XCTAssertEqual(model.results.map(\.title), ["current"])
        XCTAssertFalse(model.searchLoading)
    }

    func testEditInvalidatesAnOldErrorEvenWhenQueryReturnsBeforeNextRequestStarts() async {
        let started = expectation(description: "Old request started")
        var response: CheckedContinuation<[MusicItem], Error>?
        let model = AppModel(searchLoader: { _ in
            try await withCheckedThrowingContinuation { response = $0; started.fulfill() }
        }, searchDelay: { throw CancellationError() })
        model.connected = true
        model.query = "old"
        let request = Task { await model.search() }
        await fulfillment(of: [started], timeout: 2)
        model.query = "new"
        model.query = "old"
        response?.resume(throwing: TopsError(message: "Obsolete failure"))
        await request.value
        XCTAssertNil(model.error)
        XCTAssertTrue(model.results.isEmpty)
    }

    func testClearCancelsPendingResponseAndResetsResultsAndError() async {
        let started = expectation(description: "Request started")
        var response: CheckedContinuation<[MusicItem], Error>?
        let model = AppModel(searchLoader: { _ in
            try await withCheckedThrowingContinuation { response = $0; started.fulfill() }
        }, searchDelay: { throw CancellationError() })
        model.connected = true
        model.query = "Metallica"
        let request = Task { await model.search() }
        await fulfillment(of: [started], timeout: 2)
        model.results = [track("previous")]
        model.error = "Previous error"
        model.clearSearch()
        XCTAssertEqual(model.query, "")
        XCTAssertTrue(model.results.isEmpty)
        XCTAssertNil(model.error)
        XCTAssertFalse(model.searchLoading)
        response?.resume(returning: [track("too late")])
        await request.value
        XCTAssertTrue(model.results.isEmpty)
        XCTAssertFalse(model.searchLoading)
    }

    func testCurrentFailureCanBeRetriedWithReturn() async {
        var requests = 0
        let expected = track("recovered")
        let model = AppModel(searchLoader: { _ in
            requests += 1
            if requests == 1 { throw TopsError(message: "Temporary failure") }
            return [expected]
        }, searchDelay: { throw CancellationError() })
        model.connected = true
        model.query = "Metallica"
        await model.search()
        XCTAssertEqual(model.error, "Temporary failure")
        XCTAssertFalse(model.searchLoading)
        await model.search()
        XCTAssertEqual(model.results, [expected])
        XCTAssertNil(model.error)
        XCTAssertEqual(requests, 2)
    }
}
