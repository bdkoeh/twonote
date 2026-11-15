using System.IO.Pipes;
using System.Text;
using System.Text.Json;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using TwoNote.App.Editor;
using TwoNote.Core;
using TwoNote.Core.Sync;

namespace TwoNote.App.SelfTest;

/// <summary>
/// Drives one running app window for the self-test: the same calls the buttons, menus and shortcuts make, plus
/// read-outs of what the window shows. Used directly by the test process and, through a pipe, to drive a
/// second instance running under another profile.
/// </summary>
internal sealed class Automation(MainWindow window)
{
    private AppSession Session => window.Session;

    private TwoNoteClient Client => Session.Client ?? throw new InvalidOperationException("no client");

    private Views.MainView Main => window.Main ?? throw new InvalidOperationException("the main view is not showing");

    private RichEditBinding Binding => Main.Binding ?? throw new InvalidOperationException("no page is open");

    public static async Task<bool> WaitUntilAsync(Func<bool> condition, int timeoutMs = 15000)
    {
        var until = Environment.TickCount64 + timeoutMs;
        while (!condition())
        {
            if (Environment.TickCount64 > until)
            {
                return false;
            }

            await Task.Delay(40);
        }

        return true;
    }

    public static async Task<bool> WaitUntilAsync(Func<Task<bool>> condition, int timeoutMs = 15000)
    {
        var until = Environment.TickCount64 + timeoutMs;
        while (!await condition())
        {
            if (Environment.TickCount64 > until)
            {
                return false;
            }

            await Task.Delay(60);
        }

        return true;
    }

    /// <summary>Which view fills the window.</summary>
    public string View =>
        window.Settings is not null ? "settings"
        : window.Main is not null ? "main"
        : window.Unlock is not null ? "unlock"
        : window.Setup is { } s ? "setup:" + s.Step : "none";

    /// <summary>Every piece of text the window currently shows, for "nothing decrypted is left on screen".</summary>
    public string VisibleText()
    {
        var sb = new StringBuilder();
        void Walk(DependencyObject node)
        {
            switch (node)
            {
                case TextBlock t: sb.Append(t.Text).Append('\n'); break;
                case TextBox t: sb.Append(t.Text).Append('\n'); break;
                case PasswordBox: break;
                case RichEditBox r:
                    r.Document.GetText(TextGetOptions.None, out var text);
                    sb.Append(text).Append('\n');
                    break;
                case AutoSuggestBox a: sb.Append(a.Text).Append('\n'); break;
            }

            var count = VisualTreeHelper.GetChildrenCount(node);
            for (var i = 0; i < count; i++)
            {
                Walk(VisualTreeHelper.GetChild(node, i));
            }
        }

        Walk(window.RootElement);
        foreach (var popup in VisualTreeHelper.GetOpenPopupsForXamlRoot(window.RootElement.XamlRoot))
        {
            if (popup.Child is not null)
            {
                Walk(popup.Child);
            }
        }

        return sb.ToString();
    }

    /// <summary>Titles of every notebook with its sections and their pages, in display order.</summary>
    public string TreeDump()
    {
        var sb = new StringBuilder();
        var notebooks = Client.NotebookIds.Select(Client.OpenNotebook).OrderBy(n => n.Title, StringComparer.Ordinal).ThenBy(n => n.NotebookId, StringComparer.Ordinal);
        foreach (var tree in notebooks)
        {
            sb.Append("# ").Append(tree.Title).Append('\n');
            foreach (var section in tree.GetSections())
            {
                sb.Append("  [").Append(section.Title).Append("]\n");
                foreach (var page in tree.GetPages(section.Id))
                {
                    sb.Append("    - ").Append(page.Title).Append('\n');
                }
            }
        }

        return sb.ToString();
    }

    public string PageDump() => RichModel.Dump(RichEditBinding.ReadCells(Main.Page ?? throw new InvalidOperationException("no page is open")), effectiveBlocks: false);

    public bool IsSynced()
    {
        if (Session.Client is not { State: ClientState.Unlocked } client)
        {
            return false;
        }

        var s = client.Sync.Status;
        return s is { Running: true, State: SyncState.Idle, PendingUpdates: 0, LastSyncedAt: not null } && s.Cursor >= s.Head;
    }

