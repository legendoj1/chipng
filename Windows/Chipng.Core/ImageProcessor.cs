namespace Chipng.Core;

/// <summary>Squoosh's codecs (implemented by the WebView2 engine on Windows).</summary>
public interface ICodecEngine
{
    /// <summary>libimagequant ("Reduce palette" in Squoosh). Returns remapped RGBA pixels.</summary>
    Task<RgbaImage> QuantizeAsync(RgbaImage image, int colors, double dither);

    /// <summary>OxiPNG with alpha optimisation disabled. Returns an optimised PNG file.</summary>
    Task<byte[]> OxipngAsync(RgbaImage image, int level);
}

public enum CompressionMethod { BleedOnly, Palette, Lossless }

public sealed record ProcessedImage(byte[] Data, int Width, int Height, CompressionMethod Method, int? PaletteColors = null)
{
    public string MethodDescription => Method switch
    {
        CompressionMethod.Palette => $"Palette, {PaletteColors} colors",
        CompressionMethod.Lossless => "Lossless",
        _ => "None",
    };
}

/// <summary>Alpha-bleeds a PNG, then optionally compresses it with Squoosh. Port of ImageProcessor.swift.</summary>
public static class ImageProcessor
{
    // Squoosh's own defaults for "Reduce palette" and OxiPNG.
    public const int PaletteColors = 256;
    public const double Dithering = 1.0;
    public const int OxipngLevel = 2;

    /// <summary>
    /// Below this PSNR (dB) palette reduction is considered visibly lossy and the image
    /// is compressed losslessly instead.
    /// </summary>
    public const double MinimumPaletteQuality = 32.0;

    public static async Task<ProcessedImage> ProcessAsync(byte[] source, bool compress, ICodecEngine? engine)
    {
        var bled = await Task.Run(() =>
        {
            var image = PngCodec.Decode(source);
            AlphaBleed.Apply(image);
            return image;
        });

        if (!compress)
        {
            var data = await Task.Run(() => PngCodec.Encode(bled));
            return new ProcessedImage(data, bled.Width, bled.Height, CompressionMethod.BleedOnly);
        }
        if (engine is null) throw new InvalidOperationException("The Squoosh engine isn't available.");

        // TinyPNG-style palette reduction (libimagequant). Each visible colour may need
        // an invisible twin to keep the bleed, so the colour count is lowered (at most
        // to 128) when both don't fit in a 256-entry palette.
        var colors = PaletteColors;
        var attempt = 0;
        PaletteBleed.Result palette;
        while (true)
        {
            var quantized = await engine.QuantizeAsync(bled, colors, Dithering);
            palette = await Task.Run(() => PaletteBleed.Apply(quantized));
            if (palette.FitsPalette || colors <= 128) break;
            attempt++;
            colors = attempt == 1 ? Math.Max(128, Math.Min(colors - 1, 256 - palette.TransparentColors)) : 128;
        }

        var reduced = palette.Image;
        var quality = await Task.Run(() => Psnr(bled, reduced));
        if (quality >= MinimumPaletteQuality)
        {
            var data = await engine.OxipngAsync(reduced, OxipngLevel);
            return new ProcessedImage(data, bled.Width, bled.Height, CompressionMethod.Palette, palette.VisibleColors);
        }

        // Too many colours for a palette (photos, smooth gradients): keep every pixel.
        var lossless = await engine.OxipngAsync(bled, OxipngLevel);
        return new ProcessedImage(lossless, bled.Width, bled.Height, CompressionMethod.Lossless);
    }

    /// <summary>
    /// Peak signal-to-noise ratio of the visible result, comparing alpha-premultiplied
    /// colours so differences in nearly transparent pixels count for little.
    /// </summary>
    public static double Psnr(RgbaImage a, RgbaImage b)
    {
        double squaredError = 0;
        long samples = 0;
        var pa = a.Pixels;
        var pb = b.Pixels;
        for (var i = 0; i < pa.Length; i += 4)
        {
            if (pa[i + 3] == 0 && pb[i + 3] == 0) continue;
            double alphaA = pa[i + 3] / 255.0, alphaB = pb[i + 3] / 255.0;
            for (var c = 0; c < 3; c++)
            {
                var d = pa[i + c] * alphaA - pb[i + c] * alphaB;
                squaredError += d * d;
            }
            double da = pa[i + 3] - pb[i + 3];
            squaredError += da * da;
            samples += 4;
        }
        if (samples == 0 || squaredError == 0) return double.PositiveInfinity;
        return 10 * Math.Log10(255.0 * 255.0 / (squaredError / samples));
    }
}
