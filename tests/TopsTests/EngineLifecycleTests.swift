import Foundation
import XCTest
@testable import Tops

@MainActor
final class EngineLifecycleTests: XCTestCase {
    private func fixture(_ script: String) throws -> (EngineClient, URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("tops-engine-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let executable = directory.appendingPathComponent("engine")
        try ("#!/bin/sh\ncd -- \"$(dirname -- \"$0\")\"\n" + script)
            .write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        return (EngineClient(executableURL: executable, dataDirectoryURL: directory), directory)
    }

    func testEOFRejectsPendingCallAndRestartIgnoresOldTermination() async throws {
        let (client, directory) = try fixture(#"""
        if [ ! -f started ]; then
            : > started
            exec 1>&-
            IFS= read -r ignored
            IFS= read -r ignored
        else
            IFS= read -r request
            printf '%s\n' '{"id":2,"result":{"restarted":true}}'
            while IFS= read -r ignored; do :; done
        fi
        """#)
        defer {
            client.shutdown()
            try? FileManager.default.removeItem(at: directory)
        }
        var disconnects = 0
        client.onEvent = { event, _ in
            if event == "disconnected" { disconnects += 1 }
        }
        do {
            _ = try await client.call("pending", timeout: 2)
            XCTFail("EOF must reject the outstanding call")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("engine stopped"))
        }
        let response = try await client.call("restart", timeout: 2)
        XCTAssertEqual(response["restarted"] as? Bool, true)
        XCTAssertEqual(disconnects, 1)
    }

    func testRestartDuringEventDropsRemainingFramesFromOldChild() async throws {
        let (client, directory) = try fixture(#"""
        if [ ! -f started ]; then
            : > started
            printf '%s\n' '{"event":"restart","data":{}}' '{"event":"stale","data":{}}'
        else
            printf '%s\n' '{"event":"fresh","data":{}}'
        fi
        while IFS= read -r ignored; do :; done
        """#)
        defer {
            client.shutdown()
            try? FileManager.default.removeItem(at: directory)
        }
        let fresh = expectation(description: "Replacement engine emits its own event")
        var received: [String] = []
        var restartError: Error?
        client.onEvent = { [weak client] event, _ in
            received.append(event)
            if event == "restart" {
                guard let client else { return }
                client.shutdown()
                do { try client.start() } catch { restartError = error }
            } else if event == "fresh" {
                fresh.fulfill()
            }
        }
        try client.start()
        await fulfillment(of: [fresh], timeout: 2)
        XCTAssertNil(restartError)
        XCTAssertEqual(received, ["restart", "fresh"])
    }
}