    /// <summary>Runs one command and returns its result as text. Unknown commands and failures throw.</summary>
    public async Task<string> ExecuteAsync(string command, params string[] a)
    {
        switch (command)
        {
            case "view": return View;
            case "connect": return (await window.Setup!.ConnectAsync(a[0])).ToString();
            case "enrol":
            {
                var setup = window.Setup!;
                var ok = await setup.EnrolAsync(a[0], a[1], a[2], a[3]);
                return ok ? "ok" : "error: " + setup.Error;
            }

            case "unlock":
            {
                var unlock = window.Unlock!;
                var ok = await unlock.UnlockAsync(a[0]);
                return ok ? "ok" : "error: " + unlock.Error;
            }

            case "lock": await window.LockAsync(); return View;
            case "signout": await window.SignOutAsync(); return View;
            case "signin": return await window.SignInAgainAsync(a[0]) ?? "ok";
            case "wait-synced": return (await WaitUntilAsync(IsSynced, int.Parse(a[0]))).ToString();
            case "wait-state":
            {
                var want = Enum.Parse<SyncState>(a[0]);
                return (await WaitUntilAsync(() => Session.Client is { State: ClientState.Unlocked } c && c.Sync.Status.State == want, int.Parse(a[1]))).ToString();
            }

            case "status": return window.SyncStatusText;
            case "status-lines": return string.Join("\n", window.SyncDetailLines());
            case "pending": return Client.Sync.Status.PendingUpdates.ToString();
            case "wait-live": return (await WaitUntilAsync(() => Session.Client is { State: ClientState.Unlocked } c && c.Sync.Status.WebSocketConnected, int.Parse(a[0]))).ToString();
            case "auth-bar": return Main.AuthBarOpen.ToString();
            case "tree": return TreeDump();
            case "dump": return PageDump();
            case "verify": return Main.Binding is { } b ? b.Verify() ?? "ok" : "no page";
            case "text": return Binding.Shadow.Text;
            case "title": return Main.TitleText;
            case "toolbar": return Main.ToolbarState;
            case "session-token": return Session.Secrets.Get(SecretNames.SessionToken) ?? "";
            case "key":
            {
                // "ctrl+shift+X": what the editor's key handler does with a key (the handler itself, not real input).
                var parts = a[0].Split('+');
                var name = parts[^1];
                var key = name switch
                {
                    "." => (Windows.System.VirtualKey)190,
                    "/" => (Windows.System.VirtualKey)191,
                    "=" => (Windows.System.VirtualKey)187,
                    _ when name.Length == 1 && char.IsDigit(name[0]) => Windows.System.VirtualKey.Number0 + (name[0] - '0'),
                    _ => Enum.Parse<Windows.System.VirtualKey>(name, ignoreCase: true),
                };
                bool Has(string m) => parts[..^1].Contains(m, StringComparer.OrdinalIgnoreCase);
                return Main.HandleEditorKey(key, Has("ctrl"), Has("shift"), Has("alt")).ToString();
            }
            case "notebook": return Main.NotebookTitleText;
            case "sections": return string.Join("|", Main.SectionTitles);
            case "pages": return string.Join("|", Main.PageTitles);
            case "selected": return $"{Main.SelectedSectionTitle}|{Main.SelectedPageTitle}";
            case "ids": return $"{Main.NotebookId}|{Main.SectionId}|{Main.PageId}";
            case "visible-text": return VisibleText();
            case "counters": return $"resets={Binding.FullResets} selection={Binding.SelectionRestores} local={Binding.LocalTransactions} remote={Binding.RemoteDeltas}";
            case "open":
                Main.Navigate(a[0], a[1], a[2]);
                return $"{Main.NotebookId}|{Main.SectionId}|{Main.PageId}";
            case "open-by-title":
            {
                // "notebook/section/page" by titles (first match).
                var parts = a[0].Split('/');
                var tree = Client.NotebookIds.Select(Client.OpenNotebook).First(n => n.Title == parts[0]);
                var section = tree.GetSections().First(s => s.Title == parts[1]);
                var page = tree.GetPages(section.Id).First(p => p.Title == parts[2]);
                Main.Navigate(tree.NotebookId, section.Id, page.Id);
                return $"{Main.NotebookId}|{Main.SectionId}|{Main.PageId}";
            }

            case "type":
            {
                var sel = Main.EditorBox.Document.Selection;
                var pos = int.Parse(a[0]);
                if (pos < 0)
                {
                    pos = Binding.Shadow.Length - 1; // -1: at the end of the text
                }

                sel.SetRange(pos, pos);
                sel.TypeText(a[1].Replace('\n', '\r'));
                return "ok";
            }

            case "type-at-caret":
                Main.EditorBox.Document.Selection.TypeText(a[0].Replace('\n', '\r'));
                return "ok";
            case "type-slowly":
            {
                // One character per turn of the message loop, at the caret - like a person typing while remote edits arrive.
                foreach (var ch in a[0])
                {
                    Main.EditorBox.Document.Selection.TypeText(ch == '\n' ? "\r" : ch.ToString());
                    await Task.Delay(int.Parse(a[1]));
                }

                return "ok";
            }

            case "select":
                Main.EditorBox.Document.Selection.SetRange(int.Parse(a[0]), int.Parse(a[1]));
                return "ok";
            case "select-text":
            {
                var at = Binding.Shadow.Text.IndexOf(a[0], StringComparison.Ordinal);
                if (at < 0)
                {
                    throw new InvalidOperationException("text not found in the page");
                }

                var start = a.Length > 1 && a[1] == "after" ? at + a[0].Length : at;
                var end = a.Length > 1 && a[1] is "after" or "before" ? start : at + a[0].Length;
                Main.EditorBox.Document.Selection.SetRange(start, end);
                return $"{start},{end}";
            }

            case "delete":
                Main.EditorBox.Document.Selection.SetRange(int.Parse(a[0]), int.Parse(a[1]));
                Main.EditorBox.Document.Selection.SetText(TextSetOptions.None, "");
                return "ok";
            case "caret":
            {
                var (s, e) = Binding.Selection;
                return $"{s},{e}";
            }

            case "after-caret":
            {
                var (_, e) = Binding.Selection;
                var text = Binding.Shadow.Text;
                return text.Substring(e, Math.Min(int.Parse(a[0]), text.Length - e));
            }

            case "before-caret":
            {
                var (s, _) = Binding.Selection;
                var n = Math.Min(int.Parse(a[0]), s);
                return Binding.Shadow.Text.Substring(s - n, n);
            }

            case "run": Main.Run(a[0]); return "ok";
            case "toggle-todo-click":
            {
                var at = Binding.Shadow.Text.IndexOf(a[0], StringComparison.Ordinal);
                return Binding.TryToggleTodoAt(Binding.MarkerPoint(at)).ToString();
            }

            case "set-link": Main.SetLink(int.Parse(a[0]), int.Parse(a[1]), a[2].Length == 0 ? null : a[2]); return "ok";
            case "insert-link": Main.InsertLink(a[0], a[1]); return "ok";
            case "paste": await Main.PasteAsync(a.Length > 0 && a[0] == "plain"); return "ok";
            case "set-title": Main.SetTitle(a[0]); return "ok";
            case "add-notebook": return Main.AddNotebook(a[0]) ?? "";
            case "rename-notebook": Main.RenameNotebook(a[0]); return "ok";
            case "select-notebook": Main.SelectNotebook(NotebookId(a[0])); return "ok";
            case "add-section": return Main.AddSection(a[0]) ?? "";
            case "rename-section": Main.RenameSection(SectionId(a[0]), a[1]); return "ok";
            case "delete-section": Main.DeleteSection(SectionId(a[0])); return "ok";
            case "move-section": Main.Move(SectionId(a[0]), int.Parse(a[1]), section: true); return "ok";
            case "select-section": Main.SelectSection(SectionId(a[0])); return "ok";
            case "add-page": return Main.AddPage(a[0]) ?? "";
            case "rename-page": Main.RenamePage(PageId(a[0]), a[1]); return "ok";
            case "delete-page": Main.DeletePage(PageId(a[0])); return "ok";
            case "move-page": Main.Move(PageId(a[0]), int.Parse(a[1]), section: false); return "ok";
            case "move-page-to": Main.MovePageToSection(PageId(a[0]), SectionId(a[1])); return "ok";
            case "select-page": Main.SelectPage(PageId(a[0])); return "ok";
            case "search":
            {
                Main.InvalidateIndex();
                var hits = await Main.SearchAsync(a[0]);
                return string.Join("\n", hits.Select(h => $"{h.Entry.NotebookTitle}/{h.Entry.SectionTitle}/{h.Entry.Title}|{h.Entry.NotebookId}|{h.Entry.SectionId}|{h.Entry.PageId}|{h.Snippet}"));
            }

            case "open-settings": window.OpenSettings(); return View;
            case "close-settings": window.CloseSettings(); return View;
            case "devices":
            {
                var settings = window.Settings!;
                await settings.RefreshDevicesAsync();
                return string.Join("|", settings.Devices.OrderBy(d => d.Name, StringComparer.Ordinal).Select(d => d.Name + (d.Current ? "*" : "")));
            }

            case "revoke":
            {
                var settings = window.Settings!;
                await settings.RefreshDevicesAsync();
                return (await settings.RevokeAsync(settings.Devices.First(d => d.Name == a[0]).DeviceId)).ToString();
            }

            case "rename-device": return (await window.Settings!.RenameDeviceAsync(a[0], a[1])).ToString();
            case "change-password": return await window.Settings!.ChangePasswordAsync(a[0], a[1]) ?? "ok";
            case "reveal-key": return await window.Settings!.RevealSecretKeyAsync(a[0]) ?? "";
            case "save-kit": return (await window.Settings!.SaveKitAsync(a[0], a[1])).ToString();
            case "set-autolock": window.Settings!.SetAutoLock(int.Parse(a[0])); return "ok";
            case "theme":
                if (window.Settings is { } sv)
                {
                    sv.SetTheme(a[0]);
                }
                else
                {
                    Session.Settings.Theme = a[0];
                    window.ApplyTheme();
                }

                await Task.Delay(150);
                return "ok";
            case "idle-limit":
                window.IdleLimitOverride = a[0].Length == 0 ? null : TimeSpan.FromMilliseconds(int.Parse(a[0]));
                return "ok";
            case "sync-flyout":
                if (a[0] == "show")
                {
                    window.ShowSyncFlyout();
                }
                else
                {
                    window.HideSyncFlyout();
                }

                await Task.Delay(200);
                return "ok";
            case "shot":
                await Capture.WindowAsync(window.Hwnd, window.RootElement, a[0]);
                return "ok";
            case "focus-editor":
                Main.EditorBox.Focus(FocusState.Programmatic);
                await Task.Delay(100);
                return "ok";
            default: throw new ArgumentException($"unknown automation command '{command}'");
        }
    }

