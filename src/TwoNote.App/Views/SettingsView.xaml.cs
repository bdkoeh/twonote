using System.Globalization;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using TwoNote.App.Logic;
using TwoNote.Core;
using TwoNote.Core.Api;
using Windows.ApplicationModel.DataTransfer;

namespace TwoNote.App.Views;

/// <summary>Settings: account, devices, security, appearance, sign out.</summary>
internal sealed partial class SettingsView : UserControl
{
    private static readonly (int Minutes, string Label)[] AutoLockChoices =
    [
        (1, "1 minute"), (5, "5 minutes"), (10, "10 minutes"), (15, "15 minutes"), (30, "30 minutes"), (60, "1 hour"), (0, "Never"),
    ];

    private readonly MainWindow _shell;
    private readonly AppSession _session;
    private bool _loading = true;

    public SettingsView(MainWindow shell, AppSession session)
    {
        _shell = shell;
        _session = session;
        InitializeComponent();

        var client = session.Client!;
        var account = client.Account!;
        ServerText.Text = session.Settings.ServerUrl ?? "";
        UserText.Text = account.Username;
        DeviceNameText.Text = account.DeviceName;
        AboutText.Text = $"TwoNote {typeof(SettingsView).Assembly.GetName().Version?.ToString(3)}"
            + (session.Paths.Profile is null ? "" : $" · profile \"{session.Paths.Profile}\"")
            + $" · secrets in {(session.Settings.SecretStore == Secrets.SecretStores.Vault ? "Windows Credential Locker" : "a DPAPI-protected file")}";

        foreach (var (minutes, label) in AutoLockChoices)
        {
            AutoLockBox.Items.Add(new ComboBoxItem { Content = label, Tag = minutes });
        }

        if (AutoLockChoices.All(c => c.Minutes != session.Settings.AutoLockMinutes))
        {
            AutoLockBox.Items.Add(new ComboBoxItem { Content = $"{session.Settings.AutoLockMinutes} minutes", Tag = session.Settings.AutoLockMinutes });
        }

        AutoLockBox.SelectedItem = AutoLockBox.Items.OfType<ComboBoxItem>().First(i => (int)i.Tag == session.Settings.AutoLockMinutes);
        ThemeBox.SelectedItem = ThemeBox.Items.OfType<ComboBoxItem>().First(i => (string)i.Tag == session.Settings.Theme);
        _loading = false;

        BackButton.Click += (_, _) => _shell.CloseSettings();
        AutoLockBox.SelectionChanged += (_, _) =>
        {
            if (!_loading && AutoLockBox.SelectedItem is ComboBoxItem { Tag: int minutes })
            {
                SetAutoLock(minutes);
            }
        };
        foreach (var level in MainWindow.ZoomLevels)
        {
            ZoomBox.Items.Add(new ComboBoxItem { Content = $"{level}%", Tag = level });
        }

        ZoomBox.SelectedItem = ZoomBox.Items.OfType<ComboBoxItem>().FirstOrDefault(i => (int)i.Tag == shell.ZoomPercent);
        ZoomBox.SelectionChanged += (_, _) =>
        {
            if (!_loading && ZoomBox.SelectedItem is ComboBoxItem { Tag: int percent })
            {
                _shell.SetZoom(percent);
            }
        };
        ThemeBox.SelectionChanged += (_, _) =>
        {
            if (!_loading && ThemeBox.SelectedItem is ComboBoxItem { Tag: string theme })
            {
                SetTheme(theme);
            }
        };
        RefreshDevicesButton.Click += async (_, _) => await RefreshDevicesAsync();
        RenameDeviceButton.Click += async (_, _) => await RenameDeviceInteractiveAsync();
        ChangePasswordButton.Click += async (_, _) => await ChangePasswordInteractiveAsync();
        ShowKeyButton.Click += async (_, _) => await ShowKeyInteractiveAsync();
        SaveKitButton.Click += async (_, _) => await SaveKitInteractiveAsync();
        SignOutButton.Click += async (_, _) => await _shell.ConfirmSignOutAsync();
        KeyDown += (_, e) =>
        {
            if (e.Key == Windows.System.VirtualKey.Escape)
            {
                e.Handled = true;
                _shell.CloseSettings();
            }
        };
        Loaded += async (_, _) =>
        {
            BackButton.Focus(FocusState.Programmatic);
            await RefreshDevicesAsync();
        };
    }

