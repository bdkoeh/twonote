using System.Globalization;
using System.Runtime.InteropServices;
using Microsoft.UI.Windowing;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using TwoNote.App.Logic;
using TwoNote.App.Views;
using TwoNote.Core;
using TwoNote.Core.Api;
using TwoNote.Core.Sync;

namespace TwoNote.App;

/// <summary>What the command line asked for.</summary>
internal sealed record AppOptions(string? Profile, string? LogPath, string? SelfTest, string[] Args)
{
    public string? Value(string name)
    {
        var i = Array.IndexOf(Args, name);
        return i >= 0 && i + 1 < Args.Length ? Args[i + 1] : null;
    }

    public bool Has(string name) => Args.Contains(name);
}

/// <summary>
/// The one window: custom title bar (search, sync status, lock, settings) over whichever view the account's
/// state calls for - setup, unlock, or the notebooks. The window title never carries anything from a note.
/// </summary>
internal sealed partial class MainWindow : Window
{
    private readonly AppOptions _options;
    private readonly DispatcherTimer _idleTimer = new() { Interval = TimeSpan.FromSeconds(5) };
    private DateTimeOffset _lastActivity = DateTimeOffset.UtcNow;
    private ContentDialog? _dialog;
    private TwoNoteClient? _hooked;
    private bool _statusQueued;
    private bool _socketWasUp;
    private SyncState _settled = SyncState.Idle;
    private Mutex? _instance;
    private bool _locking;
    private bool _closing;
    private bool _closed;

    public MainWindow(AppOptions options)
    {
        _options = options;
        InitializeComponent();
        ExtendsContentIntoTitleBar = true;
        SetTitleBar(AppTitleBar);
        Hwnd = WinRT.Interop.WindowNative.GetWindowHandle(this);
        Session = new AppSession(AppPaths.For(options.Profile), DispatcherQueue);

        // The profile name is the only thing besides the product name that ever appears in a title.
        Title = options.Profile is null ? "TwoNote" : $"TwoNote ({options.Profile})";
        AppTitleBar.Subtitle = options.Profile ?? "";
        var icon = Path.Combine(AppContext.BaseDirectory, "Assets", "TwoNote.ico");
        if (File.Exists(icon))
        {
            AppWindow.SetIcon(icon);
        }

        var scale = GetDpiForWindow(Hwnd) / 96.0;
        AppWindow.Resize(new Windows.Graphics.SizeInt32(
            (int)(Math.Clamp(Session.Settings.WindowWidth, MinWindowWidth, 4000) * scale), (int)(Math.Clamp(Session.Settings.WindowHeight, MinWindowHeight, 3000) * scale)));
        if (!Microsoft.UI.Composition.SystemBackdrops.MicaController.IsSupported())
        {
            // Windows 10: no Mica. A plain themed background instead of whatever is behind the window.
            Root.Background = (Brush)Application.Current.Resources["ApplicationPageBackgroundThemeBrush"];
        }

        if (AppWindow.Presenter is OverlappedPresenter presenter)
        {
            presenter.PreferredMinimumWidth = (int)(MinWindowWidth * scale);
            presenter.PreferredMinimumHeight = (int)(MinWindowHeight * scale);
        }

        ApplyTheme();
        ZoomCanvas.SizeChanged += (_, _) => LayoutZoom();
        Root.SizeChanged += (_, _) => AdaptTitleBar();
        ApplyZoom();

        LockButton.Click += async (_, _) => await LockAsync();
        PanesButton.Click += (_, _) => Main?.TogglePanes();
        SettingsButton.Click += (_, _) => ToggleSettings();
        SyncFlyout.Opening += (_, _) => BuildSyncDetails();
        SearchBox.TextChanged += async (_, e) =>
        {
            if (e.Reason == AutoSuggestionBoxTextChangeReason.UserInput)
            {
                await UpdateSuggestionsAsync();
            }
        };
        SearchBox.GotFocus += (_, _) => Main?.InvalidateIndex();
        SearchBox.SuggestionChosen += (_, e) => OpenHit((e.SelectedItem as FrameworkElement)?.Tag as SearchHit);
        SearchBox.QuerySubmitted += async (_, e) =>
        {
            if (e.ChosenSuggestion is null && Main is not null)
            {
                OpenHit((await Main.SearchAsync(e.QueryText)).FirstOrDefault());
            }
        };

        Root.AddHandler(UIElement.PointerMovedEvent, new PointerEventHandler((_, _) => NoteActivity()), true);
        Root.AddHandler(UIElement.PointerPressedEvent, new PointerEventHandler((_, _) => NoteActivity()), true);
        Root.AddHandler(UIElement.KeyDownEvent, new KeyEventHandler((_, _) => NoteActivity()), true);
        Activated += (_, _) => NoteActivity();
        Root.ActualThemeChanged += (_, _) => Main?.OnThemeChanged();
        _idleTimer.Tick += async (_, _) => await OnIdleTickAsync();
        AppWindow.Closing += OnClosing;
        Closed += (_, _) => _closed = true;

        // Not from inside the Loaded callback itself: start-up opens the database and reads the secret store.
        Root.Loaded += (_, _) => DispatcherQueue.TryEnqueue(async () =>
        {
            await StartAsync();
            if (options.SelfTest is not null)
            {
                await SelfTest.SelfTestRunner.RunAsync(this, options);
            }
        });
    }

