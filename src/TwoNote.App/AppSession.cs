using System.Text;
using Microsoft.UI.Dispatching;
using TwoNote.App.Editor;
using TwoNote.App.Logic;
using TwoNote.App.Secrets;
using TwoNote.Core;
using TwoNote.Core.Api;

namespace TwoNote.App;

/// <summary>Diagnostics for unattended runs (<c>--log file</c>). Without a path nothing is written anywhere.
/// Product code only ever logs states and exception types - never secrets, never note content.</summary>
internal static class AppLog
{
    private static readonly Lock Gate = new();

    public static string? Path { get; set; }

    public static void Line(string s)
    {
        if (Path is null)
        {
            return;
        }

        lock (Gate)
        {
            File.AppendAllText(Path, s + Environment.NewLine, Encoding.UTF8);
        }
    }
}

/// <summary>
/// Everything one running instance owns below the UI: the profile's paths and settings, the secret store and
/// the <see cref="TwoNoteClient"/> (once the server address is known).
/// </summary>
internal sealed class AppSession
{
    private readonly DispatcherQueue _ui;

    public AppSession(AppPaths paths, DispatcherQueue ui)
    {
        Paths = paths;
        _ui = ui;
        Directory.CreateDirectory(paths.Directory);
        Settings = AppSettings.Load(paths.SettingsPath);
        Secrets = SecretStores.Create(paths, Settings);
    }

    public AppPaths Paths { get; }

    public AppSettings Settings { get; private set; }

    public ISecretStore Secrets { get; private set; }

    /// <summary>The client, once a server address is known.</summary>
    public TwoNoteClient? Client { get; private set; }

    /// <summary>The editor binding that is showing a page right now, if any. Remote changes wait for it.</summary>
    public Func<RichEditBinding?>? ActiveBinding { get; set; }

    /// <summary>Turns what the user typed into a server address. Plain host names get http:// (LAN and VPN deployments).</summary>
    public static bool TryParseServerUrl(string? text, out Uri uri)
    {
        uri = null!;
        text = text?.Trim().TrimEnd('/') ?? "";
        if (text.Length == 0)
        {
            return false;
        }

        if (!text.Contains("://", StringComparison.Ordinal))
        {
            text = "http://" + text;
        }

        if (!Uri.TryCreate(text, UriKind.Absolute, out var parsed) || parsed.Scheme is not ("http" or "https") || parsed.Host.Length == 0
            || parsed.UserInfo.Length > 0 || parsed.Query.Length > 0 || parsed.Fragment.Length > 0)
        {
            return false;
        }

        uri = parsed;
        return true;
    }

    /// <summary>Asks the server who it is (GET /api/v1/status). Returns the status or a message for the user.</summary>
    public static async Task<(ServerStatus? Status, string? Error)> CheckServerAsync(Uri url)
    {
        try
        {
            using var api = new TwoNoteApi(url, null, TimeSpan.FromSeconds(8));
            var status = await api.GetStatusAsync();
            if (status is null || status.Protocol != 1)
            {
                return (null, "That server speaks a different protocol version than this app.");
            }

            return (status, null);
        }
        catch (ServerUnreachableException)
        {
            return (null, "The server could not be reached. Check the address and that you are on the right network or VPN.");
        }
        catch (Exception)
        {
            return (null, "Something answered at that address, but it does not look like a TwoNote server.");
        }
    }

    /// <summary>Opens the local database and creates the client for <paramref name="serverUrl"/>. No network access.</summary>
    public TwoNoteClient OpenClient(Uri serverUrl)
    {
        if (Client is not null)
        {
            throw new InvalidOperationException("A client is already open.");
        }

        Client = TwoNoteClient.Open(new ClientOptions
        {
            ServerUrl = serverUrl,
            DatabasePath = Paths.DatabasePath,
            SecretStore = Secrets,
            Dispatcher = DispatchAsync,

            // A LAN or VPN server is cheap to ask: notice an outage, and come back from one, within seconds
            // rather than up to a minute.
            PollInterval = TimeSpan.FromSeconds(20),
            MaxRetryDelay = TimeSpan.FromSeconds(10),
        });
        return Client;
    }

    /// <summary>Locks and closes the client.</summary>
    public async Task CloseClientAsync()
    {
        var client = Client;
        Client = null;
        if (client is not null)
        {
            await client.DisposeAsync();
        }
    }

    /// <summary>
    /// Signs this device out: revokes it on the server if that can be reached, then removes the local database,
    /// the settings and the secrets of this profile.
    /// </summary>
    public async Task SignOutAsync()
    {
        var client = Client;
        if (client is not null)
        {
            try
            {
                if (client.Account is { } account && client.Api.Token is not null)
                {
                    using var cts = new CancellationTokenSource(TimeSpan.FromSeconds(8));
                    await client.Api.DeleteDeviceAsync(account.DeviceId, cts.Token);
                }
            }
            catch (Exception)
            {
                // Offline or already revoked: the local wipe is what matters.
            }
        }

        await CloseClientAsync();
        SecretStores.Wipe(Paths);
        Paths.DeleteAll();
        Directory.CreateDirectory(Paths.Directory);
        Settings = AppSettings.Load(Paths.SettingsPath);
        Secrets = SecretStores.Create(Paths, Settings);
    }

    /// <summary>
    /// Runs an action of the sync engine (applying remote changes to open documents) on the UI thread. If an
    /// editor is showing a page it first reconciles what the user typed; while it is in the middle of its own
    /// work or of an IME composition, the remote changes wait.
    /// </summary>
    private Task DispatchAsync(Action action)
    {
        var done = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);

        void Attempt()
        {
            try
            {
                var ready = true;
                try
                {
                    ready = ActiveBinding?.Invoke()?.PrepareForExternalChange() ?? true;
                }
                catch (Exception e)
                {
                    // The editor could not reconcile (its page is being closed). Remote changes must still be
                    // applied; the editor reloads from the document if it turns out to disagree.
                    AppLog.Line($"editor not ready for a remote change: {e.GetType().Name}");
                }

                if (!ready)
                {
                    var timer = _ui.CreateTimer();
                    timer.Interval = TimeSpan.FromMilliseconds(40);
                    timer.IsRepeating = false;
                    timer.Tick += (t, _) =>
                    {
                        t.Stop();
                        Attempt();
                    };
                    timer.Start();
                    return;
                }

                action();
                done.TrySetResult();
            }
            catch (Exception e)
            {
                done.TrySetException(e);
            }
        }

        if (_ui.HasThreadAccess)
        {
            Attempt();
        }
        else if (!_ui.TryEnqueue(Attempt))
        {
            done.TrySetException(new InvalidOperationException("The window is closing."));
        }

        return done.Task;
    }
}
