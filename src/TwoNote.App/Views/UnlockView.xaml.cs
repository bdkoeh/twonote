using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using TwoNote.Core;

namespace TwoNote.App.Views;

/// <summary>The lock screen: password only. Works with the server unreachable.</summary>
internal sealed partial class UnlockView : UserControl
{
    private readonly MainWindow _shell;
    private readonly AppSession _session;

    public UnlockView(MainWindow shell, AppSession session)
    {
        _shell = shell;
        _session = session;
        InitializeComponent();
        var account = session.Client?.Account;
        AccountText.Text = account is null ? "" : $"{account.Username} on {session.Settings.ServerUrl}";
        UnlockButton.Click += async (_, _) => await UnlockAsync(PasswordInput.Password);
        PasswordInput.KeyDown += async (_, e) =>
        {
            if (e.Key == Windows.System.VirtualKey.Enter)
            {
                e.Handled = true;
                await UnlockAsync(PasswordInput.Password);
            }
        };
        RemoveButton.Click += async (_, _) => await _shell.ConfirmSignOutAsync();
        Loaded += (_, _) => PasswordInput.Focus(FocusState.Programmatic);
    }

    /// <summary>
    /// A password that does not open the local key may still be right: after a password change on another
    /// device only the server has the matching key. Signing in fetches it. Costs nothing when offline.
    /// </summary>
    private async Task<bool> TrySignInAsync(string password)
    {
        try
        {
            using var cts = new CancellationTokenSource(TimeSpan.FromSeconds(10));
            await _session.Client!.SignInAgainAsync(password, cts.Token);
            return true;
        }
        catch (Exception)
        {
            return false;
        }
    }

    /// <summary>The error being shown, or null.</summary>
    public string? Error => ErrorBar.IsOpen ? ErrorBar.Message : null;

    /// <summary>Unlocks from local state and opens the notebooks.</summary>
    public async Task<bool> UnlockAsync(string password)
    {
        if (password.Length == 0 || !UnlockButton.IsEnabled)
        {
            return false;
        }

        ErrorBar.IsOpen = false;
        UnlockButton.IsEnabled = false;
        Progress.IsActive = true;
        try
        {
            await _session.Client!.UnlockAsync(password);
        }
        catch (WrongCredentialsException)
        {
            // If the password was changed on another device while this one was locked, the server accepts it
            // and hands out the matching key; otherwise it really is wrong.
            if (!await TrySignInAsync(password))
            {
                ErrorBar.Message = "That password is not correct.";
                ErrorBar.IsOpen = true;
                PasswordInput.Password = "";
                PasswordInput.Focus(FocusState.Programmatic);
                return false;
            }
        }
        catch (Exception e)
        {
            ErrorBar.Message = e is InvalidOperationException
                ? "The Secret Key of this device is missing from the Windows credential store. Remove the account from this device and add it again."
                : SetupView.Describe(e);
            ErrorBar.IsOpen = true;
            return false;
        }
        finally
        {
            UnlockButton.IsEnabled = true;
            Progress.IsActive = false;
        }

        PasswordInput.Password = "";
        await _shell.EnterMainAsync(firstDevice: false);
        return true;
    }
}
