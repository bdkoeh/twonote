using System.Diagnostics;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;
using TwoNote.App.Editor;
using TwoNote.App.Logic;
using TwoNote.App.Secrets;
using TwoNote.App.Views;
using TwoNote.Core;
using Windows.ApplicationModel.DataTransfer;
using Windows.Storage.Streams;

namespace TwoNote.App.SelfTest;

/// <summary>Entry point of the unattended modes that run inside the real app window (<c>--selftest mode</c>).</summary>
internal static class SelfTestRunner
{
    public static async Task RunAsync(MainWindow window, AppOptions options)
    {
        if (options.SelfTest == "agent")
        {
            // A second instance, driven by the test process through a pipe.
            try
            {
                await AgentPipe.ServeAsync(window, options.Value("--pipe") ?? throw new ArgumentException("--pipe is required"));
            }
            catch (Exception e)
            {
                AppLog.Line($"agent stopped: {e.GetType().Name}: {e.Message}");
                Environment.ExitCode = 1;
            }

            await window.ShutdownAsync();
            return;
        }

        var checks = new Checks { Scenario = options.SelfTest!, Verbose = options.Has("--verbose") };
        var clock = Stopwatch.StartNew();
        try
        {
            var test = new E2ESelfTest(window, options, checks);
            switch (options.SelfTest)
            {
                case "first": await test.FirstRunAsync(); break;
                case "restart": await test.RestartAsync(); break;
                case "two": await test.TwoInstancesAsync(); break;
                default: checks.Check($"unknown self-test mode '{options.SelfTest}'", false); break;
            }
        }
        catch (Exception e)
        {
            checks.Check("the self-test ran to the end", false, e.ToString());
        }

        try
        {
            Clipboard.Clear();
        }
        catch (Exception)
        {
            // the clipboard is not ours to insist on
        }

        AppLog.Line($"SELFTEST RESULT: {(checks.Failures == 0 ? "PASS" : "FAIL")}  mode={options.SelfTest} checks={checks.Count} failures={checks.Failures} elapsed={clock.Elapsed.TotalSeconds:F1}s");
        Environment.ExitCode = checks.Failures == 0 ? 0 : 1;
        await window.ShutdownAsync();
    }
}

/// <summary>
/// Drives the real app end to end against a real server: first run, formatting through the editor, lock and
/// unlock, restart, and a second instance under another profile. Everything goes through the same view methods
/// the buttons call; assertions read the window and the documents back.
/// </summary>
internal sealed class E2ESelfTest(MainWindow window, AppOptions options, Checks t)
{
    private const string Username = "selftest-user";
    private const string Password = "correct horse 7 battery-staple Zq";
    private const string NewPassword = "Tr0ub4dor walks 9 quiet-rivers Xv";
    private const string DeviceA = "Selftest PC A";
    private const string DeviceB = "Selftest PC B";
    private const string ProfileB = "selftest-b";

    private readonly Automation _a = new(window);
    private readonly string _server = options.Value("--server") ?? "http://localhost:18480";
    private readonly string _out = options.Value("--out") ?? Path.GetTempPath();
    private readonly string? _shots = options.Value("--shots");
    private readonly List<string> _markers = [];

    private string StatePath => Path.Combine(_out, "e2e-state.json");

    private sealed record SavedState(string Ids, string Dump, string Tree, string[] Markers);

    private Task<string> A(string command, params string[] args) => _a.ExecuteAsync(command, args);

    /// <summary>Registers text that must never show up in a profile's files.</summary>
    private string M(string text)
    {
        foreach (Match word in Regex.Matches(text, "[A-Za-z0-9]{7,}"))
        {
            if (!_markers.Contains(word.Value))
            {
                _markers.Add(word.Value);
            }
        }

        return text;
    }

    private async Task ShotAsync(Func<string, string[], Task<string>> who, string name)
    {
        if (_shots is not null)
        {
            await who("shot", [Path.Combine(_shots, name)]);
        }
    }

    private Task ShotAsync(string name) => ShotAsync((c, a) => A(c, a), name);

    private async Task Section(string name, Func<Task> body)
    {
        var before = t.Failures;
        var count = t.Count;
        t.Scenario = name;
        try
        {
            await body();
        }
        catch (Exception e)
        {
            t.Check("section threw", false, e.ToString());
        }

        AppLog.Line($"{(t.Failures == before ? "PASS" : "FAIL")} {name}  ({t.Count - count} checks)");
    }

    private List<Cell> Cells() => RichEditBinding.ReadCells(window.Main!.Page!);

    private string Blocks() => string.Join(",", Cells().Where(c => c.Ch == '\n').Select(c => c.Block.ToString() is { Length: > 0 } s ? s : "p"));

    private string ControlBlocks() =>
        string.Join(",", window.Main!.Binding!.ReadControlCells().Where(c => c.Ch == '\n').Select(c => c.Block.ToString() is { Length: > 0 } s ? s : "p"));

    private InlineAttrs InlineOf(string word, int offset = 1)
    {
        var text = window.Main!.Page!.GetText();
        var at = text.IndexOf(word, StringComparison.Ordinal);
        return at < 0 ? throw new InvalidOperationException($"'{word}' is not in the page") : Cells()[at + offset].Inline;
    }

    private async Task VerifyAsync(string when)
    {
        var problem = await A("verify");
        t.Check($"control = shadow = document {when}", problem == "ok", problem);
    }

    // =====================================================================================================
    // Phase 1: first run on a fresh profile and a fresh server
    // =====================================================================================================

