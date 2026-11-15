using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using TwoNote.App.Logic;
using TwoNote.Core;
using TwoNote.Core.Api;
using Windows.ApplicationModel.DataTransfer;
using Windows.Storage.Pickers;

namespace TwoNote.App.Views;

/// <summary>First run: server address, then "create account" or "add this device", then the Emergency Kit.</summary>
internal sealed partial class SetupView : UserControl
{
    private readonly MainWindow _shell;
    private readonly AppSession _session;
    private ServerStatus? _status;
    private string? _secretKey;
    private string? _kitPath;

    public SetupView(MainWindow shell, AppSession session)
    {
        _shell = shell;
        _session = session;
        InitializeComponent();
        CreateDevice.Text = EnrolDevice.Text = Environment.MachineName;
        StrengthHint.Text = PasswordStrength.Evaluate("").Hint;

        ConnectButton.Click += async (_, _) => await ConnectAsync(ServerUrlBox.Text);
        ServerUrlBox.KeyDown += async (_, e) => await OnEnterAsync(e, () => ConnectAsync(ServerUrlBox.Text));
        ChooseCreateButton.Click += (_, _) => Show(CreatePanel, CreateUsername);
        ChooseEnrolButton.Click += (_, _) => Show(EnrolPanel, EnrolUsername);
        ChangeServerButton.Click += async (_, _) => await ChangeServerAsync();
        CreateBackButton.Click += (_, _) => Show(ChoicePanel, ChooseCreateButton);
        EnrolBackButton.Click += (_, _) => Show(ChoicePanel, ChooseEnrolButton);
        CreatePassword.PasswordChanged += (_, _) => UpdateStrength();
        ServerUrlBox.TextChanged += (_, _) => ServerError.IsOpen = false;
        foreach (var box in new[] { CreateUsername, CreateDevice })
        {
            box.TextChanged += (_, _) => CreateError.IsOpen = false;
        }

        foreach (var box in new[] { CreatePassword, CreatePassword2 })
        {
            box.PasswordChanged += (_, _) => CreateError.IsOpen = false;
        }

        foreach (var box in new[] { EnrolUsername, EnrolSecretKey, EnrolDevice })
        {
            box.TextChanged += (_, _) => EnrolError.IsOpen = false;
        }

        EnrolPassword.PasswordChanged += (_, _) => EnrolError.IsOpen = false;
        CreateButton.Click += async (_, _) => await CreateAccountAsync(CreateUsername.Text, CreatePassword.Password, CreatePassword2.Password, CreateDevice.Text);
        CreateDevice.KeyDown += async (_, e) => await OnEnterAsync(e, () => CreateAccountAsync(CreateUsername.Text, CreatePassword.Password, CreatePassword2.Password, CreateDevice.Text));
        EnrolButton.Click += async (_, _) => await EnrolAsync(EnrolUsername.Text, EnrolPassword.Password, EnrolSecretKey.Text, EnrolDevice.Text);
        EnrolDevice.KeyDown += async (_, e) => await OnEnterAsync(e, () => EnrolAsync(EnrolUsername.Text, EnrolPassword.Password, EnrolSecretKey.Text, EnrolDevice.Text));
        CopyKeyButton.Click += (_, _) => CopySecretKey();
        SaveKitButton.Click += async (_, _) => await SaveKitAsync(null);
        OpenKitButton.Click += (_, _) => OpenKit();
        KitConfirm.Checked += (_, _) => KitContinueButton.IsEnabled = true;
        KitConfirm.Unchecked += (_, _) => KitContinueButton.IsEnabled = false;
        KitContinueButton.Click += async (_, _) => await ContinueAfterKitAsync();
        Loaded += (_, _) => (ServerPanel.Visibility == Visibility.Visible ? (Control)ServerUrlBox : ChooseCreateButton).Focus(FocusState.Programmatic);
    }

    /// <summary>Which step is showing: "server", "choice", "create", "enrol" or "kit".</summary>
    public string Step =>
        ServerPanel.Visibility == Visibility.Visible ? "server"
        : ChoicePanel.Visibility == Visibility.Visible ? "choice"
        : CreatePanel.Visibility == Visibility.Visible ? "create"
        : EnrolPanel.Visibility == Visibility.Visible ? "enrol" : "kit";

