import Foundation

/// The chipng / Pixelfix alpha-bleeding algorithm
/// (https://github.com/urraka/alpha-bleeding), ported from the chipng web app
/// (https://github.com/rbxxaxa/chipng).
///
/// Every fully transparent pixel gets the average colour of its nearest
/// visible neighbours, spreading outward ring by ring, so bilinear filtering
/// in Roblox never blends in black from invisible pixels. Alpha is untouched.
enum AlphaBleed {
    private static let offsets: [(Int, Int)] = [(-1, -1), (0, -1), (1, -1), (-1, 0), (1, 0), (-1, 1), (0, 1), (1, 1)]

    static func apply(to image: inout RGBAImage) {
        let width = image.width, height = image.height
        let count = width * height
        var opaque = [UInt8](repeating: 0, count: count)
        var loose = [Bool](repeating: false, count: count)
        var pending: [Int] = []
        var pendingNext: [Int] = []

        image.pixels.withUnsafeMutableBufferPointer { data in
            for y in 0..<height {
                for x in 0..<width {
                    let idx = y * width + x
                    if data[idx * 4 + 3] != 0 {
                        opaque[idx] = 0xFF
                        continue
                    }
                    var isLoose = true
                    for (s, t) in offsets {
                        let nx = x + s, ny = y + t
                        // Unlike the web version, neighbours don't wrap around image edges.
                        guard nx >= 0, nx < width, ny >= 0, ny < height else { continue }
                        if data[(ny * width + nx) * 4 + 3] != 0 {
                            isLoose = false
                            break
                        }
                    }
                    if isLoose { loose[idx] = true } else { pending.append(idx) }
                }
            }

            while !pending.isEmpty {
                pendingNext.removeAll(keepingCapacity: true)

                for idx in pending {
                    let x = idx % width, y = idx / width
                    var r = 0, g = 0, b = 0, n = 0

                    for (s, t) in offsets {
                        let nx = x + s, ny = y + t
                        guard nx >= 0, nx < width, ny >= 0, ny < height else { continue }
                        let nIdx = ny * width + nx
                        if opaque[nIdx] & 1 != 0 {
                            r += Int(data[nIdx * 4])
                            g += Int(data[nIdx * 4 + 1])
                            b += Int(data[nIdx * 4 + 2])
                            n += 1
                        }
                    }

                    if n > 0 {
                        data[idx * 4] = UInt8(r / n)
                        data[idx * 4 + 1] = UInt8(g / n)
                        data[idx * 4 + 2] = UInt8(b / n)
                        data[idx * 4 + 3] = 0
                        opaque[idx] = 0xFE

                        for (s, t) in offsets {
                            let nx = x + s, ny = y + t
                            guard nx >= 0, nx < width, ny >= 0, ny < height else { continue }
                            let nIdx = ny * width + nx
                            if loose[nIdx] {
                                pendingNext.append(nIdx)
                                loose[nIdx] = false
                            }
                        }
                    } else {
                        pendingNext.append(idx)
                    }
                }

                if !pendingNext.isEmpty {
                    for idx in pending { opaque[idx] >>= 1 }
                }

                swap(&pending, &pendingNext)
            }
        }
    }
}

/// Re-applies the bleed to an image that went through palette reduction.
///
/// libimagequant (like TinyPNG) collapses every invisible pixel into one
/// transparent-black palette entry, which brings the black fringes back. This
/// bleeds the quantized image again and snaps each invisible pixel's colour to
/// the nearest visible palette colour, so the result still fits in a 256-entry
/// palette: each visible colour gets at most one invisible "twin".
enum PaletteBleed {
    struct Result {
        var image: RGBAImage
        var visibleColors: Int
        var transparentColors: Int
        var fitsPalette: Bool { visibleColors + transparentColors <= 256 }
    }

    static func apply(to quantized: RGBAImage) -> Result {
        var image = quantized
        var visible: [UInt32: Void] = [:]
        image.pixels.withUnsafeBufferPointer { px in
            for i in stride(from: 0, to: px.count, by: 4) where px[i + 3] != 0 {
                visible[rgba(px, i)] = ()
            }
        }
        guard !visible.isEmpty else { return Result(image: image, visibleColors: 0, transparentColors: 0) }

        let paletteRGB = visible.keys.map { ($0 >> 24 & 0xFF, $0 >> 16 & 0xFF, $0 >> 8 & 0xFF) }
        AlphaBleed.apply(to: &image)

        var snapped: [UInt32: UInt32] = [:]
        var twins: Set<UInt32> = []
        image.pixels.withUnsafeMutableBufferPointer { px in
            for i in stride(from: 0, to: px.count, by: 4) where px[i + 3] == 0 {
                let key = rgba(UnsafeBufferPointer(px), i)
                let twin: UInt32
                if let cached = snapped[key] {
                    twin = cached
                } else {
                    let r = Int(px[i]), g = Int(px[i + 1]), b = Int(px[i + 2])
                    var best = paletteRGB[0], bestDistance = Int.max
                    for c in paletteRGB {
                        let dr = r - Int(c.0), dg = g - Int(c.1), db = b - Int(c.2)
                        let d = dr * dr + dg * dg + db * db
                        if d < bestDistance { bestDistance = d; best = c }
                    }
                    twin = best.0 << 24 | best.1 << 16 | best.2 << 8
                    snapped[key] = twin
                }
                twins.insert(twin)
                px[i] = UInt8(twin >> 24)
                px[i + 1] = UInt8(twin >> 16 & 0xFF)
                px[i + 2] = UInt8(twin >> 8 & 0xFF)
            }
        }
        return Result(image: image, visibleColors: visible.count, transparentColors: twins.count)
    }

    @inline(__always)
    private static func rgba(_ px: UnsafeBufferPointer<UInt8>, _ i: Int) -> UInt32 {
        UInt32(px[i]) << 24 | UInt32(px[i + 1]) << 16 | UInt32(px[i + 2]) << 8 | UInt32(px[i + 3])
    }
}
