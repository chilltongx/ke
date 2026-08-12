import Darwin
import Foundation
import XCTest

@testable import CodexQuickOKApp

final class CodexAppServerClientLifecycleTests: XCTestCase {
    func testStopClosesRPCBeforeTerminatingProcess() async throws {
        let process = RecordingProcess()
        process.setRunning(true)
        let sleeper = ControlledProcessSleeper()
        let client = CodexAppServerClient(
            processStarter: { _ in process },
            processTerminationTimeout: .seconds(2),
            processSleep: { duration in
                await sleeper.recordSleep(duration)
                while process.isRunning {
                    try await Task.sleep(for: .milliseconds(1))
                }
            },
            forceTerminate: { process.forceTerminate($0) }
        )
        let start = Task {
            try await client.start(codexBinary: URL(fileURLWithPath: "/tmp/codex"))
        }
        _ = process.outputReader.availableData
        process.inputWriter.write(
            Data("{\"id\":1,\"result\":{}}\n".utf8)
        )
        try await start.value
        let initialized = try Self.readRequest(from: process.outputReader)
        XCTAssertEqual(
            initialized.objectValue?["method"]?.stringValue,
            "initialized"
        )

        let pending = Task {
            try await client.readRateLimits()
        }
        let pendingRequest = try Self.readRequest(
            from: process.outputReader
        )
        XCTAssertEqual(
            pendingRequest.objectValue?["method"]?.stringValue,
            "account/rateLimits/read"
        )
        let stop = Task { await client.stop() }

        do {
            _ = try await pending.value
            XCTFail("stop should close pending RPC requests")
        } catch let error as LineJSONRPCClient.RPCError {
            XCTAssertEqual(error, .closed)
        }
        await sleeper.waitForSleeps(count: 1)
        XCTAssertEqual(process.events, ["terminate"])
        process.setRunning(false)
        await stop.value
        XCTAssertEqual(process.events, ["terminate"])
    }

    func testStopEscalatesAfterTerminationDeadline() async throws {
        let process = RecordingProcess()
        process.setRunning(true)
        let sleeper = ControlledProcessSleeper()
        let client = CodexAppServerClient(
            processStarter: { _ in process },
            processTerminationTimeout: .milliseconds(250),
            processSleep: { duration in try await sleeper.sleep(duration) },
            forceTerminate: { process.forceTerminate($0) }
        )
        let start = Task {
            try await client.start(codexBinary: URL(fileURLWithPath: "/tmp/codex"))
        }
        _ = process.outputReader.availableData
        process.inputWriter.write(
            Data("{\"id\":1,\"result\":{}}\n".utf8)
        )
        try await start.value

        let stop = Task { await client.stop() }
        await sleeper.waitForSleeps(count: 1)
        let durations = await sleeper.durations
        XCTAssertEqual(durations, [.milliseconds(25)])

        await finishSleeps(sleeper, count: 10)
        await stop.value

        XCTAssertEqual(process.events, ["terminate", "force-terminate:4242"])
    }

    func testFailedInitializationClosesTransportAndEscalatesWithoutHanging() async throws {
        let process = RecordingProcess()
        process.setRunning(true)
        let sleeper = ControlledProcessSleeper()
        let client = CodexAppServerClient(
            processStarter: { _ in process },
            processTerminationTimeout: .milliseconds(250),
            processSleep: { duration in try await sleeper.sleep(duration) },
            forceTerminate: { process.forceTerminate($0) }
        )
        let start = Task {
            try await client.start(codexBinary: URL(fileURLWithPath: "/tmp/codex"))
        }
        _ = process.outputReader.availableData
        try process.inputWriter.close()

        await sleeper.waitForSleeps(count: 1)
        await finishSleeps(sleeper, count: 10)

        do {
            try await start.value
            XCTFail("initialization should fail when stdout closes")
        } catch let error as LineJSONRPCClient.RPCError {
            XCTAssertEqual(error, .closed)
        }
        XCTAssertEqual(process.events, ["terminate", "force-terminate:4242"])
    }

    func testCancelledStopStillObservesGracePeriodBeforeEscalating() async throws {
        let process = RecordingProcess()
        process.setRunning(true)
        let sleepCount = CounterBox()
        let client = CodexAppServerClient(
            processStarter: { _ in process },
            processTerminationTimeout: .milliseconds(75),
            processSleep: { _ in
                await sleepCount.increment()
                throw CancellationError()
            },
            forceTerminate: { process.forceTerminate($0) }
        )
        let start = Task {
            try await client.start(codexBinary: URL(fileURLWithPath: "/tmp/codex"))
        }
        _ = process.outputReader.availableData
        process.inputWriter.write(
            Data("{\"id\":1,\"result\":{}}\n".utf8)
        )
        try await start.value

        let stop = Task { await client.stop() }
        stop.cancel()
        await stop.value

        let count = await sleepCount.value
        XCTAssertEqual(count, 3)
        XCTAssertEqual(process.events, ["terminate", "force-terminate:4242"])
    }

