import Foundation

/// 呼叫本機翻譯伺服器（server/gamelingo_server.py）。
/// 伺服器負責 Seed-X 提示格式、專名佔位符與 OpenCC 台灣正體，這裡只收串流結果。
struct SeedXClient {
    let baseURL: URL

    struct Update {
        var zh: String
        var explanation: String?   // mode = explain 時的解說（[COT] 後面那段）
        var done = false
        var seconds: Double?
        var error: String?
        var cancelled = false
    }

    /// 邊翻邊回傳「目前為止的整段譯文」。Task 被取消時連線會斷開，伺服器也會停止生成。
    /// context：解說用的語境（"zh" 目前譯文、"prev" 前一句），一般翻譯不用傳
    func translate(_ text: String, names: [String], mode: String = "translate",
                   context: [String: String] = [:]) -> AsyncThrowingStream<Update, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var req = URLRequest(url: baseURL.appendingPathComponent("translate"))
                    req.httpMethod = "POST"
                    req.timeoutInterval = 120
                    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    var body: [String: Any] = ["text": text, "names": names, "mode": mode]
                    for (k, v) in context { body[k] = v }
                    req.httpBody = try JSONSerialization.data(withJSONObject: body)

                    let (bytes, response) = try await URLSession.shared.bytes(for: req)
                    if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                        var body = ""
                        for try await line in bytes.lines { body += line }
                        let msg = (try? JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any])?["error"] as? String
                        throw NSError(domain: "GameLingo", code: http.statusCode,
                                      userInfo: [NSLocalizedDescriptionKey: msg ?? "伺服器錯誤 \(http.statusCode)"])
                    }
                    for try await line in bytes.lines {
                        guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { continue }
                        var u = Update(zh: obj["zh"] as? String ?? "")
                        u.explanation = obj["explanation"] as? String
                        u.done = obj["done"] as? Bool ?? false
                        u.seconds = obj["seconds"] as? Double
                        u.error = obj["error"] as? String
                        u.cancelled = obj["cancelled"] as? Bool ?? false
                        continuation.yield(u)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
