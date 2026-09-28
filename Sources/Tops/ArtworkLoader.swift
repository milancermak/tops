import Foundation
import ImageIO
import Darwin

struct ArtworkRequest: Hashable {
    let url: URL
    let pixelSize: Int

    init(url: URL, pointSize: CGFloat, displayScale: CGFloat) {
        self.url = url
        // Round resize changes into small buckets, preserving Retina sharpness.
        let pixels = min(768, max(1, Int(ceil(pointSize * displayScale))))
        pixelSize = min(768, ((pixels + 15) / 16) * 16)
    }

    var cacheKey: NSString { "\(pixelSize):\(url.absoluteString)" as NSString }
}

private final class CachedArtwork: NSObject {
    let image: CGImage
    init(_ image: CGImage) { self.image = image }
}

/// ImageIO creates the requested thumbnail directly, without first decoding the full cover.
/// An actor serializes decoding so several completed downloads cannot cause a decode spike.
private actor ArtworkDecoder {
    func decode(_ data: Data, pixelSize: Int) throws -> CGImage {
        try Task.checkCancellation()
        return try ArtworkLoader.downsample(data, pixelSize: pixelSize)
    }
}

@MainActor
final class ArtworkLoader {
    static let shared = ArtworkLoader()

    private struct Flight {
        let id: UUID
        let task: Task<CGImage, Error>
        var waiters: Set<UUID>
    }

    private let session: URLSession
    private let decoder = ArtworkDecoder()
    private let cache = NSCache<NSString, CachedArtwork>()
    private let cacheBudget: Int
    private var cacheCosts: [ArtworkRequest: Int] = [:]
    private var cacheOrder: [ArtworkRequest] = []
    private var cachedCost = 0
    private var inFlight: [ArtworkRequest: Flight] = [:]
    private let idleTrimDelay: Duration
    private let trimCooldown: Duration
    private let pressureRelief: @Sendable () -> Void
    private var trimTask: Task<Void, Never>?
    private var lastTrim: ContinuousClock.Instant?

    init(session: URLSession? = nil, cacheBudget: Int = 1_024 * 1_024,
         idleTrimDelay: Duration = .seconds(1), trimCooldown: Duration = .seconds(10),
         pressureRelief: @escaping @Sendable () -> Void = { _ = malloc_zone_pressure_relief(nil, 0) }) {
        if let session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.ephemeral
            config.urlCache = nil
            config.requestCachePolicy = .reloadIgnoringLocalCacheData
            config.httpMaximumConnectionsPerHost = 2
            config.timeoutIntervalForRequest = 15
            config.timeoutIntervalForResource = 20
            self.session = URLSession(configuration: config)
        }
        self.cacheBudget = max(0, cacheBudget)
        self.idleTrimDelay = idleTrimDelay
        self.trimCooldown = trimCooldown
        self.pressureRelief = pressureRelief
        cache.totalCostLimit = self.cacheBudget
        cache.countLimit = 32
    }

    func image(for request: ArtworkRequest) async throws -> CGImage {
        try Task.checkCancellation()
        if let cached = cache.object(forKey: request.cacheKey) {
            touch(request)
            return cached.image
        }

        let waiter = UUID()
        let flight: Flight
        if var existing = inFlight[request] {
            existing.waiters.insert(waiter)
            inFlight[request] = existing
            flight = existing
        } else {
            trimTask?.cancel()
            trimTask = nil
            let session = self.session
            let decoder = self.decoder
            let task = Task<CGImage, Error> {
                let (data, response) = try await session.data(from: request.url)
                try Task.checkCancellation()
                guard let response = response as? HTTPURLResponse,
                      (200..<300).contains(response.statusCode),
                      !data.isEmpty, data.count <= 2 * 1_024 * 1_024
                else { throw URLError(.cannotDecodeContentData) }
                return try await decoder.decode(data, pixelSize: request.pixelSize)
            }
            flight = Flight(id: UUID(), task: task, waiters: [waiter])
            inFlight[request] = flight
        }

        return try await withTaskCancellationHandler {
            do {
                let image = try await flight.task.value
                try Task.checkCancellation()
                finish(request, flightID: flight.id, waiter: waiter, image: image)
                return image
            } catch {
                finish(request, flightID: flight.id, waiter: waiter)
                throw error
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.finish(request, flightID: flight.id, waiter: waiter, cancelled: true)
            }
        }
    }

    private func finish(_ request: ArtworkRequest, flightID: UUID, waiter: UUID, image: CGImage? = nil, cancelled: Bool = false) {
        guard var flight = inFlight[request], flight.id == flightID,
              flight.waiters.remove(waiter) != nil else { return }
        if let image {
            let cost = image.bytesPerRow * image.height
            if cost <= cacheBudget {
                removeCached(request)
                // NSCache's limit is advisory; enforce our own insertion budget as well.
                while cachedCost + cost > cacheBudget || cacheOrder.count >= 32 {
                    guard let oldest = cacheOrder.first else { break }
                    removeCached(oldest)
                }
                cache.setObject(CachedArtwork(image), forKey: request.cacheKey, cost: cost)
                cacheCosts[request] = cost
                cachedCost += cost
                touch(request)
            }
        }
        if flight.waiters.isEmpty {
            inFlight[request] = nil
            if cancelled { flight.task.cancel() }
            if inFlight.isEmpty { scheduleIdleTrim() }
        } else {
            inFlight[request] = flight
        }
    }

    private func scheduleIdleTrim() {
        trimTask?.cancel()
        let clock = ContinuousClock()
        let idleDeadline = clock.now.advanced(by: idleTrimDelay)
        let deadline = max(idleDeadline, lastTrim?.advanced(by: trimCooldown) ?? idleDeadline)
        trimTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(until: deadline, clock: clock) }
            catch { return }
            guard let self, !Task.isCancelled, self.inFlight.isEmpty else { return }
            self.trimTask = nil
            self.lastTrim = clock.now
            let relief = self.pressureRelief
            // Return unused malloc pages after a decode burst, away from drawing.
            // This is one task per settled burst, with a cooldown; never a polling timer.
            Task.detached(priority: .utility) { relief() }
        }
    }

    func releaseVisibleImage() {
        if inFlight.isEmpty { scheduleIdleTrim() }
    }

    private func touch(_ request: ArtworkRequest) {
        cacheOrder.removeAll { $0 == request }
        cacheOrder.append(request)
    }

    private func removeCached(_ request: ArtworkRequest) {
        cache.removeObject(forKey: request.cacheKey)
        cachedCost -= cacheCosts.removeValue(forKey: request) ?? 0
        cacheOrder.removeAll { $0 == request }
    }

    nonisolated static func downsample(_ data: Data, pixelSize: Int) throws -> CGImage {
        try autoreleasepool {
            let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
            guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) else {
                throw URLError(.cannotDecodeContentData)
            }
            let options = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
                kCGImageSourceThumbnailMaxPixelSize: max(1, min(768, pixelSize))
            ] as CFDictionary
            guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else {
                throw URLError(.cannotDecodeContentData)
            }
            return image
        }
    }
}