    private func finishSleeps(
        _ sleeper: ControlledProcessSleeper,
        count: Int
    ) async {
        for index in 0..<count {
            await sleeper.waitForSleeps(count: index + 1)
            await sleeper.finishSleep(at: index)
        }
    }

    private static func readRequest(from handle: FileHandle) throws -> JSONValue {
        try JSONDecoder().decode(JSONValue.self, from: handle.availableData)
    }

}

final class CodexAppServerClientSnapshotCacheTests: XCTestCase {
    func testRereadsWhenInProgressCompletesWithoutUpdatedAtChange() async throws {
        let updatedAt = Int(Date().timeIntervalSince1970)
        let server = SnapshotRPCServer(
            listResults: [Self.listResult(updatedAt: updatedAt)],
            detailResults: [
                Self.detailResult(status: "inProgress", completedAt: nil),
                Self.detailResult(status: "completed", completedAt: updatedAt),
            ]
        )
        let (client, serverTask) = try await Self.startClient(server: server)

        let inProgress = try await client.readRecentTaskSnapshot()
        XCTAssertEqual(inProgress.terminalTurns, [])

        let completed = try await client.readRecentTaskSnapshot()
        XCTAssertEqual(
            completed.terminalTurns,
            [
                CodexTerminalTurn(
                    threadID: "thread-1",
                    turnID: "turn-1",
                    outcome: .completed,
                    completedAt: updatedAt
                )
            ]
        )
        let counts = server.requestCounts
        XCTAssertEqual(counts.threadReads, 2)

        await client.stop()
        await serverTask.value
    }

    func testRereadsEveryPollWhileTurnRemainsInProgress() async throws {
        let updatedAt = Int(Date().timeIntervalSince1970)
        let server = SnapshotRPCServer(
            listResults: [Self.listResult(updatedAt: updatedAt)],
            detailResults: [Self.detailResult(status: "inProgress", completedAt: nil)]
        )
        let (client, serverTask) = try await Self.startClient(server: server)

        for _ in 0..<3 {
            let snapshot = try await client.readRecentTaskSnapshot()
            XCTAssertEqual(snapshot.terminalTurns, [])
        }
        let counts = server.requestCounts
        XCTAssertEqual(counts.threadReads, 3)

        await client.stop()
        await serverTask.value
    }

    func testStopsRereadingAfterTerminalStateIsStable() async throws {
        let updatedAt = Int(Date().timeIntervalSince1970)
        let terminal = Self.detailResult(status: "completed", completedAt: updatedAt)
        let server = SnapshotRPCServer(
            listResults: [Self.listResult(updatedAt: updatedAt)],
            detailResults: [terminal]
        )
        let (client, serverTask) = try await Self.startClient(server: server)

        for _ in 0..<3 {
            _ = try await client.readRecentTaskSnapshot()
        }
        let counts = server.requestCounts
        XCTAssertEqual(counts.threadReads, 2)

        await client.stop()
        await serverTask.value
    }

    func testChangedUpdatedAtGetsAnExtraStableRead() async throws {
        let updatedAt = Int(Date().timeIntervalSince1970)
        let changedUpdatedAt = updatedAt + 1
        let server = SnapshotRPCServer(
            listResults: [
                Self.listResult(updatedAt: updatedAt),
                Self.listResult(updatedAt: updatedAt),
                Self.listResult(updatedAt: changedUpdatedAt),
                Self.listResult(updatedAt: changedUpdatedAt),
                Self.listResult(updatedAt: changedUpdatedAt),
            ],
            detailResults: [
                Self.detailResult(status: "completed", completedAt: updatedAt),
                Self.detailResult(status: "completed", completedAt: updatedAt),
                Self.detailResult(status: "completed", completedAt: changedUpdatedAt),
                Self.detailResult(status: "completed", completedAt: changedUpdatedAt),
            ]
        )
        let (client, serverTask) = try await Self.startClient(server: server)

        for _ in 0..<5 {
            _ = try await client.readRecentTaskSnapshot()
        }
        let counts = server.requestCounts
        XCTAssertEqual(counts.threadReads, 4)

        await client.stop()
        await serverTask.value
    }

    private static func startClient(
        server: SnapshotRPCServer
    ) async throws -> (CodexAppServerClient, Task<Void, Never>) {
        let process = RecordingProcess()
        let serverTask = Task.detached {
            server.run(
                requests: process.outputReader,
                responses: process.inputWriter
            )
        }
        let client = CodexAppServerClient(processStarter: { _ in process })
        try await client.start(codexBinary: URL(fileURLWithPath: "/tmp/codex"))
        return (client, serverTask)
    }