    [DllImport("user32.dll")]
    private static extern uint GetDpiForWindow(nint hwnd);

    [DllImport("user32.dll")]
    private static extern nint GetForegroundWindow();

    [StructLayout(LayoutKind.Sequential)]
    private struct LastInputInfo
    {
        public uint Size;
        public uint Time;
    }

    [DllImport("user32.dll")]
    private static extern bool GetLastInputInfo(ref LastInputInfo info);

    public nint Hwnd { get; }

    public AppSession Session { get; }

    public MainView? Main { get; private set; }

    public SetupView? Setup => Host.Children.OfType<SetupView>().FirstOrDefault();

    public UnlockView? Unlock => Host.Children.OfType<UnlockView>().FirstOrDefault();

    public SettingsView? Settings => Host.Children.OfType<SettingsView>().FirstOrDefault();

    public FrameworkElement RootElement => Root;

    public bool IsDark => Root.ActualTheme == ElementTheme.Dark;

    /// <summary>What the title-bar sync button says (self-test).</summary>
    public string SyncStatusText => SyncText.Text;

    public bool TitleButtonsVisible => TitleButtons.Visibility == Visibility.Visible;

    /// <summary>Overrides the auto-lock time from the settings (self-test).</summary>
    public TimeSpan? IdleLimitOverride { get; set; }

    public bool IsClosed => _closed;

    // ---- start-up and view switching -----------------------------------------------------------------------

    private async Task StartAsync()
    {
        // One instance per profile: two processes on one local database would both act as the same device.
        _instance = new Mutex(true, "TwoNote-" + Session.Paths.SecretScope.Replace('/', '-'), out var first);
        if (!first)
        {
            _instance.Dispose();
            _instance = null;
            await ShowDialogAsync(new ContentDialog
            {
                Title = "TwoNote is already running",
                Content = Session.Paths.Profile is null
                    ? "Another TwoNote window is open. To run a second one as a separate device, start it with --profile and a name."
                    : $"Another TwoNote window is already using the profile \"{Session.Paths.Profile}\".",
                CloseButtonText = "Close",
            });
            _closing = true; // nothing of ours to shut down
            Close();
            return;
        }

        if (!AppSession.TryParseServerUrl(Session.Settings.ServerUrl, out var url))
        {
            Show(new SetupView(this, Session));
            return;
        }

        try
        {
            Session.OpenClient(url);
        }
        catch (Exception e)
        {
            AppLog.Line($"opening the local database failed: {e.GetType().Name}");
            await ShowDialogAsync(new ContentDialog
            {
                Title = "TwoNote cannot start",
                Content = $"The local database of this profile could not be opened ({e.GetType().Name}). Close other TwoNote windows using the same profile and try again.",
                CloseButtonText = "Close",
            });
            Close();
            return;
        }

        if (Session.Client!.State == ClientState.Locked)
        {
            Show(new UnlockView(this, Session));
        }
        else
        {
            var setup = new SetupView(this, Session);
            Show(setup);
            setup.ShowChoiceFor(url);
        }
    }

