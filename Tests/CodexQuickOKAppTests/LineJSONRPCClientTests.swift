import Darwin
import Foundation
import XCTest

@testable import CodexQuickOKApp

final class LineJSONRPCClientTests: XCTestCase {
    func testMatchesResponseToRequestId() async throws {
        let input = Pipe()
        let output = Pipe()
        let client = LineJSONRPCClient(
            input: input.fileHandleForReading,
            output: output.fileHandleForWriting
        )
        let task = Task {
            try await client.request(method: "account/rateLimits/read", params: [:])
        }

        let requestData = output.fileHandleForReading.availableData
        let request = try JSONDecoder().decode(JSONValue.self, from: requestData)
        let id = try XCTUnwrap(request.objectValue?["id"]?.integerValue)
        input.fileHandleForWriting.write(
            Data("{\"id\":\(id),\"result\":{\"ok\":true}}\n".utf8)
        )

        let result = try await task.value
        XCTAssertEqual(result.objectValue?["ok"]?.boolValue, true)
    }

    func testRequestPendingAtEOFFails() async throws {
        let input = Pipe()
        let output = Pipe()
        let client = LineJSONRPCClient(
            input: input.fileHandleForReading,
            output: output.fileHandleForWriting
        )
        let outcomeBox = RequestOutcomeBox()
        let completion = expectation(description: "pending request completes after EOF")
        Task {
            let outcome: RequestOutcome
            do {
                _ = try await client.request(method: "account/rateLimits/read", params: [:])
                outcome = .succeeded
            } catch LineJSONRPCClient.RPCError.closed {
                outcome = .closed
            } catch {
                outcome = .otherFailure(String(describing: error))
            }
            await outcomeBox.store(outcome)
            completion.fulfill()
        }

        _ = output.fileHandleForReading.availableData
        try input.fileHandleForWriting.close()

        await fulfillment(of: [completion], timeout: 1)
        let outcome = await outcomeBox.value
        XCTAssertEqual(outcome, .closed)
    }

    func testRequestAfterEOFFailsPromptlyWithoutWriting() async throws {
        let input = Pipe()
        let output = Pipe()
        let client = LineJSONRPCClient(
            input: input.fileHandleForReading,
            output: output.fileHandleForWriting
        )
        let pendingOutcomeBox = RequestOutcomeBox()
        let pendingCompletion = expectation(description: "pending request completes after EOF")
        Task {
            let outcome: RequestOutcome
            do {
                _ = try await client.request(method: "account/rateLimits/read", params: [:])
                outcome = .succeeded
            } catch LineJSONRPCClient.RPCError.closed {
                outcome = .closed
            } catch {
                outcome = .otherFailure(String(describing: error))
            }
            await pendingOutcomeBox.store(outcome)
            pendingCompletion.fulfill()
        }

        _ = output.fileHandleForReading.availableData
        try input.fileHandleForWriting.close()
        await fulfillment(of: [pendingCompletion], timeout: 1)
        let pendingOutcome = await pendingOutcomeBox.value
        XCTAssertEqual(pendingOutcome, .closed)

        let descriptor = output.fileHandleForReading.fileDescriptor
        let flags = fcntl(descriptor, F_GETFL)
        XCTAssertNotEqual(flags, -1)
        XCTAssertNotEqual(fcntl(descriptor, F_SETFL, flags | O_NONBLOCK), -1)

        let laterOutcomeBox = RequestOutcomeBox()
        let laterCompletion = expectation(description: "request after EOF completes")
        Task {
            let outcome: RequestOutcome
            do {
                _ = try await client.request(method: "account/rateLimits/read", params: [:])
                outcome = .succeeded
            } catch LineJSONRPCClient.RPCError.closed {
                outcome = .closed
            } catch {
                outcome = .otherFailure(String(describing: error))
            }
            await laterOutcomeBox.store(outcome)
            laterCompletion.fulfill()
        }
        await fulfillment(of: [laterCompletion], timeout: 1)

        let laterOutcome = await laterOutcomeBox.value
        XCTAssertEqual(laterOutcome, .closed)
        XCTAssertFalse(Self.hasReadableByte(descriptor: descriptor))
    }

    func testRequestDeadlineFailsOnlyTheExpiredRequest() async throws {
        let input = Pipe()
        let output = Pipe()
        let sleeper = MethodControlledRPCSleeper()
        let client = LineJSONRPCClient(
            input: input.fileHandleForReading,
            output: output.fileHandleForWriting,
            requestTimeout: .seconds(30),
            sleep: { duration in try await sleeper.sleep(duration) }
        )
        let first = Task {
            try await client.request(
                method: "first/read",
                params: [:],
                timeout: .seconds(1)
            )
        }
        let firstRequest = try Self.readRequest(from: output.fileHandleForReading)
        let firstID = try XCTUnwrap(firstRequest.objectValue?["id"]?.integerValue)
        let second = Task {
            try await client.request(
                method: "second/read",
                params: [:],
                timeout: .seconds(2)
            )
        }
        let secondRequest = try Self.readRequest(from: output.fileHandleForReading)
        let secondID = try XCTUnwrap(secondRequest.objectValue?["id"]?.integerValue)
        await sleeper.waitForSleeps(count: 2)
        await sleeper.finishSleep(for: .seconds(1))

        do {
            _ = try await first.value
            XCTFail("expired request should fail")
        } catch let error as LineJSONRPCClient.RPCError {
            XCTAssertEqual(error, .requestTimedOut(method: "first/read"))
        }

        input.fileHandleForWriting.write(
            Data("{\"id\":\(secondID),\"result\":{\"ok\":true}}\n".utf8)
        )
        let secondResult = try await second.value
        XCTAssertEqual(secondResult.objectValue?["ok"]?.boolValue, true)

        input.fileHandleForWriting.write(
            Data("{\"id\":\(firstID),\"result\":{\"late\":true}}\n".utf8)
        )
        await Task.yield()
        await client.close()
    }

