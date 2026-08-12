import CodexQuickOKCore
import Darwin
import Foundation

actor CodexAppServerClient {
    typealias ProcessStarter = @Sendable (URL) throws -> any AppServerProcess
    typealias ProcessSleep = @Sendable (Duration) async throws -> Void
    typealias ForceTerminate = @Sendable (pid_t) -> Void

    enum ClientError: Error {
        case codexBinaryMissing
        case notStarted
    }

    private let processStarter: ProcessStarter
    private let processTerminationTimeout: Duration
    private let processSleep: ProcessSleep
    private let forceTerminate: ForceTerminate
    private var process: (any AppServerProcess)?
    private var rpc: LineJSONRPCClient?
    private var attentionCache: [String: CachedAttention] = [:]

    private struct CachedAttention: Sendable {
        let updatedAt: Int
        let attention: CodexTaskAttention?
        let terminalTurns: [CodexTerminalTurn]
        let hasInProgressTurn: Bool
        let needsStableRead: Bool
    }

    init(
        processStarter: @escaping ProcessStarter = FoundationAppServerProcess.start,
        processTerminationTimeout: Duration = .seconds(2),
        processSleep: @escaping ProcessSleep = { try await Task.sleep(for: $0) },
        forceTerminate: @escaping ForceTerminate = { processIdentifier in
            _ = Darwin.kill(processIdentifier, SIGKILL)
        }
    ) {
        self.processStarter = processStarter
        self.processTerminationTimeout = processTerminationTimeout
        self.processSleep = processSleep
        self.forceTerminate = forceTerminate
    }

    func start(codexBinary: URL) async throws {
        await stop()

        let process = try processStarter(codexBinary)

        try await initialize(process)
    }

    private func initialize(_ process: any AppServerProcess) async throws {
        let rpc = LineJSONRPCClient(
            input: process.input,
            output: process.output
        )
        self.process = process
        self.rpc = rpc

        do {
            _ = try await rpc.request(
                method: "initialize",
                params: [
                    "clientInfo": .object([
                        "name": "codex_quick_ok",
                        "title": "Codex 可",
                        "version": "0.1.0",
                    ].mapValues(JSONValue.string))
                ]
            )
            try await rpc.sendNotification(method: "initialized", params: [:])
        } catch {
            self.process = nil
            self.rpc = nil
            await rpc.close()
            await terminate(process)
            throw error
        }
    }

    func readRateLimits() async throws -> RateLimitsReadResult {
        guard let rpc else { throw ClientError.notStarted }
        let object = try await rpc.request(method: "account/rateLimits/read", params: [:])
        let data = try JSONEncoder().encode(object)
        return try JSONDecoder().decode(RateLimitsReadResult.self, from: data)
    }

    func readRecentTaskSnapshot() async throws -> CodexRecentTaskSnapshot {
        guard let rpc else { throw ClientError.notStarted }
        let list = try await rpc.request(
            method: "thread/list",
            params: [
                "limit": .integer(32),
                "sortKey": .string("updated_at"),
                "sortDirection": .string("desc"),
            ]
        )
        let newestAllowed = Int(Date().timeIntervalSince1970) - 43_200
        let summaries = CodexTaskAttentionParser.threadSummaries(from: list)
            .filter { $0.updatedAt >= newestAllowed }
        let visibleThreadIDs = Set(summaries.map(\.threadID))
        attentionCache = attentionCache.filter {
            visibleThreadIDs.contains($0.key) && $0.value.updatedAt >= newestAllowed
        }

        for summary in summaries {
            let cached = attentionCache[summary.threadID]
            let updatedAtChanged = cached?.updatedAt != summary.updatedAt
            if let cached,
               !updatedAtChanged,
               !cached.hasInProgressTurn,
               !cached.needsStableRead
            {
                continue
            }
            let detail = try await rpc.request(
                method: "thread/read",
                params: [
                    "threadId": .string(summary.threadID),
                    "includeTurns": .bool(true),
                ]
            )
            attentionCache[summary.threadID] = CachedAttention(
                updatedAt: summary.updatedAt,
                attention: CodexTaskAttentionParser.attention(
                    from: detail,
                    summary: summary
                ),
                terminalTurns: CodexTaskAttentionParser.terminalTurns(
                    from: detail,
                    summary: summary
                ),
                hasInProgressTurn: CodexTaskAttentionParser.hasInProgressTurn(
                    in: detail
                ),
                needsStableRead: updatedAtChanged
            )
        }

        let attention = attentionCache.values
            .compactMap(\.attention)
            .max { $0.updatedAt < $1.updatedAt }
        let terminalTurns = attentionCache.values
            .flatMap(\.terminalTurns)
            .sorted { lhs, rhs in
                if lhs.completedAt != rhs.completedAt {
                    return lhs.completedAt < rhs.completedAt
                }
                if lhs.threadID != rhs.threadID {
                    return lhs.threadID < rhs.threadID
                }
                return lhs.turnID < rhs.turnID
            }
        return CodexRecentTaskSnapshot(
            attention: attention,
            terminalTurns: terminalTurns
        )
    }

    func setRateLimitUpdateHandler(_ handler: @escaping @Sendable () -> Void) async throws {
        guard let rpc else { throw ClientError.notStarted }
        await rpc.setNotificationHandler { method in
            if method == "account/rateLimits/updated" {
                handler()
            }
        }
    }

    func stop() async {
        let rpc = rpc
        let process = process
        self.process = nil
        self.rpc = nil
        attentionCache.removeAll()
        await rpc?.close()
        if let process {
            await terminate(process)
        }
    }

    private func terminate(_ process: any AppServerProcess) async {
        guard process.isRunning else { return }
        process.terminate()

        await waitUntilProcessExits(
            process,
            timeout: processTerminationTimeout
        )

        guard process.isRunning else { return }
        forceTerminate(process.processIdentifier)
    }

    private func waitUntilProcessExits(
        _ process: any AppServerProcess,
        timeout: Duration
    ) async {
        let interval = min(.milliseconds(25), max(timeout, .zero))
        var elapsed = Duration.zero
        while process.isRunning, elapsed < timeout {
            let remaining = timeout - elapsed
            let delay = min(interval, remaining)
            do {
                try await processSleep(delay)
            } catch {
                // Shutdown still owns the child even if its caller is cancelled.
                await Task.yield()
            }
            elapsed += delay
        }
    }
}

