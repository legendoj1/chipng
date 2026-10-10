using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Diagnostics;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Threading.Tasks;
using System.Windows;
using System.Windows.Data;
using System.Windows.Input;
using System.Windows.Interop;
using Microsoft.Win32;
using Wpf.Ui.Appearance;
using Wpf.Ui.Controls;
using MessageBox = Wpf.Ui.Controls.MessageBox;
using MessageBoxResult = Wpf.Ui.Controls.MessageBoxResult;

namespace Chipng;

public partial class MainWindow : FluentWindow
{
    private readonly AppModel model = new();
    private ImageItem? previewItem;

    public MainWindow()
    {
        DataContext = model;
        InitializeComponent();
        ApplicationThemeManager.ApplySystemTheme();
        SystemThemeWatcher.Watch(this);
        SourceInitialized += OnSourceInitialized;
    }

    private async void OnSourceInitialized(object? sender, EventArgs e)
    {
        model.Engine = new SquooshEngine(new WindowInteropHelper(this).Handle, Dispatcher);
        try
        {
            await model.Engine.PrepareAsync();
        }
        catch (Exception error)
        {
            model.EngineError = error.Message;
        }
    }

    private List<ImageItem> SelectedItems => ImageGrid.SelectedItems.Cast<ImageItem>().ToList();

    // MARK: Adding & removing

    private async void OnAddImages(object sender, RoutedEventArgs e)
    {
        var dialog = new OpenFileDialog
        {
            Title = "Add PNG images",
            Filter = "PNG images (*.png)|*.png",
            Multiselect = true,
        };
        if (dialog.ShowDialog(this) == true) await model.AddAsync(dialog.FileNames);
    }

    private async void OnAddFolder(object sender, RoutedEventArgs e)
    {
        var dialog = new OpenFolderDialog { Title = "Add every PNG in a folder", Multiselect = true };
        if (dialog.ShowDialog(this) == true) await model.AddAsync(dialog.FolderNames);
    }

    private void OnClearAll(object sender, RoutedEventArgs e) => model.Clear();

    private void OnRemoveSelected(object sender, RoutedEventArgs e) => model.Remove(SelectedItems);

    private void OnShowInExplorer(object sender, RoutedEventArgs e)
    {
        if (SelectedItems.FirstOrDefault() is { } item) AppModel.ShowInExplorer(item.Path);
    }

    private void OnRowDoubleClick(object sender, MouseButtonEventArgs e)
    {
        if (ImageGrid.SelectedItem is ImageItem item) AppModel.ShowInExplorer(item.Path);
    }

    // MARK: Replace originals

    private async void OnReplaceOriginals(object sender, RoutedEventArgs e)
    {
        var targets = model.Targets(SelectedItems);
        if (targets.Count == 0) return;

        var title = targets.Count == 1
            ? $"Replace “{targets[0].Name}” with the processed version?"
            : $"Replace {targets.Count} original files with the processed versions?";
        var message = model.Settings.KeepOriginalsInRecycleBin
            ? "A copy of each original will be put in the Recycle Bin, just in case."
            : "The original files will be overwritten. This can’t be undone.";
        if (await AskAsync(title, message, "Replace") != MessageBoxResult.Primary) return;

        var failures = model.ReplaceOriginals(targets);
        if (failures.Count > 0) await ShowErrorAsync("Some files couldn’t be replaced", failures);
    }

    // MARK: Export

    private async void OnExportToFolder(object sender, RoutedEventArgs e)
    {
        var targets = model.Targets(SelectedItems);
        if (targets.Count == 0) return;

        var dialog = new OpenFolderDialog
        {
            Title = targets.Count == 1 ? "Choose a folder for the image" : $"Choose a folder for {targets.Count} images",
        };
        if (dialog.ShowDialog(this) != true) return;
        var folder = dialog.FolderName;

        var names = AppModel.UniqueNames(targets);
        var conflicts = names.Where(n => File.Exists(Path.Combine(folder, n))).ToList();
        if (conflicts.Count > 0)
        {
            var title = conflicts.Count == 1
                ? $"“{conflicts[0]}” already exists in “{Path.GetFileName(folder)}”."
                : $"{conflicts.Count} files already exist in “{Path.GetFileName(folder)}”.";
            var choice = await AskAsync(title, "Do you want to replace them, or keep both?", "Replace", "Keep both");
            if (choice == MessageBoxResult.Secondary) names = AppModel.UniqueNames(targets, folder);
            else if (choice != MessageBoxResult.Primary) return;
        }

        var failures = AppModel.WriteToFolder(targets, names, folder);
        if (failures.Count > 0) await ShowErrorAsync("Some images couldn’t be exported", failures);
        if (failures.Count < targets.Count) Process.Start(new ProcessStartInfo(folder) { UseShellExecute = true });
    }

