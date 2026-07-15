import Foundation

public enum ApprovalClassifier {
    private static let patterns = [
        #"可以(?:继续|执行|开始|安装|修改|提交|删除|运行|写入|创建)?吗[？?]?"#,
        #"可否(?:继续|执行|开始|安装|修改|提交|删除|运行|写入|创建)"#,
        #"是否(?:继续|执行|开始|安装|修改|提交|删除|运行|写入|创建)"#,
        #"请(?:确认|批准)"#,
        #"要我(?:继续|执行|开始|安装|修改|提交|删除|运行|写入|创建)"#,
        #"回复[“\"']?可"#,
        #"\b(?:shall|should|may|can)\s+i\s+(?:continue|proceed|run|apply|install|delete|write|create)\b"#,
        #"\bplease\s+(?:confirm|approve)\b"#,
        #"\b(?:ready to proceed|proceed with this)\b"#,
    ]

    public static func isApprovalRequest(_ message: String?) -> Bool {
        guard let message, !message.isEmpty else { return false }
        return patterns.contains { pattern in
            message.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
        }
    }
}
