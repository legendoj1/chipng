using System.Buffers.Binary;
using System.IO.Compression;
using System.Text;

namespace Chipng.Core;

/// <summary>8-bit, non-premultiplied RGBA pixels.</summary>
public sealed class RgbaImage(int width, int height, byte[] pixels)
{
    public int Width { get; } = width;
    public int Height { get; } = height;
    public byte[] Pixels { get; } = pixels;

    public RgbaImage Clone() => new(Width, Height, (byte[])Pixels.Clone());
}

public sealed class PngException(string message) : Exception(message);

/// <summary>
/// A small PNG reader/writer that keeps exact pixel values. Windows' imaging APIs
/// premultiply alpha, which erases the colour of fully transparent pixels — exactly
/// the data alpha bleeding writes — so PNGs are decoded and encoded here instead.
/// Port of PNGCodec.swift.
/// </summary>
public static class PngCodec
{
    private static readonly byte[] Signature = [137, 80, 78, 71, 13, 10, 26, 10];

    public static RgbaImage Decode(byte[] bytes)
    {
        if (bytes.Length <= 8 || !bytes.AsSpan(0, 8).SequenceEqual(Signature)) throw new PngException("Not a PNG file");

        int width = 0, height = 0, bitDepth = 0, colorType = 0, interlace = 0;
        byte[] palette = [], transparency = [];
        using var idat = new MemoryStream();
        var offset = 8;

        while (offset + 8 <= bytes.Length)
        {
            var length = (int)BinaryPrimitives.ReadUInt32BigEndian(bytes.AsSpan(offset));
            var type = Encoding.ASCII.GetString(bytes, offset + 4, 4);
            var start = offset + 8;
            if (length < 0 || start + length + 4 > bytes.Length) throw new PngException($"Damaged PNG (truncated {type} chunk)");
            var body = bytes.AsSpan(start, length);

            switch (type)
            {
                case "IHDR":
                    if (length < 13) throw new PngException("Damaged PNG (bad header)");
                    width = (int)BinaryPrimitives.ReadUInt32BigEndian(body);
                    height = (int)BinaryPrimitives.ReadUInt32BigEndian(body[4..]);
                    bitDepth = body[8];
                    colorType = body[9];
                    interlace = body[12];
                    break;
                case "PLTE": palette = body.ToArray(); break;
                case "tRNS": transparency = body.ToArray(); break;
                case "IDAT": idat.Write(body); break;
            }
            offset = start + length + 4;
            if (type == "IEND") break;
        }

        if (width <= 0 || height <= 0) throw new PngException("Damaged PNG (missing header)");
        if ((long)width * height > 16_384L * 16_384) throw new PngException("Unsupported PNG (image is too large)");

        var channels = colorType switch
        {
            0 or 3 => 1,
            2 => 3,
            4 => 2,
            6 => 4,
            _ => throw new PngException($"Unsupported PNG (colour type {colorType})"),
        };
        if (bitDepth is not (1 or 2 or 4 or 8 or 16)) throw new PngException($"Unsupported PNG (bit depth {bitDepth})");
        if (colorType == 3 && palette.Length == 0) throw new PngException("Damaged PNG (missing palette)");

        var raw = Inflate(idat.ToArray());
        var bitsPerPixel = channels * bitDepth;
        var bpp = Math.Max(1, bitsPerPixel / 8);
        var output = new byte[width * height * 4];
        var cursor = 0;

        (int x0, int y0, int dx, int dy)[] passes = interlace == 1
            ? [(0, 0, 8, 8), (4, 0, 8, 8), (0, 4, 4, 8), (2, 0, 4, 4), (0, 2, 2, 4), (1, 0, 2, 2), (0, 1, 1, 2)]
            : [(0, 0, 1, 1)];

        foreach (var (x0, y0, dx, dy) in passes)
        {
            var passWidth = (width - x0 + dx - 1) / dx;
            var passHeight = (height - y0 + dy - 1) / dy;
            if (passWidth <= 0 || passHeight <= 0) continue;
            var rowBytes = (passWidth * bitsPerPixel + 7) / 8;
            if (cursor + (long)passHeight * (rowBytes + 1) > raw.Length) throw new PngException("Damaged PNG (not enough image data)");

            var previous = new byte[rowBytes];
            var row = new byte[rowBytes];
            for (var py = 0; py < passHeight; py++)
            {
                var filter = raw[cursor++];
                Array.Copy(raw, cursor, row, 0, rowBytes);
                cursor += rowBytes;
                Unfilter(row, previous, filter, bpp);

                var y = y0 + py * dy;
                for (var px = 0; px < passWidth; px++)
                {
                    var x = x0 + px * dx;
                    WritePixel(row, px, colorType, bitDepth, channels, palette, transparency, output, (y * width + x) * 4);
                }
                (previous, row) = (row, previous);
            }
        }

        return new RgbaImage(width, height, output);
    }