    public async Task FirstRunAsync()
    {
        AppLog.Line($"e2e first run: profile={window.Session.Paths.Profile ?? "(default)"} server={_server} secrets={window.Session.Settings.SecretStore}");
        string secretKey = "";

        await Section("setup", async () =>
        {
            t.Eq("a fresh profile starts at the server step", "setup:server", _a.View);
            t.Check("no title-bar buttons before unlock", !window.TitleButtonsVisible);
            var setup = window.Setup!;
            t.Check("an address that is not a URL is refused", !await setup.ConnectAsync("not a url ::") && setup.Error is not null, setup.Error);
            t.Check("a server that is not there is refused", !await setup.ConnectAsync("http://localhost:9") && setup.Error is not null, setup.Error);
            t.Check("nothing was saved for a bad address", window.Session.Settings.ServerUrl is null);
            setup.Fill(server: _server);
            await ShotAsync("01-first-run-server.png");
            t.Check("the real server is accepted", await setup.ConnectAsync(_server), setup.Error);
            t.Eq("then the account step shows", "setup:choice", _a.View);
            t.Check("a fresh server offers to create the account", setup.CreateOffered);
            await ShotAsync("02-first-run-choice.png");

            setup.Choose(create: true);
            setup.Fill(username: Username, password: "password1", device: DeviceA);
            await Task.Delay(150);
            t.Check("a weak password gets a warning hint", setup.StrengthHintText.Contains("first passwords", StringComparison.Ordinal), setup.StrengthHintText);
            t.Check("different passwords are refused", !await setup.CreateAccountAsync(Username, Password, Password + "x", DeviceA) && setup.Error is not null);
            t.Check("a short password is refused", !await setup.CreateAccountAsync(Username, "short", "short", DeviceA));
            setup.Fill(password: Password);
            await ShotAsync("03-first-run-create-account.png");
            t.Check("the account is created", await setup.SubmitCreateAsync(), setup.Error);
            t.Eq("the Emergency Kit step comes before anything else", "setup:kit", _a.View);
            secretKey = setup.SecretKeyShown;
            t.Check("the Secret Key is shown", Regex.IsMatch(secretKey, "^T2-[0-9A-Z]{6}-[0-9A-Z]{6}-[0-9A-Z]{6}-[0-9A-Z]{8}$"), $"{secretKey.Length} characters");
            t.Check("no way past the kit step yet", !setup.CanContinue && !await setup.ContinueAfterKitAsync() && _a.View == "setup:kit");
            await Task.Delay(250);
            t.Check("no-recovery warning is on screen", _a.VisibleText().Contains("cannot be decrypted by anyone", StringComparison.Ordinal));

            var kitPath = Path.Combine(_out, "Emergency Kit (selftest).html");
            File.Delete(kitPath);
            t.Check("the Emergency Kit is written", await setup.SaveKitAsync(kitPath) && File.Exists(kitPath));
            var kit = File.Exists(kitPath) ? File.ReadAllText(kitPath) : "";
            t.Check("kit holds server, username and Secret Key", kit.Contains(_server) && kit.Contains(Username) && kit.Contains(secretKey));
            t.Check("kit has a blank line for the password and does not contain it", kit.Contains("write it here by hand") && !kit.Contains(Password));
            t.Check("kit is self-contained (no scripts, no external resources)",
                !kit.Contains("<script", StringComparison.OrdinalIgnoreCase) && !Regex.IsMatch(kit, "(src|href)\\s*=", RegexOptions.IgnoreCase));
            t.Check("kit says there is no recovery", kit.Contains("There is no recovery"));
            await ShotAsync("04-emergency-kit.png");
            setup.ConfirmKit();
            t.Check("continue after confirming", setup.CanContinue && await setup.ContinueAfterKitAsync());
            t.Eq("the notebooks show", "main", _a.View);
            t.Check("title-bar buttons are there now", window.TitleButtonsVisible);
        });

        await Section("starting content and sync", async () =>
        {
            t.Eq("a new account starts with a notebook", "My notebook", await A("notebook"));
            t.Eq("with a section", "General", await A("sections"));
            t.Check("and an open, empty page", window.Main!.EditorVisible && window.Main.Page!.GetText() == "\n", Checks.Show(window.Main.Page?.GetText()));
            t.Check("sync reaches the server", await A("wait-synced", "20000") == "True", await A("status-lines"));
            t.Eq("status says so", "Synced", await A("status"));
            t.Check("secrets are in the secret store, not in memory only",
                window.Session.Secrets.Get(SecretNames.SecretKey) == secretKey && window.Session.Secrets.Get(SecretNames.SessionToken) is { Length: > 10 });
        });

        await Section("notebooks, sections, pages", async () =>
        {
            t.Check("create a notebook", (await A("add-notebook", M("KiwiNotebook draft"))).Length == 32);
            await A("rename-notebook", M("KiwiNotebook"));
            t.Eq("renamed notebook shows in the switcher", "KiwiNotebook", await A("notebook"));
            t.Eq("a new notebook gets one section", "General", await A("sections"));
            await A("rename-section", "General", M("MangoSection"));
            await A("add-section", M("PapayaSection"));
            await A("add-section", M("GuavaSection"));
            await A("add-section", M("DoomedSection"));
            t.Eq("sections in creation order", "MangoSection|PapayaSection|GuavaSection|DoomedSection", await A("sections"));
            await A("move-section", "GuavaSection", "-1");
            await A("move-section", "MangoSection", "1");
            t.Eq("sections after moving up and down", "GuavaSection|MangoSection|PapayaSection|DoomedSection", await A("sections"));
            await A("delete-section", "DoomedSection");
            t.Eq("deleted section is gone from the list", "GuavaSection|MangoSection|PapayaSection", await A("sections"));
            t.Check("deletion is the deleted flag, not removal", window.Main!.Tree!.GetSections(includeDeleted: true).Any(s => s is { Title: "DoomedSection", Deleted: true }));

            await A("select-section", "MangoSection");
            t.Eq("empty section shows no pages", "", await A("pages"));
            t.Check("and no editor", !window.Main.EditorVisible);
            await A("add-page", M("FormattingPage"));
            await A("add-page", M("SecondPageLychee"));
            await A("add-page", M("ThirdPageDurian"));
            await A("add-page", M("DoomedPage"));
            t.Eq("pages in creation order", "FormattingPage|SecondPageLychee|ThirdPageDurian|DoomedPage", await A("pages"));
            t.Eq("the new page is selected and open", "MangoSection|DoomedPage", await A("selected"));
            await A("move-page", "ThirdPageDurian", "-1");
            t.Eq("pages after moving one up", "FormattingPage|ThirdPageDurian|SecondPageLychee|DoomedPage", await A("pages"));
            await A("delete-page", "DoomedPage");
            t.Eq("deleted page is gone; selection moved on", "FormattingPage|ThirdPageDurian|SecondPageLychee", await A("pages"));
            t.Check("a page is still open after deleting the open one", window.Main.EditorVisible && window.Main.PageId is not null);
            await A("move-page-to", "ThirdPageDurian", "PapayaSection");
            t.Eq("page moved to another section", "FormattingPage|SecondPageLychee", await A("pages"));
            await A("select-section", "PapayaSection");
            t.Eq("and shows up there", "ThirdPageDurian", await A("pages"));
            await A("select-section", "MangoSection");
            await A("select-page", "SecondPageLychee");
            await A("set-title", M("SecondPageRambutan"));
            t.Eq("title typed above the editor renames the page", "FormattingPage|SecondPageRambutan", await A("pages"));
            await A("type", "0", M("Text of the second page, with the word PERSIMMONWORD in it."));
            await VerifyAsync("after typing on the second page");
        });

        await Section("editor: every format of PROTOCOL.md 5.2", async () =>
        {
            await A("select-page", "FormattingPage");
            await A("type", "0", M("Heading one\nHeading two\nHeading three\nwords: boldword italicword underlineword strikeword codeword linkword plainword\nbullet item\nnumbered item\ntodo item\ncode block line\nindented paragraph\nQUOKKAZEBRA is a unique word"));
            await VerifyAsync("after typing ten paragraphs");
            foreach (var (text, command) in new[]
                     {
                         ("Heading one", "h1"), ("Heading two", "h2"), ("Heading three", "h3"), ("boldword", "bold"), ("italicword", "italic"),
                         ("underlineword", "underline"), ("strikeword", "strike"), ("codeword", "code"), ("bullet item", "ul"),
                         ("numbered item", "ol"), ("todo item", "todo"), ("code block line", "codeblock"),
                     })
            {
                await A("select-text", text);
                await A("run", command);
            }

            await A("select-text", "indented paragraph");
            await A("run", "indent");
            await A("run", "indent");
            await A("run", "outdent");
            var link = await A("select-text", "linkword");
            var parts = link.Split(',');
            await A("set-link", parts[0], parts[1], "https://example.com/first");
            await VerifyAsync("after applying every format");

            t.Eq("block formats in the document", "h1,h2,h3,p,ul,ol,todo,code,indent=1,p", Blocks());
            t.Eq("and in the control", "h1,h2,h3,p,ul,ol,todo,code,indent=1,p", ControlBlocks());
            t.Check("bold", InlineOf("boldword") is { Bold: true, Italic: false });
            t.Check("italic", InlineOf("italicword") is { Italic: true, Bold: false });
            t.Check("underline", InlineOf("underlineword").Underline);
            t.Check("strikethrough", InlineOf("strikeword").Strike);
            t.Check("inline code", InlineOf("codeword").Code);
            t.Check("link with its address", InlineOf("linkword").Link == "https://example.com/first");
            t.Check("plain text stayed plain", InlineOf("plainword") == default);
            var runs = window.Main!.Page!.GetRuns();
            t.Check("attributes are written the way the protocol says",
                runs.Any(r => r.Text == "boldword" && r.Attributes.Count == 1 && r.Attributes["bold"] is true)
                && runs.Any(r => r.Text == "\n" && r.Attributes.TryGetValue("block", out var b) && (string?)b == "h1")
                && runs.Any(r => r.Text == "\n" && r.Attributes.TryGetValue("indent", out var i) && i is 1.0),
                string.Join(" ", runs.Select(r => $"[{r.Text.Replace("\n", "⏎")}:{string.Join(",", r.Attributes.Select(kv => kv.Key + "=" + kv.Value))}]")));

            // The toolbar shows what the selection has.
            async Task<string> ToolbarAt(string text, string where = "")
            {
                await A("select-text", text, where);
                await Task.Delay(80); // the control reports selection changes on its next turn
                return await A("toolbar");
            }

            t.Eq("toolbar at bold text", "bold", await ToolbarAt("boldword"));
            t.Eq("toolbar at the end of a link", "link", await ToolbarAt("linkword", "after"));
            t.Eq("toolbar in a heading", "h2", await ToolbarAt("Heading two", "before"));
            t.Eq("toolbar at inline code", "code", await ToolbarAt("codeword"));
            t.Eq("toolbar in a to-do", "todo", await ToolbarAt("todo item", "after"));
            t.Eq("toolbar in a code block", "codeblock", await ToolbarAt("code block line"));

            // To-do checkbox: a click on the box ticks it, and again unticks it.
            t.Eq("click on the checkbox", "True", await A("toggle-todo-click", "todo item"));
            t.Eq("ticked", "h1,h2,h3,p,ul,ol,todo,checked,code,indent=1,p", Blocks());
            await VerifyAsync("after ticking the to-do");

            // Link: edit, find from a caret, remove, insert new.
            var range = window.Main.Binding!.LinkRangeAt(int.Parse(parts[0]) + 2);
            t.Check("the link is found from a caret inside it", range is { Url: "https://example.com/first" } && range.Value.Start == int.Parse(parts[0]) && range.Value.End == int.Parse(parts[1]));
            await A("set-link", parts[0], parts[1], "https://example.com/edited");
            t.Check("link edited", InlineOf("linkword").Link == "https://example.com/edited");
            await A("set-link", parts[0], parts[1], "");
            t.Check("link removed", InlineOf("linkword").Link is null && window.Main.Binding.LinkRangeAt(int.Parse(parts[0]) + 2) is null);
            await A("set-link", parts[0], parts[1], "https://example.com/final");
            await A("select-text", "plainword", "after");
            await A("insert-link", M(" insertedlinktext"), "https://example.org/inserted");
            t.Check("link inserted with its own text", InlineOf("insertedlinktext").Link == "https://example.org/inserted");
            await VerifyAsync("after link editing");
            t.Eq("bare host becomes https", "https://example.com/x", MainView.NormalizeLink("example.com/x"));
            t.Eq("mail address becomes mailto", "mailto:someone@example.com", MainView.NormalizeLink("someone@example.com"));
            t.Check("script and file links are refused", MainView.NormalizeLink("javascript:alert(1)") is null && MainView.NormalizeLink("file:///c:/windows/system32/calc.exe") is null);

            // Formats toggled at a caret apply to what is typed next.
            await A("select-text", "QUOKKAZEBRA is a unique word", "after");
            await A("run", "bold");
            await A("type-at-caret", M(" CARETBOLDWORD"));
            await A("run", "bold");
            await A("run", "code");
            await A("type-at-caret", M(" CARETCODEWORD"));
            await A("run", "code");
            await A("type-at-caret", M(" CARETPLAINWORD"));
            t.Check("bold at the caret", InlineOf("CARETBOLDWORD") is { Bold: true, Code: false });
            t.Check("code at the caret", InlineOf("CARETCODEWORD") is { Code: true, Bold: false });
            t.Check("and off again", InlineOf("CARETPLAINWORD") == default, InlineOf("CARETPLAINWORD").ToString());
            await VerifyAsync("after typing with caret formats");

            // Undo and redo go through the document's own undo (this device's edits only).
            var before = await A("dump");
            await Task.Delay(700); // past the undo capture window, so the next edit is its own step
            await A("type", "-1", M(" UNDOMEWORD"));
            t.Check("typed", (await A("text")).Contains("UNDOMEWORD"));
            await A("run", "undo");
            t.Eq("undo takes it away again", before, await A("dump"));
            await A("run", "redo");
            t.Check("redo brings it back", (await A("text")).Contains("UNDOMEWORD"));
            await A("run", "undo");
            await VerifyAsync("after undo and redo");
        });

        await Section("editor shortcuts (the key handler, not real key presses)", async () =>
        {
            await A("add-page", M("ShortcutPagePlum"));
            await A("type", "0", M("alphaline\nbetaline\ngammaline\ndeltaline"));
            async Task<string> Key(string where, string chord)
            {
                await A("select-text", where);
                return await A("key", chord);
            }

            t.Eq("Ctrl+Alt+1", "True", await Key("alphaline", "ctrl+alt+1"));
            t.Eq("is heading 1", "h1,p,p,p", Blocks());
            await Key("alphaline", "ctrl+alt+2");
            await Key("betaline", "ctrl+alt+3");
            t.Eq("Ctrl+Alt+2 and 3", "h2,h3,p,p", Blocks());
            await Key("alphaline", "ctrl+alt+0");
            await Key("betaline", "ctrl+alt+0");
            t.Eq("Ctrl+Alt+0 is plain paragraph", "p,p,p,p", Blocks());
            await Key("alphaline", "ctrl+shift+X");
            await Key("betaline", "ctrl+E");
            t.Check("Ctrl+Shift+X strikes, Ctrl+E is inline code", InlineOf("alphaline").Strike && InlineOf("betaline").Code);
            await Key("alphaline", "ctrl+.");
            await Key("betaline", "ctrl+/");
            await Key("gammaline", "ctrl+1");
            await Key("deltaline", "ctrl+shift+C");
            t.Eq("Ctrl+. bullets, Ctrl+/ numbers, Ctrl+1 to-do, Ctrl+Shift+C code block", "ul,ol,todo,code", Blocks());
            t.Eq("Tab in a list indents", "True", await Key("gammaline", "Tab"));
            await Key("gammaline", "Tab");
            t.Eq("twice", "ul,ol,todo,indent=2,code", Blocks());
            t.Eq("Shift+Tab outdents", "True", await Key("gammaline", "shift+Tab"));
            t.Eq("once", "ul,ol,todo,indent=1,code", Blocks());
            await Key("gammaline", "ctrl+shift+M");
            await Key("deltaline", "ctrl+M");
            t.Eq("Ctrl+Shift+M and Ctrl+M", "ul,ol,todo,code,indent=1", Blocks());
            await Key("deltaline", "ctrl+shift+C");
            await Key("deltaline", "ctrl+shift+M");
            var before = await A("dump");
            await A("select-text", "deltaline", "after");
            t.Eq("Tab in a plain paragraph is used", "True", await A("key", "Tab"));
            t.Check("and types a tab", (await A("text")).Contains("deltaline\t\n"), Checks.Show(await A("text")));
            t.Eq("Shift+Tab with nothing to outdent is left alone (moves the focus)", "False", await A("key", "shift+Tab"));
            before = await A("dump");
            foreach (var chord in new[] { "ctrl+R", "ctrl+J", "ctrl+=", "ctrl+shift+=", "ctrl+2", "ctrl+5", "ctrl+shift+L", "ctrl+shift+A" })
            {
                t.Eq($"{chord} (a RichEdit format a page cannot hold) is swallowed", "True", await Key("alphaline", chord));
            }

            t.Eq("and none of them changed anything", before, await A("dump"));
            foreach (var chord in new[] { "ctrl+B", "ctrl+I", "ctrl+U", "ctrl+C", "ctrl+A", "Enter", "ctrl+Z" })
            {
                t.Eq($"{chord} is left to the control", "False", await A("key", chord));
            }

            t.Check("Ctrl+N, Ctrl+F and Ctrl+L are app shortcuts", !window.Main!.HandleAppKey(Windows.System.VirtualKey.B, true, false, false)
                && window.Main.HandleAppKey(Windows.System.VirtualKey.F, true, false, false));
            await VerifyAsync("after the shortcut tests");
            await A("delete-page", "ShortcutPagePlum");
        });

        await Section("real keyboard and mouse", RealInputAsync);

        await Section("paste filter", async () =>
        {
            await A("select-page", "SecondPageRambutan");
            var data = new DataPackage();
            data.SetRtf(@"{\rtf1\ansi before {\pict\wmetafile8\picw100\pich100 0100090000030000} after}");
            data.SetText(M("PASTEDPLAINONLY text"));
            await SetClipboardAsync(data);
            await A("type", "-1", "\n");
            await A("paste");
            var text = await A("text");
            t.Check("rich text with a picture is pasted as its plain text", text.Contains("PASTEDPLAINONLY text") && !PasteFilter.ContainsForbidden(text), Checks.Show(text));

            data = new DataPackage();
            data.SetRtf(@"{\rtf1\ansi{\fonttbl{\f0 Times New Roman;}}\f0\fs48 plain \b " + M("PASTEDBOLDWORD") + @"\b0  tail}");
            data.SetText("ignored because the rich text is safe");
            await SetClipboardAsync(data);
            await A("type", "-1", "\n");
            await A("paste");
            t.Check("harmless rich text keeps its formatting", InlineOf("PASTEDBOLDWORD") is { Bold: true } && InlineOf("tail", 0) == default, await A("dump"));
            await VerifyAsync("after rich paste (foreign font and size normalised)");

            data = new DataPackage();
            data.SetRtf(@"{\rtf1\ansi\trowd\cellx1500\cellx3000\intbl TABLECELLONE\cell TABLECELLTWO\cell\row\pard x\par}");
            data.SetText(M("TABLEASTEXT one\ttwo"));
            await SetClipboardAsync(data);
            await A("type", "-1", "\n");
            await A("paste");
            text = await A("text");
            t.Check("a table is pasted as its plain text", text.Contains("TABLEASTEXT one\ttwo") && !text.Contains("TABLECELLONE") && !PasteFilter.ContainsForbidden(text), Checks.Show(text));

            // Only a picture on the clipboard: nothing is pasted.
            using (var stream = new InMemoryRandomAccessStream())
            {
                var encoder = await Windows.Graphics.Imaging.BitmapEncoder.CreateAsync(Windows.Graphics.Imaging.BitmapEncoder.PngEncoderId, stream);
                encoder.SetPixelData(Windows.Graphics.Imaging.BitmapPixelFormat.Bgra8, Windows.Graphics.Imaging.BitmapAlphaMode.Ignore, 2, 2, 96, 96, new byte[16]);
                await encoder.FlushAsync();
                data = new DataPackage();
                data.SetBitmap(RandomAccessStreamReference.CreateFromStream(stream));
                await SetClipboardAsync(data);
                var beforePicture = await A("dump");
                await A("paste");
                t.Eq("a picture alone pastes nothing", beforePicture, await A("dump"));
            }

            data = new DataPackage();
            data.SetText("line one\r\nline two\u0001\u0002");
            await SetClipboardAsync(data);
            await A("type", "-1", "\n");
            await A("paste", "plain");
            t.Check("plain paste keeps line breaks and drops control characters", (await A("text")).EndsWith("line one\nline two\n", StringComparison.Ordinal), Checks.Show(await A("text")));
            await VerifyAsync("after the paste tests");
            Clipboard.Clear();
        });

        await Section("search", async () =>
        {
            var hits = (await A("search", "quokkazebra")).Split('\n', StringSplitOptions.RemoveEmptyEntries);
            t.Check("page text is found, ignoring case", hits.Length == 1 && hits[0].StartsWith("KiwiNotebook/MangoSection/FormattingPage|", StringComparison.Ordinal), string.Join(" ; ", hits));
            hits = (await A("search", "rambutan")).Split('\n', StringSplitOptions.RemoveEmptyEntries);
            t.Check("page titles are found", hits.Length == 1 && hits[0].Contains("/SecondPageRambutan|"), string.Join(" ; ", hits));
            hits = (await A("search", "persimmonword second")).Split('\n', StringSplitOptions.RemoveEmptyEntries);
            t.Check("all words must match, in title or text", hits.Length == 1 && hits[0].Contains("PERSIMMONWORD"), string.Join(" ; ", hits));
            t.Eq("deleted pages are not found", "", await A("search", "DoomedPage"));
            t.Eq("nothing found for nonsense", "", await A("search", "zzzzqqqq"));
            hits = (await A("search", "durian")).Split('\n', StringSplitOptions.RemoveEmptyEntries);
            t.Check("found in another section", hits.Length == 1, string.Join(" ; ", hits));
            var fields = hits[0].Split('|');
            await A("open", fields[1], fields[2], fields[3]);
            t.Eq("jumping to a search result opens the page", "PapayaSection|ThirdPageDurian", await A("selected"));
        });

        await Section("lock and unlock", async () =>
        {
            await A("select-section", "MangoSection");
            await A("select-page", "FormattingPage");
            await A("wait-synced", "20000");
            await A("theme", "light");
            await A("focus-editor");
            await ShotAsync("05-main-light.png");

            // The "just a note" layout: narrow window, zoomed out, side panes hidden. Then back.
            var sizeBefore = window.AppWindow.Size;
            window.SetZoom(80);
            window.Main!.TogglePanes();
            window.AppWindow.Resize(new Windows.Graphics.SizeInt32(100, 1000)); // far below the minimum: the window clamps it
            await Task.Delay(500);
            t.Check("zoom is applied", window.ZoomPercent == 80);
            t.Check("the side panes are hidden", window.Main.PanesHidden);
            t.Check("the window became much narrower", window.AppWindow.Size.Width < sizeBefore.Width * 0.5, $"{sizeBefore.Width} -> {window.AppWindow.Size.Width}");
            await A("focus-editor");
            await ShotAsync("14-narrow-zoomed.png");
            await VerifyAsync("in a narrow zoomed window without panes");
            window.Main.TogglePanes();
            await Task.Delay(300);
            await ShotAsync("15-narrow-with-panes.png");
            t.Check("the side panes are back", !window.Main.PanesHidden);
            await VerifyAsync("in a narrow window with the page behind the panes");
            window.StepZoom(+1);
            window.StepZoom(+1);
            t.Check("two steps up from 80% is 100%", window.ZoomPercent == 100);
            window.AppWindow.Resize(sizeBefore);
            await Task.Delay(500);
            await VerifyAsync("after returning to the normal layout");

            var ids = await A("ids");
            var dump = await A("dump");
            var tree = await A("tree");

            t.Eq("the lock button locks", "unlock", await A("lock"));
            t.Check("the client is locked (keys out of memory)", window.Session.Client!.State == ClientState.Locked);
            var visible = _a.VisibleText();
            var leaked = _markers.Where(m => visible.Contains(m, StringComparison.OrdinalIgnoreCase)).ToList();
            t.Check("no note content is left anywhere in the window", leaked.Count == 0, string.Join(",", leaked));
            t.Check("the lock, sync and settings buttons are gone", !window.TitleButtonsVisible);
            t.Check("documents cannot be opened while locked", Throws<InvalidOperationException>(() => _ = window.Session.Client.NotebookIds));
            t.Check("a wrong password is refused", (await A("unlock", "not the password")).StartsWith("error", StringComparison.Ordinal) && _a.View == "unlock");
            t.Eq("the right one unlocks", "ok", await A("unlock", Password));
            t.Eq("last open notebook, section and page are back", ids, await A("ids"));
            t.Eq("the page content is as it was", dump, await A("dump"));
            t.Eq("the tree is as it was", tree, await A("tree"));
            await VerifyAsync("after unlock");

            // A dialog that is open when the app locks goes away with everything else.
            var prompt = window.PromptAsync("Rename page", "Name", M("DialogTextCherimoya"), "Rename");
            await Task.Delay(400);
            t.Check("the dialog is showing", _a.VisibleText().Contains("DialogTextCherimoya"));
            t.Eq("locking with a dialog open", "unlock", await A("lock"));
            t.Check("the dialog was dismissed without a result", await prompt is null);
            await Task.Delay(300);
            t.Check("and its text is off the screen", !_a.VisibleText().Contains("DialogTextCherimoya"));
            t.Eq("unlock", "ok", await A("unlock", Password));

            // Auto-lock: nothing touches the app for longer than the limit.
            await A("idle-limit", "1500");
            t.Check("locks itself after the idle time", await Automation.WaitUntilAsync(() => _a.View == "unlock", 12000), _a.View);
            await A("idle-limit", "");
            t.Eq("unlock again", "ok", await A("unlock", Password));
        });

        await Section("settings", async () =>
        {
            t.Eq("settings open", "settings", await A("open-settings"));
            t.Eq("this device is in the device list", DeviceA + "*", await A("devices"));
            await ShotAsync("07-settings-light.png");
            await A("set-autolock", "5");
            t.Check("auto-lock time is saved", AppSettings.Load(window.Session.Paths.SettingsPath).AutoLockMinutes == 5);
            t.Eq("the Secret Key is not shown for a wrong password", "", await A("reveal-key", "wrong password"));
            t.Eq("and is shown for the right one", secretKey, await A("reveal-key", Password));
            var kitPath = Path.Combine(_out, "Emergency Kit (re-saved).html");
            File.Delete(kitPath);
            t.Check("re-saving the kit needs the password", await A("save-kit", "wrong password", kitPath) == "False" && !File.Exists(kitPath));
            t.Check("re-saved kit holds the key", await A("save-kit", Password, kitPath) == "True" && File.ReadAllText(kitPath).Contains(secretKey));
            await A("theme", "dark");
            await ShotAsync("07-settings-dark.png");
            t.Eq("back to the notebooks", "main", await A("close-settings"));
            t.Eq("with the page open again", "MangoSection|FormattingPage", await A("selected"));
            await VerifyAsync("after the theme changed to dark while the page was closed");
            t.Check("the editor uses the dark colours", window.Main!.Binding!.Style.Dark);
            await A("focus-editor");
            await ShotAsync("06-main-dark.png");
            await A("theme", "light");
            t.Check("and switches back live", !window.Main.Binding.Style.Dark);
            await VerifyAsync("after switching the theme with the page open");
            await A("theme", "system");
            await A("sync-flyout", "show");
            await ShotAsync("08-sync-status.png");
            await A("sync-flyout", "hide");
            var lines = await A("status-lines");
            t.Check("sync details name the server and what is waiting", lines.Contains(_server) && lines.Contains("Waiting to send: nothing"), lines);
        });

        await Section("state for the next phase", async () =>
        {
            await A("wait-synced", "20000");
            var state = new SavedState(await A("ids"), await A("dump"), await A("tree"), [.. _markers]);
            await File.WriteAllTextAsync(StatePath, JsonSerializer.Serialize(state));
            t.Check("everything is on the server", _a.IsSynced(), await A("status-lines"));
        });
    }

