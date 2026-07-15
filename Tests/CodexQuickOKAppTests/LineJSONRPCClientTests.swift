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

    private static func hasReadableByte(descriptor: Int32) -> Bool {
        var byte: UInt8 = 0
        return Darwin.read(descriptor, &byte, 1) > 0
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
