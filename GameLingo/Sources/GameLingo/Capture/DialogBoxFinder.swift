import CoreGraphics

/// 找 DQ4 對話框的白色外框（跟階段 0 的 find_dialog_box 相同做法）。
///
/// 對畫面下半部每一列計算「接近白色的像素比例」，外框上下兩條橫線比例會特別高；
/// 再在框內找左右兩條直線。找不到外框就回傳 nil（不猜位置，避免把地圖紋理認成字）。
enum DialogBoxFinder {
    static func find(in img: PixelImage) -> CGRect? {
        let w = img.width, h = img.height
        guard w > 10, h > 10 else { return nil }

        func isWhite(_ x: Int, _ y: Int) -> Bool { img.minChannel(x, y) > 200 }

        // 1. 白色比例 > 60% 的列
        var rows: [Int] = []
        for y in (h / 2)..<h {
            var count = 0
            for x in 0..<w where isWhite(x, y) { count += 1 }
            if Double(count) / Double(w) > 0.6 { rows.append(y) }
        }
        guard rows.count >= 2 else { return nil }

        // 2. 相鄰的列合併成「線」
        var lines: [[Int]] = []
        for y in rows {
            if let last = lines.last?.last, y - last <= 3 {
                lines[lines.count - 1].append(y)
            } else {
                lines.append([y])
            }
        }
        guard lines.count >= 2 else { return nil }
        let top = lines.first!.last! + 1
        let bottom = lines.last!.first!
        guard Double(bottom - top) > Double(h) * 0.05 else { return nil }

        // 3. 框內白色比例 > 60% 的欄＝左右邊框
        var leftEdge = -1
        var rightEdge = w
        for x in 0..<w {
            var count = 0
            for y in top..<bottom where isWhite(x, y) { count += 1 }
            if Double(count) / Double(bottom - top) > 0.6 {
                if x < w / 2 { leftEdge = max(leftEdge, x) } else { rightEdge = min(rightEdge, x) }
            }
        }
        let left = leftEdge + 1
        let pad = 4
        let rect = CGRect(x: left + pad, y: top + pad, width: rightEdge - pad - (left + pad), height: bottom - pad - (top + pad))
        return rect.width > 20 && rect.height > 10 ? rect : nil
    }
}
