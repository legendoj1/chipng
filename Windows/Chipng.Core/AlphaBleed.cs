namespace Chipng.Core;

/// <summary>
/// The chipng / Pixelfix alpha-bleeding algorithm (https://github.com/urraka/alpha-bleeding).
/// Every fully transparent pixel gets the average colour of its nearest visible
/// neighbours, spreading outward ring by ring, so bilinear filtering in Roblox never
/// blends in black from invisible pixels. Alpha is untouched. Port of AlphaBleed.swift.
/// </summary>
public static class AlphaBleed
{
    private static readonly (int S, int T)[] Offsets = [(-1, -1), (0, -1), (1, -1), (-1, 0), (1, 0), (-1, 1), (0, 1), (1, 1)];

    public static void Apply(RgbaImage image)
    {
        int width = image.Width, height = image.Height, count = width * height;
        var data = image.Pixels;
        var opaque = new byte[count];
        var loose = new bool[count];
        var pending = new List<int>();
        var pendingNext = new List<int>();

        for (var y = 0; y < height; y++)
        {
            for (var x = 0; x < width; x++)
            {
                var idx = y * width + x;
                if (data[idx * 4 + 3] != 0)
                {
                    opaque[idx] = 0xFF;
                    continue;
                }
                var isLoose = true;
                foreach (var (s, t) in Offsets)
                {
                    int nx = x + s, ny = y + t;
                    if (nx < 0 || nx >= width || ny < 0 || ny >= height) continue;
                    if (data[(ny * width + nx) * 4 + 3] != 0)
                    {
                        isLoose = false;
                        break;
                    }
                }
                if (isLoose) loose[idx] = true;
                else pending.Add(idx);
            }
        }

        while (pending.Count > 0)
        {
            pendingNext.Clear();

            foreach (var idx in pending)
            {
                int x = idx % width, y = idx / width;
                int r = 0, g = 0, b = 0, n = 0;

                foreach (var (s, t) in Offsets)
                {
                    int nx = x + s, ny = y + t;
                    if (nx < 0 || nx >= width || ny < 0 || ny >= height) continue;
                    var nIdx = ny * width + nx;
                    if ((opaque[nIdx] & 1) != 0)
                    {
                        r += data[nIdx * 4];
                        g += data[nIdx * 4 + 1];
                        b += data[nIdx * 4 + 2];
                        n++;
                    }
                }

                if (n > 0)
                {
                    data[idx * 4] = (byte)(r / n);
                    data[idx * 4 + 1] = (byte)(g / n);
                    data[idx * 4 + 2] = (byte)(b / n);
                    data[idx * 4 + 3] = 0;
                    opaque[idx] = 0xFE;

                    foreach (var (s, t) in Offsets)
                    {
                        int nx = x + s, ny = y + t;
                        if (nx < 0 || nx >= width || ny < 0 || ny >= height) continue;
                        var nIdx = ny * width + nx;
                        if (loose[nIdx])
                        {
                            pendingNext.Add(nIdx);
                            loose[nIdx] = false;
                        }
                    }
                }
                else
                {
                    pendingNext.Add(idx);
                }
            }

            if (pendingNext.Count > 0)
            {
                foreach (var idx in pending) opaque[idx] >>= 1;
            }

            (pending, pendingNext) = (pendingNext, pending);
        }
    }
}

/// <summary>
/// Re-applies the bleed to an image that went through palette reduction.
/// libimagequant (like TinyPNG) collapses every invisible pixel into one
/// transparent-black palette entry, which brings the black fringes back. This bleeds
/// the quantized image again and snaps each invisible pixel's colour to the nearest
/// visible palette colour, so the result still fits in a 256-entry palette: each
/// visible colour gets at most one invisible "twin".
/// </summary>
public static class PaletteBleed
{
    public sealed record Result(RgbaImage Image, int VisibleColors, int TransparentColors)
    {
        public bool FitsPalette => VisibleColors + TransparentColors <= 256;
    }

    public static Result Apply(RgbaImage quantized)
    {
        var image = quantized.Clone();
        var px = image.Pixels;
        var visible = new HashSet<uint>();
        for (var i = 0; i < px.Length; i += 4)
        {
            if (px[i + 3] != 0) visible.Add(Rgba(px, i));
        }
        if (visible.Count == 0) return new Result(image, 0, 0);

        var palette = visible.Select(c => (R: (int)(c >> 24), G: (int)(c >> 16 & 0xFF), B: (int)(c >> 8 & 0xFF))).ToArray();
        AlphaBleed.Apply(image);

        var snapped = new Dictionary<uint, uint>();
        var twins = new HashSet<uint>();
        for (var i = 0; i < px.Length; i += 4)
        {
            if (px[i + 3] != 0) continue;
            var key = Rgba(px, i);
            if (!snapped.TryGetValue(key, out var twin))
            {
                int r = px[i], g = px[i + 1], b = px[i + 2];
                var best = palette[0];
                var bestDistance = int.MaxValue;
                foreach (var c in palette)
                {
                    int dr = r - c.R, dg = g - c.G, db = b - c.B;
                    var d = dr * dr + dg * dg + db * db;
                    if (d < bestDistance) { bestDistance = d; best = c; }
                }
                twin = (uint)best.R << 24 | (uint)best.G << 16 | (uint)best.B << 8;
                snapped[key] = twin;
            }
            twins.Add(twin);
            px[i] = (byte)(twin >> 24);
            px[i + 1] = (byte)(twin >> 16 & 0xFF);
            px[i + 2] = (byte)(twin >> 8 & 0xFF);
        }
        return new Result(image, visible.Count, twins.Count);
    }

    private static uint Rgba(byte[] px, int i) => (uint)px[i] << 24 | (uint)px[i + 1] << 16 | (uint)px[i + 2] << 8 | px[i + 3];
}