    private static int Sample(byte[] row, int index, int bitDepth)
    {
        switch (bitDepth)
        {
            case 16: return row[index * 2] << 8 | row[index * 2 + 1];
            case 8: return row[index];
            default:
                var bit = index * bitDepth;
                var shift = 8 - bitDepth - bit % 8;
                return (row[bit / 8] >> shift) & ((1 << bitDepth) - 1);
        }
    }

    private static byte Scale(int value, int bitDepth) => bitDepth switch
    {
        8 => (byte)value,
        16 => (byte)((value * 255 + 32767) / 65535),
        _ => (byte)(value * 255 / ((1 << bitDepth) - 1)),
    };

    private static void WritePixel(byte[] row, int index, int colorType, int bitDepth, int channels,
        byte[] palette, byte[] transparency, byte[] output, int o)
    {
        var b = index * channels;
        switch (colorType)
        {
            case 0:
            {
                var g = Sample(row, b, bitDepth);
                var v = Scale(g, bitDepth);
                output[o] = v; output[o + 1] = v; output[o + 2] = v;
                var key = transparency.Length >= 2 ? transparency[0] << 8 | transparency[1] : -1;
                output[o + 3] = g == key ? (byte)0 : (byte)255;
                break;
            }
            case 2:
            {
                int r = Sample(row, b, bitDepth), g = Sample(row, b + 1, bitDepth), bl = Sample(row, b + 2, bitDepth);
                output[o] = Scale(r, bitDepth);
                output[o + 1] = Scale(g, bitDepth);
                output[o + 2] = Scale(bl, bitDepth);
                byte alpha = 255;
                if (transparency.Length >= 6)
                {
                    var tr = transparency[0] << 8 | transparency[1];
                    var tg = transparency[2] << 8 | transparency[3];
                    var tb = transparency[4] << 8 | transparency[5];
                    if (r == tr && g == tg && bl == tb) alpha = 0;
                }
                output[o + 3] = alpha;
                break;
            }
            case 3:
            {
                var i = Sample(row, index, bitDepth);
                if (i * 3 + 2 < palette.Length)
                {
                    output[o] = palette[i * 3]; output[o + 1] = palette[i * 3 + 1]; output[o + 2] = palette[i * 3 + 2];
                }
                output[o + 3] = i < transparency.Length ? transparency[i] : (byte)255;
                break;
            }
            case 4:
            {
                var v = Scale(Sample(row, b, bitDepth), bitDepth);
                output[o] = v; output[o + 1] = v; output[o + 2] = v;
                output[o + 3] = Scale(Sample(row, b + 1, bitDepth), bitDepth);
                break;
            }
            default:
                for (var c = 0; c < 4; c++) output[o + c] = Scale(Sample(row, b + c, bitDepth), bitDepth);
                break;
        }
    }

    private static void Unfilter(byte[] row, byte[] previous, byte filter, int bpp)
    {
        var n = row.Length;
        switch (filter)
        {
            case 0: break;
            case 1:
                for (var i = bpp; i < n; i++) row[i] = (byte)(row[i] + row[i - bpp]);
                break;
            case 2:
                for (var i = 0; i < n; i++) row[i] = (byte)(row[i] + previous[i]);
                break;
            case 3:
                for (var i = 0; i < n; i++)
                {
                    var left = i >= bpp ? row[i - bpp] : 0;
                    row[i] = (byte)(row[i] + (left + previous[i]) / 2);
                }
                break;
            case 4:
                for (var i = 0; i < n; i++)
                {
                    var a = i >= bpp ? row[i - bpp] : 0;
                    var c = i >= bpp ? previous[i - bpp] : 0;
                    row[i] = (byte)(row[i] + Paeth(a, previous[i], c));
                }
                break;
            default:
                throw new PngException($"Damaged PNG (unknown filter {filter})");
        }
    }

