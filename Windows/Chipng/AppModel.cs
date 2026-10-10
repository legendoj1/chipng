using System;
using System.Collections.Generic;
using System.Collections.ObjectModel;
using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.IO.Compression;
using System.Linq;
using System.Runtime.CompilerServices;
using System.Text.Json;
using System.Threading.Tasks;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using Chipng.Core;

namespace Chipng;

public abstract class ObservableObject : INotifyPropertyChanged
{
    public event PropertyChangedEventHandler? PropertyChanged;

    protected void OnPropertyChanged([CallerMemberName] string? name = null) =>
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(name));

    protected bool Set<T>(ref T field, T value, [CallerMemberName] string? name = null)
    {
        if (EqualityComparer<T>.Default.Equals(field, value)) return false;
        field = value;
        OnPropertyChanged(name);
        return true;
    }
}

public enum ItemStatus { Queued, Processing, Ready, Failed }

public sealed class ImageItem : ObservableObject
{
    private ItemStatus status = ItemStatus.Queued;
    private ImageSource? thumbnail;
    private byte[]? output;
    private string? dimensions;
    private string? method;
    private string? error;
    private bool isSavedToOriginal;

    public ImageItem(string path, byte[] data)
    {
        Path = path;
        OriginalData = data;
    }

    public string Path { get; }
    public string Name => System.IO.Path.GetFileName(Path);

    /// <summary>
    /// The file's bytes as they were when added. Re-processing always starts from
    /// these, even after the file on disk has been replaced.
    /// </summary>
    public byte[] OriginalData { get; }

    public bool HasRecycleBinBackup { get; set; }
    public int Generation { get; set; }

    public ImageSource? Thumbnail { get => thumbnail; set => Set(ref thumbnail, value); }
    public string Dimensions { get => dimensions ?? "—"; set => Set(ref dimensions, value); }
    public string? Method { get => method; set => Set(ref method, value); }
    public string? Error { get => error; set => Set(ref error, value); }

    public ItemStatus Status
    {
        get => status;
        set
        {
            if (!Set(ref status, value)) return;
            OnPropertyChanged(nameof(StatusText));
            OnPropertyChanged(nameof(IsProcessing));
            OnPropertyChanged(nameof(IsDone));
            OnPropertyChanged(nameof(IsFailed));
            OnPropertyChanged(nameof(IsWaiting));
        }
    }

    public byte[]? Output
    {
        get => output;
        set
        {
            if (!Set(ref output, value)) return;
            OnPropertyChanged(nameof(ResultSizeText));
            OnPropertyChanged(nameof(ChangeText));
            OnPropertyChanged(nameof(IsSmaller));
        }
    }

    public bool IsSavedToOriginal
    {
        get => isSavedToOriginal;
        set { if (Set(ref isSavedToOriginal, value)) OnPropertyChanged(nameof(StatusText)); }
    }

    public string OriginalSizeText => Format.Bytes(OriginalData.Length);
    public string ResultSizeText => Output is null ? "—" : Format.Bytes(Output.Length);

    public string ChangeText
    {
        get
        {
            if (Output is null || OriginalData.Length == 0) return "—";
            var change = 1 - (double)Output.Length / OriginalData.Length;
            return change >= 0 ? $"−{change:P0}".Replace(" ", "") : $"+{-change:P0}".Replace(" ", "");
        }
    }

    public bool IsSmaller => Output is not null && Output.Length < OriginalData.Length * 0.995;
    public bool IsWaiting => Status == ItemStatus.Queued;
    public bool IsProcessing => Status == ItemStatus.Processing;
    public bool IsDone => Status == ItemStatus.Ready;
    public bool IsFailed => Status == ItemStatus.Failed;

    public string StatusText => Status switch
    {
        ItemStatus.Queued => "Waiting",
        ItemStatus.Processing => "Processing",
        ItemStatus.Ready => IsSavedToOriginal ? "Replaced" : "Ready",
        _ => "Can’t process",
    };
}

public sealed class AppSettings : ObservableObject
{
    private bool compress = true;
    private bool keepOriginalsInRecycleBin = true;

    private static string FilePath => System.IO.Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Chipng", "settings.json");

    public event Action? CompressionChanged;

    public bool Compress
    {
        get => compress;
        set
        {
            if (!Set(ref compress, value)) return;
            Save();
            CompressionChanged?.Invoke();
        }
    }

    public bool KeepOriginalsInRecycleBin
    {
        get => keepOriginalsInRecycleBin;
        set { if (Set(ref keepOriginalsInRecycleBin, value)) Save(); }
    }