protocol AppServerProcess: Sendable {
    var input: FileHandle { get }
    var output: FileHandle { get }
    var isRunning: Bool { get }
    var processIdentifier: pid_t { get }

    func terminate()
}

private final class FoundationAppServerProcess: AppServerProcess, @unchecked Sendable {
    let input: FileHandle
    let output: FileHandle
    private let process: Process

    private init(process: Process, input: FileHandle, output: FileHandle) {
        self.process = process
        self.input = input
        self.output = output
    }

    static func start(executableURL: URL) throws -> FoundationAppServerProcess {
        let process = Process()
        let stdin = Pipe()
        let stdout = Pipe()
        process.executableURL = executableURL
        process.arguments = ["app-server", "--listen", "stdio://"]
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        try process.run()
        return FoundationAppServerProcess(
            process: process,
            input: stdout.fileHandleForReading,
            output: stdin.fileHandleForWriting
        )
    }

    var isRunning: Bool { process.isRunning }
    var processIdentifier: pid_t { process.processIdentifier }

    func terminate() {
        process.terminate()
    }
}

struct CodexThreadSummary: Equatable, Sendable {
    let threadID: String
    let updatedAt: Int
}

struct CodexTaskAttention: Equatable, Sendable {
    let threadID: String
    let turnID: String
    let updatedAt: Int
}

enum CodexTerminalOutcome: Equatable, Hashable, Sendable {
    case completed
    case interrupted
}