    private void Show(UserControl view)
    {
        Host.Children.Clear();
        Host.Children.Add(view);
        var unlocked = view is MainView or SettingsView;
        TitleButtons.Visibility = unlocked ? Visibility.Visible : Visibility.Collapsed;
        SearchBox.Visibility = view is MainView ? Visibility.Visible : Visibility.Collapsed;
    }

    /// <summary>The account is unlocked: show the notebooks and start syncing.</summary>
    public async Task EnterMainAsync(bool firstDevice)
    {
        var client = Session.Client!;
        Main = new MainView(this, Session);
        Show(Main);
        await Task.Yield(); // let the view enter the tree before the editor is bound
        Main.Start(firstDevice);

        _hooked = client;
        _socketWasUp = false;
        _settled = SyncState.Idle;
        client.Sync.StatusChanged += OnSyncStatusChanged;
        client.Sync.IssueReported += OnSyncIssue;
        client.Sync.Start();
        UpdateSyncStatus();
        NoteActivity();
        _idleTimer.Start();
    }

    private void Unhook()
    {
        _idleTimer.Stop();
        if (_hooked is not null)
        {
            _hooked.Sync.StatusChanged -= OnSyncStatusChanged;
            _hooked.Sync.IssueReported -= OnSyncIssue;
            _hooked = null;
        }
    }

    private void ToggleSettings()
    {
        if (Settings is not null)
        {
            CloseSettings();
        }
        else if (Main is not null && Session.Client?.State == ClientState.Unlocked)
        {
            OpenSettings();
        }
    }

    public SettingsView OpenSettings()
    {
        Main!.CloseCurrentPageForOverlay();
        var view = new SettingsView(this, Session);
        Show(view);
        return view;
    }

    public void CloseSettings()
    {
        if (Settings is not null && Main is not null)
        {
            Show(Main);
            Main.ReturnFromOverlay();
        }
    }

    // ---- locking -------------------------------------------------------------------------------------------

    /// <summary>Records keyboard or mouse activity for the auto-lock.</summary>
    public void NoteActivity() => _lastActivity = DateTimeOffset.UtcNow;

    private async Task OnIdleTickAsync()
    {
        var limit = IdleLimitOverride ?? TimeSpan.FromMinutes(Session.Settings.AutoLockMinutes);
        if (limit <= TimeSpan.Zero || Session.Client?.State != ClientState.Unlocked)
        {
            return;
        }

        // Input that went to a dialog or flyout of ours does not reach the root element; the system's own idle
        // clock covers that while this window is in front.
        if (GetForegroundWindow() == Hwnd)
        {
            var info = new LastInputInfo { Size = (uint)Marshal.SizeOf<LastInputInfo>() };
            if (GetLastInputInfo(ref info))
            {
                var idle = TimeSpan.FromMilliseconds(unchecked((uint)Environment.TickCount - info.Time));
                var last = DateTimeOffset.UtcNow - idle;
                if (last > _lastActivity)
                {
                    _lastActivity = last;
                }
            }
        }


        if (DateTimeOffset.UtcNow - _lastActivity >= limit)
        {
            await LockAsync();
        }
    }

    /// <summary>Locks: decrypted content leaves the window, the keys leave memory, the unlock screen shows.</summary>
    public async Task LockAsync()
    {
        var client = Session.Client;
        if (_locking || client is null || client.State != ClientState.Unlocked)
        {
            return;
        }

        _locking = true;
        try
        {
            ClearUnlockedUi();
            Show(new UserControl { Content = new ProgressRing { IsActive = true, Width = 32, Height = 32 } });
            await client.LockAsync();
            if (!_closing)
            {
                Show(new UnlockView(this, Session));
            }
        }
        finally
        {
            _locking = false;
        }
    }