    private sealed record Stored(bool Compress = true, bool KeepOriginalsInRecycleBin = true);

    public static AppSettings Load()
    {
        var settings = new AppSettings();
        try
        {
            if (File.Exists(FilePath))
            {
                var stored = JsonSerializer.Deserialize<Stored>(File.ReadAllText(FilePath)) ?? new Stored();
                settings.compress = stored.Compress;
                settings.keepOriginalsInRecycleBin = stored.KeepOriginalsInRecycleBin;
            }
        }
        catch (Exception e) when (e is IOException or JsonException or UnauthorizedAccessException) { }
        return settings;
    }

    private void Save()
    {
        try
        {
            Directory.CreateDirectory(System.IO.Path.GetDirectoryName(FilePath)!);
            File.WriteAllText(FilePath, JsonSerializer.Serialize(new Stored(compress, keepOriginalsInRecycleBin)));
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException) { }
    }
}

public sealed class AppModel : ObservableObject
{
    private const int MaxConcurrent = 4;

    private int running;
    private string? engineError;
    private bool isWorking;

    public AppModel()
    {
        Settings.CompressionChanged += Reprocess;
        Items.CollectionChanged += (_, _) => Refresh();
    }

    public AppSettings Settings { get; } = AppSettings.Load();
    public ObservableCollection<ImageItem> Items { get; } = [];
    public SquooshEngine? Engine { get; set; }

    public string? EngineError
    {
        get => engineError;
        set { if (Set(ref engineError, value)) Refresh(); }
    }

    public bool IsWorking
    {
        get => isWorking;
        set { if (Set(ref isWorking, value)) Refresh(); }
    }

    // MARK: Derived state (bound by the window; refreshed together)

    public bool IsEmpty => Items.Count == 0;
    public bool HasItems => Items.Count > 0;
    public IEnumerable<ImageItem> ReadyItems => Items.Where(i => i.Status == ItemStatus.Ready && i.Output is not null);
    public int PendingCount => Items.Count(i => i.Status is ItemStatus.Queued or ItemStatus.Processing);
    public int FailedCount => Items.Count(i => i.Status == ItemStatus.Failed);
    public bool IsProcessing => PendingCount > 0;
    public bool CanExport => ReadyItems.Any() && !IsProcessing && !IsWorking;
    public double Progress => Items.Count == 0 ? 0 : (double)(Items.Count - PendingCount) / Items.Count;
    public string ModeText => Settings.Compress ? "Alpha bleed + Squoosh" : "Alpha bleed only";

    public string StatusText
    {
        get
        {
            if (IsProcessing) return $"Processing {Items.Count - PendingCount} of {Items.Count}…";
            if (IsWorking) return "Exporting…";
            var ready = ReadyItems.ToList();
            if (ready.Count == 0) return EngineError ?? (Items.Count == 0 ? "Ready" : "");
            long before = ready.Sum(i => (long)i.OriginalData.Length), after = ready.Sum(i => (long)i.Output!.Length);
            var text = $"{Format.Bytes(before)} → {Format.Bytes(after)}";
            if (before > 0)
            {
                var change = 1 - (double)after / before;
                text += change >= 0 ? $" ({change:P0} smaller)" : $" ({-change:P0} larger)";
            }
            if (FailedCount > 0) text += $" · {FailedCount} couldn’t be processed";
            return text;
        }
    }

    public void Refresh()
    {
        foreach (var name in new[]
                 {
                     nameof(IsEmpty), nameof(HasItems), nameof(IsProcessing), nameof(CanExport), nameof(Progress), nameof(StatusText),
                     nameof(ModeText),
                 })
        {
            OnPropertyChanged(name);
        }
    }

    /// <summary>The selection if there is one, otherwise everything; only processed images.</summary>
    public List<ImageItem> Targets(IEnumerable<ImageItem>? selection)
    {
        var chosen = selection?.ToList() is { Count: > 0 } list ? list : Items.ToList();
        return chosen.Where(i => i.Status == ItemStatus.Ready && i.Output is not null).ToList();
    }

    // MARK: Adding & removing

