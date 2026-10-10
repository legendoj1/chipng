import Foundation

struct ProcessedImage: Sendable {
    enum Method: Sendable {
        case bleedOnly
        case palette(colors: Int)
        case lossless
    }

    var data: Data
    var width: Int
    var height: Int
    var method: Method
}

enum ImageProcessor {
    // Squoosh's own defaults for "Reduce palette" and OxiPNG.
    static let paletteColors = 256
    static let dithering = 1.0
    static let oxipngLevel = 2
    /// Below this PSNR (dB) palette reduction is considered visibly lossy and the
    /// image is compressed losslessly instead.
    static let minimumPaletteQuality = 32.0

    /// Alpha-bleeds a PNG, then (optionally) compresses it with Squoosh's codecs.
    static func process(_ source: Data, compress: Bool) async throws -> ProcessedImage {
        let bled = try await Task.detached(priority: .userInitiated) {
            var image = try PNGCodec.decode(source)
            AlphaBleed.apply(to: &image)
            return image
        }.value

        guard compress else {
            let data = try await Task.detached(priority: .userInitiated) { try PNGCodec.encode(bled) }.value
            return ProcessedImage(data: data, width: bled.width, height: bled.height, method: .bleedOnly)
        }

        // TinyPNG-style palette reduction (libimagequant). Each visible colour may need
        // an invisible twin to keep the bleed, so the colour count is lowered (at most
        // to 128) when both don't fit in a 256-entry palette.
        var colors = paletteColors
        var attempt = 0
        var palette: PaletteBleed.Result
        while true {
            let quantized = try await SquooshEngine.shared.quantize(bled, colors: colors, dither: dithering)
            palette = await Task.detached(priority: .userInitiated) { PaletteBleed.apply(to: quantized) }.value
            if palette.fitsPalette || colors <= 128 { break }
            attempt += 1
            colors = attempt == 1 ? max(128, min(colors - 1, 256 - palette.transparentColors)) : 128
        }

        let reduced = palette.image
        let quality = await Task.detached(priority: .userInitiated) { psnr(bled, reduced) }.value
        if quality >= minimumPaletteQuality {
            let data = try await SquooshEngine.shared.oxipng(reduced, level: oxipngLevel)
            return ProcessedImage(data: data, width: bled.width, height: bled.height, method: .palette(colors: palette.visibleColors))
        }

        // Too many colours for a palette (photos, smooth gradients): keep every pixel.
        let data = try await SquooshEngine.shared.oxipng(bled, level: oxipngLevel)
        return ProcessedImage(data: data, width: bled.width, height: bled.height, method: .lossless)
    }

    /// Peak signal-to-noise ratio of the visible result, comparing alpha-premultiplied
    /// colours so differences in nearly transparent pixels count for little.
    static func psnr(_ a: RGBAImage, _ b: RGBAImage) -> Double {
        var squaredError = 0.0
        var samples = 0
        a.pixels.withUnsafeBufferPointer { pa in
            b.pixels.withUnsafeBufferPointer { pb in
                for i in stride(from: 0, to: pa.count, by: 4) where pa[i + 3] != 0 || pb[i + 3] != 0 {
                    let alphaA = Double(pa[i + 3]) / 255, alphaB = Double(pb[i + 3]) / 255
                    for c in 0..<3 {
                        let d = Double(pa[i + c]) * alphaA - Double(pb[i + c]) * alphaB
                        squaredError += d * d
                    }
                    let d = Double(pa[i + 3]) - Double(pb[i + 3])
                    squaredError += d * d
                    samples += 4
                }
            }
        }
        guard samples > 0, squaredError > 0 else { return .infinity }
        return 10 * log10(255 * 255 / (squaredError / Double(samples)))
    }
}