struct CodexTerminalTurn: Equatable, Hashable, Sendable {
    let threadID: String
    let turnID: String
    let outcome: CodexTerminalOutcome
    let completedAt: Int
}

struct CodexRecentTaskSnapshot: Equatable, Sendable {
    let attention: CodexTaskAttention?
    let terminalTurns: [CodexTerminalTurn]
}

enum CodexTaskAttentionParser {
    static func threadSummaries(from response: JSONValue) -> [CodexThreadSummary] {
        guard let data = response.objectValue?["data"]?.arrayValue else { return [] }
        return data.compactMap { value in
            guard let object = value.objectValue,
                  let threadID = object["id"]?.stringValue,
                  let updatedAt = object["updatedAt"]?.integerValue
            else { return nil }
            return CodexThreadSummary(threadID: threadID, updatedAt: updatedAt)
        }
    }

    static func attention(
        from response: JSONValue,
        summary: CodexThreadSummary
    ) -> CodexTaskAttention? {
        guard let thread = response.objectValue?["thread"]?.objectValue,
              let turns = thread["turns"]?.arrayValue,
              let latestTurn = turns.last?.objectValue,
              latestTurn["status"]?.stringValue == "completed",
              let turnID = latestTurn["id"]?.stringValue,
              let items = latestTurn["items"]?.arrayValue
        else { return nil }

        let agentMessages = items.compactMap { item -> (text: String, phase: String?)? in
            guard let object = item.objectValue,
                  object["type"]?.stringValue == "agentMessage",
                  let text = object["text"]?.stringValue
            else { return nil }
            return (text, object["phase"]?.stringValue)
        }
        let finalMessage = agentMessages.last { $0.phase == "final_answer" }
            ?? agentMessages.last { $0.phase == nil }
        guard ApprovalClassifier.isApprovalRequest(finalMessage?.text) else { return nil }

        return CodexTaskAttention(
            threadID: summary.threadID,
            turnID: turnID,
            updatedAt: summary.updatedAt
        )
    }

    static func terminalTurns(
        from response: JSONValue,
        summary: CodexThreadSummary
    ) -> [CodexTerminalTurn] {
        guard let thread = response.objectValue?["thread"]?.objectValue,
              let turns = thread["turns"]?.arrayValue
        else { return [] }

        return turns.compactMap { value in
            guard let turn = value.objectValue,
                  let turnID = turn["id"]?.stringValue,
                  let status = turn["status"]?.stringValue
            else { return nil }

            let outcome: CodexTerminalOutcome
            switch status {
            case "completed":
                outcome = .completed
            case "interrupted":
                outcome = .interrupted
            default:
                return nil
            }
            return CodexTerminalTurn(
                threadID: summary.threadID,
                turnID: turnID,
                outcome: outcome,
                completedAt: turn["completedAt"]?.integerValue ?? summary.updatedAt
            )
        }
    }

    static func hasInProgressTurn(in response: JSONValue) -> Bool {
        guard let thread = response.objectValue?["thread"]?.objectValue,
              let turns = thread["turns"]?.arrayValue
        else { return false }

        return turns.contains { turn in
            turn.objectValue?["status"]?.stringValue == "inProgress"
        }
    }
}

protocol CodexAppServerServing: Sendable {
    func start(codexBinary: URL) async throws
    func readRateLimits() async throws -> RateLimitsReadResult
    func readRecentTaskSnapshot() async throws -> CodexRecentTaskSnapshot
    func setRateLimitUpdateHandler(
        _ handler: @escaping @Sendable () -> Void
    ) async throws
    func stop() async
}

extension CodexAppServerServing {
    func readRecentTaskSnapshot() async throws -> CodexRecentTaskSnapshot {
        CodexRecentTaskSnapshot(attention: nil, terminalTurns: [])
    }
}

extension CodexAppServerClient: CodexAppServerServing {}
