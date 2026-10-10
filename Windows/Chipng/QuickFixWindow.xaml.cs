using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Interop;
using Chipng.Core;
using Wpf.Ui.Appearance;
using Wpf.Ui.Controls;

namespace Chipng;

/// <summary>
/// Pixelfix-style drop-on-the-exe mode: every PNG dropped onto Chipng.exe is
/// alpha-bled, compressed (if enabled) and written back over the original,
/// using the same settings as the main window. Closes itself when all went well.
/// </summary>
public partial class QuickFixWindow : FluentWindow
{
    private const int MaxConcurrent = 4;

    private readonly string[] arguments;
    private readonly AppSettings settings = AppSettings.Load();

    public QuickFixWindow(string[] arguments)
    {
        this.arguments = arguments;
        InitializeComponent();
        ApplicationThemeManager.ApplySystemTheme();
        SystemThemeWatcher.Watch(this);
        SourceInitialized += async (_, _) => await RunAsync();
    }

    private async Task RunAsync()
    {
        var files = await Task.Run(() => AppModel.CollectPngs(arguments));
        if (files.Count == 0)
        {
            Finish("No PNG images to fix", "Drop .png files or folders containing them onto Chipng.", []);
            return;
        }

        Heading.Text = files.Count == 1 ? $"Fixing {Path.GetFileName(files[0])}…" : $"Fixing {files.Count} images…";

        SquooshEngine? engine = null;
        if (settings.Compress)
        {
            Detail.Text = "Starting Squoosh…";
            engine = new SquooshEngine(new WindowInteropHelper(this).Handle, Dispatcher);
            try
            {
                await engine.PrepareAsync();
            }
            catch (Exception error)
            {
                Finish("Couldn’t start compression", "No files were changed.", [error.Message]);
                return;
            }
        }

        var failures = new List<string>();
        long before = 0, after = 0;
        var done = 0;
        var queue = new Queue<string>(files);

        async Task Worker()
        {
            while (queue.TryDequeue(out var file))
            {
                Detail.Text = Path.GetFileName(file);
                try
                {
                    var original = await File.ReadAllBytesAsync(file);
                    var result = await ImageProcessor.ProcessAsync(original, settings.Compress, engine);
                    if (settings.KeepOriginalsInRecycleBin) AppModel.RecycleCopy(original, Path.GetFileName(file));
                    AppModel.WriteAtomically(file, result.Data);
                    before += original.Length;
                    after += result.Data.Length;
                }
                catch (Exception error)
                {
                    failures.Add($"{Path.GetFileName(file)}: {error.Message}");
                }
                done++;
                Progress.Value = (double)done / files.Count;
            }
        }

        // Workers all run on the UI thread, so the counters above need no locking.
        await Task.WhenAll(Enumerable.Range(0, Math.Min(MaxConcurrent, files.Count)).Select(_ => Worker()));

        var fixedCount = files.Count - failures.Count;
        var heading = fixedCount == 0
            ? "Couldn’t fix the images"
            : $"Fixed {fixedCount} image{(fixedCount == 1 ? "" : "s")}";
        var detail = fixedCount == 0 ? "No files were changed." : Summary(before, after);
        Finish(heading, detail, failures);
    }

    private string Summary(long before, long after)
    {
        var text = $"{Format.Bytes(before)} → {Format.Bytes(after)}";
        if (before > 0)
        {
            var change = 1 - (double)after / before;
            text += change >= 0 ? $" ({change:P0} smaller)" : $" ({-change:P0} larger)";
        }
        if (settings.KeepOriginalsInRecycleBin) text += ". Originals are in the Recycle Bin.";
        return text;
    }

    private async void Finish(string heading, string detail, List<string> failures)
    {
        Heading.Text = heading;
        Detail.Text = detail;
        Detail.TextTrimming = TextTrimming.None;
        Detail.TextWrapping = TextWrapping.Wrap;
        Progress.Visibility = Visibility.Collapsed;
        Spinner.Visibility = Visibility.Collapsed;

        if (failures.Count == 0 && heading.StartsWith("Fixed", StringComparison.Ordinal))
        {
            DoneIcon.Visibility = Visibility.Visible;
            await Task.Delay(TimeSpan.FromSeconds(2.5));
            Close();
            return;
        }

        FailedIcon.Visibility = Visibility.Visible;
        if (failures.Count > 0)
        {
            Failures.Text = string.Join(Environment.NewLine, failures);
            Failures.Visibility = Visibility.Visible;
        }
        Buttons.Visibility = Visibility.Visible;
    }

    private void OnOpenChipng(object sender, RoutedEventArgs e)
    {
        if (Environment.ProcessPath is { } exe) Process.Start(new ProcessStartInfo(exe) { UseShellExecute = true });
        Close();
    }

    private void OnClose(object sender, RoutedEventArgs e) => Close();
}