    /// <summary>The message of whichever error bar is open, or null.</summary>
    public string? Error =>
        new[] { ServerError, CreateError, EnrolError }.FirstOrDefault(b => b.IsOpen && b.Visibility == Visibility.Visible)?.Message;

    /// <summary>Where the Emergency Kit was saved, once it was.</summary>
    public string? KitPath => _kitPath;

    /// <summary>Starts at the account step for a server that is already configured.</summary>
    public void ShowChoiceFor(Uri serverUrl)
    {
        ServerUrlBox.Text = serverUrl.ToString().TrimEnd('/');
        ServerInfo.Text = $"Server: {ServerUrlBox.Text}";
        Show(ChoicePanel, ChooseCreateButton);
        _ = RefreshStatusAsync(serverUrl);
    }

    private async Task RefreshStatusAsync(Uri url)
    {
        var (status, _) = await AppSession.CheckServerAsync(url);
        if (status is not null)
        {
            ApplyStatus(url, status);
        }
    }

    private void ApplyStatus(Uri url, ServerStatus status)
    {
        _status = status;
        ServerInfo.Text = $"Connected to {url.ToString().TrimEnd('/')} (server version {status.Version}).";
        ChooseCreateButton.IsEnabled = status.RegistrationOpen;
        ChooseCreateNote.Text = status.RegistrationOpen
            ? "This is the first device. You get a Secret Key and an Emergency Kit."
            : "This server already has an account. Add this device to it instead.";
    }

    private void Show(FrameworkElement panel, Control? focus)
    {
        foreach (var p in new FrameworkElement[] { ServerPanel, ChoicePanel, CreatePanel, EnrolPanel, KitPanel })
        {
            p.Visibility = p == panel ? Visibility.Visible : Visibility.Collapsed;
        }

        ServerError.IsOpen = CreateError.IsOpen = EnrolError.IsOpen = false;
        focus?.Focus(FocusState.Programmatic);
    }

    private static async Task OnEnterAsync(KeyRoutedEventArgs e, Func<Task> action)
    {
        if (e.Key == Windows.System.VirtualKey.Enter)
        {
            e.Handled = true;
            await action();
        }
    }

    // ---- step 1 -----------------------------------------------------------------------------------------

    /// <summary>Validates the address against GET /api/v1/status and moves on to the account step.</summary>
    public async Task<bool> ConnectAsync(string address)
    {
        ServerError.IsOpen = false;
        if (!AppSession.TryParseServerUrl(address, out var url))
        {
            return Fail(ServerError, "Enter the address of your server, for example http://nas.local:8080.");
        }

        ConnectButton.IsEnabled = false;
        ServerProgress.IsActive = true;
        try
        {
            var (status, error) = await AppSession.CheckServerAsync(url);
            if (status is null)
            {
                return Fail(ServerError, error!);
            }

            _session.Settings.ServerUrl = url.ToString().TrimEnd('/');
            _session.Settings.Save();
            if (_session.Client is null)
            {
                _session.OpenClient(url);
            }

            ApplyStatus(url, status);
            Show(ChoicePanel, status.RegistrationOpen ? ChooseCreateButton : ChooseEnrolButton);
            return true;
        }
        finally
        {
            ConnectButton.IsEnabled = true;
            ServerProgress.IsActive = false;
        }
    }

    private async Task ChangeServerAsync()
    {
        await _session.CloseClientAsync();
        _session.Settings.ServerUrl = null;
        _session.Settings.Save();
        Show(ServerPanel, ServerUrlBox);
    }

    // ---- step 3a ----------------------------------------------------------------------------------------

    private void UpdateStrength()
    {
        var (score, hint) = PasswordStrength.Evaluate(CreatePassword.Password);
        StrengthBar.Value = score;
        StrengthBar.ShowError = score <= 1 && CreatePassword.Password.Length > 0;
        StrengthHint.Text = hint;
    }

