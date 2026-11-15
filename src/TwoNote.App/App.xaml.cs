using Microsoft.UI.Xaml;
using TwoNote.App.Logic;

namespace TwoNote.App;

/// <summary>
/// TwoNote for Windows. Command line:
///   --profile name     use a separate profile (own database, settings and secrets), e.g. to run two devices on one PC
///   --log file         write diagnostics (never secrets or note content) to a file
///   --selftest mode    unattended verification; see run-selftest.ps1
/// </summary>
public partial class App : Application
{
    private Window? _window;

    public App()
    {
        InitializeComponent();
        UnhandledException += (_, e) => AppLog.Line($"UNHANDLED: {e.Exception.GetType().Name} {e.Exception.StackTrace}");
    }

    protected override void OnLaunched(LaunchActivatedEventArgs args)
    {
        var argv = Environment.GetCommandLineArgs().Skip(1).ToArray();
        string? Value(string name)
        {
            var i = Array.IndexOf(argv, name);
            return i >= 0 && i + 1 < argv.Length ? argv[i + 1] : null;
        }

        var options = new AppOptions(Value("--profile"), Value("--log"), Value("--selftest"), argv);
        AppLog.Path = options.LogPath;
        Editor.RichEditBinding.Log = AppLog.Line;
        AppDomain.CurrentDomain.UnhandledException += (_, e) => AppLog.Line($"UNHANDLED (domain): {(e.ExceptionObject as Exception)?.GetType().Name} {(e.ExceptionObject as Exception)?.StackTrace}");
        if (options.Has("--trace-exceptions"))
        {
            AppDomain.CurrentDomain.FirstChanceException += (_, e) => AppLog.Line($"first chance: {e.Exception.GetType().Name} at {new System.Diagnostics.StackTrace(e.Exception, false).GetFrame(0)?.GetMethod()?.DeclaringType?.Name}.{new System.Diagnostics.StackTrace(e.Exception, false).GetFrame(0)?.GetMethod()?.Name}");
        }
        if (options.Profile is not null && !AppPaths.IsValidProfileName(options.Profile))
        {
            AppLog.Line("invalid --profile name");
            Environment.Exit(2);
        }

        if (options.SelfTest == "wipe")
        {
            // Removes everything a profile holds (files and secret-store entries), without showing a window.
            var paths = AppPaths.For(options.Profile);
            Secrets.SecretStores.Wipe(paths);
            paths.DeleteAll();
            Environment.Exit(0);
        }

        _window = options.SelfTest == "binding" ? new SelfTest.BindingTestWindow(options) : new MainWindow(options);
        _window.Activate();
    }
}
