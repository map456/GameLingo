import AppKit
import SwiftUI

/// 設定視窗：翻譯、翻譯視窗外觀、記憶體、啟動、名字清單、快捷鍵一覽。
/// 大部分設定改了立刻生效（存在 UserDefaults）。
struct SettingsView: View {
    @AppStorage(AppSettings.Key.autoTranslate) private var autoTranslate = true
    @AppStorage(AppSettings.Key.autoInterval) private var autoInterval = 1.0
    @AppStorage(AppSettings.Key.chineseFontSize) private var zhSize = 19.0
    @AppStorage(AppSettings.Key.englishFontSize) private var enSize = 15.0
    @AppStorage(AppSettings.Key.panelOpacity) private var opacity = 1.0
    @AppStorage(AppSettings.Key.releaseMemory) private var releaseMemory = true
    @AppStorage(AppSettings.Key.releaseDelayMinutes) private var releaseDelay = 1.0
    @AppStorage(AppSettings.Key.spellingPractice) private var spellingPractice = true
    @AppStorage(AppSettings.Key.spellingRepeats) private var spellingRepeats = 2
    @State private var launchAtLogin = AppSettings.launchAtLogin
    @State private var names = ""
    @State private var namesSaved = false

    var body: some View {
        Form {
            Section("翻譯") {
                Toggle("自動翻譯（對話停住就翻，⌃⌥A 也能切換）", isOn: $autoTranslate)
                LabeledContent("偵測間隔") {
                    HStack {
                        Slider(value: $autoInterval, in: 0.5...3, step: 0.5)
                        Text(String(format: "%.1f 秒", autoInterval)).monospacedDigit().frame(width: 52, alignment: .trailing)
                    }
                }
                Text("間隔越短翻得越快，但比較耗電。預設 1 秒。")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("翻譯視窗") {
                LabeledContent("中文字級") {
                    HStack {
                        Slider(value: $zhSize, in: 14...32, step: 1)
                        Text("\(Int(zhSize))").monospacedDigit().frame(width: 52, alignment: .trailing)
                    }
                }
                LabeledContent("英文字級") {
                    HStack {
                        Slider(value: $enSize, in: 11...24, step: 1)
                        Text("\(Int(enSize))").monospacedDigit().frame(width: 52, alignment: .trailing)
                    }
                }
                LabeledContent("不透明度") {
                    HStack {
                        Slider(value: $opacity, in: 0.4...1, step: 0.05)
                        Text("\(Int(opacity * 100))%").monospacedDigit().frame(width: 52, alignment: .trailing)
                    }
                }
                Text("最新一句用上面的字級，舊句子會小一些。").font(.caption).foregroundStyle(.secondary)
            }

            Section("記憶體") {
                Toggle("OpenEmu 關閉後釋放翻譯模型的記憶體（約 8 GB）", isOn: $releaseMemory)
                Picker("關閉多久後釋放", selection: $releaseDelay) {
                    Text("立刻").tag(0.0)
                    Text("1 分鐘").tag(1.0)
                    Text("5 分鐘").tag(5.0)
                    Text("15 分鐘").tag(15.0)
                }
                .disabled(!releaseMemory)
                Text("釋放後查字典、複習單字卡照常可用；開 OpenEmu 或按翻譯時會自動重新載入（約幾秒）。")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("單字卡複習") {
                Toggle("按「忘記」後打字練習這個字", isOn: $spellingPractice)
                Stepper("要打對 \(spellingRepeats) 次", value: $spellingRepeats, in: 1...5)
                    .disabled(!spellingPractice)
            }

            Section("啟動") {
                Toggle("登入 Mac 時自動開啟 GameLingo", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, v in
                        AppSettings.launchAtLogin = v
                        launchAtLogin = AppSettings.launchAtLogin  // 以系統實際狀態為準
                    }
            }

            Section("名字清單（一律保留英文，一行一個）") {
                TextEditor(text: $names)
                    .font(.system(size: 13, design: .monospaced))
                    .frame(minHeight: 90)
                    .onChange(of: names) { _, _ in namesSaved = false }
                HStack {
                    Text("主角名字是你自己取的，一定要寫在這裡。# 開頭是註解。")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    if namesSaved { Text("已儲存").font(.caption).foregroundStyle(.green) }
                    Button("儲存") {
                        try? names.write(to: AppPaths.knownNames, atomically: true, encoding: .utf8)
                        namesSaved = true
                    }
                }
            }

            Section("快捷鍵") {
                shortcut("⌃⌥T", "翻譯目前的對話")
                shortcut("⌃⌥R", "重新擷取並翻譯（不用快取）")
                shortcut("⌃⌥A", "開啟／關閉自動翻譯")
                shortcut("⌃⌥H", "顯示／隱藏翻譯視窗")
            }
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 680)
        .onAppear {
            _ = KnownNames.load()
            names = (try? String(contentsOf: AppPaths.knownNames, encoding: .utf8)) ?? ""
            namesSaved = false
            launchAtLogin = AppSettings.launchAtLogin
        }
    }

    private func shortcut(_ keys: String, _ what: String) -> some View {
        LabeledContent(what) { Text(keys).font(.system(.body, design: .monospaced)) }
    }
}

@MainActor
final class SettingsWindow {
    private var window: NSWindow?

    var isVisible: Bool { window?.isVisible ?? false }

    func show() {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 680),
                             styleMask: [.titled, .closable], backing: .buffered, defer: false)
            w.title = "GameLingo 設定"
            w.isReleasedWhenClosed = false
            w.contentViewController = NSHostingController(rootView: SettingsView())
            w.center()
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