    private string NotebookId(string title) => Client.NotebookIds.First(id => Client.OpenNotebook(id).Title == title);

    private string SectionId(string title) => Main.Tree!.GetSections().First(s => s.Title == title).Id;

    private string PageId(string title) => Main.Tree!.GetAllPages().First(p => p.Title == title).Id;
}

/// <summary>The two ends of the pipe that lets one test process drive a second app instance.</summary>
internal static class AgentPipe
{
    private sealed record Request(string Command, string[] Args);

    private sealed record Response(bool Ok, string Value);

    /// <summary>Agent side: connect to the driver and execute commands until told to quit or the pipe closes.</summary>
    public static async Task ServeAsync(MainWindow window, string pipeName)
    {
        var automation = new Automation(window);
        await using var pipe = new NamedPipeClientStream(".", pipeName, PipeDirection.InOut, PipeOptions.Asynchronous);
        await pipe.ConnectAsync(20000);
        using var reader = new StreamReader(pipe, Encoding.UTF8, false, 4096, leaveOpen: true);
        await using var writer = new StreamWriter(pipe, new UTF8Encoding(false), 4096, leaveOpen: true) { AutoFlush = true };
        while (await reader.ReadLineAsync() is { } line)
        {
            var request = JsonSerializer.Deserialize<Request>(line)!;
            if (request.Command == "quit")
            {
                await writer.WriteLineAsync(JsonSerializer.Serialize(new Response(true, "bye")));
                break;
            }

            Response response;
            try
            {
                response = new Response(true, await automation.ExecuteAsync(request.Command, request.Args));
            }
            catch (Exception e)
            {
                response = new Response(false, $"{e.GetType().Name}: {e.Message}");
            }

            await writer.WriteLineAsync(JsonSerializer.Serialize(response));
        }
    }