    private RealKeys.ScreenPoint OnScreen(Microsoft.UI.Xaml.UIElement element, Windows.Foundation.Point point)
    {
        var inWindow = element.TransformToVisual(null).TransformPoint(point);
        var scale = window.RootElement.XamlRoot.RasterizationScale;
        var p = new RealKeys.ScreenPoint { X = (int)Math.Round(inWindow.X * scale), Y = (int)Math.Round(inWindow.Y * scale) };
        RealKeys.ClientToScreen(window.Hwnd, ref p);
        return p;
    }

    /// <summary>
    /// The same things once more with real key presses and real mouse clicks (SendInput), which is the only way
    /// the control's own key handling, the app's key handlers and its pointer handlers get exercised. Runs only
    /// with --input and only while this window is the foreground window; otherwise it says so and checks nothing.
    /// </summary>
    private async Task RealInputAsync()
    {
        const ushort Enter = 0x0D, Ctrl = 0x11, Shift = 0x10, Alt = 0x12, Tab = 0x09, Home = 0x24, End = 0x23, Period = 0xBE;
        if (!options.Has("--input"))
        {
            AppLog.Line("  SKIPPED real keyboard and mouse: not requested (--input)");
            return;
        }

        var keys = new RealKeys(window.Hwnd);
        window.Activate();
        var previous = keys.TakeForeground();
        try
        {
            await Task.Delay(400);
            if (!keys.IsForeground)
            {
                AppLog.Line("  SKIPPED real keyboard and mouse: the window could not become the foreground window; nothing was typed");
                return;
            }

            await A("select-section", "MangoSection");
            await A("add-page", M("RealKeysPageFig"));
            await A("focus-editor");
            var ok = await keys.Type(M("typedwithrealkeys"));
            await Task.Delay(200);
            t.Eq("typing reaches the page", "typedwithrealkeys\n", await A("text"));

            // Lists: Ctrl+. makes a bullet, Enter continues it, Tab indents, Shift+Tab outdents.
            ok &= await keys.Press(Enter);
            ok &= await keys.Type("itemone");
            ok &= await keys.Chord(Ctrl, Period);
            ok &= await keys.Press(Enter);
            ok &= await keys.Type("itemtwo");
            ok &= await keys.Press(Tab);
            await Task.Delay(200);
            t.Eq("Ctrl+. , Enter and Tab", "p,ul,ul,indent=1", Blocks());
            ok &= await keys.Chord(Shift, Tab);
            await Task.Delay(200);
            t.Eq("Shift+Tab", "p,ul,ul", Blocks());

            // Headings and inline formats by shortcut.
            ok &= await keys.Chord(Ctrl, Home);
            ok &= await keys.Chord(Ctrl, Alt, 0x32);
            await Task.Delay(200);
            t.Eq("Ctrl+Alt+2", "h2,ul,ul", Blocks());
            ok &= await keys.Chord(Ctrl, End);
            ok &= await keys.Press(Enter);
            ok &= await keys.Press(Enter); // a second Enter on the empty item leaves the list
            ok &= await keys.Chord(Ctrl, 0x42);
            ok &= await keys.Type("realbold");
            ok &= await keys.Chord(Ctrl, 0x42);
            ok &= await keys.Type(" ");
            ok &= await keys.Chord(Ctrl, Shift, 0x58);
            ok &= await keys.Type("realstrike");
            ok &= await keys.Chord(Ctrl, Shift, 0x58);
            ok &= await keys.Type(" ");
            ok &= await keys.Chord(Ctrl, 0x45);
            ok &= await keys.Type("realcode");
            ok &= await keys.Chord(Ctrl, 0x45);
            ok &= await keys.Type(" plainagain");
            await Task.Delay(250);
            t.Check("Ctrl+B, Ctrl+Shift+X and Ctrl+E apply to what is typed next",
                InlineOf("realbold") is { Bold: true, Strike: false } && InlineOf("realstrike") is { Strike: true, Bold: false }
                && InlineOf("realcode") is { Code: true, Strike: false } && InlineOf("plainagain") == default, await A("dump"));
            Checks.Note($"blocks after Enter, Enter at the end of a list: [{Blocks()}]");
            await VerifyAsync("after real typing and shortcuts");

            // Spell checking is on. Its squiggles must stay a display matter: nothing may reach the document.
            ok &= await keys.Type(" mispeled wrod ");
            await Task.Delay(1800);
            await ShotAsync("13-real-typing.png");
            var spelled = await A("text");
            t.Check("the typed words are there (Windows may autocorrect the second one)", spelled.Contains("mispeled wrod") || spelled.Contains("mispeled word"), Checks.Show(spelled));
            Checks.Note(spelled.Contains("mispeled word") ? "autocorrect changed 'wrod' to 'word'; it arrived as an ordinary edit" : "autocorrect did not change the typed words");
            t.Check("spell-check marks are not formatting", InlineOf("mispeled") == default && InlineOf("plainagain") == default && !Cells().Any(c => c.Inline.Underline), await A("dump"));
            await VerifyAsync("after the spell checker had time to mark and correct words");

            // Ctrl+Z / Ctrl+Y through the document's undo.
            await Task.Delay(700);
            ok &= await keys.Type(" undome");
            await Task.Delay(700);
            ok &= await keys.Chord(Ctrl, 0x5A);
            await Task.Delay(200);
            t.Check("Ctrl+Z", !(await A("text")).Contains("undome"), await A("text"));
            ok &= await keys.Chord(Ctrl, 0x59);
            await Task.Delay(200);
            t.Check("Ctrl+Y", (await A("text")).Contains("undome"), await A("text"));

            // Ctrl+K: the link flyout, filled in by keyboard.
            ok &= await keys.Press(Enter);
            ok &= await keys.Chord(Ctrl, 0x4B);
            await Task.Delay(500);
            ok &= await keys.Type("keyboardlink");
            ok &= await keys.Press(Tab);
            ok &= await keys.Type("example.com/kb");
            ok &= await keys.Press(Enter);
            await Task.Delay(500);
            t.Check("Ctrl+K inserts a link from the flyout", (await A("text")).Contains("keyboardlink") && InlineOf("keyboardlink").Link == "https://example.com/kb", await A("dump"));
            ok &= await keys.Type(" after");
            await Task.Delay(200);
            t.Check("and typing carries on in the editor", (await A("text")).Contains("keyboardlink after"), await A("text"));
            await VerifyAsync("after the link flyout");

            // Ctrl+V with a picture in the rich text: the paste filter, reached through the control's own Paste event.
            var data = new DataPackage();
            data.SetRtf(@"{\rtf1\ansi rich {\pict\wmetafile8\picw100\pich100 0100090000030000} rich}");
            data.SetText("pastedbykeyboard");
            await SetClipboardAsync(data);
            ok &= await keys.Press(Enter);
            ok &= await keys.Chord(Ctrl, 0x56);
            await Task.Delay(400);
            var pasted = await A("text");
            t.Check("Ctrl+V goes through the paste filter", pasted.Contains("pastedbykeyboard") && !pasted.Contains("rich") && !PasteFilter.ContainsForbidden(pasted), Checks.Show(pasted));

            // A real click on a to-do checkbox.
            ok &= await keys.Press(Enter);
            ok &= await keys.Type("clickme");
            ok &= await keys.Chord(Ctrl, 0x31);
            await Task.Delay(250);
            var binding = window.Main!.Binding!;
            var at = binding.Shadow.Text.IndexOf("clickme", StringComparison.Ordinal);
            t.Check("Ctrl+1 makes a to-do", binding.Shadow.BlockAt(at).Effective() is { Block: "todo", Checked: false });
            ok &= await keys.Click(OnScreen(binding.ContentElement!, binding.MarkerPoint(at)));
            await Task.Delay(300);
            t.Check("a mouse click on the box ticks it", binding.Shadow.BlockAt(at).Effective().Checked, Blocks());
            var textPoint = binding.MarkerPoint(at);
            ok &= await keys.Click(OnScreen(binding.ContentElement!, new Windows.Foundation.Point(textPoint.X + 60, textPoint.Y)));
            await Task.Delay(300);
            t.Check("a click in the text does not untick it", binding.Shadow.BlockAt(at).Effective().Checked, Blocks());
            await VerifyAsync("after the mouse clicks");

            // Ctrl+N: a new page, title typed, Enter moves to the text.
            ok &= await keys.Chord(Ctrl, 0x4E);
            await Task.Delay(400);
            ok &= await keys.Type(M("TitleTypedForReal"));
            ok &= await keys.Press(Enter);
            ok &= await keys.Type("bodytypedforreal");
            await Task.Delay(300);
            t.Eq("Ctrl+N, title, Enter, text", "MangoSection|TitleTypedForReal", await A("selected"));
            t.Eq("the text went into the new page", "bodytypedforreal\n", await A("text"));

            // Dragging a page in the list with the mouse.
            var pagesBefore = await A("pages");
            var first = window.Main.ListItem("FormattingPage", section: false)!;
            var second = window.Main.ListItem("SecondPageRambutan", section: false)!;
            var from = OnScreen(first, new Windows.Foundation.Point(first.ActualWidth / 2, first.ActualHeight / 2));
            var to = OnScreen(second, new Windows.Foundation.Point(second.ActualWidth / 2, second.ActualHeight * 0.9));
            var dragsBefore = window.Main.DragsStarted;
            ok &= await keys.Drag(from, to);
            await Task.Delay(500);
            Checks.Note($"mouse drag from ({from.X},{from.Y}) to ({to.X},{to.Y}): the list reported {window.Main.DragsStarted - dragsBefore} drag(s) started");
            var order = window.Main.Tree!.GetPages(window.Main.SectionId!).Select(p => p.Title).ToList();
            t.Check("dragging a page below the next one reorders them", order.IndexOf("FormattingPage") == order.IndexOf("SecondPageRambutan") + 1, $"before {pagesBefore} / after {string.Join("|", order)}");
            t.Eq("the list shows the new order", string.Join("|", order), await A("pages"));
            await A("move-page", "FormattingPage", "-1");

            // Ctrl+F: search from the title bar, Enter opens the first result.
            ok &= await keys.Chord(Ctrl, 0x46);
            await Task.Delay(300);
            ok &= await keys.Type("typedwithrealkeys");
            await Task.Delay(900);
            ok &= await keys.Press(Enter);
            await Task.Delay(500);
            t.Eq("Ctrl+F, a word, Enter", "MangoSection|RealKeysPageFig", await A("selected"));

            // Ctrl+L locks; the password typed into the lock screen and Enter unlock.
            await A("focus-editor");
            ok &= await keys.Chord(Ctrl, 0x4C);
            t.Check("Ctrl+L locks", await Automation.WaitUntilAsync(() => _a.View == "unlock", 8000), _a.View);
            await Task.Delay(500);
            ok &= await keys.Type("wrong password");
            ok &= await keys.Press(Enter);
            t.Check("a wrong password typed at the lock screen is refused", await Automation.WaitUntilAsync(() => window.Unlock?.Error is not null, 15000));
            ok &= await keys.Type(Password);
            ok &= await keys.Press(Enter);
            t.Check("the password and Enter unlock", await Automation.WaitUntilAsync(() => _a.View == "main" && window.Main?.Page is not null, 15000), _a.View);
            t.Eq("back on the same page", "MangoSection|RealKeysPageFig", await A("selected"));
            t.Check("the foreground window was ours for every keystroke and click", ok);
            await A("delete-page", "RealKeysPageFig");
            await A("delete-page", "TitleTypedForReal");
        }
        finally
        {
            keys.Restore(previous);
        }
    }

