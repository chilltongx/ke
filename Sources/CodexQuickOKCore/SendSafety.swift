import Foundation

public enum SendSafetyError: Error, Equatable, LocalizedError {
    case wrongApplication
    case sessionMismatch
    case existingDraft

    public var errorDescription: String? {
        switch self {
        case .wrongApplication:
            "无法确认当前窗口属于 Codex"
        case .sessionMismatch:
            "无法确认目标 Codex 任务"
        case .existingDraft:
            "检测到未发送草稿"
        }
    }
}

public enum SendSafety {
    public static func validate(
        bundleId: String?,
        composerValue: String
    ) throws {
        guard bundleId == "com.openai.codex" else {
            throw SendSafetyError.wrongApplication
        }
        guard composerValue.trimmingCharacters(
            in: .whitespacesAndNewlines
        ).isEmpty else {
            throw SendSafetyError.existingDraft
        }
    }

    @available(*, deprecated, message: "Use current-window validation")
    public static func validate(
        bundleId: String?,
        sessionMatched: Bool,
        composerValue: String
    ) throws {
        guard sessionMatched else { throw SendSafetyError.sessionMismatch }
        try validate(bundleId: bundleId, composerValue: composerValue)
    }
}