    private void ClearUnlockedUi()
    {
        _dialog?.Hide();
        SyncFlyout.Hide();
        SyncDetails.Children.Clear();
        SearchBox.ItemsSource = null;
        SearchBox.Text = "";
        Unhook();
        Main?.Teardown();
        Main = null;
        Host.Children.Clear();
    }

    public async Task ConfirmSignOutAsync()
    {
        var pending = Session.Client?.State == ClientState.Unlocked ? Session.Client.Sync.Status.PendingUpdates : 0;
        var warning = pending > 0 ? $"\n\n{pending} edit(s) made on this device have not reached the server yet and will be lost." : "";
        if (await ConfirmAsync(
                "Sign out of this device?",
                "The local copy of your notes, the settings and the Secret Key are removed from this PC. To use TwoNote here again you need your password and your Secret Key (it is on your Emergency Kit)." + warning,
                "Sign out and erase"))
        {
            await SignOutAsync();
        }
    }

    /// <summary>Wipes this profile and returns to the first-run screen.</summary>
    public async Task SignOutAsync()
    {
        ClearUnlockedUi();
        Show(new UserControl { Content = new ProgressRing { IsActive = true, Width = 32, Height = 32 } });
        await Session.SignOutAsync();
        Show(new SetupView(this, Session));
    }

    private async void OnClosing(AppWindow sender, AppWindowClosingEventArgs args)
    {
        if (_closing)
        {
            return;
        }

        // Stop the sync engine and close the database before the window goes away.
        args.Cancel = true;
        await ShutdownAsync();
    }

    /// <summary>Closes the window the orderly way: content off the screen, sync stopped, database closed.</summary>
    public async Task ShutdownAsync()
    {
        if (_closing)
        {
            return;
        }

        _closing = true;
        try
        {
            var scale = GetDpiForWindow(Hwnd) / 96.0;
            Session.Settings.WindowWidth = (int)(AppWindow.Size.Width / scale);
            Session.Settings.WindowHeight = (int)(AppWindow.Size.Height / scale);
            Session.Settings.Save();
            ClearUnlockedUi();
            await Session.CloseClientAsync();
        }
        catch (Exception e)
        {
            AppLog.Line($"shutdown: {e.GetType().Name}");
        }

        Close();
    }

    /// <summary>The title bar button that hides and shows the side panes reflects what the main view shows.</summary>
    public void ShowPanesState(bool hidden)
    {
        PanesIcon.Glyph = hidden ? "" : "";
        var label = hidden ? "Show side panes" : "Hide side panes";
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(PanesButton, label);
        ToolTipService.SetToolTip(PanesButton, label + " (Ctrl+\\)");
    }

    // ---- window size and zoom ------------------------------------------------------------------------------

    /// <summary>Smallest window, in device-independent pixels: enough for the title bar buttons and a narrow page.</summary>
    private const int MinWindowWidth = 420;

    private const int MinWindowHeight = 320;

    /// <summary>The zoom levels the shortcuts step through and the settings offer.</summary>
    public static readonly int[] ZoomLevels = [50, 60, 70, 80, 90, 100, 110, 125, 150, 175, 200];

    public int ZoomPercent => Math.Clamp(Session.Settings.ZoomPercent, ZoomLevels[0], ZoomLevels[^1]);

    public void SetZoom(int percent)
    {
        Session.Settings.ZoomPercent = Math.Clamp(percent, ZoomLevels[0], ZoomLevels[^1]);
        Session.Settings.Save();
        ApplyZoom();
    }

    /// <summary>Ctrl+plus / Ctrl+minus: the next larger or smaller zoom level.</summary>
    public void StepZoom(int direction)
    {
        var current = ZoomPercent;
        var next = direction > 0
            ? ZoomLevels.FirstOrDefault(l => l > current, ZoomLevels[^1])
            : ZoomLevels.LastOrDefault(l => l < current, ZoomLevels[0]);
        SetZoom(next);
    }

