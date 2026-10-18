import Foundation

/// 啟動並監看本機翻譯伺服器（server/gamelingo_server.py）。
///
/// 伺服器本身很小（約 50 MB），負責字典與字根查詢；翻譯模型（約 8 GB）可以另外載入／卸載：
/// OpenEmu 關掉一陣子後卸載模型釋放記憶體，開遊戲時再載入（約 1～5 秒）。
/// 已經有伺服器在跑（例如上次沒關乾淨）就直接沿用。
@MainActor
final class ModelServer {
    enum State: Equatable {
        case starting           // 伺服器啟動中
        case unloaded           // 伺服器在跑，模型沒載入（省記憶體）
        case loading            // 模型載入中
        case ready              // 可以翻譯
        case failed(String)
    }

    let port = 8765
    var baseURL: URL { URL(string: "http://127.0.0.1:\(port)")! }

    private(set) var state: State = .starting {
        didSet { if state != oldValue { onChange?() } }
    }
    var onChange: (() -> Void)?

    /// 伺服器在跑就能查字典（不需要模型）
    var canLookup: Bool {
        switch state {
        case .unloaded, .loading, .ready: return true
        default: return false
        }
    }

    private var process: Process?
    private var pollTask: Task<Void, Never>?

    /// 啟動伺服器；loadModel＝false 時先不載入模型
    func start(loadModel: Bool) {
        Task {
            if let h = await health() {
                // 沿用已經在跑的伺服器（例如 App 重開）：當作用目前設定的模型
                if launchedModel == nil { launchedModel = AppSettings.translationModel }
                apply(h)
                if loadModel { load() }
                return
            }
            guard launch(lazy: !loadModel) else { return }
            // 等伺服器起來（約 1～3 秒）
            for _ in 0..<60 {
                try? await Task.sleep(for: .milliseconds(500))
                if let process, !process.isRunning {
                    state = .failed("翻譯伺服器意外結束，詳情見 server.log：\n" + logTail())
                    return
                }
                if let h = await health() {
                    apply(h)
                    if loadModel { load() }
                    return
                }
            }
            state = .failed("翻譯伺服器啟動逾時，詳情見 server.log")
        }
    }

    /// 載入模型（已載入就什麼都不做）
    func load() {
        guard state == .unloaded || state == .starting || { if case .failed = state { return true }; return false }() else { return }
        state = .loading
        post("load")
        poll(until: { $0.ready })
    }

    /// 卸載模型，釋放約 8 GB 記憶體（字典查詢照常可用）
    func unload() {
        guard state == .ready || state == .loading else { return }
        pollTask?.cancel()
        post("unload")
        state = .unloaded
        appLog("已卸載翻譯模型（釋放記憶體）")
    }

    func stop() {
        pollTask?.cancel()
        process?.terminate()
        process = nil
    }

    /// 目前伺服器用的模型組合（啟動時決定）
    private(set) var launchedModel: TranslationModel?

    /// 換模型：關掉伺服器、等它真的停了，再用新設定啟動
    func restart(loadModel: Bool) {
        pollTask?.cancel()
        process?.terminate()
        process = nil
        state = .starting
        Task {
            for _ in 0..<20 {
                if await health() == nil { break }
                try? await Task.sleep(for: .milliseconds(250))
            }
            start(loadModel: loadModel)
        }
    }

    // MARK: - 內部

    private struct Health {
        let ready: Bool
        let loading: Bool
        let error: String?
    }

    private func apply(_ h: Health) {
        if let e = h.error, !e.isEmpty, !h.ready, !h.loading {
            state = .failed("模型載入失敗：\(e)")
        } else if h.ready {
            state = .ready
        } else if h.loading {
            state = .loading
            poll(until: { $0.ready })
        } else {
            state = .unloaded
        }
    }

    private func poll(until done: @escaping (Health) -> Bool) {
        pollTask?.cancel()
        pollTask = Task {
            for _ in 0..<360 {
                try? await Task.sleep(for: .milliseconds(500))
                if Task.isCancelled { return }
                guard let h = await health() else { continue }
                if done(h) || (h.error != nil && !h.loading) {
                    apply(h)
                    return
                }
            }
            state = .failed("模型載入逾時，詳情見 server.log")
        }
    }

    private func health() async -> Health? {
        var req = URLRequest(url: baseURL.appendingPathComponent("health"))
        req.timeoutInterval = 2
        guard let (data, _) = try? await URLSession.shared.data(for: req),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return Health(ready: obj["ready"] as? Bool ?? false,
                      loading: obj["loading"] as? Bool ?? false,
                      error: obj["error"] as? String)
    }

    private func post(_ path: String) {
        var req = URLRequest(url: baseURL.appendingPathComponent(path))
        req.httpMethod = "POST"
        req.timeoutInterval = 5
        URLSession.shared.dataTask(with: req).resume()
    }

    private func launch(lazy: Bool) -> Bool {
        guard let root = AppPaths.repoRoot else {
            state = .failed("不知道專案資料夾在哪裡，請用 build.sh 重新編譯")
            return false
        }
        let python = root.appendingPathComponent("server/.venv/bin/python")
        let script = root.appendingPathComponent("server/gamelingo_server.py")
        guard FileManager.default.fileExists(atPath: python.path) else {
            state = .failed("找不到伺服器的 Python 環境：\(python.path)\n請在專案資料夾執行 ./build.sh")
            return false
        }

        FileManager.default.createFile(atPath: AppPaths.serverLog.path, contents: nil)
        let log = try? FileHandle(forWritingTo: AppPaths.serverLog)

        let p = Process()
        p.executableURL = python
        // 選的模型還沒下載（沒有 config.json）就退回 Seed-X 組合
        var choice = AppSettings.translationModel
        if !FileManager.default.fileExists(atPath: root.appendingPathComponent(choice.folders.model + "/config.json").path) {
            appLog("找不到 \(choice.folders.model)，改用 Seed-X")
            choice = .seedx
        }
        launchedModel = choice
        p.arguments = [script.path, "--port", String(port),
                       "--model", root.appendingPathComponent(choice.folders.model).path,
                       "--explainer", root.appendingPathComponent(choice.folders.explainer).path]
            + (lazy ? ["--lazy"] : [])
        p.currentDirectoryURL = root.appendingPathComponent("server")
        p.standardOutput = log
        p.standardError = log
        var env = ProcessInfo.processInfo.environment
        env["PYTHONUNBUFFERED"] = "1"
        p.environment = env
        do {
            try p.run()
            process = p
            state = .starting
            return true
        } catch {
            state = .failed("無法啟動翻譯伺服器：\(error.localizedDescription)")
            return false
        }
    }

    private func logTail() -> String {
        guard let text = try? String(contentsOf: AppPaths.serverLog, encoding: .utf8) else { return "" }
        return text.split(separator: "\n").suffix(8).joined(separator: "\n")
    }
}
