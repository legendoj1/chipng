using System;
using System.IO;
using System.Windows;
using System.Windows.Threading;

namespace Chipng;

public partial class App : Application
{
    protected override void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);
        DispatcherUnhandledException += OnUnhandledException;

        try
        {
            // Files dragged onto Chipng.exe arrive as arguments: fix them in place, like Pixelfix.
            Window window = e.Args.Length > 0 ? new QuickFixWindow(e.Args) : new MainWindow();
            MainWindow = window;
            window.Show();
        }
        catch (Exception error)
        {
            Log(error);
            MessageBox.Show($"Chipng couldn’t start: {error.Message}", "Chipng", MessageBoxButton.OK, MessageBoxImage.Error);
            Shutdown(1);
        }
    }

    private static void OnUnhandledException(object sender, DispatcherUnhandledExceptionEventArgs e)
    {
        Log(e.Exception);
        MessageBox.Show(e.Exception.Message, "Chipng ran into a problem", MessageBoxButton.OK, MessageBoxImage.Error);
        e.Handled = true;
    }

    private static void Log(Exception error)
    {
        try
        {
            var log = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Chipng", "error.log");
            Directory.CreateDirectory(Path.GetDirectoryName(log)!);
            File.AppendAllText(log, $"[{DateTime.Now:u}] {error}\n\n");
        }
        catch (IOException) { }
    }
}
