import Foundation

/// 8-bit, non-premultiplied RGBA pixels.
struct RGBAImage: Sendable {
    var width: Int
    var height: Int
    var pixels: [UInt8]
}

enum PNGError: LocalizedError {
    case notPNG
    case corrupt(String)
    case unsupported(String)

    var errorDescription: String? {
        switch self {
        case .notPNG: return "Not a PNG file"
        case .corrupt(let why): return "Damaged PNG (\(why))"
        case .unsupported(let why): return "Unsupported PNG (\(why))"
        }
    }
}

/// A small PNG reader/writer that keeps exact pixel values.
///
/// CoreGraphics premultiplies alpha when decoding, which throws away the colour of
/// fully transparent pixels — exactly the data alpha bleeding writes — so we decode
/// and encode ourselves, the same way pngjs did in the original web app.
enum PNGCodec {
    private static let signature: [UInt8] = [137, 80, 78, 71, 13, 10, 26, 10]

    // MARK: Decoding

    static func decode(_ data: Data) throws -> RGBAImage {
        let bytes = [UInt8](data)
        guard bytes.count > 8, Array(bytes[0..<8]) == signature else { throw PNGError.notPNG }

        var width = 0, height = 0, bitDepth = 0, colorType = 0, interlace = 0
        var palette: [UInt8] = []
        var transparency: [UInt8] = []
        var idat = Data()
        var offset = 8

        while offset + 8 <= bytes.count {
            let length = Int(readUInt32(bytes, offset))
            let type = String(bytes: bytes[offset + 4..<offset + 8], encoding: .ascii) ?? ""
            let start = offset + 8
            guard length >= 0, start + length + 4 <= bytes.count else { throw PNGError.corrupt("truncated \(type) chunk") }
            let body = bytes[start..<start + length]

            switch type {
            case "IHDR":
                guard length >= 13 else { throw PNGError.corrupt("bad header") }
                width = Int(readUInt32(bytes, start))
                height = Int(readUInt32(bytes, start + 4))
                bitDepth = Int(bytes[start + 8])
                colorType = Int(bytes[start + 9])
                interlace = Int(bytes[start + 12])
            case "PLTE": palette = Array(body)
            case "tRNS": transparency = Array(body)
            case "IDAT": idat.append(contentsOf: body)
            default: break
            }
            offset = start + length + 4
            if type == "IEND" { break }
        }

        guard width > 0, height > 0 else { throw PNGError.corrupt("missing header") }
        guard width * height <= 16_384 * 16_384 else { throw PNGError.unsupported("image is too large") }

        let channels: Int
        switch colorType {
        case 0: channels = 1
        case 2: channels = 3
        case 3: channels = 1
        case 4: channels = 2
        case 6: channels = 4
        default: throw PNGError.unsupported("colour type \(colorType)")
        }
        guard [1, 2, 4, 8, 16].contains(bitDepth) else { throw PNGError.unsupported("bit depth \(bitDepth)") }
        if colorType == 3 && palette.isEmpty { throw PNGError.corrupt("missing palette") }

        let raw = try inflate(idat)
        let bitsPerPixel = channels * bitDepth
        let bpp = max(1, bitsPerPixel / 8)

        var out = [UInt8](repeating: 0, count: width * height * 4)
        var cursor = 0

        // Adam7 passes (or a single full-size pass when not interlaced).
        let passes: [(x0: Int, y0: Int, dx: Int, dy: Int)] = interlace == 1
            ? [(0, 0, 8, 8), (4, 0, 8, 8), (0, 4, 4, 8), (2, 0, 4, 4), (0, 2, 2, 4), (1, 0, 2, 2), (0, 1, 1, 2)]
            : [(0, 0, 1, 1)]

        for pass in passes {
            let passWidth = (width - pass.x0 + pass.dx - 1) / pass.dx
            let passHeight = (height - pass.y0 + pass.dy - 1) / pass.dy
            if passWidth <= 0 || passHeight <= 0 { continue }
            let rowBytes = (passWidth * bitsPerPixel + 7) / 8
            guard cursor + passHeight * (rowBytes + 1) <= raw.count else { throw PNGError.corrupt("not enough image data") }

            var previous = [UInt8](repeating: 0, count: rowBytes)
            var row = [UInt8](repeating: 0, count: rowBytes)
            for py in 0..<passHeight {
                let filter = raw[cursor]
                cursor += 1
                for i in 0..<rowBytes { row[i] = raw[cursor + i] }
                cursor += rowBytes
                try unfilter(&row, previous: previous, filter: filter, bpp: bpp)

                let y = pass.y0 + py * pass.dy
                for px in 0..<passWidth {
                    let x = pass.x0 + px * pass.dx
                    let o = (y * width + x) * 4
                    writePixel(
                        row: row, index: px, colorType: colorType, bitDepth: bitDepth, channels: channels,
                        palette: palette, transparency: transparency, out: &out, at: o
                    )
                }
                swap(&previous, &row)
            }
        }

        return RGBAImage(width: width, height: height, pixels: out)
    }