    public async Task AddAsync(IEnumerable<string> paths)
    {
        var existing = new HashSet<string>(Items.Select(i => i.Path), StringComparer.OrdinalIgnoreCase);
        var loaded = await Task.Run(() => CollectPngs(paths)
            .Where(p => !existing.Contains(p))
            .Select(p =>
            {
                try { return (Path: p, Data: File.ReadAllBytes(p)); }
                catch (Exception e) when (e is IOException or UnauthorizedAccessException) { return (Path: p, Data: (byte[]?)null); }
            })
            .Where(x => x.Data is not null)
            .ToList());

        foreach (var (path, data) in loaded)
        {
            if (!existing.Add(path)) continue;
            var item = new ImageItem(path, data!);
            Items.Add(item);
            _ = SetThumbnailAsync(item, data!);
        }
        Pump();
    }

    internal static List<string> CollectPngs(IEnumerable<string> paths)
    {
        var result = new List<string>();
        foreach (var path in paths)
        {
            if (Directory.Exists(path))
            {
                try
                {
                    result.AddRange(Directory.EnumerateFiles(path, "*", new EnumerationOptions
                        {
                            RecurseSubdirectories = true, IgnoreInaccessible = true, AttributesToSkip = FileAttributes.Hidden | FileAttributes.System,
                        })
                        .Where(IsPng));
                }
                catch (IOException) { }
            }
            else if (File.Exists(path) && IsPng(path))
            {
                result.Add(Path.GetFullPath(path));
            }
        }
        return result.OrderBy(p => p, StringComparer.CurrentCultureIgnoreCase).ToList();
    }

    private static bool IsPng(string path) => string.Equals(Path.GetExtension(path), ".png", StringComparison.OrdinalIgnoreCase);

    public void Remove(IEnumerable<ImageItem> items)
    {
        foreach (var item in items.ToList()) Items.Remove(item);
    }

    public void Clear() => Items.Clear();

    // MARK: Processing

    private void Reprocess()
    {
        foreach (var item in Items)
        {
            item.Generation++;
            item.Status = ItemStatus.Queued;
            item.Output = null;
            item.Method = null;
            item.Error = null;
            item.IsSavedToOriginal = false;
        }
        Refresh();
        Pump();
    }

    private void Pump()
    {
        while (running < MaxConcurrent && Items.FirstOrDefault(i => i.Status == ItemStatus.Queued) is { } item)
        {
            running++;
            item.Status = ItemStatus.Processing;
            _ = ProcessAsync(item, item.Generation, Settings.Compress);
        }
        Refresh();
    }

    private async Task ProcessAsync(ImageItem item, int generation, bool compress)
    {
        ProcessedImage? result = null;
        string? error = null;
        try
        {
            result = await ImageProcessor.ProcessAsync(item.OriginalData, compress, Engine);
        }
        catch (Exception e)
        {
            error = e.Message;
        }

        running--;
        if (item.Generation == generation && Items.Contains(item))
        {
            if (result is not null)
            {
                item.Output = result.Data;
                item.Dimensions = $"{result.Width} × {result.Height}";
                item.Method = result.MethodDescription;
                item.Status = ItemStatus.Ready;
                _ = SetThumbnailAsync(item, result.Data);
            }
            else
            {
                item.Error = error;
                item.Status = ItemStatus.Failed;
            }
        }
        Pump();
    }

    private static async Task SetThumbnailAsync(ImageItem item, byte[] data)
    {
        var thumbnail = await Task.Run(() => Imaging.Load(data, decodeWidth: 56));
        if (thumbnail is not null) item.Thumbnail = thumbnail;
    }

    // MARK: Replace originals

    /// <summary>Overwrites the original files. Returns error messages for files that failed.</summary>
    public List<string> ReplaceOriginals(IEnumerable<ImageItem> targets)
    {
        var failures = new List<string>();
        foreach (var item in targets)
        {
            if (item.Output is null) continue;
            try
            {
                if (Settings.KeepOriginalsInRecycleBin && !item.HasRecycleBinBackup)
                {
                    RecycleCopy(item.OriginalData, item.Name);
                    item.HasRecycleBinBackup = true;
                }
                WriteAtomically(item.Path, item.Output);
                item.IsSavedToOriginal = true;
            }
            catch (Exception e)
            {
                failures.Add($"{item.Name}: {e.Message}");
            }
        }
        Refresh();
        return failures;
    }

    /// <summary>
    /// Puts a copy of the original bytes in the Recycle Bin. Going through a file in
    /// %TEMP% works for every drive, including network and cloud drives without one.
    /// </summary>
    internal static void RecycleCopy(byte[] data, string name)
    {
        var folder = Path.Combine(Path.GetTempPath(), $"Chipng-{Guid.NewGuid():N}");
        Directory.CreateDirectory(folder);
        try
        {
            var file = Path.Combine(folder, name);
            File.WriteAllBytes(file, data);
            Microsoft.VisualBasic.FileIO.FileSystem.DeleteFile(
                file,
                Microsoft.VisualBasic.FileIO.UIOption.OnlyErrorDialogs,
                Microsoft.VisualBasic.FileIO.RecycleOption.SendToRecycleBin);
        }
        finally
        {
            try { Directory.Delete(folder, recursive: true); } catch (IOException) { }
        }
    }