    private static func listResult(updatedAt: Int) -> JSONValue {
        .object([
            "data": .array([
                .object([
                    "id": .string("thread-1"),
                    "updatedAt": .integer(updatedAt),
                ])
            ])
        ])
    }

    private static func detailResult(status: String, completedAt: Int?) -> JSONValue {
        var turn: [String: JSONValue] = [
            "id": .string("turn-1"),
            "status": .string(status),
            "items": .array([]),
        ]
        if let completedAt {
            turn["completedAt"] = .integer(completedAt)
        }
        return .object([
            "thread": .object([
                "turns": .array([.object(turn)])
            ])
        ])
    }
}

private final class RecordingProcess: AppServerProcess, @unchecked Sendable {
    private let lock = NSLock()
    private var storedEvents: [String] = []
    private var storedRunning = false
    private let inputPipe = Pipe()
    private let outputPipe = Pipe()

    var input: FileHandle { inputPipe.fileHandleForReading }
    var output: FileHandle { outputPipe.fileHandleForWriting }
    var inputWriter: FileHandle { inputPipe.fileHandleForWriting }
    var outputReader: FileHandle { outputPipe.fileHandleForReading }

    var events: [String] {
        lock.withLock { storedEvents }
    }

    func setRunning(_ value: Bool) {
        lock.withLock { storedRunning = value }
    }

    var isRunning: Bool { lock.withLock { storedRunning } }
    var processIdentifier: pid_t { 4_242 }

    func terminate() {
        lock.withLock { storedEvents.append("terminate") }
    }

    func forceTerminate(_ processIdentifier: pid_t) {
        lock.withLock {
            storedEvents.append("force-terminate:\(processIdentifier)")
            storedRunning = false
        }
    }
}

private actor ControlledProcessSleeper {
    private(set) var durations: [Duration] = []
    private var continuations: [CheckedContinuation<Void, Error>?] = []

    func sleep(_ duration: Duration) async throws {
        try await withCheckedThrowingContinuation { continuation in
            durations.append(duration)
            continuations.append(continuation)
        }
    }

    func recordSleep(_ duration: Duration) {
        durations.append(duration)
    }

    func waitForSleeps(count: Int) async {
        for _ in 0..<1_000 {
            if continuations.count >= count { return }
            await Task.yield()
        }
    }

    func finishSleep(at index: Int) {
        guard continuations.indices.contains(index),
              let continuation = continuations[index]
        else { return }
        continuations[index] = nil
        continuation.resume()
    }
}

private actor CounterBox {
    private(set) var value = 0

    func increment() {
        value += 1
    }
}

private final class SnapshotRPCServer: @unchecked Sendable {
    private let lock = NSLock()
    private let listResults: [JSONValue]
    private let detailResults: [JSONValue]
    private var listIndex = 0
    private var detailIndex = 0

    init(listResults: [JSONValue], detailResults: [JSONValue]) {
        precondition(!listResults.isEmpty)
        precondition(!detailResults.isEmpty)
        self.listResults = listResults
        self.detailResults = detailResults
    }

    var requestCounts: (threadLists: Int, threadReads: Int) {
        lock.withLock { (listIndex, detailIndex) }
    }

    func run(requests: FileHandle, responses: FileHandle) {
        var buffered = Data()
        do {
            while true {
                let data = requests.availableData
                guard !data.isEmpty else { return }
                buffered.append(data)
                while let newline = buffered.firstIndex(of: 0x0A) {
                    let line = buffered[..<newline]
                    buffered.removeSubrange(...newline)
                    guard let request = try? JSONDecoder().decode(JSONValue.self, from: line),
                          let object = request.objectValue,
                          let method = object["method"]?.stringValue,
                          let id = object["id"]?.integerValue
                    else { continue }

                    let result: JSONValue = lock.withLock {
                        responseResult(for: method)
                    }
                    let response = JSONValue.object([
                        "id": .integer(id),
                        "result": result,
                    ])
                    responses.write(try JSONEncoder().encode(response) + Data([0x0A]))
                }
            }
        } catch {
            // Closing the client ends the fake server's request stream.
        }
    }

    private func responseResult(for method: String) -> JSONValue {
        switch method {
        case "initialize":
            return .object([:])
        case "thread/list":
            let result = listResults[min(listIndex, listResults.count - 1)]
            listIndex += 1
            return result
        case "thread/read":
            let result = detailResults[min(detailIndex, detailResults.count - 1)]
            detailIndex += 1
            return result
        default:
            return .object([:])
        }
    }
}