    /// <summary>
    /// Zooms everything below the title bar (the title bar keeps its size: its drag regions and caption buttons
    /// belong to the system). The content is laid out at window / zoom and then scaled by zoom, so at 80% it
    /// has a quarter more room and text is a fifth smaller.
    /// </summary>
    public void ApplyZoom()
    {
        var zoom = ZoomPercent / 100.0;
        Host.RenderTransform = zoom == 1 ? null : new ScaleTransform { ScaleX = zoom, ScaleY = zoom };
        LayoutZoom();
    }

    private void LayoutZoom()
    {
        var zoom = ZoomPercent / 100.0;
        if (ZoomCanvas.ActualWidth > 0 && ZoomCanvas.ActualHeight > 0)
        {
            Host.Width = ZoomCanvas.ActualWidth / zoom;
            Host.Height = ZoomCanvas.ActualHeight / zoom;
        }
    }

    /// <summary>In a narrow window the search box shrinks and then goes, and the sync status keeps only its icon.</summary>
    private void AdaptTitleBar()
    {
        var width = Root.ActualWidth;
        var search = width - 470;
        SearchBox.Width = search < 110 ? 0 : Math.Min(search, 360);
        SearchBox.IsTabStop = search >= 110;
        SyncText.Visibility = width < 620 ? Visibility.Collapsed : Visibility.Visible;
    }

    // ---- theme ---------------------------------------------------------------------------------------------

    public void ApplyTheme()
    {
        Root.RequestedTheme = Session.Settings.Theme switch
        {
            "light" => ElementTheme.Light,
            "dark" => ElementTheme.Dark,
            _ => ElementTheme.Default,
        };
        AppWindow.TitleBar.PreferredTheme = Session.Settings.Theme switch
        {
            "light" => TitleBarTheme.Light,
            "dark" => TitleBarTheme.Dark,
            _ => TitleBarTheme.UseDefaultAppMode,
        };
    }

    // ---- sync status ---------------------------------------------------------------------------------------

    private void OnSyncIssue(SyncIssue issue) => OnSyncStatusChanged(null);

    /// <summary>A local edit went into the outbox: the count of pending edits in the status needs a fresh look.</summary>
    public void RefreshSyncStatus() => OnSyncStatusChanged(null);

    private void OnSyncStatusChanged(SyncStatus? status)
    {
        // Raised on any thread and often; one UI update per burst is enough.
        if (_statusQueued)
        {
            return;
        }

        _statusQueued = true;
        DispatcherQueue.TryEnqueue(() =>
        {
            _statusQueued = false;
            UpdateSyncStatus();
        });
    }

    private void UpdateSyncStatus()
    {
        var client = _hooked;
        if (client is null || client.State != ClientState.Unlocked)
        {
            return;
        }

        var status = client.Sync.Status;
        if (_socketWasUp && !status.WebSocketConnected && status.Running)
        {
            // The live connection dropped. Ask for a sync now, so the status says "offline" (or recovers) at
            // once rather than at the next poll.
            client.Sync.RequestSync();
        }

        _socketWasUp = status.WebSocketConnected;
        if (status.State != SyncState.Syncing)
        {
            _settled = status.State;
        }
        else if (_settled is SyncState.Offline or SyncState.Error)
        {
            // A retry while the server is away: keep saying what is wrong instead of flickering to "Syncing…".
            status = status with { State = _settled };
        }

        var (glyph, text) = Describe(status);
        SyncIcon.Glyph = glyph;
        SyncText.Text = text;
        Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(SyncButton, "Sync status: " + text);
        Main?.SetAuthRequired(status.State == SyncState.AuthRequired);
        if (SyncFlyout.IsOpen)
        {
            BuildSyncDetails();
        }
    }

