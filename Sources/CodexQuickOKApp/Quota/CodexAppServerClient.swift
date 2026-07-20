import CodexQuickOKCore
import Foundation

actor CodexAppServerClient {
    enum ClientError: Error {
        case codexBinaryMissing
        case notStarted
    }

    private var process: Process?
    private var rpc: LineJSONRPCClient?

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
    }
}

protocol CodexAppServerServing: Sendable {
    func start(codexBinary: URL) async throws
    func readRateLimits() async throws -> RateLimitsReadResult
    func setRateLimitUpdateHandler(
        _ handler: @escaping @Sendable () -> Void
    ) async throws
    func stop() async
}

extension CodexAppServerClient: CodexAppServerServing {}