    private static async Task SetClipboardAsync(DataPackage data)
    {
        await BindingSelfTest.SetClipboard(data);
        await Task.Delay(150); // the clipboard takes a moment to hand the new content out
    }

    private static bool Throws<T>(Action action)
        where T : Exception
    {
        try
        {
            action();
            return false;
        }
        catch (T)
        {
            return true;
        }
    }

    // =====================================================================================================
    // Phase 2: the app was closed and is started again
    // =====================================================================================================

    public async Task RestartAsync()
    {
        var state = JsonSerializer.Deserialize<SavedState>(await File.ReadAllTextAsync(StatePath))!;
        _markers.AddRange(state.Markers);
        await Section("restart", async () =>
        {
            t.Eq("a later launch starts at the unlock screen", "unlock", _a.View);
            t.Check("locked, nothing decrypted", window.Session.Client!.State == ClientState.Locked);
            var visible = _a.VisibleText();
            t.Check("no note content on the unlock screen", !_markers.Any(m => visible.Contains(m, StringComparison.OrdinalIgnoreCase)));
            t.Check("the window title carries no content", window.Title.StartsWith("TwoNote", StringComparison.Ordinal) && !_markers.Any(m => window.Title.Contains(m)));
            await A("theme", "light");
            await ShotAsync("09-unlock.png");
            await A("theme", "system");
            t.Check("wrong password", (await A("unlock", "nope nope nope")).StartsWith("error", StringComparison.Ordinal));
            t.Eq("unlock", "ok", await A("unlock", Password));
            t.Eq("the same notebook, section and page are open", state.Ids, await A("ids"));
            t.Eq("the tree is all there", state.Tree, await A("tree"));
            t.Eq("the formatted page is all there", state.Dump, await A("dump"));
            await VerifyAsync("after restart");
            t.Check("auto-lock setting survived", window.Session.Settings.AutoLockMinutes == 5);
            await A("select-page", "SecondPageRambutan");
            t.Check("other pages too", (await A("text")).Contains("PERSIMMONWORD"));
            t.Check("syncs after the restart", await A("wait-synced", "20000") == "True", await A("status-lines"));
        });
    }

