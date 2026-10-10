using System;
using System.Collections.Generic;
using System.IO;
using System.Reflection;
using System.Text.Json;
using System.Threading.Tasks;
using System.Windows.Threading;
using Chipng.Core;
using Microsoft.Web.WebView2.Core;

namespace Chipng;

/// <summary>
/// Runs Google's Squoosh codecs (OxiPNG + libimagequant, compiled to WebAssembly)
/// inside a hidden WebView2. It loads the same page as the Mac app
/// (Resources/Squoosh), which keeps a pool of Web Workers so several images
/// compress in parallel.
/// </summary>
public sealed class SquooshEngine : ICodecEngine
{
    private const string Host = "engine.chipng.example";

    private readonly IntPtr parentWindow;
    private readonly Dispatcher dispatcher;
    private readonly Dictionary<long, TaskCompletionSource<string>> pending = new();
    private CoreWebView2Controller? controller;
    private Task? readyTask;
    private long nextId;

    public SquooshEngine(IntPtr parentWindow, Dispatcher dispatcher)
    {
        this.parentWindow = parentWindow;
        this.dispatcher = dispatcher;
    }

    private static string AppDataFolder =>
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Chipng");

    /// <summary>Loads the engine page and waits for every worker to finish compiling the codecs.</summary>
    public Task PrepareAsync() => dispatcher.Invoke(() => readyTask ??= LoadAsync());

    private async Task LoadAsync()
    {
        try
        {
            var folder = ExtractEngineFiles();
            var environment = await CoreWebView2Environment.CreateAsync(null, Path.Combine(AppDataFolder, "WebView2"));
            controller = await environment.CreateCoreWebView2ControllerAsync(parentWindow);
            controller.Bounds = new System.Drawing.Rectangle(0, 0, 0, 0);
            controller.IsVisible = true; // Zero-sized, but "visible" so the page isn't throttled.

            var web = controller.CoreWebView2;
            web.Settings.AreDevToolsEnabled = false;
            web.Settings.AreDefaultContextMenusEnabled = false;
            web.Settings.IsStatusBarEnabled = false;
            web.SetVirtualHostNameToFolderMapping(Host, folder, CoreWebView2HostResourceAccessKind.Allow);
            web.WebMessageReceived += OnWebMessage;
            web.ProcessFailed += (_, e) => Reset($"The Squoosh engine stopped ({e.ProcessFailedKind}).");

            var navigated = new TaskCompletionSource<bool>();
            web.NavigationCompleted += (_, e) => navigated.TrySetResult(e.IsSuccess);
            web.Navigate($"https://{Host}/index.html");
            if (!await navigated.Task) throw new InvalidOperationException("The Squoosh engine page failed to load.");

            await SendAsync(new Dictionary<string, object?> { ["op"] = "ready" });
        }
        catch (WebView2RuntimeNotFoundException)
        {
            readyTask = null;
            throw new InvalidOperationException(
                "Compression needs the Microsoft Edge WebView2 Runtime. Install it from microsoft.com, or turn off “Compress with Squoosh”.");
        }
        catch
        {
            readyTask = null;
            throw;
        }
    }

    public async Task<RgbaImage> QuantizeAsync(RgbaImage image, int colors, double dither)
    {
        var output = await RunAsync("quantize", image, new Dictionary<string, object> { ["colors"] = colors, ["dither"] = dither });
        if (output.Length != image.Pixels.Length) throw new InvalidOperationException("Squoosh: unexpected quantizer output");
        return new RgbaImage(image.Width, image.Height, output);
    }

    public Task<byte[]> OxipngAsync(RgbaImage image, int level) =>
        RunAsync("oxipng", image, new Dictionary<string, object> { ["level"] = level });

    private async Task<byte[]> RunAsync(string op, RgbaImage image, Dictionary<string, object> options)
    {
        await PrepareAsync();
        var input = await Task.Run(() => Convert.ToBase64String(image.Pixels));
        var result = await SendAsync(new Dictionary<string, object?>
        {
            ["op"] = op,
            ["input"] = input,
            ["width"] = image.Width,
            ["height"] = image.Height,
            ["options"] = options,
        });
        return await Task.Run(() => Convert.FromBase64String(result));
    }

    private Task<string> SendAsync(Dictionary<string, object?> message) => dispatcher.Invoke(() =>
    {
        var web = controller?.CoreWebView2 ?? throw new InvalidOperationException("Squoosh engine not loaded");
        var id = ++nextId;
        message["id"] = id;
        var completion = new TaskCompletionSource<string>(TaskCreationOptions.RunContinuationsAsynchronously);
        pending[id] = completion;
        web.PostWebMessageAsJson(JsonSerializer.Serialize(message));
        return completion.Task;
    });

    private void OnWebMessage(object? sender, CoreWebView2WebMessageReceivedEventArgs e)
    {
        using var json = JsonDocument.Parse(e.WebMessageAsJson);
        var root = json.RootElement;
        var id = root.GetProperty("id").GetInt64();
        if (!pending.Remove(id, out var completion)) return;

        if (root.GetProperty("ok").GetBoolean())
        {
            completion.TrySetResult(root.GetProperty("data").GetString() ?? "");
        }
        else
        {
            var error = root.TryGetProperty("error", out var message) ? message.GetString() : null;
            completion.TrySetException(new InvalidOperationException($"Squoosh: {error ?? "unknown error"}"));
        }
    }

    private void Reset(string reason)
    {
        foreach (var completion in pending.Values) completion.TrySetException(new InvalidOperationException(reason));
        pending.Clear();
        controller?.Close();
        controller = null;
        readyTask = null; // Reload on the next request.
    }

    /// <summary>
    /// Copies the engine page and codecs (embedded in the exe) to
    /// %LOCALAPPDATA%\Chipng\Squoosh-{build}, which WebView2 then serves.
    /// </summary>
    private static string ExtractEngineFiles()
    {
        var assembly = Assembly.GetExecutingAssembly();
        var build = assembly.ManifestModule.ModuleVersionId.ToString("N")[..12];
        var folder = Path.Combine(AppDataFolder, $"Squoosh-{build}");
        var marker = Path.Combine(folder, ".complete");
        if (File.Exists(marker)) return folder;

        foreach (var old in Directory.Exists(AppDataFolder) ? Directory.GetDirectories(AppDataFolder, "Squoosh-*") : [])
        {
            try { Directory.Delete(old, recursive: true); } catch (IOException) { } catch (UnauthorizedAccessException) { }
        }

        foreach (var name in assembly.GetManifestResourceNames())
        {
            var relative = name.Replace('\\', '/');
            if (!relative.StartsWith("Squoosh/", StringComparison.Ordinal)) continue;
            var path = Path.Combine(folder, relative["Squoosh/".Length..].Replace('/', Path.DirectorySeparatorChar));
            Directory.CreateDirectory(Path.GetDirectoryName(path)!);
            using var source = assembly.GetManifestResourceStream(name)!;
            using var target = File.Create(path);
            source.CopyTo(target);
        }
        File.WriteAllText(marker, build);
        return folder;
    }
}
