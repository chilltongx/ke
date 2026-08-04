import Foundation

struct ChatElementSummary: Equatable {
    let role: String?
    let subrole: String?
    let title: String?
    let description: String?
    let enabled: Bool
    let valueSettable: Bool

    var normalizedLabels: [String] {
        [title, description, subrole]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .map { $0.lowercased() }
    }
}

struct FocusedChatContext: Equatable {
    let focused: ChatElementSummary
    let ancestors: [ChatElementSummary]
    let nearby: [ChatElementSummary]

    var evidence: [ChatElementSummary] {
        [focused] + ancestors + nearby
    }
}

enum ChatTargetKind: Equatable {
    case codex
    case visualStudioCode
    case weChat
    case generic
}

struct ChatTargetMatch: Equatable {
    let kind: ChatTargetKind
    let placeholderDescription: String?

    init(
        kind: ChatTargetKind,
        placeholderDescription: String? = nil
    ) {
        self.kind = kind
        self.placeholderDescription = placeholderDescription
    }

    func normalizedComposerValue(_ rawValue: String) -> String {
        guard kind == .codex,
              let placeholderDescription,
              !placeholderDescription.isEmpty,
              rawValue == "\n\(placeholderDescription)"
        else {
            return rawValue
        }
        return ""
    }
}

enum ChatTargetClassificationError: Error, Equatable, LocalizedError {
    case unsupportedInputContext

    var errorDescription: String? {
        "当前光标不在支持的聊天输入框中"
    }
}

protocol ChatTargetClassifying: AnyObject {
    func classify(
        bundleIdentifier: String,
        context: FocusedChatContext
    ) throws -> ChatTargetMatch
}

protocol ChatTargetAdapting {
    var bundleIdentifiers: Set<String> { get }

    func classify(context: FocusedChatContext) throws -> ChatTargetMatch
}

struct FocusedTargetSnapshot {
    let processIdentifier: pid_t
    let bundleIdentifier: String
    let window: AnyObject
    let element: AnyObject
    let context: FocusedChatContext
}

@MainActor
protocol FocusedInputControlling: AnyObject {
    func captureTarget() throws -> FocusedTargetSnapshot
    func revalidate(_ target: FocusedTargetSnapshot) throws
    func composerValue(in target: FocusedTargetSnapshot) throws -> String
    func setComposerValue(
        _ value: String,
        in target: FocusedTargetSnapshot
    ) throws
    func waitUntilComposerValue(
        _ expected: String,
        in target: FocusedTargetSnapshot,
        timeout: TimeInterval
    ) async throws
    func pressReturn(in target: FocusedTargetSnapshot) throws
}