    // =====================================================================================================
    // Phase 3: a second instance under another profile, as a second device
    // =====================================================================================================

    private async Task<bool> ConvergedAsync(AgentPipe.Driver b, int timeoutMs = 30000)
    {
        var until = Environment.TickCount64 + timeoutMs;
        while (Environment.TickCount64 < until)
        {
            if (_a.IsSynced() && await b.CallAsync("wait-synced", "50") == "True")
            {
                var mine = await A("dump");
                if (mine == await b.CallAsync("dump") && _a.IsSynced())
                {
                    return true;
                }
            }

            await Task.Delay(100);
        }

        return false;
    }

    private async Task ControlAsync(string request)
    {
        // The runner script owns the container: it acts on the request file and deletes it when done.
        var dir = Path.Combine(_out, "control");
        Directory.CreateDirectory(dir);
        var file = Path.Combine(dir, request + ".request");
        await File.WriteAllTextAsync(file, "");
        t.Check($"the runner handled '{request}'", await Automation.WaitUntilAsync(() => !File.Exists(file), 90000));
    }

    public async Task TwoInstancesAsync()
    {
        var state = JsonSerializer.Deserialize<SavedState>(await File.ReadAllTextAsync(StatePath))!;
        _markers.AddRange(state.Markers);
        var pipeName = "twonote-selftest-" + Guid.NewGuid().ToString("N");
        await using var b = new AgentPipe.Driver(pipeName);
        Task<string> B(string command, params string[] args) => b.CallAsync(command, args);
        Process? agent = null;
        var secretKey = "";

        try
        {
            await Section("second device enrols", async () =>
            {
                t.Eq("device A unlocks", "ok", await A("unlock", Password));
                await A("idle-limit", "3600000"); // this phase is long; auto-lock is tested in the first one
                await A("open-settings");
                secretKey = await A("reveal-key", Password);
                await A("close-settings");
                t.Check("A is synced", await A("wait-synced", "20000") == "True");

                agent = Process.Start(new ProcessStartInfo(Environment.ProcessPath!)
                {
                    UseShellExecute = false,
                    ArgumentList = { "--profile", ProfileB, "--selftest", "agent", "--pipe", pipeName, "--log", Path.Combine(_out, "agent.log") },
                })!;
                await b.WaitForAgentAsync(30000);
                t.Eq("the second instance starts at first run (its own profile)", "setup:server", await B("view"));
                t.Eq("B connects", "True", await B("connect", _server));
                t.Check("a wrong Secret Key is refused", (await B("enrol", Username, Password, "T2-AAAAAA-AAAAAA-AAAAAA-AAAAAAAA", DeviceB)).StartsWith("error", StringComparison.Ordinal));
                t.Check("half a Secret Key is refused", (await B("enrol", Username, Password, "T2-AAAAAA", DeviceB)).StartsWith("error", StringComparison.Ordinal));
                t.Eq("B enrols with username, password and Secret Key", "ok", await B("enrol", Username, Password, secretKey.ToLowerInvariant().Replace("-", " "), DeviceB));
                t.Eq("B shows the notebooks", "main", await B("view"));
                await B("idle-limit", "3600000");
                t.Check("B's first sync completes", await B("wait-synced", "30000") == "True", await B("status-lines"));
                t.Eq("both devices show the same tree", await A("tree"), await B("tree"));
                t.Check("B picked a notebook by itself", (await B("notebook")).Length > 0, await B("notebook"));
            });

            await Section("same page on both", async () =>
            {
                await A("select-notebook", "KiwiNotebook");
                await A("select-section", "MangoSection");
                await A("select-page", "FormattingPage");
                var ids = (await A("ids")).Split('|');
                await B("open", ids[0], ids[1], ids[2]);
                t.Eq("B opened the same page", "MangoSection|FormattingPage", await B("selected"));
                t.Eq("identical content, formatting included", await A("dump"), await B("dump"));
                t.Eq("B's control agrees with its document", "ok", await B("verify"));
                await B("theme", "light");
                await ShotAsync((c, a) => B(c, a), "12-second-device.png");
                await B("theme", "system");
            });

            await Section("concurrent edits and caret stability", async () =>
            {
                await A("add-page", M("SharedPagePomelo"));
                await A("type", "0", M("The quick brown fox jumps over the lazy dog\nsecond paragraph of the shared page"));
                var ids = (await A("ids")).Split('|');
                t.Check("B sees the new page arrive", await Automation.WaitUntilAsync(async () => (await B("pages")).Contains("SharedPagePomelo"), 15000), await B("pages"));
                await B("open", ids[0], ids[1], ids[2]);
                t.Check("pages converge", await ConvergedAsync(b), $"A «{Checks.Show(await A("text"))}» B «{Checks.Show(await B("text"))}»");

                // B's caret sits before "lazy"; A edits before it, at it, and around it.
                await B("select-text", "lazy", "before");
                await A("type", "0", "AAA ");
                t.Check("converged after an insert before B's caret", await ConvergedAsync(b));
                t.Eq("B's caret is still before the same word", "lazy", await B("after-caret", "4"));
                var caret = (await B("caret")).Split(',');
                t.Check("and is still a caret", caret[0] == caret[1], string.Join(",", caret));
                await A("select-text", "lazy", "before");
                await A("type-at-caret", "XX");
                t.Check("converged after an insert exactly at B's caret", await ConvergedAsync(b));
                t.Eq("remote text at the caret lands after it", "XXlazy", await B("after-caret", "6"));
                await B("type-at-caret", "bb");
                t.Check("converged after B typed at its kept caret", await ConvergedAsync(b));
                t.Check("B's typing went where its caret was", (await A("text")).Contains("the bbXXlazy dog"), await A("text"));

                // Both type at the same time, one character per message-loop turn, in the same paragraph.
                await A("select-text", "The quick", "before");
                await B("select-text", "dog", "after");
                var typingB = B("type-slowly", "BBBBBBBBBBBBBBBBBBBBBBBBB", "25");
                await A("type-slowly", "aaaaaaaaaaaaaaaaaaaaaaaaa", "25");
                await typingB;
                t.Check("converged after simultaneous typing", await ConvergedAsync(b), $"A «{Checks.Show(await A("text"))}» B «{Checks.Show(await B("text"))}»");
                var text = await A("text");
                t.Check("A's keystrokes stayed together, in order, where A typed", text.StartsWith("AAA aaaaaaaaaaaaaaaaaaaaaaaaaThe quick", StringComparison.Ordinal), text);
                t.Check("B's keystrokes stayed together, in order, where B typed", text.Contains("dogBBBBBBBBBBBBBBBBBBBBBBBBB\n"), text);
                t.Eq("A consistent", "ok", await A("verify"));
                t.Eq("B consistent", "ok", await B("verify"));
                t.Check("no full reloads were needed on either side", (await A("counters")).StartsWith("resets=0 ", StringComparison.Ordinal) && (await B("counters")).StartsWith("resets=0 ", StringComparison.Ordinal),
                    $"A {await A("counters")} / B {await B("counters")}");

                // Formatting against typing, both before the other side's change has arrived.
                await A("select-text", "quick brown");
                await B("select-text", "brown", "before");
                await A("run", "bold");
                await B("type-at-caret", "dark ");
                await B("select-text", "second paragraph");
                await B("run", "todo");
                await A("select-text", "second paragraph of", "after");
                await A("type-at-caret", " (A was here)");
                t.Check("converged after concurrent formatting and typing", await ConvergedAsync(b), $"A «{Checks.Show(await A("dump"))}» B «{Checks.Show(await B("dump"))}»");
                t.Check("the bold and the to-do both made it", (await A("dump")).Contains("{b}") && (await A("dump")).Contains("|todo]") && (await A("text")).Contains("(A was here)"), await A("dump"));
                t.Eq("A consistent after formatting", "ok", await A("verify"));
                t.Eq("B consistent after formatting", "ok", await B("verify"));

                // Undo on B only takes back B's own edit.
                await Task.Delay(700);
                await B("type", "-1", M(" BONLYUNDOWORD"));
                t.Check("converged", await ConvergedAsync(b));
                await Task.Delay(700);
                await A("type", "0", M("AKEEPSWORD "));
                t.Check("converged", await ConvergedAsync(b));
                await B("run", "undo");
                t.Check("converged after B's undo", await ConvergedAsync(b));
                text = await A("text");
                t.Check("B's undo removed B's text and left A's", !text.Contains("BONLYUNDOWORD") && text.Contains("AKEEPSWORD"), text);
            });

            await Section("offline, then merge", async () =>
            {
                t.Check("both have their live connection before the outage", await A("wait-live", "20000") == "True" && await B("wait-live", "20000") == "True", $"A: {await A("status-lines")} / B: {await B("status-lines")}");
                await ControlAsync("server-stop");
                t.Check("A notices the server is gone", await A("wait-state", "Offline", "40000") == "True", await A("status-lines"));
                t.Check("B notices too", await B("wait-state", "Offline", "40000") == "True", await B("status-lines"));
                await A("type", "0", M("OFFLINEFROMA "));
                await A("select-text", "OFFLINEFROMA");
                await A("run", "italic");
                await B("type", "-1", M(" OFFLINEFROMB"));
                await B("add-page", M("PageMadeOfflineOnB"));
                await B("type", "0", M("written on B while the server was down"));
                await B("select-page", "SharedPagePomelo");
                async Task<bool> ShowsPending(Func<string, string[], Task<string>> who) =>
                    await Automation.WaitUntilAsync(async () => Regex.IsMatch(await who("status", []), @"^(Offline|Syncing…) · \d+ pending$|^Offline · \d+ pending$"), 5000)
                    && await Automation.WaitUntilAsync(async () => Regex.IsMatch(await who("status", []), @"^Offline · \d+ pending$"), 15000);
                t.Check("A shows offline with its pending edits", await ShowsPending((c, a) => A(c, a)), await A("status"));
                t.Check("B shows offline with its pending edits", await ShowsPending((c, a) => B(c, a)), await B("status"));
                t.Check("the two differ while offline", await A("dump") != await B("dump"));
                await A("theme", "light");
                await A("sync-flyout", "show");
                await ShotAsync("10-sync-offline.png");
                await A("sync-flyout", "hide");
                await A("theme", "system");
                t.Check("editing carries on offline", (await A("verify")) == "ok" && (await B("verify")) == "ok");

                await ControlAsync("server-start");
                t.Check("both reconnect by themselves and merge", await ConvergedAsync(b, 90000), $"A {await A("status")} / B {await B("status")}");
                var text = await A("text");
                t.Check("both offline edits are in the merged page", text.StartsWith("OFFLINEFROMA ", StringComparison.Ordinal) && text.TrimEnd('\n').EndsWith("OFFLINEFROMB", StringComparison.Ordinal), text);
                t.Check("offline formatting merged", (await B("dump")).StartsWith("OFFLINEFROMA{i}", StringComparison.Ordinal), await B("dump"));
                t.Check("the page made offline on B reached A", await Automation.WaitUntilAsync(async () => (await A("pages")).Contains("PageMadeOfflineOnB"), 15000), await A("pages"));
                t.Eq("status is back to synced on A", "Synced", await A("status"));
                t.Eq("and on B", "Synced", await B("status"));
                t.Eq("trees agree after the merge", await A("tree"), await B("tree"));
                t.Check("the live connection comes back on both", await A("wait-live", "45000") == "True" && await B("wait-live", "45000") == "True", $"A: {await A("status-lines")} / B: {await B("status-lines")}");
            });

            await Section("tree changes travel and the lists update live", async () =>
            {
                async Task<bool> BSees(string command, string expected) =>
                    await Automation.WaitUntilAsync(async () => (await B(command)) == expected, 15000);
                async Task<bool> ASees(string command, string expected) =>
                    await Automation.WaitUntilAsync(async () => (await A(command)) == expected, 15000);

                var selectedOnB = await B("selected");
                await A("add-section", M("SectionFromA"));
                t.Check("a new section appears on B", await Automation.WaitUntilAsync(async () => (await B("sections")).Contains("SectionFromA"), 15000), await B("sections"));
                t.Eq("B's selection did not jump", selectedOnB, await B("selected"));
                await A("select-section", "MangoSection");
                await A("move-section", "SectionFromA", "-3");
                t.Check("B shows the new section order", await BSees("sections", await A("sections")), $"A {await A("sections")} / B {await B("sections")}");
                await B("rename-section", "SectionFromA", M("SectionRenamedOnB"));
                t.Check("a rename on B shows on A", await Automation.WaitUntilAsync(async () => (await A("sections")).Contains("SectionRenamedOnB"), 15000), await A("sections"));

                await A("select-page", "SharedPagePomelo");
                await B("select-page", "SharedPagePomelo");
                await B("set-title", M("SharedPageRenamedOnB"));
                t.Check("a page renamed on B shows in A's list", await Automation.WaitUntilAsync(async () => (await A("pages")).Contains("SharedPageRenamedOnB"), 15000), await A("pages"));
                t.Check("and in the title above A's editor, while A has the page open", await ASees("title", "SharedPageRenamedOnB"), await A("title"));
                t.Eq("A still has that page selected", "MangoSection|SharedPageRenamedOnB", await A("selected"));

                await A("move-page", "SharedPageRenamedOnB", "-1");
                t.Check("page order follows on B", await BSees("pages", await A("pages")), $"A {await A("pages")} / B {await B("pages")}");
                t.Eq("B keeps its page selected through the reorder", "MangoSection|SharedPageRenamedOnB", await B("selected"));

                await A("delete-page", "SharedPageRenamedOnB");
                t.Check("a page deleted on A disappears on B, though B had it open", await Automation.WaitUntilAsync(async () => !(await B("pages")).Contains("SharedPageRenamedOnB"), 15000), await B("pages"));
                t.Check("B moved on to another page", await Automation.WaitUntilAsync(async () => { var s = await B("selected"); return s.StartsWith("MangoSection|", StringComparison.Ordinal) && s.Length > "MangoSection|".Length; }, 5000), await B("selected"));
                t.Eq("B is consistent on the page it moved to", "ok", await B("verify"));

                await A("add-notebook", M("NotebookFromA"));
                t.Check("a notebook created on A arrives on B", await Automation.WaitUntilAsync(async () => (await B("tree")).Contains("# NotebookFromA"), 20000), await B("tree"));
                await A("rename-notebook", M("NotebookRenamedOnA"));
                t.Check("and its new name", await Automation.WaitUntilAsync(async () => (await B("tree")).Contains("# NotebookRenamedOnA"), 20000), await B("tree"));
                await A("select-notebook", "KiwiNotebook");
                t.Check("everything settles", await Automation.WaitUntilAsync(async () => _a.IsSynced() && (await B("wait-synced", "50")) == "True", 20000));
                t.Eq("trees agree at the end", await A("tree"), await B("tree"));
            });

            await Section("devices, password change, sign-in again", async () =>
            {
                await A("open-settings");
                t.Eq("A lists both devices", $"{DeviceA}*|{DeviceB}", await A("devices"));
                await B("open-settings");
                t.Eq("B renames itself (needs the password)", "True", await B("rename-device", Password, "Selftest Laptop B"));
                t.Eq("A sees the new name", $"Selftest Laptop B|{DeviceA}*", await A("devices"));
                t.Eq("a wrong password does not rename", "False", await B("rename-device", "wrong", "Nope"));
                await B("close-settings");

                t.Check("a wrong current password does not change the password", await A("change-password", "wrong", NewPassword) != "ok");
                t.Eq("A changes the master password", "ok", await A("change-password", Password, NewPassword));
                await A("theme", "light");
                await ShotAsync("11-settings-two-devices.png");
                await A("theme", "system");
                await A("close-settings");

                // A device that is idle learns of a revoked session at its next sync; an edit elsewhere causes one.
                await A("select-section", "MangoSection");
                await A("select-page", "FormattingPage");
                await A("type", "-1", M(" AFTERPASSWORDCHANGE"));
                t.Check("B is told to sign in again", await B("wait-state", "AuthRequired", "40000") == "True", await B("status"));
                t.Eq("B's status says so", "Sign in needed", await B("status"));
                t.Eq("and the page shows the sign-in bar", "True", await B("auth-bar"));
                await B("select-section", "MangoSection");
                await B("select-page", "FormattingPage");
                await B("type", "-1", M(" TYPEDWHILESIGNEDOUT"));
                t.Check("B keeps working and queues its edits", int.Parse(await B("pending")) > 0);
                t.Check("the old password no longer signs in", await B("signin", Password) != "ok");
                t.Eq("the new password does", "ok", await B("signin", NewPassword));
                t.Check("B syncs again", await B("wait-synced", "30000") == "True", await B("status-lines"));
                t.Eq("the sign-in bar is gone", "False", await B("auth-bar"));
                await A("select-section", "MangoSection");
                await A("select-page", "FormattingPage");
                t.Check("what B typed while signed out reaches A", await Automation.WaitUntilAsync(async () => (await A("text")).Contains("TYPEDWHILESIGNEDOUT"), 20000), await A("text"));

                t.Eq("B locks", "unlock", await B("lock"));
                t.Check("B's lock screen no longer takes the old password", (await B("unlock", Password)).StartsWith("error", StringComparison.Ordinal));
                t.Eq("and takes the new one", "ok", await B("unlock", NewPassword));
                t.Eq("A locks", "unlock", await A("lock"));
                t.Eq("A unlocks with the new password", "ok", await A("unlock", NewPassword));

                await A("open-settings");
                t.Eq("A revokes B", "True", await A("revoke", "Selftest Laptop B"));
                t.Eq("B is gone from the list", DeviceA + "*", await A("devices"));
                await A("close-settings");
                t.Check("B finds out it was revoked", await B("wait-state", "AuthRequired", "40000") == "True", await B("status"));
            });

            await Section("nothing readable on disk", async () =>
            {
                await A("wait-synced", "20000");
                var tokenA = await A("session-token");
                var tokenB = await B("session-token");
                t.Check("both devices hold a session token to look for", tokenA.Length > 10 && tokenB.Length > 10 && tokenA != tokenB);
                string[] secrets = [Password, NewPassword, secretKey, secretKey.Replace("-", ""), tokenA, tokenB];
                foreach (var profile in new[] { window.Session.Paths, AppPaths.For(ProfileB) })
                {
                    ScanProfile(profile, [.. secrets, .. _markers]);
                }

                // The logs of this run (this process and the second instance) may quote test text in a failure
                // message, but never a password, the Secret Key or a session token.
                foreach (var log in new[] { AppLog.Path, Path.Combine(_out, "agent.log"), Path.Combine(_out, "e2e-first.log"), Path.Combine(_out, "e2e-restart.log") })
                {
                    if (log is null || !File.Exists(log))
                    {
                        continue;
                    }

                    using var stream = new FileStream(log, FileMode.Open, FileAccess.Read, FileShare.ReadWrite);
                    using var reader = new StreamReader(stream);
                    var text = reader.ReadToEnd();
                    t.Check($"no secret in {Path.GetFileName(log)}", !secrets.Any(s => text.Contains(s, StringComparison.Ordinal)));
                }

                var settings = File.ReadAllText(window.Session.Paths.SettingsPath);
                t.Check("the settings file holds ids and preferences only", settings.Contains("lastNotebookId") && !_markers.Any(settings.Contains), settings);
            });

            await Section("sign out wipes the device", async () =>
            {
                var pathsB = AppPaths.For(ProfileB);
                t.Eq("B signs out", "setup:server", await B("signout"));
                t.Check("B's database is gone", !File.Exists(pathsB.DatabasePath) && !File.Exists(pathsB.DatabasePath + "-wal"));
                t.Check("B's secrets are gone", new VaultSecretStore(pathsB.SecretScope).Get(SecretNames.SecretKey) is null
                    && new VaultSecretStore(pathsB.SecretScope).Get(SecretNames.SessionToken) is null && !File.Exists(pathsB.DpapiSecretsPath));
                t.Eq("B stops", "bye", await B("quit"));
                t.Check("the second instance exits by itself", agent!.WaitForExit(20000), "still running");

                var pathsA = window.Session.Paths;
                t.Eq("A signs out", "setup:server", await A("signout"));
                t.Check("A's database is gone", !File.Exists(pathsA.DatabasePath));
                t.Check("A's secrets are gone", window.Session.Secrets.Get(SecretNames.SecretKey) is null && window.Session.Secrets.Get(SecretNames.SessionToken) is null);
                t.Check("A's settings are back to defaults", AppSettings.Load(pathsA.SettingsPath) is { ServerUrl: null, LastNotebookId: null });
                t.Check("the server still has the account (sign-out is local)", (await AppSession.CheckServerAsync(new Uri(_server))).Status is { RegistrationOpen: false });
            });
        }
        finally
        {
            if (agent is { HasExited: false })
            {
                try
                {
                    await b.CallAsync("quit");
                }
                catch (Exception)
                {
                    // already gone or stuck
                }

                if (!agent.WaitForExit(8000))
                {
                    agent.Kill();
                    t.Check("the second instance had to be killed", false);
                }
            }
        }
    }

