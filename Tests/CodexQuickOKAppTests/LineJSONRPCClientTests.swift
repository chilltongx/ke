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
}
