import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import Tops

private final class ArtworkStubProtocol: URLProtocol {
    static let lock = NSLock()
    static var bytes = Data()
    static var requests = 0
    static var holdResponses = false
    static var didStart: (() -> Void)?
    static var didStop: (() -> Void)?

    static func reset(_ data: Data, hold: Bool = false, onStart: (() -> Void)? = nil, onStop: (() -> Void)? = nil) {
        lock.lock()
        defer { lock.unlock() }
        bytes = data
        requests = 0
        holdResponses = hold
        didStart = onStart
        didStop = onStop
    }

    static var requestCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return requests
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock()
        Self.requests += 1
        let data = Self.bytes
        let hold = Self.holdResponses
        let onStart = Self.didStart
        Self.lock.unlock()
        onStart?()
        if hold { return }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "image/png"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {
        Self.lock.lock()
        let onStop = Self.didStop
        Self.didStop = nil
        Self.lock.unlock()
        onStop?()
    }
}

private final class ArtworkTrimProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0

    func record() {
        lock.lock()
        calls += 1
        lock.unlock()
    }

    var count: Int {
        lock.lock()
        defer { lock.unlock() }
        return calls
    }
}

@MainActor
final class ArtworkLoaderTests: XCTestCase {
    private func sourceImage() throws -> Data {
        let context = try XCTUnwrap(CGContext(data: nil, width: 2_048, height: 1_024, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: 0.2, green: 0.7, blue: 0.5, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 2_048, height: 1_024))
        let image = try XCTUnwrap(context.makeImage())
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }

    func testLargeArtworkDecodesToRetinaThumbnailDimensions() throws {
        let request = ArtworkRequest(url: URL(string: "https://artwork.test/cover.png")!, pointSize: 42, displayScale: 2)
        let thumbnail = try ArtworkLoader.downsample(sourceImage(), pixelSize: request.pixelSize)
        XCTAssertEqual(request.pixelSize, 96)
        XCTAssertEqual(thumbnail.width, 96)
        XCTAssertEqual(thumbnail.height, 48)
        XCTAssertLessThan(thumbnail.bytesPerRow * thumbnail.height, 32 * 1_024)
    }

    func testConcurrentIdenticalRequestsShareDownloadAndThumbnailCache() async throws {
        ArtworkStubProtocol.reset(try sourceImage())
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ArtworkStubProtocol.self]
        config.urlCache = nil
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let loader = ArtworkLoader(session: session)
        let request = ArtworkRequest(url: URL(string: "https://artwork.test/shared.png")!, pointSize: 50, displayScale: 2)
        async let first = loader.image(for: request)
        async let second = loader.image(for: request)
        let (a, b) = try await (first, second)
        let cached = try await loader.image(for: request)
        XCTAssertTrue(a === b)
        XCTAssertTrue(a === cached)
        XCTAssertEqual(ArtworkStubProtocol.requestCount, 1)
    }

    func testInvalidArtworkDoesNotDecode() {
        XCTAssertThrowsError(try ArtworkLoader.downsample(Data("not an image".utf8), pixelSize: 100))
    }

    func testCacheEvictsPreviousThumbnailBeforeExceedingBudget() async throws {
        ArtworkStubProtocol.reset(try sourceImage())
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ArtworkStubProtocol.self]
        config.urlCache = nil
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        // Each 112×56 RGBA thumbnail fits, but two exceed this budget.
        let loader = ArtworkLoader(session: session, cacheBudget: 30_000)
        let a = ArtworkRequest(url: URL(string: "https://artwork.test/a.png")!, pointSize: 50, displayScale: 2)
        let b = ArtworkRequest(url: URL(string: "https://artwork.test/b.png")!, pointSize: 50, displayScale: 2)
        _ = try await loader.image(for: a)
        _ = try await loader.image(for: b)
        _ = try await loader.image(for: a)
        XCTAssertEqual(ArtworkStubProtocol.requestCount, 3)
    }

    func testCancellingLastWaiterCancelsDownloadAndAllowsRetry() async throws {
        let data = try sourceImage()
        let started = expectation(description: "Artwork download started")
        let stopped = expectation(description: "Unused artwork download cancelled")
        ArtworkStubProtocol.reset(data, hold: true, onStart: { started.fulfill() }, onStop: { stopped.fulfill() })
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ArtworkStubProtocol.self]
        config.urlCache = nil
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let loader = ArtworkLoader(session: session)
        let request = ArtworkRequest(url: URL(string: "https://artwork.test/cancel.png")!, pointSize: 50, displayScale: 2)
        let task = Task { try await loader.image(for: request) }
        await fulfillment(of: [started], timeout: 2)
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("A cancelled view must not receive artwork")
        } catch {}
        await fulfillment(of: [stopped], timeout: 2)

        ArtworkStubProtocol.reset(data)
        let retried = try await loader.image(for: request)
        XCTAssertEqual(retried.width, request.pixelSize)
        XCTAssertEqual(ArtworkStubProtocol.requestCount, 1)
    }

    func testNewDownloadDefersHeapTrimUntilArtworkBecomesIdle() async throws {
        let data = try sourceImage()
        ArtworkStubProtocol.reset(data)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ArtworkStubProtocol.self]
        config.urlCache = nil
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let trimmed = expectation(description: "Settled artwork batch releases unused heap pages")
        let probe = ArtworkTrimProbe()
        let loader = ArtworkLoader(session: session, idleTrimDelay: .milliseconds(40), trimCooldown: .milliseconds(100)) {
            probe.record()
            trimmed.fulfill()
        }
        let first = ArtworkRequest(url: URL(string: "https://artwork.test/first.png")!, pointSize: 50, displayScale: 2)
        _ = try await loader.image(for: first)

        let started = expectation(description: "Next download started before the pending trim")
        ArtworkStubProtocol.reset(data, hold: true, onStart: { started.fulfill() })
        let second = ArtworkRequest(url: URL(string: "https://artwork.test/second.png")!, pointSize: 50, displayScale: 2)
        let task = Task { try await loader.image(for: second) }
        await fulfillment(of: [started], timeout: 2)
        try await Task.sleep(for: .milliseconds(70))
        XCTAssertEqual(probe.count, 0, "Do not reclaim allocator pages during a pending artwork request")
        task.cancel()
        _ = try? await task.value
        await fulfillment(of: [trimmed], timeout: 2)
        XCTAssertEqual(probe.count, 1)
    }
}