    /// <summary>What the device list shows (self-test).</summary>
    public IReadOnlyList<DeviceInfo> Devices { get; private set; } = [];

    public string DevicesStatusText => DevicesStatus.Text;

    public string DeviceNameShown => DeviceNameText.Text;

    public string? SecurityMessage => SecurityInfo.IsOpen ? SecurityInfo.Message : null;

    // ---- simple settings -----------------------------------------------------------------------------------

    public void SetAutoLock(int minutes)
    {
        _session.Settings.AutoLockMinutes = Math.Clamp(minutes, 0, 24 * 60);
        _session.Settings.Save();
        _shell.NoteActivity();
        Show(AutoLockBox, i => i.Tag is int m && m == _session.Settings.AutoLockMinutes);
    }

    public void SetTheme(string theme)
    {
        _session.Settings.Theme = theme is "light" or "dark" ? theme : "system";
        _session.Settings.Save();
        _shell.ApplyTheme();
        Show(ThemeBox, i => (string)i.Tag == _session.Settings.Theme);
    }

    private void Show(ComboBox box, Func<ComboBoxItem, bool> match)
    {
        var item = box.Items.OfType<ComboBoxItem>().FirstOrDefault(match);
        if (item is not null && !ReferenceEquals(box.SelectedItem, item))
        {
            _loading = true;
            box.SelectedItem = item;
            _loading = false;
        }
    }

    // ---- devices -------------------------------------------------------------------------------------------

    public async Task RefreshDevicesAsync()
    {
        var client = _session.Client;
        if (client is null || client.State != ClientState.Unlocked)
        {
            return;
        }

        RefreshDevicesButton.IsEnabled = false;
        try
        {
            Devices = await client.Api.GetDevicesAsync();
            DevicesStatus.Text = "Devices that can open this account:";
        }
        catch (ServerUnreachableException)
        {
            Devices = [];
            DevicesStatus.Text = "The device list needs the server, which cannot be reached right now.";
        }
        catch (ApiException e) when (e.Status == 401)
        {
            Devices = [];
            DevicesStatus.Text = "This device has been signed out by the server. Sign in again to see the device list.";
        }
        catch (Exception e)
        {
            Devices = [];
            DevicesStatus.Text = SetupView.Describe(e);
        }
        finally
        {
            RefreshDevicesButton.IsEnabled = true;
        }

        DeviceList.Children.Clear();
        foreach (var device in Devices.OrderByDescending(d => d.Current).ThenBy(d => d.Name, StringComparer.CurrentCultureIgnoreCase))
        {
            var grid = new Grid { ColumnSpacing = 12 };
            grid.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
            grid.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            var text = new StackPanel();
            text.Children.Add(new TextBlock { Text = device.Name + (device.Current ? "  (this device)" : ""), TextTrimming = TextTrimming.CharacterEllipsis });
            text.Children.Add(new TextBlock
            {
                Text = $"Added {device.CreatedAt.ToLocalTime().ToString("d MMM yyyy", CultureInfo.CurrentCulture)} · last seen {device.LastSeenAt.ToLocalTime().ToString("d MMM yyyy HH:mm", CultureInfo.CurrentCulture)}",
                Style = (Style)Resources["Secondary"],
                FontSize = 12,
            });
            grid.Children.Add(text);
            if (!device.Current)
            {
                var revoke = new Button { Content = "Revoke", VerticalAlignment = VerticalAlignment.Center };
                Microsoft.UI.Xaml.Automation.AutomationProperties.SetName(revoke, "Revoke " + device.Name);
                revoke.Click += async (_, _) =>
                {
                    if (await _shell.ConfirmAsync("Revoke this device?", $"\"{device.Name}\" is signed out and can no longer sync. Notes already on it stay readable there until it is signed out or wiped; to shut it out completely, also change your password.", "Revoke"))
                    {
                        await RevokeAsync(device.DeviceId);
                    }
                };
                Grid.SetColumn(revoke, 1);
                grid.Children.Add(revoke);
            }

            DeviceList.Children.Add(grid);
        }
    }