    internal static void WriteAtomically(string path, byte[] data)
    {
        var temp = path + ".chipng-tmp";
        File.WriteAllBytes(temp, data);
        File.Move(temp, path, overwrite: true);
    }

    // MARK: Export

    /// <summary>File names for the targets, with " (1)", " (2)"… added to duplicates and, optionally, to files already in <paramref name="folder"/>.</summary>
    public static List<string> UniqueNames(IEnumerable<ImageItem> items, string? folder = null)
    {
        var used = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        var names = new List<string>();
        foreach (var item in items)
        {
            var stem = Path.GetFileNameWithoutExtension(item.Name);
            var extension = Path.GetExtension(item.Name);
            var candidate = item.Name;
            for (var n = 1; used.Contains(candidate) || (folder is not null && File.Exists(Path.Combine(folder, candidate))); n++)
            {
                candidate = $"{stem} ({n}){extension}";
            }
            used.Add(candidate);
            names.Add(candidate);
        }
        return names;
    }

    public static List<string> WriteToFolder(IReadOnlyList<ImageItem> items, IReadOnlyList<string> names, string folder)
    {
        var failures = new List<string>();
        for (var i = 0; i < items.Count; i++)
        {
            try { WriteAtomically(Path.Combine(folder, names[i]), items[i].Output!); }
            catch (Exception e) { failures.Add($"{names[i]}: {e.Message}"); }
        }
        return failures;
    }

    public async Task WriteZipAsync(IReadOnlyList<ImageItem> items, string destination)
    {
        IsWorking = true;
        try
        {
            var files = UniqueNames(items).Zip(items.Select(i => i.Output!)).ToList();
            await Task.Run(() =>
            {
                var temp = destination + ".chipng-tmp";
                using (var stream = File.Create(temp))
                using (var zip = new ZipArchive(stream, ZipArchiveMode.Create))
                {
                    foreach (var (name, data) in files)
                    {
                        using var entry = zip.CreateEntry(name, CompressionLevel.Fastest).Open();
                        entry.Write(data);
                    }
                }
                File.Move(temp, destination, overwrite: true);
            });
        }
        finally
        {
            IsWorking = false;
        }
    }

    public static void ShowInExplorer(string path) =>
        Process.Start(new ProcessStartInfo("explorer.exe", $"/select,\"{path}\"") { UseShellExecute = true });
}

public static class Format
{
    /// <summary>File sizes the way File Explorer shows them.</summary>
    public static string Bytes(long bytes) => bytes switch
    {
        < 1024 => $"{bytes} bytes",
        < 1024 * 1024 => $"{bytes / 1024.0:0.#} KB",
        _ => $"{bytes / (1024.0 * 1024):0.##} MB",
    };
}

public static class Imaging
{
    public static BitmapSource? Load(byte[] png, int decodeWidth = 0)
    {
        try
        {
            var image = new BitmapImage();
            image.BeginInit();
            image.CacheOption = BitmapCacheOption.OnLoad;
            image.StreamSource = new MemoryStream(png);
            if (decodeWidth > 0) image.DecodePixelWidth = decodeWidth;
            image.EndInit();
            image.Freeze();
            return image;
        }
        catch (Exception)
        {
            return null;
        }
    }

    /// <summary>
    /// The image with alpha ignored, which shows the colours hidden in transparent
    /// pixels — i.e. what alpha bleeding filled in.
    /// </summary>
    public static BitmapSource? RevealHiddenColors(byte[] png)
    {
        try
        {
            var image = PngCodec.Decode(png);
            var bgr = new byte[image.Pixels.Length];
            for (var i = 0; i < bgr.Length; i += 4)
            {
                bgr[i] = image.Pixels[i + 2];
                bgr[i + 1] = image.Pixels[i + 1];
                bgr[i + 2] = image.Pixels[i];
                bgr[i + 3] = 255;
            }
            var bitmap = BitmapSource.Create(image.Width, image.Height, 96, 96, PixelFormats.Bgr32, null, bgr, image.Width * 4);
            bitmap.Freeze();
            return bitmap;
        }
        catch (PngException)
        {
            return null;
        }
    }
}