    private async void OnExportZip(object sender, RoutedEventArgs e)
    {
        var targets = model.Targets(SelectedItems);
        if (targets.Count == 0) return;

        var dialog = new SaveFileDialog
        {
            Title = "Export as a ZIP file",
            Filter = "ZIP archive (*.zip)|*.zip",
            FileName = "images.zip",
            DefaultExt = ".zip",
            AddExtension = true,
        };
        if (dialog.ShowDialog(this) != true) return;

        try
        {
            await model.WriteZipAsync(targets, dialog.FileName);
            AppModel.ShowInExplorer(dialog.FileName);
        }
        catch (Exception error)
        {
            await ShowErrorAsync("Couldn’t create the ZIP file", [error.Message]);
        }
    }

    // MARK: Dialogs

    private static async Task<MessageBoxResult> AskAsync(string title, string message, string primary, string? secondary = null)
    {
        var box = new MessageBox
        {
            Title = title,
            Content = message,
            PrimaryButtonText = primary,
            PrimaryButtonAppearance = ControlAppearance.Primary,
            CloseButtonText = "Cancel",
            IsSecondaryButtonEnabled = secondary is not null,
        };
        if (secondary is not null) box.SecondaryButtonText = secondary;
        return await box.ShowDialogAsync();
    }

    private static async Task ShowErrorAsync(string title, IEnumerable<string> lines)
    {
        var box = new MessageBox
        {
            Title = title,
            Content = string.Join(Environment.NewLine, lines),
            CloseButtonText = "OK",
            IsPrimaryButtonEnabled = false,
            IsSecondaryButtonEnabled = false,
        };
        await box.ShowDialogAsync();
    }

    // MARK: Preview

    private void OnSelectionChanged(object sender, System.Windows.Controls.SelectionChangedEventArgs e)
    {
        if (previewItem is not null) previewItem.PropertyChanged -= OnPreviewItemChanged;
        previewItem = ImageGrid.SelectedItems.Count == 1 ? ImageGrid.SelectedItem as ImageItem : null;
        if (previewItem is not null) previewItem.PropertyChanged += OnPreviewItemChanged;

        PreviewPanel.DataContext = previewItem;
        PreviewPanel.Visibility = previewItem is null ? Visibility.Collapsed : Visibility.Visible;
        _ = UpdatePreviewAsync();
    }

    private void OnPreviewItemChanged(object? sender, PropertyChangedEventArgs e)
    {
        if (e.PropertyName == nameof(ImageItem.Output)) _ = UpdatePreviewAsync();
    }

    private void OnHiddenColorsToggled(object sender, RoutedEventArgs e) => _ = UpdatePreviewAsync();

    private async Task UpdatePreviewAsync()
    {
        var item = previewItem;
        if (item is null)
        {
            PreviewImage.Source = null;
            return;
        }
        var data = item.Output ?? item.OriginalData;
        var revealHidden = HiddenColorsToggle.IsChecked == true;
        var image = await Task.Run(() => revealHidden ? Imaging.RevealHiddenColors(data) : Imaging.Load(data));
        if (item == previewItem) PreviewImage.Source = image;
    }

    // MARK: Drag & drop

    private void OnDragEnter(object sender, DragEventArgs e) => UpdateDrag(e);

    private void OnDragOver(object sender, DragEventArgs e) => UpdateDrag(e);

    private void UpdateDrag(DragEventArgs e)
    {
        var hasFiles = e.Data.GetDataPresent(DataFormats.FileDrop);
        e.Effects = hasFiles ? DragDropEffects.Copy : DragDropEffects.None;
        DropHighlight.Visibility = hasFiles ? Visibility.Visible : Visibility.Collapsed;
        e.Handled = true;
    }

    private void OnDragLeave(object sender, DragEventArgs e) => DropHighlight.Visibility = Visibility.Collapsed;

    private async void OnDrop(object sender, DragEventArgs e)
    {
        DropHighlight.Visibility = Visibility.Collapsed;
        if (e.Data.GetData(DataFormats.FileDrop) is string[] paths) await model.AddAsync(paths);
    }

    // MARK: Keyboard

    private void OnPreviewKeyDown(object sender, KeyEventArgs e)
    {
        var ctrl = Keyboard.Modifiers.HasFlag(ModifierKeys.Control);
        var shift = Keyboard.Modifiers.HasFlag(ModifierKeys.Shift);
        var alt = Keyboard.Modifiers.HasFlag(ModifierKeys.Alt);
        var key = e.Key == Key.System ? e.SystemKey : e.Key;

        if (ctrl && !shift && !alt && key == Key.O) OnAddImages(this, e);
        else if (ctrl && shift && key == Key.E && model.CanExport) OnExportToFolder(this, e);
        else if (ctrl && alt && key == Key.E && model.CanExport) OnExportZip(this, e);
        else if (ctrl && shift && key == Key.R && model.CanExport) OnReplaceOriginals(this, e);
        else if (key == Key.Delete && ImageGrid.IsKeyboardFocusWithin) model.Remove(SelectedItems);
        else return;
        e.Handled = true;
    }
}

public sealed class BoolToVisibilityConverter : IValueConverter
{
    public bool Invert { get; set; }

    public object Convert(object value, Type targetType, object parameter, CultureInfo culture) =>
        (value is true) != Invert ? Visibility.Visible : Visibility.Collapsed;

    public object ConvertBack(object value, Type targetType, object parameter, CultureInfo culture) =>
        throw new NotSupportedException();
}