    private static (string Glyph, string Text) Describe(SyncStatus s)
    {
        var pending = s.PendingUpdates > 0 ? $" · {s.PendingUpdates} pending" : "";
        return s.State switch
        {
            SyncState.AuthRequired => ("\uE72E", "Sign in needed"),
            SyncState.Offline => ("\uE871", "Offline" + pending),
            SyncState.Error => ("\uE783", "Sync error" + pending),
            SyncState.Syncing => ("\uE895", "Syncing…"),
            _ when !s.Running => ("\uE769", "Sync paused" + pending),
            _ when s.PendingUpdates > 0 => ("\uE895", "Syncing…"),
            _ when s.LastSyncedAt is null => ("\uE895", "Connecting…"),
            _ => ("\uE73E", "Synced"),
        };
    }

    private void BuildSyncDetails()
    {
        SyncDetails.Children.Clear();
        var client = _hooked;
        if (client is null || client.State != ClientState.Unlocked)
        {
            return;
        }

        var s = client.Sync.Status;
        if (s.State == SyncState.Syncing && _settled is SyncState.Offline or SyncState.Error)
        {
            s = s with { State = _settled };
        }

        var secondary = (Brush)Application.Current.Resources["TextFillColorSecondaryBrush"];
        SyncDetails.Children.Add(new TextBlock
        {
            Text = s.State switch
            {
                SyncState.AuthRequired => "The server signed this device out. Sign in again to carry on syncing.",
                SyncState.Offline => "The server cannot be reached. You can keep working; your edits are stored here and sent when it is back.",
                SyncState.Error => "The last sync did not finish. It is retried automatically.",
                SyncState.Syncing => "Syncing with the server…",
                _ when !s.Running => "Syncing is paused.",
                _ when s.PendingUpdates > 0 => "Sending your latest edits…",
                _ => "Everything on this device is on the server.",
            },
            TextWrapping = TextWrapping.Wrap,
            Style = (Style)Application.Current.Resources["BodyStrongTextBlockStyle"],
        });

        void Row(string label, string value)
        {
            var grid = new Grid();
            grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(130) });
            grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            grid.Children.Add(new TextBlock { Text = label, Foreground = secondary });
            var v = new TextBlock { Text = value, TextWrapping = TextWrapping.Wrap };
            Grid.SetColumn(v, 1);
            grid.Children.Add(v);
            SyncDetails.Children.Add(grid);
        }

        Row("Server", Session.Settings.ServerUrl ?? "");
        Row("Last synced", s.LastSyncedAt is { } at ? at.ToLocalTime().ToString("d MMM yyyy HH:mm:ss", CultureInfo.CurrentCulture) : "not yet");
        Row("Waiting to send", s.PendingUpdates == 0 ? "nothing" : $"{s.PendingUpdates} edit(s)");
        Row("Live updates", s.WebSocketConnected ? "connected" : "not connected");
        Row("Received", $"{s.Cursor} of {s.Head} server changes");
        if (s.LastError is not null)
        {
            Row("Last error", s.LastError);
        }

        var issues = client.Sync.Issues;
        if (issues.Count > 0)
        {
            SyncDetails.Children.Add(new TextBlock { Text = $"Problems reported ({issues.Count})", Margin = new Thickness(0, 6, 0, 0), Style = (Style)Application.Current.Resources["BodyStrongTextBlockStyle"] });
            foreach (var issue in issues.Reverse().Take(8))
            {
                SyncDetails.Children.Add(new TextBlock
                {
                    Text = $"• {IssueTitle(issue.Kind)}: {issue.Message}",
                    TextWrapping = TextWrapping.Wrap,
                    Foreground = secondary,
                    FontSize = 12,
                });
            }
        }

        var buttons = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8, Margin = new Thickness(0, 8, 0, 0) };
        var now = new Button { Content = "Sync now" };
        now.Click += (_, _) =>
        {
            if (!client.Sync.IsRunning)
            {
                client.Sync.Start();
            }

            client.Sync.RequestSync();
        };
        buttons.Children.Add(now);
        if (s.State == SyncState.AuthRequired)
        {
            var signIn = new Button { Content = "Sign in again", Style = (Style)Application.Current.Resources["AccentButtonStyle"] };
            signIn.Click += async (_, _) =>
            {
                SyncFlyout.Hide();
                await PromptSignInAgainAsync();
            };
            buttons.Children.Add(signIn);
        }

        SyncDetails.Children.Add(buttons);
    }

    private static string IssueTitle(SyncIssueKind kind) => kind switch
    {
        SyncIssueKind.BlobRejected => "Data that could not be decrypted was skipped",
        SyncIssueKind.UpdateRejected => "A damaged change was skipped",
        SyncIssueKind.NotebookKeyRejected => "A notebook cannot be opened",
        SyncIssueKind.SnapshotTooLarge => "A document is too large to compact",
        SyncIssueKind.EditsDropped => "Edits were dropped",
        _ => kind.ToString(),
    };

    /// <summary>The lines of the sync details panel (self-test).</summary>
    public IReadOnlyList<string> SyncDetailLines()
    {
        BuildSyncDetails();
        var lines = new List<string>();
        foreach (var child in SyncDetails.Children)
        {
            if (child is TextBlock t)
            {
                lines.Add(t.Text);
            }
            else if (child is Grid g)
            {
                lines.Add(string.Join(": ", g.Children.OfType<TextBlock>().Select(x => x.Text)));
            }
        }

        return lines;
    }

    /// <summary>Opens the sync details flyout (screenshots).</summary>
    public void ShowSyncFlyout() => SyncFlyout.ShowAt(SyncButton);

    public void HideSyncFlyout() => SyncFlyout.Hide();

    /// <summary>Asks for the password until the server accepts it or the user gives up.</summary>
    public async Task PromptSignInAgainAsync()
    {
        string? error = null;
        while (Session.Client?.State == ClientState.Unlocked)
        {
            var password = await PromptPasswordAsync(
                "Sign in again",
                (error is null ? "" : error + "\n\n") + "Enter your master password. If you changed it on another device, enter the new one.",
                "Sign in");
            if (password is null)
            {
                return;
            }

            error = await SignInAgainAsync(password);
            if (error is null)
            {
                return;
            }
        }
    }

    /// <summary>Signs in again after the server refused the session. Returns null on success, else a message.</summary>
    public async Task<string?> SignInAgainAsync(string password)
    {
        try
        {
            await Session.Client!.SignInAgainAsync(password);
            UpdateSyncStatus();
            return null;
        }
        catch (WrongCredentialsException)
        {
            return "That password is not correct.";
        }
        catch (Exception e)
        {
            return SetupView.Describe(e);
        }
    }

    // ---- search --------------------------------------------------------------------------------------------

    public void FocusSearch()
    {
        if (SearchBox.Visibility == Visibility.Visible)
        {
            SearchBox.Focus(FocusState.Keyboard);
        }
    }

    private async Task UpdateSuggestionsAsync()
    {
        var main = Main;
        var query = SearchBox.Text;
        if (main is null || string.IsNullOrWhiteSpace(query))
        {
            SearchBox.ItemsSource = null;
            return;
        }

        var hits = await main.SearchAsync(query);
        if (!ReferenceEquals(main, Main) || SearchBox.Text != query)
        {
            return; // locked or typed on meanwhile
        }

        var secondary = (Brush)Application.Current.Resources["TextFillColorSecondaryBrush"];
        var items = new List<FrameworkElement>();
        foreach (var hit in hits)
        {
            var panel = new StackPanel { Tag = hit, Padding = new Thickness(0, 4, 0, 4) };
            panel.Children.Add(new TextBlock { Text = hit.Entry.Title, TextTrimming = TextTrimming.CharacterEllipsis });
            panel.Children.Add(new TextBlock
            {
                Text = $"{hit.Entry.NotebookTitle} › {hit.Entry.SectionTitle}" + (hit.Snippet.Length > 0 ? "  —  " + hit.Snippet : ""),
                Foreground = secondary,
                FontSize = 12,
                TextTrimming = TextTrimming.CharacterEllipsis,
            });
            items.Add(panel);
        }

        if (items.Count == 0)
        {
            items.Add(new TextBlock { Text = "No pages found", Foreground = secondary });
        }

        SearchBox.ItemsSource = items;
    }

    private void OpenHit(SearchHit? hit)
    {
        if (hit is null || Main is null)
        {
            return;
        }

        SearchBox.Text = "";
        SearchBox.ItemsSource = null;
        Main.Navigate(hit.Entry.NotebookId, hit.Entry.SectionId, hit.Entry.PageId);
    }

    // ---- dialogs -------------------------------------------------------------------------------------------

    /// <summary>Shows a dialog over the window. Only one is open at a time; locking closes it.</summary>
    public async Task<ContentDialogResult> ShowDialogAsync(ContentDialog dialog)
    {
        _dialog?.Hide();
        dialog.XamlRoot = Root.XamlRoot;
        dialog.RequestedTheme = Root.ActualTheme;
        _dialog = dialog;
        try
        {
            return await dialog.ShowAsync();
        }
        finally
        {
            if (ReferenceEquals(_dialog, dialog))
            {
                _dialog = null;
            }
        }
    }

    /// <summary>Asks for a short text. Returns it trimmed, or null when cancelled or left empty.</summary>
    public async Task<string?> PromptAsync(string title, string label, string initial, string ok)
    {
        var box = new TextBox { Header = label, Text = initial, MaxLength = 200, Width = 320 };
        box.SelectAll();
        var dialog = new ContentDialog { Title = title, Content = box, PrimaryButtonText = ok, CloseButtonText = "Cancel", DefaultButton = ContentDialogButton.Primary };
        box.KeyDown += (_, e) =>
        {
            if (e.Key == Windows.System.VirtualKey.Enter)
            {
                e.Handled = true;
                _accepted = true;
                dialog.Hide();
            }
        };
        _accepted = false;
        var result = await ShowDialogAsync(dialog);
        var accepted = result == ContentDialogResult.Primary || _accepted;
        _accepted = false;
        var text = box.Text.Trim();
        return accepted && text.Length > 0 ? text : null;
    }

    private bool _accepted;

    /// <summary>Asks for the master password. Returns null when cancelled.</summary>
    public async Task<string?> PromptPasswordAsync(string title, string message, string ok)
    {
        var box = new PasswordBox { Header = "Master password", Width = 320 };
        var panel = new StackPanel { Spacing = 10, Width = 340 };
        panel.Children.Add(new TextBlock { Text = message, TextWrapping = TextWrapping.Wrap });
        panel.Children.Add(box);
        var dialog = new ContentDialog { Title = title, Content = panel, PrimaryButtonText = ok, CloseButtonText = "Cancel", DefaultButton = ContentDialogButton.Primary };
        box.KeyDown += (_, e) =>
        {
            if (e.Key == Windows.System.VirtualKey.Enter)
            {
                e.Handled = true;
                _accepted = true;
                dialog.Hide();
            }
        };
        _accepted = false;
        var result = await ShowDialogAsync(dialog);
        var accepted = result == ContentDialogResult.Primary || _accepted;
        _accepted = false;
        var password = box.Password;
        box.Password = "";
        return accepted && password.Length > 0 ? password : null;
    }

    public async Task<bool> ConfirmAsync(string title, string message, string ok, bool destructive = true)
    {
        var dialog = new ContentDialog
        {
            Title = title,
            Content = new TextBlock { Text = message, TextWrapping = TextWrapping.Wrap, MaxWidth = 420 },
            PrimaryButtonText = ok,
            CloseButtonText = "Cancel",
            DefaultButton = destructive ? ContentDialogButton.Close : ContentDialogButton.Primary,
        };
        return await ShowDialogAsync(dialog) == ContentDialogResult.Primary;
    }
}