    /// <summary>Asserts that none of the given strings occurs in any file of a profile, as UTF-8 or UTF-16.</summary>
    private void ScanProfile(AppPaths paths, IReadOnlyList<string> needles)
    {
        var files = paths.OwnFiles().ToList();
        long total = 0;
        var sawUsername = false;
        var found = new List<string>();
        foreach (var file in files)
        {
            byte[] bytes;
            using (var stream = new FileStream(file, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete))
            {
                bytes = new byte[stream.Length];
                stream.ReadExactly(bytes);
            }

            total += bytes.Length;
            sawUsername |= bytes.AsSpan().IndexOf(Encoding.UTF8.GetBytes(Username)) >= 0;
            foreach (var needle in needles.Where(n => n.Length > 0))
            {
                if (bytes.AsSpan().IndexOf(Encoding.UTF8.GetBytes(needle)) >= 0 || bytes.AsSpan().IndexOf(Encoding.Unicode.GetBytes(needle)) >= 0)
                {
                    found.Add($"{Path.GetFileName(file)}: {(needle.Length > 12 ? needle[..6] + "…" : needle)}");
                }
            }
        }

        var name = paths.Profile ?? "(default)";
        Checks.Note($"profile {name}: {files.Count} files, {total} bytes [{string.Join(", ", files.Select(Path.GetFileName))}], {needles.Count} strings looked for");
        t.Check($"profile {name} has a database worth scanning", files.Any(f => f.EndsWith("twonote.db", StringComparison.Ordinal)) && total > 20000, $"{total} bytes");
        t.Check($"the scan can see plaintext in profile {name} (the username is stored in the clear)", sawUsername);
        t.Check($"no password, Secret Key or note text in the files of profile {name}", found.Count == 0, string.Join("; ", found.Take(10)));
    }
}
