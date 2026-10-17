import CoreGraphics
import ImageIO
import Foundation

/// 整張遊戲畫面 → 對話框文字（找框 → 裁切 → OCR 投票）。
enum DialogueReader {
    struct Output {
        let text: String
        let crop: CGImage
        let box: CGRect
    }

    struct Frame {
        let signature: [UInt8]
        let crop: CGImage
        let text: String?  // 畫面跟上次一樣時不重跑 OCR，回傳 nil
    }

    /// 自動模式用：找對話框，算出「縮圖指紋」；指紋跟 previous 不同才跑 OCR（省電）。
    /// 找不到對話框回傳 nil。
    static func readIfChanged(_ screenshot: CGImage, previous: [UInt8]?) -> Frame? {
        guard let full = PixelImage(screenshot),
              let box = DialogBoxFinder.find(in: full),
              let crop = screenshot.cropping(to: box),
              let cropPixels = PixelImage(crop) else { return nil }
        let sig = signature(of: cropPixels)
        let text = sig == previous ? nil : OCRService.ensemble(crop: cropPixels).text
        return Frame(signature: sig, crop: crop, text: text)
    }

    /// 對話框縮成 128×32 的黑白點陣（字＝1），用來快速判斷畫面有沒有變
    static func signature(of crop: PixelImage, columns: Int = 128, rows: Int = 32) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: columns * rows)
        for r in 0..<rows {
            let y = min(crop.height - 1, (r * crop.height + crop.height / (2 * rows)) / rows)
            for c in 0..<columns {
                let x = min(crop.width - 1, (c * crop.width + crop.width / (2 * columns)) / columns)
                out[r * columns + c] = crop.minChannel(x, y) > 190 ? 1 : 0
            }
        }
        return out
    }

    /// 文字相似度（0～1）：1 − 編輯距離 ÷ 較長字串長度
    static func similarity(_ a: String, _ b: String) -> Double {
        let x = Array(a), y = Array(b)
        if x.isEmpty && y.isEmpty { return 1 }
        var prev = Array(0...y.count)
        for i in 1...max(1, x.count) where !x.isEmpty {
            var cur = [i] + [Int](repeating: 0, count: y.count)
            for j in stride(from: 1, through: y.count, by: 1) {
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (x[i - 1] == y[j - 1] ? 0 : 1))
            }
            prev = cur
        }
        let dist = x.isEmpty ? y.count : prev[y.count]
        return 1 - Double(dist) / Double(max(x.count, y.count))
    }

    /// 找不到對話框回傳 nil
    static func read(_ screenshot: CGImage) -> Output? {
        guard let full = PixelImage(screenshot),
              let box = DialogBoxFinder.find(in: full),
              let crop = screenshot.cropping(to: box),
              let cropPixels = PixelImage(crop) else { return nil }
        let result = OCRService.ensemble(crop: cropPixels)
        return Output(text: result.text, crop: crop, box: box)
    }
}

/// `GameLingo --ocr-test 圖.png …`：對截圖檔跑 OCR，印出結果。
enum OCRTestCLI {
    static func run(paths: [String]) {
        for path in paths {
            let url = URL(fileURLWithPath: path)
            guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
                print("\(path): 讀不到圖片")
                continue
            }
            let t0 = Date()
            if let out = DialogueReader.read(img) {
                let ms = Int(Date().timeIntervalSince(t0) * 1000)
                print("\(url.lastPathComponent)\t\(Int(out.box.minX)),\(Int(out.box.minY)),\(Int(out.box.width))x\(Int(out.box.height))\t\(ms)ms\t\(out.text)")
            } else {
                print("\(url.lastPathComponent)\t（沒有對話框）")
            }
        }
    }
}