    /// <summary>Driver side of the pipe.</summary>
    public sealed class Driver : IAsyncDisposable
    {
        private readonly NamedPipeServerStream _pipe;
        private readonly SemaphoreSlim _gate = new(1, 1);
        private StreamReader? _reader;
        private StreamWriter? _writer;

        public Driver(string pipeName) =>
            _pipe = new NamedPipeServerStream(pipeName, PipeDirection.InOut, 1, PipeTransmissionMode.Byte, PipeOptions.Asynchronous | PipeOptions.CurrentUserOnly);

        public async Task WaitForAgentAsync(int timeoutMs)
        {
            using var cts = new CancellationTokenSource(timeoutMs);
            await _pipe.WaitForConnectionAsync(cts.Token);
            _reader = new StreamReader(_pipe, Encoding.UTF8, false, 4096, leaveOpen: true);
            _writer = new StreamWriter(_pipe, new UTF8Encoding(false), 4096, leaveOpen: true) { AutoFlush = true };
        }

        /// <summary>Sends one command to the other instance and returns its result; a failure there throws here.</summary>
        public async Task<string> CallAsync(string command, params string[] args)
        {
            await _gate.WaitAsync();
            try
            {
                await _writer!.WriteLineAsync(JsonSerializer.Serialize(new Request(command, args)));
                var line = await _reader!.ReadLineAsync().WaitAsync(TimeSpan.FromSeconds(90)) ?? throw new IOException("the other instance closed the pipe");
                var response = JsonSerializer.Deserialize<Response>(line)!;
                return response.Ok ? response.Value : throw new InvalidOperationException($"other instance: {command} failed: {response.Value}");
            }
            finally
            {
                _gate.Release();
            }
        }

        public async ValueTask DisposeAsync()
        {
            _reader?.Dispose();
            if (_writer is not null)
            {
                try
                {
                    await _writer.DisposeAsync();
                }
                catch (IOException)
                {
                }
            }

            await _pipe.DisposeAsync();
        }
    }
}
