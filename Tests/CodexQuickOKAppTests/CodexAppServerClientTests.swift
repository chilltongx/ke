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
