public enum SendSafetyError: Error, Equatable {
    case wrongApplication
    case sessionMismatch
    case existingDraft
}

public enum SendSafety {
    public static func validate(
        bundleId: String?,
        sessionMatched: Bool,
        composerValue: String
    ) throws {
        guard bundleId == "com.openai.codex" else {
            throw SendSafetyError.wrongApplication
        }
        guard sessionMatched else {
            throw SendSafetyError.sessionMismatch
        }
        guard composerValue.isEmpty else {
            throw SendSafetyError.existingDraft
        }
    }
}