    /// <summary>Registers the account and shows the Emergency Kit step.</summary>
    public async Task<bool> CreateAccountAsync(string username, string password, string repeat, string deviceName)
    {
        CreateError.IsOpen = false;
        if (string.IsNullOrWhiteSpace(username))
        {
            return Fail(CreateError, "Choose a username.");
        }

        if (password.Length < 8)
        {
            return Fail(CreateError, "The master password needs at least 8 characters. Longer is better.");
        }

        if (password != repeat)
        {
            return Fail(CreateError, "The two passwords are not the same.");
        }

        if (string.IsNullOrWhiteSpace(deviceName))
        {
            return Fail(CreateError, "Give this device a name, so you can recognise it in the device list.");
        }

        SetBusy(CreateButton, CreateProgress, true);
        try
        {
            _secretKey = await _session.Client!.RegisterAsync(username, password, deviceName);
        }
        catch (ApiException e) when (e.Code == ErrorCodes.RegistrationClosed)
        {
            ChooseCreateButton.IsEnabled = false;
            return Fail(CreateError, "This server already has an account. Go back and choose \"Add this device\".");
        }
        catch (Exception e)
        {
            return Fail(CreateError, Describe(e));
        }
        finally
        {
            SetBusy(CreateButton, CreateProgress, false);
        }

        CreatePassword.Password = CreatePassword2.Password = "";
        SecretKeyText.Text = _secretKey;
        KitStatus.Text = "Not saved yet.";
        Show(KitPanel, SaveKitButton);
        return true;
    }

    // ---- step 3b ----------------------------------------------------------------------------------------

    /// <summary>Adds this device to the existing account and opens the notebooks.</summary>
    public async Task<bool> EnrolAsync(string username, string password, string secretKey, string deviceName)
    {
        EnrolError.IsOpen = false;
        if (string.IsNullOrWhiteSpace(username) || password.Length == 0 || string.IsNullOrWhiteSpace(secretKey))
        {
            return Fail(EnrolError, "Enter your username, your master password and your Secret Key.");
        }

        if (string.IsNullOrWhiteSpace(deviceName))
        {
            return Fail(EnrolError, "Give this device a name, so you can recognise it in the device list.");
        }

        SetBusy(EnrolButton, EnrolProgress, true);
        try
        {
            await _session.Client!.EnrolAsync(username, password, secretKey, deviceName);
        }
        catch (FormatException)
        {
            return Fail(EnrolError, "That is not a complete Secret Key. It looks like T2-XXXXXX-XXXXXX-XXXXXX-XXXXXXXX.");
        }
        catch (Exception e)
        {
            return Fail(EnrolError, Describe(e));
        }
        finally
        {
            SetBusy(EnrolButton, EnrolProgress, false);
        }

        EnrolPassword.Password = "";
        EnrolSecretKey.Text = "";
        await _shell.EnterMainAsync(firstDevice: false);
        return true;
    }

    // ---- step 4 -----------------------------------------------------------------------------------------

    private void CopySecretKey()
    {
        if (_secretKey is null)
        {
            return;
        }

        var data = new DataPackage();
        data.SetText(_secretKey);
        Clipboard.SetContent(data);
        KitStatus.Text = "Secret Key copied. Remember to clear the clipboard after pasting it somewhere safe.";
    }

    /// <summary>Writes the Emergency Kit; asks where when <paramref name="path"/> is null.</summary>
    public async Task<bool> SaveKitAsync(string? path)
    {
        var account = _session.Client?.Account;
        if (_secretKey is null || account is null)
        {
            return false;
        }

        path ??= await PickKitPathAsync(_shell, account.Username);
        if (path is null)
        {
            return false;
        }

        try
        {
            await File.WriteAllTextAsync(path, EmergencyKit.BuildHtml(_session.Settings.ServerUrl ?? "", account.Username, _secretKey, DateTimeOffset.Now));
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            KitStatus.Text = "The file could not be written there. Choose another place.";
            return false;
        }

        _kitPath = path;
        KitStatus.Text = $"Saved to {path}. Open it and print it (Ctrl+P), then write your password on the printout.";
        OpenKitButton.IsEnabled = true;
        return true;
    }

