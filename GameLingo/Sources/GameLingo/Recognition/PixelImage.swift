import CoreGraphics

/// 把 CGImage 攤成 RGBA 位元組陣列，方便逐像素分析（左上角為原點）。
struct PixelImage {
    let width: Int
    let height: Int
    let bytes: [UInt8]  // RGBA，每像素 4 bytes

    init?(_ image: CGImage) {
        let w = image.width, h = image.height
        var buf = [UInt8](repeating: 0, count: w * h * 4)
        let ok = buf.withUnsafeMutableBytes { ptr -> Bool in
            guard let ctx = CGContext(data: ptr.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                      bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard ok else { return nil }
        width = w
        height = h
        bytes = buf
    }

    /// 該像素 R、G、B 三者的最小值（三個都亮才算白）
    @inline(__always)
    func minChannel(_ x: Int, _ y: Int) -> UInt8 {
        let i = (y * width + x) * 4
        return min(bytes[i], bytes[i + 1], bytes[i + 2])
    }
}