    public async Task<bool> RevokeAsync(string deviceId)
    {
        try
        {
            await _session.Client!.Api.DeleteDeviceAsync(deviceId);
        }
        catch (Exception e)
        {
            DevicesStatus.Text = SetupView.Describe(e);
            return false;
        }

        await RefreshDevicesAsync();
        return true;
    }

    private async Task RenameDeviceInteractiveAsync()
    {
        var name = await _shell.PromptAsync("Rename this device", "Name", DeviceNameText.Text, "Next");
        if (name is null)
        {
            return;
        }

        var password = await _shell.PromptPasswordAsync("Rename this device", "The server renames a device when it signs in. Enter your master password.", "Rename");
        if (password is not null)
        {
            await RenameDeviceAsync(password, name);
        }
    }

    public async Task<bool> RenameDeviceAsync(string password, string name)
    {
        if (string.IsNullOrWhiteSpace(name))
        {
            return false;
        }

        try
        {
            await _session.Client!.RenameDeviceAsync(password, name);
        }
        catch (Exception e)
        {
            Info(InfoBarSeverity.Error, e is WrongCredentialsException ? "That password is not correct." : SetupView.Describe(e));
            return false;
        }

        DeviceNameText.Text = _session.Client!.Account!.DeviceName;
        Info(InfoBarSeverity.Success, "The device was renamed.");
        await RefreshDevicesAsync();
        return true;
    }

    // ---- security ------------------------------------------------------------------------------------------

    private void Info(InfoBarSeverity severity, string message)
    {
        SecurityInfo.Severity = severity;
        SecurityInfo.Message = message;
        SecurityInfo.IsOpen = true;
    }

    private async Task ChangePasswordInteractiveAsync()
    {
        var current = new PasswordBox { Header = "Current master password" };
        var next = new PasswordBox { Header = "New master password" };
        var repeat = new PasswordBox { Header = "Repeat new master password" };
        var bar = new ProgressBar { Minimum = 0, Maximum = 4 };
        var hint = new TextBlock { TextWrapping = TextWrapping.Wrap, FontSize = 12, Text = PasswordStrength.Evaluate("").Hint };
        var error = new TextBlock { TextWrapping = TextWrapping.Wrap, Foreground = (Microsoft.UI.Xaml.Media.Brush)Application.Current.Resources["SystemFillColorCriticalBrush"], Visibility = Visibility.Collapsed };
        next.PasswordChanged += (_, _) =>
        {
            var (score, text) = PasswordStrength.Evaluate(next.Password);
            bar.Value = score;
            hint.Text = text;
        };
        var panel = new StackPanel { Spacing = 8, Width = 340 };
        foreach (var child in new UIElement[] { current, next, bar, hint, repeat, error })
        {
            panel.Children.Add(child);
        }

        var dialog = new ContentDialog
        {
            Title = "Change master password",
            Content = panel,
            PrimaryButtonText = "Change password",
            CloseButtonText = "Cancel",
            DefaultButton = ContentDialogButton.Primary,
        };
        dialog.PrimaryButtonClick += async (_, args) =>
        {
            var deferral = args.GetDeferral();
            try
            {
                string? problem = null;
                if (next.Password.Length < 8)
                {
                    problem = "The new password needs at least 8 characters.";
                }
                else if (next.Password != repeat.Password)
                {
                    problem = "The two new passwords are not the same.";
                }
                else
                {
                    dialog.IsPrimaryButtonEnabled = false;
                    problem = await ChangePasswordAsync(current.Password, next.Password);
                    dialog.IsPrimaryButtonEnabled = true;
                }

                if (problem is not null)
                {
                    error.Text = problem;
                    error.Visibility = Visibility.Visible;
                    args.Cancel = true;
                }
            }
            finally
            {
                deferral.Complete();
            }
        };
        await _shell.ShowDialogAsync(dialog);
        current.Password = next.Password = repeat.Password = "";
    }

