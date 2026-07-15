import CodexQuickOKCore
import Foundation

@main
struct CodexQuickOKHookMain {
    static func main() async {
        do {
            let data = FileHandle.standardInput.readDataToEndOfFile()
            let event = try HookEvent.decode(data)
            let store = SessionStateStore(directory: try SessionStateStore.defaultDirectory())
            let existing = try await store.loadAll(now: Date(), staleAfter: 43_200)
                .first(where: { $0.sessionId == event.sessionId })
            if let next = HookReducer.reduce(event: event, previous: existing, now: Date()) {
                try await store.save(next)
            }
        } catch {
            FileHandle.standardError.write(Data("CodexQuickOKHook: \(error)\n".utf8))
        }
    }
}