    private static func sample(_ row: [UInt8], _ index: Int, bitDepth: Int) -> Int {
        switch bitDepth {
        case 16: return Int(row[index * 2]) << 8 | Int(row[index * 2 + 1])
        case 8: return Int(row[index])
        default:
            let bit = index * bitDepth
            let byte = Int(row[bit / 8])
            let shift = 8 - bitDepth - (bit % 8)
            return (byte >> shift) & ((1 << bitDepth) - 1)
        }
    }

    private static func scale(_ value: Int, bitDepth: Int) -> UInt8 {
        switch bitDepth {
        case 8: return UInt8(value)
        case 16: return UInt8((value * 255 + 32767) / 65535)
        default: return UInt8(value * 255 / ((1 << bitDepth) - 1))
        }
    }

    private static func writePixel(
        row: [UInt8], index: Int, colorType: Int, bitDepth: Int, channels: Int,
        palette: [UInt8], transparency: [UInt8], out: inout [UInt8], at o: Int
    ) {
        let base = index * channels
        switch colorType {
        case 0:
            let g = sample(row, base, bitDepth: bitDepth)
            let v = scale(g, bitDepth: bitDepth)
            out[o] = v; out[o + 1] = v; out[o + 2] = v
            let key = transparency.count >= 2 ? Int(transparency[0]) << 8 | Int(transparency[1]) : -1
            out[o + 3] = g == key ? 0 : 255
        case 2:
            let r = sample(row, base, bitDepth: bitDepth)
            let g = sample(row, base + 1, bitDepth: bitDepth)
            let b = sample(row, base + 2, bitDepth: bitDepth)
            out[o] = scale(r, bitDepth: bitDepth)
            out[o + 1] = scale(g, bitDepth: bitDepth)
            out[o + 2] = scale(b, bitDepth: bitDepth)
            var alpha: UInt8 = 255
            if transparency.count >= 6 {
                let tr = Int(transparency[0]) << 8 | Int(transparency[1])
                let tg = Int(transparency[2]) << 8 | Int(transparency[3])
                let tb = Int(transparency[4]) << 8 | Int(transparency[5])
                if r == tr && g == tg && b == tb { alpha = 0 }
            }
            out[o + 3] = alpha
        case 3:
            let i = sample(row, index, bitDepth: bitDepth)
            if i * 3 + 2 < palette.count {
                out[o] = palette[i * 3]; out[o + 1] = palette[i * 3 + 1]; out[o + 2] = palette[i * 3 + 2]
            }
            out[o + 3] = i < transparency.count ? transparency[i] : 255
        case 4:
            let v = scale(sample(row, base, bitDepth: bitDepth), bitDepth: bitDepth)
            out[o] = v; out[o + 1] = v; out[o + 2] = v
            out[o + 3] = scale(sample(row, base + 1, bitDepth: bitDepth), bitDepth: bitDepth)
        default:
            for c in 0..<4 { out[o + c] = scale(sample(row, base + c, bitDepth: bitDepth), bitDepth: bitDepth) }
        }
    }

    private static func unfilter(_ row: inout [UInt8], previous: [UInt8], filter: UInt8, bpp: Int) throws {
        let n = row.count
        switch filter {
        case 0: break
        case 1:
            for i in bpp..<max(bpp, n) { row[i] = row[i] &+ row[i - bpp] }
        case 2:
            for i in 0..<n { row[i] = row[i] &+ previous[i] }
        case 3:
            for i in 0..<n {
                let left = i >= bpp ? Int(row[i - bpp]) : 0
                row[i] = row[i] &+ UInt8((left + Int(previous[i])) / 2)
            }
        case 4:
            for i in 0..<n {
                let a = i >= bpp ? Int(row[i - bpp]) : 0
                let b = Int(previous[i])
                let c = i >= bpp ? Int(previous[i - bpp]) : 0
                row[i] = row[i] &+ UInt8(paeth(a, b, c))
            }
        default:
            throw PNGError.corrupt("unknown filter \(filter)")
        }
    }

    @inline(__always)
    private static func paeth(_ a: Int, _ b: Int, _ c: Int) -> Int {
        let p = a + b - c
        let pa = abs(p - a), pb = abs(p - b), pc = abs(p - c)
        if pa <= pb && pa <= pc { return a }
        return pb <= pc ? b : c
    }