    func testRequestCanOverrideDefaultDeadline() async throws {
        let input = Pipe()
        let output = Pipe()
        let recordedDurations = DurationBox()
        let client = LineJSONRPCClient(
            input: input.fileHandleForReading,
            output: output.fileHandleForWriting,
            requestTimeout: .seconds(30),
            sleep: { duration in
                await recordedDurations.append(duration)
                throw CancellationError()
            }
        )
        let task = Task {
            try await client.request(
                method: "account/rateLimits/read",
                params: [:],
                timeout: .seconds(3)
            )
        }
        let request = try Self.readRequest(from: output.fileHandleForReading)
        let id = try XCTUnwrap(request.objectValue?["id"]?.integerValue)
        input.fileHandleForWriting.write(Data("{\"id\":\(id),\"result\":{}}\n".utf8))

        _ = try await task.value
        await Self.waitUntil { await recordedDurations.values.count == 1 }
        let durations = await recordedDurations.values
        XCTAssertEqual(durations, [.seconds(3)])
        await client.close()
    }

    func testCloseFailsAllPendingRequestsAndRejectsLaterWrites() async throws {
        let input = Pipe()
        let output = Pipe()
        let sleeper = ControlledRPCSleeper()
        let client = LineJSONRPCClient(
            input: input.fileHandleForReading,
            output: output.fileHandleForWriting,
            sleep: { duration in try await sleeper.sleep(duration) }
        )
        let first = Task {
            try await client.request(method: "first/read", params: [:])
        }
        _ = output.fileHandleForReading.availableData
        let second = Task {
            try await client.request(method: "second/read", params: [:])
        }
        _ = output.fileHandleForReading.availableData

        await client.close()

        for task in [first, second] {
            do {
                _ = try await task.value
                XCTFail("closed request should fail")
            } catch let error as LineJSONRPCClient.RPCError {
                XCTAssertEqual(error, .closed)
            }
        }

        do {
            _ = try await client.request(method: "later/read", params: [:])
            XCTFail("request after close should fail")
        } catch let error as LineJSONRPCClient.RPCError {
            XCTAssertEqual(error, .closed)
        }
    }

    func testCancellingRequestRemovesPendingContinuation() async throws {
        let input = Pipe()
        let output = Pipe()
        let sleeper = ControlledRPCSleeper()
        let client = LineJSONRPCClient(
            input: input.fileHandleForReading,
            output: output.fileHandleForWriting,
            sleep: { duration in try await sleeper.sleep(duration) }
        )
        let task = Task {
            try await client.request(method: "account/rateLimits/read", params: [:])
        }
        _ = output.fileHandleForReading.availableData

        task.cancel()

        do {
            _ = try await task.value
            XCTFail("cancelled request should fail")
        } catch is CancellationError {
            // Expected.
        }
        await client.close()
    }

    private static func hasReadableByte(descriptor: Int32) -> Bool {
        var byte: UInt8 = 0
        return Darwin.read(descriptor, &byte, 1) > 0
    }

    private static func readRequest(from handle: FileHandle) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: handle.availableData)
    }

    private static func waitUntil(
        iterations: Int = 1_000,
        condition: @escaping @Sendable () async -> Bool
    ) async {
        for _ in 0..<iterations {
            if await condition() { return }
            await Task.yield()
        }
        XCTFail("condition did not become true")
    }
}

private enum RequestOutcome: Equatable, Sendable {
    case succeeded
    case closed
    case otherFailure(String)
}

private actor RequestOutcomeBox {
    private(set) var value: RequestOutcome?

    func store(_ value: RequestOutcome) {
        self.value = value
    }
}

private actor ControlledRPCSleeper {
    private var continuations: [CheckedContinuation<Void, Error>?] = []

    func sleep(_ duration: Duration) async throws {
        try await withCheckedThrowingContinuation { continuation in
            continuations.append(continuation)
        }
    }

    func waitForSleeps(count: Int) async {
        for _ in 0..<1_000 {
            if continuations.count >= count { return }
            await Task.yield()
        }
    }

    func finishSleep(at index: Int) {
        continuations[index]?.resume()
        continuations[index] = nil
    }
}

private actor MethodControlledRPCSleeper {
    private var continuations: [Duration: CheckedContinuation<Void, Error>] = [:]

    func sleep(_ duration: Duration) async throws {
        try await withCheckedThrowingContinuation { continuation in
            continuations[duration] = continuation
        }
    }

    func waitForSleeps(count: Int) async {
        for _ in 0..<1_000 {
            if continuations.count >= count { return }
            await Task.yield()
        }
    }

    func finishSleep(for duration: Duration) {
        continuations.removeValue(forKey: duration)?.resume()
    }
}

private actor DurationBox {
    private(set) var values: [Duration] = []

    func append(_ value: Duration) {
        values.append(value)
    }
}
