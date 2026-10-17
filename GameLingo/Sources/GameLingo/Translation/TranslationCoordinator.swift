import Foundation

/// 翻譯協調：查快取、取消舊任務、只處理最新一句。
@MainActor
final class TranslationCoordinator {
    /// 快取鍵＝清理後文字＋模型名稱＋prompt 版本；換模型或改提示格式時舊快取自動失效
    static let modelName = "seedx-ppo-7b-mlx-8bit"
    static let promptVersion = "v1-x-placeholder"

    private let client: SeedXClient
    private var cache: [String: String] = [:]
    private var task: Task<Void, Never>?

    init(client: SeedXClient) {
        self.client = client
    }

    func cached(_ text: String) -> String? { cache[key(text)] }

    func cancel() {
        task?.cancel()
        task = nil
    }

    /// onUpdate：每次有新的部分譯文；onDone：(最終譯文, 秒數, 錯誤訊息)
    func translate(_ text: String, names: [String],
                   onUpdate: @escaping (String) -> Void,
                   onDone: @escaping (String?, Double?, String?) -> Void) {
        cancel()
        let k = key(text)
        task = Task { [client] in
            var latest = ""
            do {
                for try await u in client.translate(text, names: names) {
                    if Task.isCancelled { return }
                    if u.cancelled { return }
                    if let err = u.error {
                        onDone(nil, nil, err)
                        return
                    }
                    latest = u.zh
                    if u.done {
                        self.cache[k] = latest
                        onDone(latest, u.seconds, nil)
                        return
                    }
                    onUpdate(latest)
                }
            } catch {
                if Task.isCancelled || (error as? URLError)?.code == .cancelled { return }
                onDone(nil, nil, error.localizedDescription)
            }
        }
    }

    private func key(_ text: String) -> String {
        "\(text)\u{1F}\(Self.modelName)\u{1F}\(Self.promptVersion)"
    }
}