    /// <summary>Changes the master password. Returns null on success, otherwise what to tell the user.</summary>
    public async Task<string?> ChangePasswordAsync(string current, string next)
    {
        try
        {
            await _session.Client!.ChangePasswordAsync(current, next);
        }
        catch (WrongCredentialsException)
        {
            return "The current password is not correct.";
        }
        catch (Exception e)
        {
            return e is ServerUnreachableException
                ? "Changing the password needs the server, which cannot be reached right now."
                : SetupView.Describe(e);
        }

        Info(InfoBarSeverity.Success, "The password was changed. Your other devices will ask for the new password. Write the new password on your Emergency Kit.");
        return null;
    }

    /// <summary>The Secret Key, after the password was checked. Null when the password is wrong.</summary>
    public async Task<string?> RevealSecretKeyAsync(string password)
    {
        var client = _session.Client!;
        return await client.VerifyPasswordAsync(password) ? client.GetSecretKeyForDisplay() : null;
    }

    private async Task<string?> AskForKeyAsync(string title)
    {
        var password = await _shell.PromptPasswordAsync(title, "Enter your master password to continue.", "Continue");
        if (password is null)
        {
            return null;
        }

        var key = await RevealSecretKeyAsync(password);
        if (key is null)
        {
            Info(InfoBarSeverity.Error, "That password is not correct.");
        }

        return key;
    }

    private async Task ShowKeyInteractiveAsync()
    {
        if (await AskForKeyAsync("Show Secret Key") is not { } key)
        {
            return;
        }

        var text = new TextBlock { Text = key, FontFamily = new Microsoft.UI.Xaml.Media.FontFamily("Consolas"), FontSize = 18, IsTextSelectionEnabled = true, TextWrapping = TextWrapping.Wrap };
        var panel = new StackPanel { Spacing = 12, Width = 380 };
        panel.Children.Add(text);
        panel.Children.Add(new TextBlock
        {
            Text = "Anyone with this key and your password can read your notes. Close this window when you are done.",
            TextWrapping = TextWrapping.Wrap,
            Style = (Style)Resources["Secondary"],
        });
        var dialog = new ContentDialog { Title = "Your Secret Key", Content = panel, PrimaryButtonText = "Copy", CloseButtonText = "Close", DefaultButton = ContentDialogButton.Close };
        dialog.PrimaryButtonClick += (_, _) =>
        {
            var data = new DataPackage();
            data.SetText(key);
            Clipboard.SetContent(data);
        };
        await _shell.ShowDialogAsync(dialog);
        text.Text = "";
    }

    private async Task SaveKitInteractiveAsync()
    {
        if (await AskForKeyAsync("Save Emergency Kit") is not { } key)
        {
            return;
        }

        var path = await SetupView.PickKitPathAsync(_shell, _session.Client!.Account!.Username);
        if (path is not null && await WriteKitAsync(key, path))
        {
            if (await _shell.ConfirmAsync("Emergency Kit saved", $"Saved to {path}. Open it now to print it?", "Open", destructive: false))
            {
                SetupView.OpenFile(path);
            }
        }
    }

    /// <summary>Checks the password and writes the Emergency Kit to <paramref name="path"/> (self-test).</summary>
    public async Task<bool> SaveKitAsync(string password, string path) =>
        await RevealSecretKeyAsync(password) is { } key && await WriteKitAsync(key, path);

    private async Task<bool> WriteKitAsync(string key, string path)
    {
        try
        {
            await File.WriteAllTextAsync(path, EmergencyKit.BuildHtml(_session.Settings.ServerUrl ?? "", _session.Client!.Account!.Username, key, DateTimeOffset.Now));
            Info(InfoBarSeverity.Success, "The Emergency Kit was saved. Print it and write your password on the printout.");
            return true;
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            Info(InfoBarSeverity.Error, "The file could not be written there.");
            return false;
        }
    }
}
