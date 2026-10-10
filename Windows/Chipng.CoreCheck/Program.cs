// Usage: Chipng.CoreCheck <input.png> <output.png> [reference.png]
//
// Alpha-bleeds without compression (the part of the pipeline that doesn't need
// WebView2), then runs PaletteBleed on a crude stand-in for libimagequant to check
// that transparent pixels keep their colours and the result fits a 256-colour palette.

using Chipng.Core;

if (args.Length < 2)
{
    Console.Error.WriteLine("usage: Chipng.CoreCheck <input.png> <output.png>");
    return 64;
}

var source = File.ReadAllBytes(args[0]);
var result = await ImageProcessor.ProcessAsync(source, compress: false, engine: null);
File.WriteAllBytes(args[1], result.Data);

// Round trip: our own encoder's output must decode to the same pixels.
var bled = PngCodec.Decode(result.Data);
var expected = PngCodec.Decode(source);
AlphaBleed.Apply(expected);
if (!bled.Pixels.AsSpan().SequenceEqual(expected.Pixels)) throw new Exception("Encode/decode round trip changed pixels");

// Stand-in quantizer: posterise to 6 levels per channel and make invisible pixels black.
var quantized = bled.Clone();
var px = quantized.Pixels;
for (var i = 0; i < px.Length; i += 4)
{
    if (px[i + 3] == 0) { px[i] = px[i + 1] = px[i + 2] = 0; continue; }
    for (var c = 0; c < 4; c++) px[i + c] = (byte)(px[i + c] / 51 * 51);
}
var palette = PaletteBleed.Apply(quantized);
var blackEdges = 0;
var p = palette.Image.Pixels;
for (var i = 0; i < p.Length; i += 4)
{
    if (p[i + 3] == 0 && p[i] == 0 && p[i + 1] == 0 && p[i + 2] == 0) blackEdges++;
}

Console.WriteLine($"{args[0]}: {source.Length} -> {result.Data.Length} bytes, {result.Width}x{result.Height}; " +
                  $"palette check: {palette.VisibleColors} visible + {palette.TransparentColors} transparent colours, " +
                  $"{blackEdges} black transparent px, PSNR {ImageProcessor.Psnr(bled, palette.Image):F1} dB");

// Optional: compare against another implementation's bleed-only output (e.g. the Mac app's).
if (args.Length >= 3)
{
    var reference = PngCodec.Decode(File.ReadAllBytes(args[2])).Pixels;
    var mismatched = 0;
    for (var i = 0; i < reference.Length; i++) if (reference[i] != bled.Pixels[i]) mismatched++;
    Console.WriteLine(mismatched == 0 ? "  identical to reference" : $"  {mismatched} bytes differ from reference");
    if (mismatched > 0) return 1;
}
return 0;
