import Foundation

final class ChatTargetClassifier: ChatTargetClassifying {
    private let adapters: [any ChatTargetAdapting]
    private let generic = GenericChatTargetAdapter()

    convenience init() {
        self.init(adapters: [
            CodexChatTargetAdapter(),
            VisualStudioCodeChatTargetAdapter(),
            WeChatTargetAdapter(),
        ])
    }

    init(adapters: [any ChatTargetAdapting]) {
        self.adapters = adapters
    }

    func classify(
        bundleIdentifier: String,
        context: FocusedChatContext
    ) throws -> ChatTargetMatch {
        try ChatEvidence.requireEditableChatCandidate(context)
        if let adapter = adapters.first(where: {
            $0.bundleIdentifiers.contains(bundleIdentifier)
        }) {
            return try adapter.classify(context: context)
        }
        return try generic.classify(context: context)
    }
}

private enum ChatEvidence {
    static let editableRoles = Set(["AXTextArea", "AXTextField"])
    static let denyTokens = [
        "search", "find", "terminal", "text editor", "code editor",
        "source control", "scm", "command palette", "password", "address",
        "account", "username", "email", "搜索", "查找", "终端", "代码",
        "编辑器", "密码", "地址", "账号", "用户名", "邮箱",
    ]
    static let chatTokens = [
        "chat", "message", "reply", "send", "conversation", "copilot",
        "聊天", "消息", "回复", "发送", "对话",
    ]
    static let strongChatTokens = [
        "chat", "reply", "conversation", "thread",
        "聊天", "回复", "对话", "会话",
    ]

    static func requireEditableChatCandidate(
        _ context: FocusedChatContext
    ) throws {
        let focused = context.focused
        guard focused.enabled,
              focused.valueSettable,
              editableRoles.contains(focused.role ?? ""),
              !(focused.subrole?.lowercased().contains("secure") ?? false),
              !containsAny(denyTokens, in: context.evidence)
        else {
            throw ChatTargetClassificationError.unsupportedInputContext
        }
    }

    static func containsChatEvidence(_ context: FocusedChatContext) -> Bool {
        containsAny(chatTokens, in: context.evidence)
    }

    static func containsAny(
        _ tokens: [String],
        in elements: [ChatElementSummary]
    ) -> Bool {
        elements.flatMap(\.normalizedLabels).contains { label in
            tokens.contains { label.contains($0) }
        }
    }
}

private struct CodexChatTargetAdapter: ChatTargetAdapting {
    let bundleIdentifiers: Set<String> = ["com.openai.codex"]

    func classify(context: FocusedChatContext) throws -> ChatTargetMatch {
        let inMain = context.ancestors.contains {
            $0.role == "AXLandmarkMain" || $0.subrole == "AXLandmarkMain"
        }
        let hasNativeApproval = ChatEvidence.containsAny(
            ["approve", "allow", "批准", "允许"],
            in: context.nearby
        )
        guard (inMain || ChatEvidence.containsChatEvidence(context)),
              !hasNativeApproval
        else {
            throw ChatTargetClassificationError.unsupportedInputContext
        }
        return ChatTargetMatch(
            kind: .codex,
            placeholderDescription: context.focused.description
        )
    }
}

private struct VisualStudioCodeChatTargetAdapter: ChatTargetAdapting {
    let bundleIdentifiers: Set<String> = [
        "com.microsoft.VSCode",
        "com.microsoft.VSCodeInsiders",
    ]

    func classify(context: FocusedChatContext) throws -> ChatTargetMatch {
        guard ChatEvidence.containsAny(
            ["chat", "copilot", "message", "聊天", "消息"],
            in: context.evidence
        ) else {
            throw ChatTargetClassificationError.unsupportedInputContext
        }
        return ChatTargetMatch(kind: .visualStudioCode)
    }
}

private struct WeChatTargetAdapter: ChatTargetAdapting {
    let bundleIdentifiers: Set<String> = ["com.tencent.xinWeChat"]

    func classify(context: FocusedChatContext) throws -> ChatTargetMatch {
        let isMessageEditor = context.focused.role == "AXTextArea"
        let hasMessageEvidence = ChatEvidence.containsAny(
            ["message", "send", "chat", "消息", "发送", "聊天"],
            in: context.evidence
        )
        guard isMessageEditor, hasMessageEvidence else {
            throw ChatTargetClassificationError.unsupportedInputContext
        }
        return ChatTargetMatch(kind: .weChat)
    }
}

private struct GenericChatTargetAdapter: ChatTargetAdapting {
    let bundleIdentifiers: Set<String> = []

    func classify(context: FocusedChatContext) throws -> ChatTargetMatch {
        guard ChatEvidence.containsAny(
            ChatEvidence.strongChatTokens,
            in: context.evidence
        ) else {
            throw ChatTargetClassificationError.unsupportedInputContext
        }
        return ChatTargetMatch(kind: .generic)
    }
}