    /// <summary>The save dialog for the kit. Returns null when cancelled.</summary>
    public static async Task<string?> PickKitPathAsync(MainWindow shell, string username)
    {
        var picker = new FileSavePicker
        {
            SuggestedStartLocation = PickerLocationId.DocumentsLibrary,
            SuggestedFileName = Path.GetFileNameWithoutExtension(EmergencyKit.SuggestedFileName(username)),
        };
        picker.FileTypeChoices.Add("Web page (prints on one sheet)", [".html"]);
        WinRT.Interop.InitializeWithWindow.Initialize(picker, shell.Hwnd);
        var file = await picker.PickSaveFileAsync();
        return file?.Path;
    }

    private void OpenKit()
    {
        if (_kitPath is not null)
        {
            OpenFile(_kitPath);
        }
    }

    /// <summary>Opens a file with whatever the user has set for it (the browser, for the kit).</summary>
    public static void OpenFile(string path)
    {
        try
        {
            System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo(path) { UseShellExecute = true });
        }
        catch (Exception)
        {
            // No handler for the file type; the user can open it from Explorer.
        }
    }

    /// <summary>Leaves the kit step (the checkbox must be ticked).</summary>
    public async Task<bool> ContinueAfterKitAsync()
    {
        if (KitConfirm.IsChecked != true)
        {
            return false;
        }

        _secretKey = null;
        SecretKeyText.Text = "";
        await _shell.EnterMainAsync(firstDevice: true);
        return true;
    }

    /// <summary>Fills in the visible form without submitting it (self-test screenshots).</summary>
    public void Fill(string? server = null, string? username = null, string? password = null, string? device = null)
    {
        if (server is not null)
        {
            ServerUrlBox.Text = server;
        }

        if (username is not null)
        {
            CreateUsername.Text = EnrolUsername.Text = username;
        }

        if (password is not null)
        {
            CreatePassword.Password = CreatePassword2.Password = EnrolPassword.Password = password;
        }

        if (device is not null)
        {
            CreateDevice.Text = EnrolDevice.Text = device;
        }
    }

    /// <summary>Shows the create-account or add-device form, as the two buttons of the choice step do.</summary>
    public void Choose(bool create) => Show(create ? CreatePanel : EnrolPanel, create ? CreateUsername : EnrolUsername);

    /// <summary>Presses "Create account" with what is in the form.</summary>
    public Task<bool> SubmitCreateAsync() => CreateAccountAsync(CreateUsername.Text, CreatePassword.Password, CreatePassword2.Password, CreateDevice.Text);

    /// <summary>The Secret Key the kit step is showing.</summary>
    public string SecretKeyShown => SecretKeyText.Text;

    public bool CanContinue => KitContinueButton.IsEnabled;

    public bool CreateOffered => ChooseCreateButton.IsEnabled;

    public string StrengthHintText => StrengthHint.Text;

    /// <summary>Ticks the confirmation box (self-test).</summary>
    public void ConfirmKit() => KitConfirm.IsChecked = true;

    // ---- helpers ----------------------------------------------------------------------------------------

    private static bool Fail(InfoBar bar, string message)
    {
        bar.Message = message;
        bar.IsOpen = true;
        return false;
    }

    private static void SetBusy(Button button, ProgressRing ring, bool busy)
    {
        button.IsEnabled = !busy;
        ring.IsActive = busy;
    }

    /// <summary>A message for the user that says what went wrong without echoing anything they typed.</summary>
    public static string Describe(Exception e) => e switch
    {
        WrongCredentialsException => "The username, the password or the Secret Key is not correct.",
        ServerUnreachableException => "The server could not be reached. Check your network or VPN and try again.",
        ApiException { Status: 429 } => "Too many attempts. Wait a minute and try again.",
        ApiException api => $"The server refused the request ({api.Status} {api.Code}).",
        ProtocolViolationException => "The server sent an answer this app does not accept.",
        ArgumentException => "The password contains characters that cannot be used.",
        _ => $"That did not work ({e.GetType().Name}).",
    };
}
