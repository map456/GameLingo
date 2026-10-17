import CoreGraphics

/// OCR 前處理（階段 0 實測的最佳做法）：
/// 二值化（白字 → 黑字白底）→ 縮到固定寬度 → 四周加白邊。
/// Vision 對「字貼著圖片邊緣」很敏感，像素字的 a 會被認成 o；四周留白之後幾乎全對。
enum Preprocessor {
    /// 對話框裁切圖 → 二值化灰階圖（字是黑色）
    static func binarize(_ crop: PixelImage, threshold: UInt8 = 190) -> CGImage? {
        let w = crop.width, h = crop.height
        var gray = [UInt8](repeating: 255, count: w * h)
        for y in 0..<h {
            for x in 0..<w where crop.minChannel(x, y) > threshold {
                gray[y * w + x] = 0
            }
        }
        return gray.withUnsafeMutableBytes { ptr -> CGImage? in
            CGContext(data: ptr.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)?
                .makeImage()
        }
    }

    /// 縮到 targetWidth 寬，四周留 margin 像素白邊
    static func fit(_ binary: CGImage, targetWidth: Int, margin: Int = 60) -> CGImage? {
        let scale = Double(targetWidth) / Double(binary.width)
        let th = max(1, Int(Double(binary.height) * scale))
        let cw = targetWidth + margin * 2, ch = th + margin * 2
        guard let ctx = CGContext(data: nil, width: cw, height: ch, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceGray(),
                                  bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        ctx.setFillColor(gray: 1, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: cw, height: ch))
        ctx.interpolationQuality = .high
        ctx.draw(binary, in: CGRect(x: margin, y: margin, width: targetWidth, height: th))
        return ctx.makeImage()
    }
}
