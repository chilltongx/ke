import CodexQuickOKCore
import Foundation

actor CodexAppServerClient {
    enum ClientError: Error {
        case codexBinaryMissing
        case notStarted
    }

    private var process: Process?
    private var rpc: LineJSONRPCClient?
    private var attentionCache: [String: CachedAttention] = [:]

    private struct CachedAttention: Sendable {
        let updatedAt: Int
        let attention: CodexTaskAttention?
    }

    func start(codexBinary: URL) async throws {
        let process = Process()
        let stdin = Pipe()
        let stdout = Pipe()
        process.executableURL = codexBinary
        process.arguments = ["app-server", "--listen", "stdio://"]
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        try process.run()

        let rpc = LineJSONRPCClient(
            input: stdout.fileHandleForReading,
            output: stdin.fileHandleForWriting
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
            process.terminate()
            self.process = nil
            self.rpc = nil
            throw error
        }
    }

    func readRateLimits() async throws -> RateLimitsReadResult {
        guard let rpc else { throw ClientError.notStarted }
        let object = try await rpc.request(method: "account/rateLimits/read", params: [:])
        let data = try JSONEncoder().encode(object)
        return try JSONDecoder().decode(RateLimitsReadResult.self, from: data)
    }

    func readRecentTaskAttention() async throws -> CodexTaskAttention? {
        guard let rpc else { throw ClientError.notStarted }
        let list = try await rpc.request(
            method: "thread/list",
            params: [
                "limit": .integer(8),
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
            if attentionCache[summary.threadID]?.updatedAt == summary.updatedAt {
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
                )
            )
        }

        return attentionCache.values
            .compactMap(\.attention)
            .max { $0.updatedAt < $1.updatedAt }
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
        process?.terminate()
        process = nil
        rpc = nil
        attentionCache.removeAll()
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
}

protocol CodexAppServerServing: Sendable {
    func start(codexBinary: URL) async throws
    func readRateLimits() async throws -> RateLimitsReadResult
    func readRecentTaskAttention() async throws -> CodexTaskAttention?
    func setRateLimitUpdateHandler(
        _ handler: @escaping @Sendable () -> Void
    ) async throws
    func stop() async
}

extension CodexAppServerClient: CodexAppServerServing {}
