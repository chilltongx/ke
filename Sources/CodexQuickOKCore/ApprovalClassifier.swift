import Foundation

public enum ApprovalClassifier {
    private static let patterns = [
        #"可以(?:继续|执行|开始|安装|修改|提交|删除|运行|写入|创建)?吗[？?]?"#,
        #"可否(?:继续|执行|开始|安装|修改|提交|删除|运行|写入|创建)"#,
        #"是否(?:继续|执行|开始|安装|修改|提交|删除|运行|写入|创建)"#,
        #"请(?:确认|批准)"#,
        #"(?:等待|等)(?:你|您的)?确认"#,
        #"需要(?:你|您)?确认"#,
        #"确认(?:后|之后).{0,24}(?:继续|执行|开始|安装|修改|提交|删除|运行|写入|创建)"#,
        #"(?:如果|若)(?:你|您)?.{0,12}确认.{0,24}(?:继续|执行|开始|安装|修改|提交|删除|运行|写入|创建)"#,
        #"要我(?:继续|执行|开始|安装|修改|提交|删除|运行|写入|创建)"#,
        #"回复[“\"']?可"#,
        #"\b(?:shall|should|may|can)\s+i\s+(?:continue|proceed|run|apply|install|delete|write|create)\b"#,
        #"\bplease\s+(?:confirm|approve)\b"#,
        #"\b(?:waiting|wait)\s+for\s+(?:your\s+)?(?:confirmation|approval)\b"#,
        #"\bonce\s+you\s+(?:confirm|approve).{0,48}\b(?:continue|proceed|run|apply)\b"#,
        #"\b(?:ready to proceed|proceed with this)\b"#,
    ]

    public static func isApprovalRequest(_ message: String?) -> Bool {
        guard let message, !message.isEmpty else { return false }
        return patterns.contains { pattern in
            message.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
        }
    }
}