    // MARK: Encoding

    /// Writes a plain 8-bit RGBA PNG (colour type 6), choosing a filter per row.
    static func encode(_ image: RGBAImage) throws -> Data {
        let rowBytes = image.width * 4
        var filtered = [UInt8]()
        filtered.reserveCapacity((rowBytes + 1) * image.height)

        var previous = [UInt8](repeating: 0, count: rowBytes)
        var candidate = [UInt8](repeating: 0, count: rowBytes)
        var best = [UInt8](repeating: 0, count: rowBytes)

        image.pixels.withUnsafeBufferPointer { px in
            for y in 0..<image.height {
                let row = Array(px[y * rowBytes..<(y + 1) * rowBytes])
                var bestScore = Int.max
                var bestFilter: UInt8 = 0
                for filter in UInt8(0)...4 {
                    var score = 0
                    for i in 0..<rowBytes {
                        let a = i >= 4 ? Int(row[i - 4]) : 0
                        let b = Int(previous[i])
                        let c = i >= 4 ? Int(previous[i - 4]) : 0
                        let predictor: Int
                        switch filter {
                        case 0: predictor = 0
                        case 1: predictor = a
                        case 2: predictor = b
                        case 3: predictor = (a + b) / 2
                        default: predictor = paeth(a, b, c)
                        }
                        let v = UInt8(truncatingIfNeeded: Int(row[i]) - predictor)
                        candidate[i] = v
                        score += v < 128 ? Int(v) : 256 - Int(v)
                    }
                    if score < bestScore {
                        bestScore = score
                        bestFilter = filter
                        swap(&best, &candidate)
                    }
                }
                filtered.append(bestFilter)
                filtered.append(contentsOf: best)
                previous = row
            }
        }

        var png = Data(signature)
        var header = Data()
        header.appendUInt32(UInt32(image.width))
        header.appendUInt32(UInt32(image.height))
        header.append(contentsOf: [8, 6, 0, 0, 0])
        appendChunk("IHDR", header, to: &png)
        appendChunk("IDAT", try deflate(Data(filtered)), to: &png)
        appendChunk("IEND", Data(), to: &png)
        return png
    }

    private static func appendChunk(_ type: String, _ body: Data, to png: inout Data) {
        let typeBytes = Data(type.utf8)
        png.appendUInt32(UInt32(body.count))
        png.append(typeBytes)
        png.append(body)
        png.appendUInt32(CRC32.checksum(typeBytes + body))
    }

    // MARK: zlib

    private static func inflate(_ zlib: Data) throws -> [UInt8] {
        // Foundation's `.zlib` algorithm is raw DEFLATE, so skip the 2-byte zlib header.
        guard zlib.count > 2 else { throw PNGError.corrupt("no image data") }
        let deflated = zlib.subdata(in: zlib.startIndex + 2..<zlib.endIndex)
        do {
            return [UInt8](try (deflated as NSData).decompressed(using: .zlib) as Data)
        } catch {
            throw PNGError.corrupt("could not decompress image data")
        }
    }

    private static func deflate(_ data: Data) throws -> Data {
        var out = Data([0x78, 0x9C])
        out.append(try (data as NSData).compressed(using: .zlib) as Data)
        out.appendUInt32(adler32(data))
        return out
    }

    private static func adler32(_ data: Data) -> UInt32 {
        var a: UInt32 = 1, b: UInt32 = 0
        data.withUnsafeBytes { buffer in
            var index = 0
            let bytes = buffer.bindMemory(to: UInt8.self)
            while index < bytes.count {
                let end = min(index + 5552, bytes.count)
                while index < end {
                    a += UInt32(bytes[index])
                    b += a
                    index += 1
                }
                a %= 65521
                b %= 65521
            }
        }
        return b << 16 | a
    }

    private static func readUInt32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        UInt32(bytes[offset]) << 24 | UInt32(bytes[offset + 1]) << 16 | UInt32(bytes[offset + 2]) << 8 | UInt32(bytes[offset + 3])
    }
}

enum CRC32 {
    private static let table: [UInt32] = (0..<256).map { n in
        var c = UInt32(n)
        for _ in 0..<8 { c = c & 1 != 0 ? 0xEDB8_8320 ^ (c >> 1) : c >> 1 }
        return c
    }

    static func checksum(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data { crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8) }
        return crc ^ 0xFFFF_FFFF
    }
}

extension Data {
    mutating func appendUInt32(_ value: UInt32) {
        append(contentsOf: [UInt8(value >> 24 & 0xFF), UInt8(value >> 16 & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)])
    }
}
