import AppKit
import SwiftUI

/// 浮動翻譯視窗的內容狀態
@MainActor
final class OverlayModel: ObservableObject {
    /// 一句翻譯（英文＋中文），新的接在下面
    struct Entry: Identifiable, Equatable {
        let id = UUID()
        var english: String
        var chinese: String
        var explanation: String?   // 語境解說（按 💡 才產生）
        var explaining = false
    }

    @Published var entries: [Entry] = []
    @Published var status = "按 ⌃⌥T 翻譯目前的對話"
    @Published var busy = false
    @Published var editing = false
    @Published var editText = ""
    @Published var auto = false

    /// 點字查詢
    @Published var word: WordInfo?
    @Published var wordLoading: String?
    /// 被點的字出自哪一句（收藏時記下遊戲原句）
    @Published var wordEntry: Entry?
    @Published var wordMorph: MorphInfo?

    static let maxEntries = 100

    var english: String { entries.last?.english ?? "" }

    /// 開始一句新的翻譯；如果跟最後一句幾乎一樣（重新翻譯，或 OCR 只差一兩個字），就沿用那一列
    func begin(_ english: String) {
        if let last = entries.last, DialogueReader.similarity(last.english, english) >= 0.9 {
            entries[entries.count - 1].english = english
            entries[entries.count - 1].chinese = ""
        } else {
            entries.append(Entry(english: english, chinese: ""))
            if entries.count > Self.maxEntries { entries.removeFirst(entries.count - Self.maxEntries) }
        }
    }

    func setChinese(_ zh: String) {
        guard !entries.isEmpty else { return }
        entries[entries.count - 1].chinese = zh
    }
}

/// 不搶焦點的浮動視窗：遊戲照常吃鍵盤，視窗永遠浮在最上層。
final class OverlayPanel: NSPanel {
    init(model: OverlayModel, store: StudyStore, actions: TranslationView.Actions) {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 460, height: 440),
                   styleMask: [.titled, .resizable, .nonactivatingPanel, .fullSizeContentView],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .floating
        hidesOnDeactivate = false          // 我們的 App 從不在前景，不能讓它自動隱藏
        becomesKeyOnlyIfNeeded = true      // 點按鈕不會拿走鍵盤焦點
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        titlebarAppearsTransparent = true
        titleVisibility = .hidden
        isMovableByWindowBackground = true
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        appearance = NSAppearance(named: .darkAqua)
        minSize = NSSize(width: 300, height: 220)
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            standardWindowButton(button)?.isHidden = true
        }

        // 半透明毛玻璃背景（state = .active：App 不在前景時也保持效果）
        let effect = NSVisualEffectView()
        effect.material = .hudWindow
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 12
        effect.layer?.masksToBounds = true

        let hosting = NSHostingView(rootView: TranslationView(model: model, store: store, actions: actions))
        hosting.translatesAutoresizingMaskIntoConstraints = false
        effect.addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
            hosting.topAnchor.constraint(equalTo: effect.topAnchor),
            hosting.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
        ])
        contentView = effect

        // 記住位置與大小；第一次放在主螢幕右上角
        if !setFrameUsingName("GameLingoOverlay"), let screen = NSScreen.main?.visibleFrame {
            setFrameOrigin(NSPoint(x: screen.maxX - frame.width - 24, y: screen.maxY - frame.height - 24))
        }
        setFrameAutosaveName("GameLingoOverlay")
        // 舊版存的視窗比較矮；改成累積清單後至少要有 360 高（保持上緣不動）
        if frame.height < 360 {
            setFrame(NSRect(x: frame.minX, y: frame.maxY - 440, width: max(frame.width, 460), height: 440), display: false)
        }
    }

    /// 平常完全不能拿鍵盤焦點（遊戲才收得到按鍵）；只有按鉛筆修正原文時才打開
    var allowsKeyboard = false
    override var canBecomeKey: Bool { allowsKeyboard }
    override var canBecomeMain: Bool { false }
}