    private static int Paeth(int a, int b, int c)
    {
        var p = a + b - c;
        int pa = Math.Abs(p - a), pb = Math.Abs(p - b), pc = Math.Abs(p - c);
        if (pa <= pb && pa <= pc) return a;
        return pb <= pc ? b : c;
    }

    /// <summary>Writes a plain 8-bit RGBA PNG (colour type 6), choosing a filter per row.</summary>
    public static byte[] Encode(RgbaImage image)
    {
        var rowBytes = image.Width * 4;
        var filtered = new byte[(rowBytes + 1) * image.Height];
        var previous = new byte[rowBytes];
        var candidate = new byte[rowBytes];
        var best = new byte[rowBytes];
        var row = new byte[rowBytes];

        for (var y = 0; y < image.Height; y++)
        {
            Array.Copy(image.Pixels, y * rowBytes, row, 0, rowBytes);
            var bestScore = long.MaxValue;
            byte bestFilter = 0;
            for (byte filter = 0; filter <= 4; filter++)
            {
                long score = 0;
                for (var i = 0; i < rowBytes; i++)
                {
                    var a = i >= 4 ? row[i - 4] : 0;
                    var b = previous[i];
                    var c = i >= 4 ? previous[i - 4] : 0;
                    var predictor = filter switch
                    {
                        0 => 0,
                        1 => a,
                        2 => b,
                        3 => (a + b) / 2,
                        _ => Paeth(a, b, c),
                    };
                    var v = (byte)(row[i] - predictor);
                    candidate[i] = v;
                    score += v < 128 ? v : 256 - v;
                }
                if (score < bestScore)
                {
                    bestScore = score;
                    bestFilter = filter;
                    (best, candidate) = (candidate, best);
                }
            }
            var o = y * (rowBytes + 1);
            filtered[o] = bestFilter;
            Array.Copy(best, 0, filtered, o + 1, rowBytes);
            (previous, row) = (row, previous);
        }

        using var png = new MemoryStream();
        png.Write(Signature);
        var header = new byte[13];
        BinaryPrimitives.WriteUInt32BigEndian(header, (uint)image.Width);
        BinaryPrimitives.WriteUInt32BigEndian(header.AsSpan(4), (uint)image.Height);
        header[8] = 8;
        header[9] = 6;
        WriteChunk(png, "IHDR", header);
        WriteChunk(png, "IDAT", Deflate(filtered));
        WriteChunk(png, "IEND", []);
        return png.ToArray();
    }

    private static void WriteChunk(Stream png, string type, byte[] body)
    {
        Span<byte> word = stackalloc byte[4];
        BinaryPrimitives.WriteUInt32BigEndian(word, (uint)body.Length);
        png.Write(word);
        var typeAndBody = new byte[4 + body.Length];
        Encoding.ASCII.GetBytes(type, typeAndBody);
        body.CopyTo(typeAndBody, 4);
        png.Write(typeAndBody);
        BinaryPrimitives.WriteUInt32BigEndian(word, Crc32.Compute(typeAndBody));
        png.Write(word);
    }

    private static byte[] Inflate(byte[] zlib)
    {
        try
        {
            using var input = new ZLibStream(new MemoryStream(zlib), CompressionMode.Decompress);
            using var output = new MemoryStream();
            input.CopyTo(output);
            return output.ToArray();
        }
        catch (InvalidDataException)
        {
            throw new PngException("Damaged PNG (could not decompress image data)");
        }
    }

    private static byte[] Deflate(byte[] data)
    {
        using var output = new MemoryStream();
        using (var z = new ZLibStream(output, CompressionLevel.SmallestSize, leaveOpen: true)) z.Write(data);
        return output.ToArray();
    }
}

internal static class Crc32
{
    private static readonly uint[] Table = Enumerable.Range(0, 256).Select(n =>
    {
        var c = (uint)n;
        for (var k = 0; k < 8; k++) c = (c & 1) != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1;
        return c;
    }).ToArray();

    public static uint Compute(ReadOnlySpan<byte> data)
    {
        var crc = 0xFFFFFFFFu;
        foreach (var b in data) crc = Table[(crc ^ b) & 0xFF] ^ (crc >> 8);
        return crc ^ 0xFFFFFFFFu;
    }
}
