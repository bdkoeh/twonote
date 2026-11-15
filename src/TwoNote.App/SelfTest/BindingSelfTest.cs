using System.Diagnostics;
using System.Runtime.InteropServices;
using Microsoft.UI.Dispatching;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using TwoNote.App.Editor;
using TwoNote.Core;
using TwoNote.Core.Documents;
using Windows.ApplicationModel.DataTransfer;

namespace TwoNote.App.SelfTest;

/// <summary>
/// In-process stand-in for "two PCs and a server": carries the updates of two page documents between two
/// bindings, optionally late, and can be cut. On reconnect the two sides exchange state-vector diffs, exactly
/// like a real resync.
/// </summary>
internal sealed class LoopbackLink
{
    private readonly RichEditBinding _a, _b;
    private readonly DispatcherQueue _dispatcher;
    private readonly Dictionary<RichEditBinding, Task> _tail = [];
    private int _inFlight;

    public LoopbackLink(RichEditBinding a, RichEditBinding b, DispatcherQueue dispatcher)
    {
        _a = a;
        _b = b;
        _dispatcher = dispatcher;
        a.Page.LocalUpdate += u =>
        {
            if (Connected)
            {
                Send(_b, u);
            }
        };
        b.Page.LocalUpdate += u =>
        {
            if (Connected)
            {
                Send(_a, u);
            }
        };
    }

    public bool Connected { get; private set; } = true;

    public int DelayMs { get; set; }

    public int Delivered { get; private set; }

    public int Failures { get; private set; }

    /// <summary>
    /// True (default): updates arrive in the order they were sent, like the product's per-document server log.
    /// False: each update is delayed independently, so they can overtake each other (Yrs can then keep a delete
    /// pending until the next state-vector resync).
    /// </summary>
    public bool Ordered { get; set; } = true;

    public void SetConnected(bool connected)
    {
        if (connected == Connected)
        {
            return;
        }

        Connected = connected;
        if (!connected)
        {
            return;
        }

        _a.SyncLocal();
        _b.SyncLocal();
        var fromA = _a.Page.EncodeDiff(_b.Page.EncodeStateVector());
        var fromB = _b.Page.EncodeDiff(_a.Page.EncodeStateVector());
        Send(_b, fromA);
        Send(_a, fromB);
    }

    private async void Send(RichEditBinding to, byte[] update)
    {
        _inFlight++;
        try
        {
            // Always asynchronous: an update is never applied from inside the sender's TextChanging handler.
            var latency = DelayMs > 0 ? Task.Delay(DelayMs) : Task.CompletedTask;
            var mine = new TaskCompletionSource();
            var previous = _tail.GetValueOrDefault(to, Task.CompletedTask);
            if (Ordered)
            {
                _tail[to] = mine.Task;
            }

            try
            {
                await latency;
                if (Ordered)
                {
                    await previous;
                }

                await Deliver(to, update);
            }
            finally
            {
                mine.SetResult();
            }
        }
        finally
        {
            _inFlight--;
        }
    }

    private async Task Deliver(RichEditBinding to, byte[] update)
    {
        var done = new TaskCompletionSource();
        _dispatcher.TryEnqueue(() =>
        {
            try
            {
                to.ApplyRemoteUpdate(update);
                Delivered++;
            }
            catch (Exception ex)
            {
                Failures++;
                AppLog.Line($"delivery to {to.Name} failed: {ex}");
            }
            finally
            {
                done.SetResult();
            }
        });
        await done.Task;
    }

    /// <summary>Completes when nothing is in flight any more.</summary>
    public async Task DrainAsync()
    {
        do
        {
            await Task.Delay(5);
        }
        while (_inFlight > 0);
    }
}

/// <summary>Two editors, each with its own replica of one page document, joined by a <see cref="LoopbackLink"/>.</summary>
internal sealed partial class BindingTestWindow : Window
{
    private readonly Grid _root = new();
    private PageDocument? _pageA, _pageB;

    public BindingTestWindow(AppOptions options)
    {
        Title = "TwoNote binding self-test";
        AppWindow.Resize(new Windows.Graphics.SizeInt32(1500, 900));
        _root.ColumnDefinitions.Add(new ColumnDefinition());
        _root.ColumnDefinitions.Add(new ColumnDefinition());
        _root.Background = (Microsoft.UI.Xaml.Media.Brush)Application.Current.Resources["ApplicationPageBackgroundThemeBrush"];
        BoxA = new RichEditBox { Margin = new Thickness(8, 8, 4, 8), IsSpellCheckEnabled = false };
        BoxB = new RichEditBox { Margin = new Thickness(4, 8, 8, 8), IsSpellCheckEnabled = false };
        Grid.SetColumn(BoxB, 1);
        _root.Children.Add(BoxA);
        _root.Children.Add(BoxB);
        Content = _root;
        if (options.Value("--theme") == "dark")
        {
            _root.RequestedTheme = ElementTheme.Dark;
        }

        _root.ActualThemeChanged += (_, _) =>
        {
            AppLog.Line($"  note: ActualThemeChanged -> {(Dark ? "dark" : "light")}");
            A?.SetTheme(Dark);
            B?.SetTheme(Dark);
        };
        _root.Loaded += async (_, _) =>
        {
            var checks = new Checks { Verbose = options.Has("--verbose") };
            try
            {
                NewSession();
                var seeds = (options.Value("--seeds") ?? "1,2,3,4,5").Split(',').Select(int.Parse).ToArray();
                var ops = int.Parse(options.Value("--ops") ?? "300");
                await new BindingSelfTest(this, checks, options.Value("--out")).RunAsync(seeds, ops, options.Has("--input"), options.Value("--only"));
            }
            catch (Exception ex)
            {
                AppLog.Line("SELFTEST RESULT: FAIL (harness exception) " + ex);
                checks.Check("harness", false);
            }

            Environment.ExitCode = checks.Failures == 0 ? 0 : 1;
            Close();
        };
    }

    public RichEditBinding A { get; private set; } = null!;

    public RichEditBinding B { get; private set; } = null!;

    public LoopbackLink Link { get; private set; } = null!;

    public RichEditBox BoxA { get; }

    public RichEditBox BoxB { get; }

    public FrameworkElement RootElement => _root;

    public bool Dark => _root.ActualTheme == ElementTheme.Dark;

    /// <summary>Fresh pair of replicas. A creates the page; B opens it from A's state (a page is created once).</summary>
    public void NewSession(int undoCaptureMs = 500)
    {
        A?.Dispose();
        B?.Dispose();
        _pageA?.Dispose();
        _pageB?.Dispose();
        var id = WireEncoding.IdToHex(WireEncoding.NewId());
        _pageA = new PageDocument(id, undoCaptureMs);
        _pageA.Initialize();
        _pageB = new PageDocument(id, undoCaptureMs);
        _pageB.ApplyUpdate(_pageA.EncodeState());
        A = new RichEditBinding("A", BoxA, _pageA, Dark);
        B = new RichEditBinding("B", BoxB, _pageB, Dark);
        Link = new LoopbackLink(A, B, DispatcherQueue);
    }

    public void SetConnected(bool on) => Link.SetConnected(on);

    /// <summary>Changes the theme of the whole window content, as a system theme change does.</summary>
    public void SetElementTheme(bool dark) => _root.RequestedTheme = dark ? ElementTheme.Dark : ElementTheme.Light;
}

/// <summary>
/// The binding assertions, run against the product binding on <see cref="PageDocument"/>
/// (<c>--selftest binding</c>). Drives both editors through the text object model the way user input does (the
/// binding only ever sees "the control changed"), toggles the link, and after every step asserts
/// control == shadow == CRDT on each side, and A == B once the link has drained.
/// </summary>
internal sealed class BindingSelfTest(BindingTestWindow w, Checks t, string? shots)
{
    private const string TestLink = "https://example.com/";
    private int _reentrantSeen;

    private sealed class Side(RichEditBox box, Func<RichEditBinding> binding)
    {
        public RichEditBox Box => box;

        public RichEditTextDocument Doc => box.Document;

        public RichEditBinding B => binding();

        public string Text => B.Shadow.Text;

        public int Len => B.Shadow.Length;

        public void Select(int a, int b) => Doc.Selection.SetRange(a, b);

        public void Type(int pos, string text)
        {
            Doc.Selection.SetRange(pos, pos);
            Doc.Selection.TypeText(text.Replace('\n', '\r'));
        }

        public void Replace(int a, int b, string text)
        {
            Doc.Selection.SetRange(a, b);
            Doc.Selection.TypeText(text.Replace('\n', '\r'));
        }

        public void Delete(int a, int b)
        {
            Doc.Selection.SetRange(a, b);
            Doc.Selection.SetText(TextSetOptions.None, "");
        }

        public int ParaStart(int index)
        {
            var text = Text;
            var p = 0;
            for (var i = 0; i < index; i++)
            {
                p = text.IndexOf('\n', p) + 1;
            }

            return p;
        }

        public string Blocks() => string.Join(",", B.ReadControlCells().Where(c => c.Ch == '\n').Select(c => c.Block.ToString() is { Length: > 0 } s ? s : "p"));

        /// <summary>A fixed test URL on the selection, or off.</summary>
        public void ToggleLink()
        {
            B.SyncLocal();
            var (s, e) = B.Selection;
            B.SetLink(s, e, B.AllHave(s, e, "link") ? null : TestLink);
        }

        public void Toggle(string key)
        {
            if (key == "link")
            {
                ToggleLink();
            }
            else
            {
                B.ToggleInline(key);
            }
        }
    }

    private Side A => new(w.BoxA, () => w.A);

    private Side B => new(w.BoxB, () => w.B);

    private static string Show(string s) => Checks.Show(s);

    private static List<Cell> Cells(RichEditBinding b) => RichEditBinding.ReadCells(b.Page);

    private async Task Settle()
    {
        for (var i = 0; i < 3; i++)
        {
            await w.Link.DrainAsync();
            w.A.RunQueuedRender();
            w.B.RunQueuedRender();
            await Task.Delay(10);
        }

        await w.Link.DrainAsync();
    }

    private void VerifySide(RichEditBinding b, string when)
    {
        var problem = b.Verify();
        t.Check($"{b.Name} consistent {when}", problem == null, problem);
    }

    /// <summary>Both sides internally consistent and, when the link is up and drained, identical to each other.</summary>
    private async Task VerifyAll(string when)
    {
        await Settle();
        VerifySide(w.A, when);
        VerifySide(w.B, when);
        if (!w.Link.Connected)
        {
            return;
        }

        await Settle();
        var a = RichModel.Dump(Cells(w.A), effectiveBlocks: false);
        var b = RichModel.Dump(Cells(w.B), effectiveBlocks: false);
        t.Check($"CRDT A == CRDT B {when}", a == b, RichEditBinding.FirstDiff(a, b));
        if (a != b)
        {
            AppLog.Line($"  DIAG state vectors equal: {w.A.Page.EncodeStateVector().SequenceEqual(w.B.Page.EncodeStateVector())}; text equal: {w.A.Shadow.Text == w.B.Shadow.Text}");
        }

        var ca = RichModel.Dump(w.A.ReadControlCells(), linkAsFlag: true);
        var cb = RichModel.Dump(w.B.ReadControlCells(), linkAsFlag: true);
        t.Check($"control A == control B {when}", ca == cb, RichEditBinding.FirstDiff(ca, cb));
        t.Check($"no failed deliveries {when}", w.Link.Failures == 0, $"{w.Link.Failures} failed");
        if (w.A.ReentrantDeliveries + w.B.ReentrantDeliveries > _reentrantSeen)
        {
            _reentrantSeen = w.A.ReentrantDeliveries + w.B.ReentrantDeliveries;
            Checks.Note($"{_reentrantSeen} deliveries arrived re-entrantly (nested message pump) and were deferred");
        }
    }

    private async Task Fresh(int undoCaptureMs = 0)
    {
        w.NewSession(undoCaptureMs);
        _reentrantSeen = 0;
        w.Link.DelayMs = 0;
        await Task.Delay(20);
    }

    public async Task RunAsync(int[] seeds, int ops, bool realInput, string? only)
    {
        var sw = Stopwatch.StartNew();
        AppLog.Line($"binding self-test: theme={(w.Dark ? "dark" : "light")} seeds={string.Join(',', seeds)} ops={ops}");
        var scenarios = new List<(string Name, Func<Task> Run)>
        {
            ("typing", Typing), ("inline", Inline), ("blocks", Blocks), ("native-paragraphs", NativeParagraphs),
            ("offline-merge", OfflineMerge), ("delayed-concurrency", DelayedConcurrency), ("selection", Selection),
            ("scroll", Scroll), ("undo", Undo), ("paste", Paste), ("unicode", Unicode), ("composition-gating", CompositionGating),
            ("foreign-attrs", ForeignAttrs), ("not-yet-arrived", NotYetArrived), ("forbidden-content", ForbiddenContent),
            ("theme-switch", ThemeSwitch), ("theme-real", ThemeReal), ("auto-list", AutoList), ("rich-paste", RichPaste), ("perf", Perf),
        };
        foreach (var seed in seeds)
        {
            scenarios.Add(($"random-{seed}", () => Random(seed, ops)));
        }

        foreach (var seed in seeds)
        {
            scenarios.Add(($"unordered-{seed}", () => Random(seed, ops, ordered: false)));
        }

        if (realInput)
        {
            scenarios.Add(("real-input", RealInput));
        }

        foreach (var (name, run) in scenarios)
        {
            if (only != null && !only.Split(',').Any(name.StartsWith))
            {
                continue;
            }

            t.Scenario = name;
            var before = t.Failures;
            var checksBefore = t.Count;
            try
            {
                await Fresh();
                await run();
                t.Check("no full resets (ranged apply always matched)",
                    (w.A.FullResets == 0 && w.B.FullResets == 0) || name is "foreign-attrs" or "not-yet-arrived" or "forbidden-content",
                    $"A={w.A.FullResets} B={w.B.FullResets}");
            }
            catch (Exception ex)
            {
                t.Check("scenario threw", false, ex.ToString());
            }

            AppLog.Line($"{(t.Failures == before ? "PASS" : "FAIL")} {name}  ({t.Count - checksBefore} checks; A tx={w.A.LocalTransactions} deltas={w.A.RemoteDeltas} fixes={w.A.RenderFixes}; B tx={w.B.LocalTransactions} deltas={w.B.RemoteDeltas} fixes={w.B.RenderFixes})");
        }

        try
        {
            Clipboard.Clear();
        }
        catch (Exception)
        {
            // not ours to insist on
        }

        AppLog.Line($"SELFTEST RESULT: {(t.Failures == 0 ? "PASS" : "FAIL")}  checks={t.Count} failures={t.Failures} elapsed={sw.Elapsed.TotalSeconds:F1}s");
    }

    // ---------------------------------------------------------------------------------------------------

    private async Task Typing()
    {
        A.Type(0, "Hello world");
        await Settle();
        t.Eq("B received A's typing", "Hello world\n", B.Text);
        B.Type(0, "Say: ");
        await Settle();
        t.Eq("A received B's typing", "Say: Hello world\n", A.Text);
        A.Type(A.Len - 1, "\nsecond paragraph");
        await Settle();
        t.Eq("paragraph break arrives", "Say: Hello world\nsecond paragraph\n", B.Text);
        B.Delete(0, 5);
        await Settle();
        t.Eq("deletion arrives", "Hello world\nsecond paragraph\n", A.Text);
        await VerifyAll("after typing");
    }

    private async Task Inline()
    {
        A.Type(0, "The quick brown fox jumps");
        A.Select(4, 9);
        A.Toggle("bold");
        A.Select(7, 15);
        A.Toggle("italic");
        A.Select(10, 19);
        A.Toggle("underline");
        A.Select(16, 19);
        A.Toggle("strike");
        A.Select(20, 25);
        A.Toggle("code");
        A.Select(0, 3);
        A.Toggle("link");
        await VerifyAll("after inline formatting");
        var c = w.B.Shadow.Cells;
        t.Check("bold range", !c[3].Inline.Bold && c[4].Inline.Bold && c[8].Inline.Bold && !c[9].Inline.Bold);
        t.Check("bold+italic overlap", c[7].Inline.Bold && c[7].Inline.Italic);
        t.Check("underline+strike", c[17].Inline.Underline && c[17].Inline.Strike && !c[15].Inline.Strike);
        t.Check("code", c[21].Inline.Code && w.B.ReadControlCells()[21].Inline.Code);
        t.Check("link url travels", c[1].Inline.Link == TestLink && w.B.ReadControlCells()[1].Inline.Link == "*");
        A.Select(4, 9);
        A.Toggle("bold");
        await VerifyAll("after un-bolding");
        t.Check("bold removed remotely", !w.B.Shadow.Cells[5].Inline.Bold);

        // Typing inside formatted text on the other side inherits the formatting through the control.
        B.Type(8, "X");
        B.Type(1, "Y");
        B.Type(23, "Z");
        await VerifyAll("after typing inside formatted runs");
        t.Check("typed inside italic is italic", w.A.Shadow.Cells[9].Inline.Italic);
        t.Check("typed inside link gets the neighbour's url", w.A.Shadow.Cells[1].Inline.Link == TestLink);
        t.Check("typed inside code is code", w.A.Shadow.Cells[23].Inline.Code, A.Text);

        // Native format change straight on the control (what built-in Ctrl+B does).
        B.Select(0, 4);
        B.Doc.Selection.CharacterFormat.Bold = FormatEffect.On;
        await VerifyAll("after native character format change");
        t.Check("native bold reached A", w.A.Shadow.Cells[2].Inline.Bold);

        // Link editing: change the address, find the range from a caret inside it, remove it.
        var link = w.A.LinkRangeAt(2);
        t.Check("link range found from a caret inside it", link is { Start: 0, Url: TestLink }, link?.ToString());
        if (link is { } l)
        {
            w.A.SetLink(l.Start, l.End, "https://example.org/changed");
            await VerifyAll("after changing a link");
            t.Check("changed address reached B", w.B.Shadow.Cells[1].Inline.Link == "https://example.org/changed");
            w.A.SetLink(l.Start, l.End, null);
            await VerifyAll("after removing a link");
            t.Check("link removed on B", w.B.Shadow.Cells[1].Inline.Link == null && w.B.LinkRangeAt(1) == null);
        }

        A.Select(A.Len - 1, A.Len - 1);
        w.A.InsertLink("inserted link", "https://example.net/");
        await VerifyAll("after inserting a link");
        var at = B.Text.IndexOf("inserted link", StringComparison.Ordinal);
        t.Check("inserted link text and address reached B", at >= 0 && w.B.Shadow.Cells[at + 3].Inline.Link == "https://example.net/", B.Text);
    }

    private async Task Blocks()
    {
        A.Type(0, "Title\nSub\nSubsub\nbullet\nnumber\ntask\ncode()\nindented");
        string[] blocks = ["h1", "h2", "h3", "ul", "ol", "todo", "code"];
        for (var i = 0; i < blocks.Length; i++)
        {
            var p = A.ParaStart(i);
            var block = blocks[i];
            w.A.UpdateBlocks(p, p, b => b with { Block = block });
        }

        var last = A.ParaStart(7);
        w.A.UpdateBlocks(last, last, b => b with { Indent = 2 });
        await VerifyAll("after block formatting");
        t.Eq("B control paragraphs", "h1,h2,h3,ul,ol,todo,code,indent=2", B.Blocks());

        // To-do: click on the marker toggles, click on the text does not.
        var task = B.ParaStart(5);
        t.Check("click in text does not toggle", !w.B.TryToggleTodoAt(new Windows.Foundation.Point(w.B.MarkerPoint(task).X + 60, w.B.MarkerPoint(task).Y)));
        t.Check("click on marker toggles", w.B.TryToggleTodoAt(w.B.MarkerPoint(task)));
        await VerifyAll("after to-do toggle");
        t.Eq("A sees checked", "h1,h2,h3,ul,ol,todo,checked,code,indent=2", A.Blocks());

        // Enter inside a to-do (native split) gives more to-dos; neighbours in the same state must not count up.
        A.Type(A.ParaStart(6) - 1, "\ntask two\ntask three\ntask four");
        await VerifyAll("after splitting to-dos");
        t.Eq("to-do run", "h1,h2,h3,ul,ol,todo,checked,todo,checked,todo,checked,todo,checked,code,indent=2", B.Blocks());
        var t2 = B.ParaStart(6);
        w.B.UpdateBlocks(t2, B.ParaStart(8), b => b with { Checked = false });
        await VerifyAll("after unchecking");
        w.A.UpdateBlocks(A.ParaStart(3), A.ParaStart(4), b => b with { Indent = b.Indent + 1 });
        await VerifyAll("after indenting lists");
        if (shots is not null)
        {
            await Capture.WindowAsync(WinRT.Interop.WindowNative.GetWindowHandle(w), w.RootElement, Path.Combine(shots, $"binding-blocks-{(w.Dark ? "dark" : "light")}.png"));
        }

        // Remove a to-do from the middle of the run remotely: alignment chain must be repaired on both sides.
        B.Delete(B.ParaStart(6), B.ParaStart(7));
        await VerifyAll("after deleting a to-do paragraph");
        w.B.ToggleBlock("todo");
        await VerifyAll("after toggling block off");
    }

    private async Task NativeParagraphs()
    {
        A.Type(0, "head\nbody one\nbody two");
        w.A.UpdateBlocks(0, 0, b => b with { Block = "h1" });
        w.A.UpdateBlocks(A.ParaStart(1), A.ParaStart(1), b => b with { Block = "ul" });
        await VerifyAll("setup");
        A.Type(A.ParaStart(1) + 4, "\n"); // Enter inside the bullet
        await VerifyAll("after native split");
        t.Eq("split keeps the list on both halves", "h1,ul,ul,p", B.Blocks());
        A.Delete(4, 5); // join heading and first bullet: RichEdit keeps the FIRST paragraph's format
        await VerifyAll("after native join");
        Checks.Note($"joining h1 + ul in the control gives [{A.Blocks()}], text «{Show(A.Text)}»");
        B.Delete(B.ParaStart(1) - 1, B.ParaStart(1)); // join on the other side
        await VerifyAll("after second join");

        // RichEdit changing paragraph format on its own (e.g. Backspace at the start of a bullet).
        A.Type(A.Len - 1, "\nlist item");
        var p = A.ParaStart(A.Text.Count(ch => ch == '\n') - 1);
        A.Select(p, p);
        A.Doc.Selection.ParagraphFormat.ListType = MarkerType.Bullet;
        await VerifyAll("after native list on");
        t.Check("native bullet reached B", B.Blocks().EndsWith("ul", StringComparison.Ordinal), B.Blocks());
        A.Doc.Selection.ParagraphFormat.ListType = MarkerType.None;
        await VerifyAll("after native list off");
        t.Check("native bullet removal reached B", B.Blocks().EndsWith(",p", StringComparison.Ordinal), B.Blocks());

        // Native alignment (Ctrl+E/R/J in RichEdit) is not part of the format: it is put back.
        A.Select(0, 0);
        A.Doc.Selection.ParagraphFormat.Alignment = ParagraphAlignment.Center;
        await VerifyAll("after native centre alignment");
        t.Check("alignment was normalised", A.Doc.GetRange(0, 0).ParagraphFormat.Alignment == ParagraphAlignment.Left,
            A.Doc.GetRange(0, 0).ParagraphFormat.Alignment.ToString());
    }

    private async Task OfflineMerge()
    {
        A.Type(0, "alpha beta gamma\nsecond line");
        await VerifyAll("setup");
        w.SetConnected(false);
        A.Type(6, "AAA ");
        A.Select(0, 5);
        A.Toggle("bold");
        w.A.UpdateBlocks(0, 0, b => b with { Block = "h1" });
        B.Type(6, "BBB ");
        var g = B.Text.IndexOf("gamma", StringComparison.Ordinal);
        B.Delete(g, g + 5);
        w.B.UpdateBlocks(B.ParaStart(1), B.ParaStart(1), b => b with { Block = "todo" });
        B.Type(B.Len - 1, " (edited offline)");
        VerifySide(w.A, "offline");
        VerifySide(w.B, "offline");
        t.Check("sides differ while offline", A.Text != B.Text);
        w.SetConnected(true);
        await VerifyAll("after reconnect");
        t.Check("both offline insertions survive", A.Text.Contains("AAA ") && A.Text.Contains("BBB ") && !A.Text.Contains("gamma") && A.Text.Contains("(edited offline)"), A.Text);
        t.Eq("offline block changes merged", "h1,todo", A.Blocks());
        t.Check("offline bold merged", w.B.Shadow.Cells[0].Inline.Bold, RichModel.Dump(w.B.Shadow.Cells));
    }

    private async Task DelayedConcurrency()
    {
        A.Type(0, "shared starting text for both sides\nsecond paragraph here");
        await VerifyAll("setup");
        w.Link.DelayMs = 120;
        var rng = new Random(42);
        for (var i = 0; i < 60; i++)
        {
            var s = i % 2 == 0 ? A : B;
            var len = s.Len;
            if (rng.Next(4) == 0 && len > 6)
            {
                var at = rng.Next(len - 4);
                s.Delete(at, at + rng.Next(1, 3));
            }
            else
            {
                s.Type(rng.Next(len), rng.Next(8) == 0 ? "\n" : "" + (char)('a' + i % 26) + (char)('A' + i % 26));
            }

            if (i % 7 == 3)
            {
                s.Select(rng.Next(len / 2), len / 2 + rng.Next(len / 2));
                s.Toggle(i % 2 == 0 ? "bold" : "italic");
            }

            await Task.Delay(15); // shorter than the link delay: edits really are concurrent
        }

        await VerifyAll("after 60 concurrent edits with 120 ms latency");
        w.Link.DelayMs = 0;
    }

    private async Task Selection()
    {
        A.Type(0, "0123456789 abcdefghij klmnop");
        await Settle();
        string Sel()
        {
            var s = B.Doc.Selection;
            return B.Text[s.StartPosition..s.EndPosition];
        }

        B.Select(11, 21);
        t.Eq("initial selection", "abcdefghij", Sel());
        A.Type(0, "XX");
        await Settle();
        t.Eq("insert before selection", "abcdefghij", Sel());
        A.Type(A.Text.IndexOf('d'), "YY");
        await Settle();
        t.Eq("insert inside selection", "abcYYdefghij", Sel());
        A.Type(A.Text.IndexOf('a'), "<<");
        await Settle();
        t.Eq("insert at selection start stays outside", "abcYYdefghij", Sel());
        A.Type(A.Text.IndexOf('j') + 1, ">>");
        await Settle();
        t.Eq("insert at selection end stays outside", "abcYYdefghij", Sel());
        var nine = A.Text.IndexOf('9');
        A.Delete(nine, A.Text.IndexOf('c'));
        await Settle();
        t.Eq("delete overlapping selection start", "cYYdefghij", Sel());
        A.Delete(A.Text.IndexOf('h'), A.Text.IndexOf('m'));
        await Settle();
        t.Eq("delete overlapping selection end", "cYYdefg", Sel());
        B.Select(5, 5);
        var after = B.Text[5..9];
        A.Type(2, "ZZZ");
        await Settle();
        var caret = B.Doc.Selection.StartPosition;
        t.Check("caret is still a caret", B.Doc.Selection.EndPosition == caret);
        t.Eq("caret keeps its place in the text", after, B.Text[caret..(caret + 4)]);
        A.Type(caret, "!!");
        await Settle();
        t.Eq("remote insert exactly at the caret lands after it", "!!", B.Text[B.Doc.Selection.StartPosition..(B.Doc.Selection.StartPosition + 2)]);
        A.Delete(caret - 2, caret + 4);
        await Settle();
        t.Check("caret survives deletion around it", B.Doc.Selection.StartPosition == caret - 2 && B.Doc.Selection.EndPosition == caret - 2,
            $"{B.Doc.Selection.StartPosition}..{B.Doc.Selection.EndPosition} expected {caret - 2}");

        // Local typing continues at the caret after remote changes.
        B.Doc.Selection.TypeText("local");
        await VerifyAll("after selection tests");
        t.Check("typing continues at the preserved caret", A.Text.Substring(caret - 2, 5) == "local", A.Text);
        Checks.Note($"selection corrected {w.B.SelectionRestores} times (RichEdit moved it itself otherwise)");
    }

    private async Task Scroll()
    {
        var sb = new System.Text.StringBuilder();
        for (var i = 0; i < 300; i++)
        {
            sb.Append("line ").Append(i).Append(" lorem ipsum dolor sit amet\n");
        }

        A.Type(0, sb.ToString().TrimEnd('\n'));
        await VerifyAll("long document");
        w.B.ScrollTo(2500);
        await Task.Delay(150);
        t.Check("B scrolled", Math.Abs(w.B.VerticalOffset - 2500) < 1, w.B.VerticalOffset.ToString("F1"));

        // A line that is on screen in B.
        var marker = Enumerable.Range(0, 300).Select(i => $"line {i} ").First(m => w.B.ViewY(B.Text.IndexOf(m, StringComparison.Ordinal)) > 100);
        double Y() => w.B.ViewY(B.Text.IndexOf(marker, StringComparison.Ordinal));
        var y0 = Y();
        A.Type(0, "new 1\nnew 2\nnew 3\nnew 4\nnew 5\n");
        await Settle();
        await Task.Delay(150);
        t.Check("view stays anchored when lines are inserted above", Math.Abs(Y() - y0) < 1.5, $"{marker}: y {y0:F1} -> {Y():F1}, offset {w.B.VerticalOffset:F1}");
        t.Check("offset moved to compensate", w.B.VerticalOffset > 2550, w.B.VerticalOffset.ToString("F1"));
        A.Delete(0, A.ParaStart(12));
        await Settle();
        await Task.Delay(150);
        t.Check("view stays anchored when lines are deleted above", Math.Abs(Y() - y0) < 1.5, $"y {y0:F1} -> {Y():F1}, offset {w.B.VerticalOffset:F1}");
        w.A.UpdateBlocks(0, A.ParaStart(5), b => b with { Block = "h1" });
        await Settle();
        await Task.Delay(150);
        t.Check("view stays anchored when lines above grow (headings)", Math.Abs(Y() - y0) < 1.5, $"y {y0:F1} -> {Y():F1}, offset {w.B.VerticalOffset:F1}");
        var off = w.B.VerticalOffset;
        A.Type(A.Len - 1, "\nappended at the end");
        A.Type(A.Text.IndexOf(marker, StringComparison.Ordinal) + marker.Length, "[edit on screen]");
        await Settle();
        await Task.Delay(150);
        t.Check("offset untouched by edits at/below the viewport", Math.Abs(w.B.VerticalOffset - off) < 0.5 && Math.Abs(Y() - y0) < 1.5, $"{off:F1} -> {w.B.VerticalOffset:F1}");
        Checks.Note($"scroll corrected {w.B.ScrollRestores} times");
        await VerifyAll("after scroll tests");
    }

    private async Task Undo()
    {
        t.Check("native undo is off", !A.Doc.CanUndo() && A.Doc.UndoLimit == 0);
        A.Type(0, "aaa ");
        await Settle();
        B.Type(B.Len - 1, "bbb ");
        await Settle();
        A.Type(A.Len - 1, "ccc");
        await Settle();
        t.Eq("setup", "aaa bbb ccc\n", B.Text);
        t.Check("native undo still empty after edits", !A.Doc.CanUndo());
        t.Check("undo 1", w.A.Undo());
        await VerifyAll("after undo 1");
        t.Eq("A's last edit undone on both sides", "aaa bbb \n", B.Text);
        t.Check("undo 2", w.A.Undo());
        await VerifyAll("after undo 2");
        t.Eq("A's first edit undone, B's text untouched", "bbb \n", A.Text);
        t.Check("nothing left to undo for A", !w.A.Undo());
        t.Check("redo 1", w.A.Redo());
        await VerifyAll("after redo 1");
        t.Eq("redo restores", "aaa bbb \n", B.Text);
        t.Check("redo 2", w.A.Redo());
        await VerifyAll("after redo 2");
        t.Eq("redo restores all", "aaa bbb ccc\n", B.Text);
        t.Check("B undoes only its own", w.B.Undo());
        await VerifyAll("after B undo");
        t.Eq("B's text gone, A's kept", "aaa ccc\n", A.Text);

        // Formatting and block changes are undoable too.
        A.Select(0, 3);
        A.Toggle("bold");
        w.A.ToggleBlock("h2");
        await VerifyAll("after format");
        t.Check("format applied", w.B.Shadow.Cells[0].Inline.Bold && B.Blocks() == "h2");
        w.A.Undo();
        await VerifyAll("after undoing block");
        t.Eq("block undone", "p", B.Blocks());
        w.A.Undo();
        await VerifyAll("after undoing bold");
        t.Check("bold undone", !w.B.Shadow.Cells[0].Inline.Bold);

        // Undo after a remote edit landed in the middle of the local one.
        A.Type(0, "local words here ");
        await Settle();
        B.Type(6, "REMOTE ");
        await Settle();
        w.A.Undo();
        await VerifyAll("after undo around remote text");
        t.Check("remote text survives undo of surrounding local text", A.Text.Contains("REMOTE ") && !A.Text.Contains("local"), A.Text);
    }

    private async Task Paste()
    {
        A.Type(0, "plain BOLD tail\nheading para");
        A.Select(6, 10);
        A.Toggle("bold");
        w.A.UpdateBlocks(A.ParaStart(1), A.ParaStart(1), b => b with { Block = "h2" });
        await VerifyAll("setup");

        // Rich copy from one editor, paste into the other (RTF on the clipboard).
        A.Select(6, A.Len - 1);
        A.Doc.Selection.Copy();
        await Task.Delay(100);
        B.Select(0, 0);
        B.Doc.Selection.Paste(0);
        await Task.Delay(100);
        await VerifyAll("after rich paste between editors");
        t.Check("pasted text present", A.Text.StartsWith("BOLD tail\nheading para", StringComparison.Ordinal), A.Text);
        t.Check("pasted bold kept", w.A.Shadow.Cells[0].Inline.Bold && !w.A.Shadow.Cells[5].Inline.Bold);
        Checks.Note($"blocks after rich paste: [{A.Blocks()}]");

        // Foreign rich text: other font, 30pt, red, bold, two paragraphs. Must be normalised to our rendering.
        var dp = new DataPackage();
        dp.SetRtf(@"{\rtf1\ansi\deff0{\fonttbl{\f0 Times New Roman;}}{\colortbl;\red255\green0\blue0;}\f0\fs60\cf1 Big red \b bold\b0  text\par second para}");
        await SetClipboard(dp);
        await Task.Delay(100);
        B.Select(B.Len - 1, B.Len - 1);
        B.Doc.Selection.Paste(0);
        await Task.Delay(100);
        await VerifyAll("after foreign RTF paste");
        var at = A.Text.IndexOf("Big red bold text", StringComparison.Ordinal);
        t.Check("foreign text arrived", at >= 0, A.Text);
        if (at >= 0)
        {
            t.Check("foreign bold kept, rest plain", w.A.Shadow.Cells[at + 9].Inline.Bold && !w.A.Shadow.Cells[at].Inline.Bold);
        }

        dp = new DataPackage();
        dp.SetText("plain line 1\r\nplain line 2");
        await SetClipboard(dp);
        await Task.Delay(100);
        A.Select(3, 7); // paste over a selection
        A.Doc.Selection.Paste(0);
        await Task.Delay(100);
        await VerifyAll("after plain-text paste over a selection");
        t.Check("plain paste arrived", B.Text.Contains("plain line 1\nplain line 2"), B.Text);

        // Move text inside one editor (what drag-and-drop does: one removal plus one insertion).
        var text = A.Text;
        var from = text.IndexOf("plain line 1", StringComparison.Ordinal);
        A.Select(from, from + 6);
        A.Doc.Selection.Cut();
        await Task.Delay(100);
        A.Select(A.Len - 1, A.Len - 1);
        A.Doc.Selection.Paste(0);
        await Task.Delay(100);
        await VerifyAll("after cut + paste elsewhere");
    }

    internal static async Task SetClipboard(DataPackage dp)
    {
        for (var attempt = 0; ; attempt++)
        {
            try
            {
                Clipboard.SetContent(dp);
                Clipboard.Flush();
                return;
            }
            catch (COMException) when (attempt < 10)
            {
                await Task.Delay(50); // clipboard busy
            }
        }
    }

    private async Task Unicode()
    {
        A.Type(0, "a😀b漢c é");
        await VerifyAll("emoji and CJK");
        B.Type(B.Len - 1, "😁");
        var i = A.Text.IndexOf("😀", StringComparison.Ordinal);
        A.Replace(i, i + 2, "😁"); // shares the high surrogate with the replaced emoji
        await VerifyAll("after replacing an emoji");
        t.Check("no lone surrogates", !A.Text.Contains("😀") && A.Text.Count(char.IsHighSurrogate) == A.Text.Count(char.IsLowSurrogate), A.Text);
        A.Doc.GetRange(1, 1).SetText(TextSetOptions.None, "\v"); // Shift+Enter
        await VerifyAll("after soft line break");
        t.Check("soft break is U+2028 in the CRDT", B.Text.Contains('\u2028'), B.Text);
        A.Type(2, "\t");
        await VerifyAll("after tab");
    }

    /// <summary>The IME gating logic only (TextCompositionStarted/Ended are simulated; a real IME was not available).</summary>
    private async Task CompositionGating()
    {
        A.Type(0, "before after");
        await VerifyAll("setup");
        w.A.CompositionStarted();
        A.Type(7, "にほ"); // the composition string lives in the document while composing
        B.Type(0, "REMOTE ");
        await w.Link.DrainAsync();
        await Task.Delay(30);
        t.Eq("composition text is not sent while composing", "REMOTE before after\n", B.Text);
        A.Doc.GetText(TextGetOptions.None, out var during);
        t.Eq("remote text is not applied under an active composition", "before にほafter\r", during);
        t.Check("the binding reports busy while composing (the sync dispatcher waits)", w.A.IsBusy && !w.A.PrepareForExternalChange());
        A.Replace(7, 9, "日本"); // commit
        w.A.CompositionEnded();
        await VerifyAll("after composition ended");
        t.Eq("both arrive after the composition", "REMOTE before 日本after\n", B.Text);
        t.Eq("and on the composing side", "REMOTE before 日本after\n", A.Text);
        t.Check("ready for remote changes again", w.A.PrepareForExternalChange());
    }

    private async Task ForeignAttrs()
    {
        A.Type(0, "para one\npara two");
        await VerifyAll("setup");

        // A newer client writes a block type and an inline attribute this client does not know.
        using var c = new PageDocument(w.A.Page.DocId);
        c.ApplyUpdate(w.A.Page.EncodeState());
        c.Edit(ed =>
        {
            ed.Format(8, 1, new Dictionary<string, object?> { ["block"] = "quote" });
            ed.Format(0, 4, new Dictionary<string, object?> { ["color"] = "red" });
        });
        var update = c.EncodeDiff(w.A.Page.EncodeStateVector());
        w.A.ApplyRemoteUpdate(update);
        w.B.ApplyRemoteUpdate(update);
        await VerifyAll("after unknown attributes arrived");
        A.Type(2, "XX");
        A.Select(0, 3);
        A.Toggle("bold");
        A.Type(A.ParaStart(1) + 2, "YY");
        await VerifyAll("after editing around unknown attributes");
        c.ApplyUpdate(w.A.Page.EncodeDiff(c.EncodeStateVector()));
        var cells = RichEditBinding.ReadCells(c);
        var nl = cells.FindIndex(x => x.Ch == '\n');
        t.Check("unknown block value survives local edits", cells[nl].Block.Block == "quote", cells[nl].Block.ToString());
        t.Check("unknown inline attribute survives local edits", c.GetRuns()[0].Attributes.TryGetValue("color", out var color) && (string?)color == "red");
        t.Eq("control shows it as a plain paragraph", "p,p", A.Blocks());

        // A misbehaving peer deletes the final newline. Core's PageDocument refuses to do that, so the peer is
        // a bare Yjs document. PROTOCOL.md 5.2: the newline comes back as part of this client's next edit.
        w.SetConnected(false);
        byte[] damage;
        using (var raw = new YDotNet.Document.Doc(new YDotNet.Document.Options.DocOptions { Encoding = YDotNet.Document.Options.DocEncoding.Utf16 }))
        {
            var text = raw.Text("c:" + PageDocument.MainContainer);
            using (var txn = raw.WriteTransaction())
            {
                txn.ApplyV1(w.A.Page.EncodeState());
            }

            using (var txn = raw.WriteTransaction())
            {
                text.RemoveRange(txn, text.Length(txn) - 1, 1);
            }

            using var read = raw.ReadTransaction();
            damage = read.StateDiffV1(w.A.Page.EncodeStateVector());
        }

        w.A.ApplyRemoteUpdate(damage);
        t.Check("the final newline is gone from the document", !w.A.Page.GetText().EndsWith('\n'));
        w.A.SyncLocal();
        t.Check("not repaired merely by looking at the page", !w.A.Page.GetText().EndsWith('\n'));
        A.Type(0, "Z");
        VerifySide(w.A, "after final-newline repair");
        t.Check("the next edit put the newline back", w.A.Page.GetText().EndsWith('\n') && w.A.Page.GetText().StartsWith('Z'), w.A.Page.GetText());
        w.SetConnected(true);
        await VerifyAll("after repair propagated");
        t.Check("text ends with newline again", A.Text.EndsWith('\n') && B.Text.EndsWith('\n'));
        Checks.Note($"repair used {w.A.FullResets} full reset(s) on A, {w.B.FullResets} on B (expected: only here)");
    }

    /// <summary>A page whose content has not been synced yet opens empty and fills in later; opening it writes nothing.</summary>
    private async Task NotYetArrived()
    {
        A.Type(0, "content from the first device\nsecond line");
        w.A.UpdateBlocks(0, 0, b => b with { Block = "h2" });
        await VerifyAll("setup");

        using var late = new PageDocument(w.A.Page.DocId);
        var updates = 0;
        late.LocalUpdate += _ => updates++;
        var box = w.BoxB;
        w.B.Dispose();
        using (var binding = new RichEditBinding("late", box, late, w.Dark))
        {
            binding.SyncLocal();
            await Task.Delay(30);
            binding.SyncLocal();
            t.Check("opening a page that has not arrived writes nothing", updates == 0 && late.GetText().Length == 0, $"{updates} updates");
            binding.ApplyRemoteUpdate(w.A.Page.EncodeState());
            t.Eq("content shows once it arrives", w.A.Page.GetText(), binding.Shadow.Text);
            t.Check("consistent after arrival", binding.Verify() == null, binding.Verify());
            t.Check("still nothing written by this replica", updates == 0);
            box.Document.Selection.SetRange(0, 0);
            box.Document.Selection.TypeText("typed late ");
            t.Check("typing afterwards is an ordinary edit", updates == 1 && late.GetText().StartsWith("typed late content", StringComparison.Ordinal), late.GetText());
            t.Check("consistent after typing", binding.Verify() == null, binding.Verify());
        }

        // Typing into the empty page before anything arrived: the edit carries the first newline with it.
        using var early = new PageDocument(w.A.Page.DocId);
        using (var binding = new RichEditBinding("early", box, early, w.Dark))
        {
            box.Document.Selection.TypeText("early bird");
            t.Eq("typed into a page that has not arrived", "early bird\n", early.GetText());
            binding.ApplyRemoteUpdate(w.A.Page.EncodeState());
            t.Check("consistent after the real content merged in", binding.Verify() == null, binding.Verify());
            t.Check("both texts are there", early.GetText().Contains("early bird") && early.GetText().Contains("content from the first device"), early.GetText());
        }
    }

    /// <summary>Embedded objects and table structure never reach the document, however they got into the control.</summary>
    private async Task ForbiddenContent()
    {
        A.Type(0, "text before and after");
        await VerifyAll("setup");
        var updates = 0;
        void Count(byte[] _) => updates++;
        w.A.Page.LocalUpdate += Count;

        // A picture dropped into the control (drag and drop does not go through the paste filter): RichEdit
        // holds it as an embedded object, which reads as U+FFFC.
        using (var png = await TinyPngAsync())
        {
            A.Doc.GetRange(5, 5).InsertImage(16, 16, 0, VerticalCharacterAlignment.Baseline, "picture", png);
        }

        A.Doc.GetText(TextGetOptions.None, out var withObject);
        t.Check("the control holds the picture as an embedded object", withObject.Contains('\uFFFC'), Show(withObject));
        t.Check("nothing is written while the object is in the control", updates == 0 && !w.A.Page.GetText().Contains('\uFFFC'), $"{updates} updates");
        await Task.Delay(60);
        A.Doc.GetText(TextGetOptions.None, out var control);
        t.Check("the object was removed from the control", !control.Contains('\uFFFC'), Show(control));
        t.Check("and never reached the document", !w.A.Page.GetText().Contains('\uFFFC') && w.A.ForbiddenCharactersRemoved == 1, $"removed {w.A.ForbiddenCharactersRemoved}");
        w.A.Page.LocalUpdate -= Count;
        await VerifyAll("after an embedded object was dropped in");
        t.Eq("text is as before", "text before and after\n", B.Text);

        // Typed together with real text: the text survives, the object does not.
        A.Type(4, " kept");
        using (var png = await TinyPngAsync())
        {
            A.Doc.GetRange(9, 9).InsertImage(16, 16, 0, VerticalCharacterAlignment.Baseline, "picture", png);
        }

        await Task.Delay(60);
        await VerifyAll("after text plus object");
        t.Eq("text kept, object dropped", "text kept before and after\n", B.Text);

        // A table forced into the control as RTF: its structure characters must not reach the document either.
        A.Doc.GetRange(0, 0).SetText(TextSetOptions.FormatRtf, @"{\rtf1\ansi\trowd\cellx1500\cellx3000\intbl cell one\cell cell two\cell\row\pard after table\par}");
        A.Doc.GetText(TextGetOptions.None, out var withTable);
        Checks.Note($"a table in the control reads as «{string.Concat(withTable.Take(40).Select(ch => ch < ' ' || ch > '\uFF00' ? $"<{(int)ch:X4}>" : ch.ToString()))}»");
        await Task.Delay(80);
        await VerifyAll("after a table was forced in");
        t.Check("no table structure in the document", !PasteFilter.ContainsForbidden(w.A.Page.GetText()) && !PasteFilter.ContainsForbidden(w.B.Page.GetText()), Show(w.A.Page.GetText()));
        A.Doc.GetText(TextGetOptions.None, out var afterTable);
        t.Check("no table structure left in the control", !PasteFilter.ContainsForbidden(afterTable.Replace('\r', '\n')), Show(afterTable));
        // The filter itself.
        t.Check("RTF with a picture is refused", !PasteFilter.RtfIsSafe(@"{\rtf1 x{\pict\wmetafile8 0102}}"));
        t.Check("RTF with a table is refused", !PasteFilter.RtfIsSafe(@"{\rtf1\trowd\cellx1000 a\cell\row}"));
        t.Check("RTF with an embedded object is refused", !PasteFilter.RtfIsSafe(@"{\rtf1{\object\objemb{\*\objdata 00}}}"));
        t.Check("RTF with a field (hyperlink) is refused", !PasteFilter.RtfIsSafe(@"{\rtf1{\field{\*\fldinst HYPERLINK ""x""}{\fldrslt y}}}"));
        t.Check("plain formatted RTF is accepted", PasteFilter.RtfIsSafe(@"{\rtf1\ansi\b bold\b0  and \i italic\i0\par}"));
        A.Select(0, A.Len - 1);
        A.Doc.Selection.Copy();
        await Task.Delay(100);
        var own = await Clipboard.GetContent().GetRtfAsync();
        t.Check("RTF copied from the editor itself is accepted", PasteFilter.RtfIsSafe(own), Show(own));
    }

    /// <summary>A 2x2 PNG, for inserting a real embedded picture.</summary>
    private static async Task<Windows.Storage.Streams.InMemoryRandomAccessStream> TinyPngAsync()
    {
        var stream = new Windows.Storage.Streams.InMemoryRandomAccessStream();
        var encoder = await Windows.Graphics.Imaging.BitmapEncoder.CreateAsync(Windows.Graphics.Imaging.BitmapEncoder.PngEncoderId, stream);
        encoder.SetPixelData(Windows.Graphics.Imaging.BitmapPixelFormat.Bgra8, Windows.Graphics.Imaging.BitmapAlphaMode.Ignore, 2, 2, 96, 96, new byte[16]);
        await encoder.FlushAsync();
        stream.Seek(0);
        return stream;
    }

    private async Task ThemeSwitch()
    {
        A.Type(0, "Heading\nplain code link\ntask\nblock");
        w.A.UpdateBlocks(0, 0, b => b with { Block = "h1" });
        A.Select(14, 18);
        A.Toggle("code");
        A.Select(19, 23);
        A.Toggle("link");
        w.A.UpdateBlocks(A.ParaStart(2), A.ParaStart(2), b => b with { Block = "todo", Checked = true });
        w.A.UpdateBlocks(A.ParaStart(3), A.ParaStart(3), b => b with { Block = "code" });
        await VerifyAll("setup");
        var before = RichModel.Dump(Cells(w.A), effectiveBlocks: false);
        var updates = 0;
        void Count(byte[] _) => updates++;
        w.A.Page.LocalUpdate += Count;
        var dark = w.A.Style.Dark;
        var plainBefore = A.Doc.GetRange(8, 9).CharacterFormat.ForegroundColor;
        w.A.SetTheme(!dark);
        VerifySide(w.A, "after switching the theme");
        var plainAfter = A.Doc.GetRange(8, 9).CharacterFormat.ForegroundColor;
        t.Check("plain text changed colour", plainBefore != plainAfter && plainAfter == w.A.Style.TextFg, $"{plainBefore} -> {plainAfter}");
        t.Check("code marker uses the new theme's colour", A.Doc.GetRange(15, 16).CharacterFormat.BackgroundColor == w.A.Style.CodeBg);
        t.Check("link marker uses the new theme's colour", A.Doc.GetRange(20, 21).CharacterFormat.ForegroundColor == w.A.Style.LinkFg);
        t.Check("a theme switch writes nothing to the document", updates == 0 && before == RichModel.Dump(Cells(w.A), effectiveBlocks: false), $"{updates} updates");
        A.Type(A.Len - 1, " typed after the switch");
        B.Type(0, "remote ");
        await VerifyAll("editing after the switch (A in one theme, B in the other)");
        w.A.SetTheme(dark);
        w.A.Page.LocalUpdate -= Count;
        await VerifyAll("after switching back");
    }

    /// <summary>The element theme itself changes under the editor (the user switches Windows to dark).</summary>
    private async Task ThemeReal()
    {
        A.Type(0, "plain linkword codeword");
        A.Select(6, 14);
        A.Toggle("link");
        A.Select(15, 23);
        A.Toggle("code");
        await VerifyAll("setup");
        string Colours() => $"plain fg {A.Doc.GetRange(1, 2).CharacterFormat.ForegroundColor}, link fg {A.Doc.GetRange(7, 8).CharacterFormat.ForegroundColor}, code bg {A.Doc.GetRange(16, 17).CharacterFormat.BackgroundColor}, default fg {A.Doc.GetDefaultCharacterFormat().ForegroundColor}";
        Checks.Note("before: " + Colours());
        var updates = 0;
        void Count(byte[] _) => updates++;
        w.A.Page.LocalUpdate += Count;
        var dark = w.Dark;
        w.SetElementTheme(!dark);
        await Task.Delay(400);
        Checks.Note($"after the element theme changed to {(w.Dark ? "dark" : "light")}: " + Colours());
        t.Check("the element theme really changed", w.Dark != dark);
        t.Check("both bindings follow the element theme", w.A.Style.Dark == w.Dark && w.B.Style.Dark == w.Dark);
        await VerifyAll("after the element theme changed");
        t.Check("link survived the theme change", w.A.Shadow.Cells[8].Inline.Link == TestLink && w.A.ReadControlCells()[8].Inline.Link == "*");
        t.Check("code survived the theme change", w.A.Shadow.Cells[17].Inline.Code && w.A.ReadControlCells()[17].Inline.Code);
        t.Check("a theme change writes nothing to the document", updates == 0, $"{updates} updates");
        A.Type(A.Len - 1, " more");
        await VerifyAll("typing after the change");
        w.SetElementTheme(dark);
        await Task.Delay(400);
        await VerifyAll("after changing back");
        t.Check("still nothing but the typing was written", updates == 1, $"{updates} updates");
        w.A.Page.LocalUpdate -= Count;
    }

    private async Task AutoList()
    {
        // "- " typed at the start of a plain line turns it into a bullet; the dash goes away.
        A.Type(0, "intro\n-");
        A.Select(7, 7);
        t.Check("dash + space becomes a list", w.A.TryAutoList());
        await VerifyAll("after auto bullet");
        t.Eq("dash removed", "intro\n\n", A.Text);
        t.Eq("bullet on both sides", "p,ul", B.Blocks());
        t.Check("caret stays in the new bullet", A.Doc.Selection.StartPosition == 6 && A.Doc.Selection.EndPosition == 6);
        A.Type(6, "item");
        await VerifyAll("after typing in the bullet");
        t.Eq("typed text is in the bullet", "intro\nitem\n", B.Text);

        // Not at the start of the line, not in a line that is already a list, not for other text.
        A.Select(10, 10);
        t.Check("no conversion inside a list item", !w.A.TryAutoList());
        A.Type(5, " -");
        A.Select(7, 7);
        t.Check("no conversion in the middle of a line", !w.A.TryAutoList());
        t.Eq("nothing changed", "intro -\nitem\n", A.Text);

        // The other shortcuts.
        A.Type(A.Len - 1, "\n");
        w.A.UpdateBlocks(A.Len - 1, A.Len - 1, b => b with { Block = null });
        A.Type(A.Len - 1, "1.");
        A.Select(A.Len - 1, A.Len - 1);
        t.Check("1. becomes a numbered list", w.A.TryAutoList());
        A.Type(A.Len - 1, "one\n");
        w.A.UpdateBlocks(A.Len - 1, A.Len - 1, b => b with { Block = null });
        A.Type(A.Len - 1, "[]");
        A.Select(A.Len - 1, A.Len - 1);
        t.Check("[] becomes a to-do", w.A.TryAutoList());
        A.Type(A.Len - 1, "task\n");
        w.A.UpdateBlocks(A.Len - 1, A.Len - 1, b => b with { Block = null });
        A.Type(A.Len - 1, "*");
        A.Select(A.Len - 1, A.Len - 1);
        t.Check("* becomes a bullet", w.A.TryAutoList());
        await VerifyAll("after the other shortcuts");
        t.Eq("blocks", "p,ul,ol,todo,ul", B.Blocks());
        t.Eq("text", "intro -\nitem\none\ntask\n\n", B.Text);
    }

    private async Task RichPaste()
    {
        const string html = """
            <p><b>Bold</b> and <i>italic</i> and <s>struck</s> and <u>under</u> and <code>code</code> and <a href="https://example.com/">link</a></p>
            <ul><li>bullet one</li><li>bullet <b>two</b><ul><li>nested</li></ul></li></ul>
            <ol><li>number one</li></ol>
            <h2>Heading</h2>
            <p>tail</p>
            """;
        var rich = HtmlPaste.Parse(html);
        t.Check("parsed paragraphs", rich.Count == 7, rich.Count.ToString());

        // Into an empty page.
        A.Select(0, 0);
        t.Check("inserted", w.A.InsertRich(rich));
        await VerifyAll("after rich paste into an empty page");
        t.Eq("text", "Bold and italic and struck and under and code and link\nbullet one\nbullet two\nnested\nnumber one\nHeading\ntail\n", B.Text);
        t.Eq("blocks on the other side", "p,ul,ul,ul,indent=1,ol,h2,p", B.Blocks());
        var c = w.B.Shadow.Cells;
        t.Check("bold", c[0].Inline.Bold && c[3].Inline.Bold && !c[4].Inline.Bold);
        t.Check("italic", c[9].Inline.Italic && !c[9].Inline.Bold && !c[15].Inline.Italic);
        t.Check("strike", c[20].Inline.Strike && !c[26].Inline.Strike);
        t.Check("underline", c[31].Inline.Underline && !c[36].Inline.Underline);
        t.Check("code", c[41].Inline.Code && !c[45].Inline.Code);
        t.Check("link", c[50].Inline.Link == "https://example.com/" && c[53].Inline.Link == "https://example.com/");
        var two = B.Text.IndexOf("two", StringComparison.Ordinal);
        t.Check("bold inside a list item", c[two].Inline.Bold && !c[two - 2].Inline.Bold);
        t.Check("caret after the pasted text", A.Doc.Selection.StartPosition == A.Len - 1, A.Doc.Selection.StartPosition.ToString());

        // In the middle of a bold line: the first paragraph joins the line, the pasted text keeps its own formats,
        // and the rest of the line keeps its own.
        await Fresh();
        A.Type(0, "startEND");
        A.Select(0, 8);
        w.A.ToggleInline("bold");
        A.Select(5, 5);
        t.Check("inserted mid-line", w.A.InsertRich(HtmlPaste.Parse("plain <i>slanted</i><ul><li>item</li></ul>")));
        await VerifyAll("after rich paste in the middle of a line");
        t.Eq("text", "startplain slanted\nitemEND\n", B.Text);
        c = w.B.Shadow.Cells;
        t.Check("surrounding text keeps bold", c[0].Inline.Bold && c[24].Inline.Bold);
        t.Check("pasted plain text is not bold", !c[5].Inline.Bold && !c[19].Inline.Bold);
        t.Check("pasted italic", c[11].Inline.Italic && !c[11].Inline.Bold);
        t.Eq("the list item is a bullet", "p,ul", B.Blocks());

        // A single word pasted into an existing bullet does not change the bullet.
        await Fresh();
        A.Type(0, "x");
        w.A.ToggleBlock("ul");
        A.Select(0, 0);
        t.Check("inserted into a bullet", w.A.InsertRich(HtmlPaste.Parse("<b>word</b> ")));
        await VerifyAll("after pasting a word into a bullet");
        t.Eq("text", "wordx\n", B.Text);
        t.Eq("still one bullet", "ul", B.Blocks());
        t.Check("word is bold, old text is not", w.B.Shadow.Cells[0].Inline.Bold && !w.B.Shadow.Cells[4].Inline.Bold);

        // Undo takes the paste away again without touching what was there.
        while (w.A.Undo())
        {
        }

        await VerifyAll("after undoing the paste");
    }

    private async Task Perf()
    {
        var sb = new System.Text.StringBuilder();
        for (var i = 0; i < 400; i++)
        {
            sb.Append("The quick brown fox jumps over the lazy dog, line ").Append(i).Append('\n');
        }

        var sw = Stopwatch.StartNew();
        A.Type(0, sb.ToString().TrimEnd('\n'));
        var load = sw.ElapsedMilliseconds;
        await Settle();
        AppLog.Line($"  perf: typing {A.Len} chars in one go: local sync {load} ms, remote side settled after {sw.ElapsedMilliseconds} ms");
        for (var i = 0; i < 400; i += 3)
        {
            var p = A.ParaStart(i);
            A.Select(p + 4, p + 9);
            A.Toggle("bold");
        }

        await Settle();
        sw.Restart();
        var mid = A.Len / 2;
        for (var i = 0; i < 100; i++)
        {
            A.Type(mid + i, "x");
        }

        var perKey = sw.Elapsed.TotalMilliseconds / 100;
        AppLog.Line($"  perf: local keystroke -> CRDT in a {A.Len}-char document: {perKey:F2} ms each");
        await Settle();
        w.SetConnected(false);
        var updates = new List<byte[]>();
        void Grab(byte[] u) => updates.Add(u);
        w.A.Page.LocalUpdate += Grab;
        for (var i = 0; i < 100; i++)
        {
            A.Type(mid + i, "y");
        }

        w.A.Page.LocalUpdate -= Grab;
        sw.Restart();
        foreach (var u in updates)
        {
            w.B.ApplyRemoteUpdate(u);
        }

        var perRemote = sw.Elapsed.TotalMilliseconds / updates.Count;
        AppLog.Line($"  perf: remote single-char update -> control: {perRemote:F2} ms each ({updates.Count} updates)");
        w.SetConnected(true);
        sw.Restart();
        _ = w.B.Verify();
        AppLog.Line($"  perf: full verify (2 full scans + render check) of {B.Len} chars: {sw.ElapsedMilliseconds} ms");
        t.Check("keystroke cost acceptable (< 8 ms)", perKey < 8, perKey.ToString("F2"));
        t.Check("remote apply cost acceptable (< 8 ms)", perRemote < 8, perRemote.ToString("F2"));
        await VerifyAll("after perf run");
    }

    // ---------------------------------------------------------------------------------------------------

    private static readonly string[] Words = ["a", "bc", "def ", "x", " ", "é", "😀", "😁", "漢字", "Hello", "\t", ". "];
    private static readonly string?[] BlockKinds = [null, "h1", "h2", "h3", "ul", "ol", "todo", "code"];
    private static readonly string[] InlineKeys = ["bold", "italic", "underline", "strike"];

    /// <param name="seed">Seed of the random sequence.</param>
    /// <param name="ops">Number of operations.</param>
    /// <param name="ordered">false = updates may overtake each other in transit. Yrs can then keep a delete pending
    /// until the next resync, so in that mode every checkpoint does a real resync (cut + reconnect) first.</param>
    private async Task Random(int seed, int ops, bool ordered = true)
    {
        w.Link.Ordered = ordered;
        var rng = new Random(seed);
        A.Type(0, "seed text one\nseed text two\nseed text three");
        await VerifyAll("setup");
        var counts = new Dictionary<string, int>();
        var failuresAtStart = t.Failures;
        void Count(string k) => counts[k] = counts.GetValueOrDefault(k) + 1;
        for (var n = 0; n < ops; n++)
        {
            var s = rng.Next(2) == 0 ? A : B;
            var text = s.Text;
            var len = text.Length;
            int Pos(int max)
            {
                var p = rng.Next(Math.Max(1, max));
                if (p > 0 && p < text.Length && char.IsLowSurrogate(text[p]))
                {
                    p--;
                }

                return p;
            }

            (int, int) Range(int maxLen)
            {
                var a = Pos(len - 1);
                var b = Math.Min(len - 1, a + rng.Next(1, maxLen + 1));
                if (b < text.Length && char.IsLowSurrogate(text[b]))
                {
                    b++;
                }

                return (a, Math.Min(b, len - 1));
            }

            var roll = rng.Next(100);
            if (len > 1200)
            {
                roll = 45; // keep the document bounded
            }

            string op;
            if (roll < 28)
            {
                op = "type";
                s.Type(Pos(len), Words[rng.Next(Words.Length)] + (rng.Next(3) == 0 ? Words[rng.Next(Words.Length)] : ""));
            }
            else if (roll < 38)
            {
                op = "newline";
                s.Type(Pos(len), "\n");
            }
            else if (roll < 52)
            {
                op = "delete";
                var (a, b) = Range(len > 1200 ? 200 : 8);
                if (b > a)
                {
                    s.Delete(a, b);
                }
            }
            else if (roll < 56)
            {
                op = "replace";
                var (a, b) = Range(5);
                s.Replace(a, b, Words[rng.Next(Words.Length)]);
            }
            else if (roll < 67)
            {
                op = "inline";
                var (a, b) = Range(20);
                s.Select(a, b);
                s.Toggle(InlineKeys[rng.Next(InlineKeys.Length)]);
            }
            else if (roll < 72)
            {
                op = "code/link";
                var (a, b) = Range(12);
                s.Select(a, b);
                s.Toggle(rng.Next(2) == 0 ? "code" : "link");
            }
            else if (roll < 81)
            {
                op = "block";
                var (a, b) = Range(rng.Next(3) == 0 ? 40 : 1);
                var kind = BlockKinds[rng.Next(BlockKinds.Length)];
                s.B.UpdateBlocks(a, b, x => x with { Block = kind, Checked = false });
            }
            else if (roll < 84)
            {
                op = "native-list";
                var p = Pos(len);
                s.Select(p, p);
                s.Doc.Selection.ParagraphFormat.ListType = rng.Next(2) == 0 ? MarkerType.Bullet : MarkerType.None;
            }
            else if (roll < 88)
            {
                op = "indent";
                var (a, b) = Range(30);
                s.Select(a, b);
                s.B.Indent(rng.Next(3) == 0 ? -1 : 1);
            }
            else if (roll < 91)
            {
                op = "check";
                var p = Pos(len);
                s.B.UpdateBlocks(p, p, x => x.Block == "todo" ? x with { Checked = !x.Checked } : x);
            }
            else if (roll < 94)
            {
                op = "undo";
                if (rng.Next(3) == 0)
                {
                    s.B.Redo();
                }
                else
                {
                    s.B.Undo();
                }
            }
            else if (roll < 96)
            {
                op = "link-toggle";
                w.SetConnected(!w.Link.Connected);
            }
            else if (roll < 98)
            {
                op = "delay";
                w.Link.DelayMs = new[] { 0, 0, 15, 60 }[rng.Next(4)];
            }
            else
            {
                op = "wait";
                await Task.Delay(rng.Next(5, 60));
            }

            Count(op);

            // Move the other side's selection around so remote application has something to preserve.
            if (rng.Next(6) == 0)
            {
                var o = ReferenceEquals(s.Box, w.BoxA) ? B : A;
                var a = rng.Next(o.Len);
                o.Select(a, Math.Min(o.Len - 1, a + rng.Next(0, 6)));
            }

            if (rng.Next(4) == 0)
            {
                await Task.Delay(1); // let queued deliveries interleave with the edits
            }

            var problem = s.B.Verify();
            if (problem != null)
            {
                t.Check($"step {n} ({op}) keeps {s.B.Name} consistent", false, problem);
                break;
            }

            t.Pass();
            if (n % 40 == 39)
            {
                if (!ordered)
                {
                    await Settle();
                    w.SetConnected(false);
                }

                w.SetConnected(true);
                await VerifyAll($"at step {n}");
                if (t.Failures > failuresAtStart)
                {
                    break;
                }
            }
        }

        if (!ordered)
        {
            await Settle();
            w.SetConnected(false);
        }

        w.SetConnected(true);
        w.Link.DelayMs = 0;
        await VerifyAll("at the end");
        AppLog.Line($"  seed {seed}: {ops} ops [{string.Join(" ", counts.OrderBy(k => k.Key).Select(k => k.Key + "=" + k.Value))}] final length {A.Len}, paragraphs {A.Text.Count(c => c == '\n')}");
    }

    // ---------------------------------------------------------------------------------------------------
    // Real keyboard input through SendInput. Only runs when our window really is the foreground window.
    // ---------------------------------------------------------------------------------------------------

    private nint Hwnd => WinRT.Interop.WindowNative.GetWindowHandle(w);

    private async Task RealInput()
    {
        var keys = new RealKeys(Hwnd);
        w.Activate();
        var previous = keys.TakeForeground();
        try
        {
            await Task.Delay(300);
            w.BoxA.Focus(FocusState.Keyboard);
            await Task.Delay(300);
            if (!keys.IsForeground)
            {
                AppLog.Line("  SKIPPED real-input: the test window could not become the foreground window; nothing was typed");
                return;
            }

            await RealInputCore(keys);
        }
        finally
        {
            keys.Restore(previous);
        }
    }

    private async Task RealInputCore(RealKeys keys)
    {
        const ushort Enter = 0x0D, Back = 0x08, Ctrl = 0x11, Shift = 0x10, Left = 0x25, Home = 0x24, End = 0x23, Del = 0x2E;
        var ok = await keys.Type("Typed with real keys");
        await Task.Delay(150);
        await Settle();
        if (!ok)
        {
            AppLog.Line("  SKIPPED real-input: lost the foreground while typing");
            return;
        }

        t.Eq("real typing reaches B", "Typed with real keys\n", B.Text);
        ok &= await keys.Press(Enter);
        ok &= await keys.Type("second");
        ok &= await keys.Press(Back, 2);
        await Task.Delay(150);
        await VerifyAll("after Enter + Backspace keys");
        t.Eq("Enter and Backspace", "Typed with real keys\nseco\n", B.Text);

        // Ctrl+B is handled by RichEdit itself: selection formatting and "insertion formatting".
        ok &= await keys.Keys((Shift, '\0', false));
        ok &= await keys.Press(Home);
        ok &= await keys.Keys((Shift, '\0', true));
        ok &= await keys.Chord(Ctrl, 0x42);
        await Task.Delay(150);
        await VerifyAll("after native Ctrl+B on a selection");
        t.Check("native Ctrl+B on selection", w.B.Shadow.Cells[B.Text.IndexOf("seco", StringComparison.Ordinal)].Inline.Bold);
        ok &= await keys.Press(End);
        ok &= await keys.Chord(Ctrl, 0x49);
        ok &= await keys.Type("ital");
        await Task.Delay(150);
        await VerifyAll("after Ctrl+I then typing");
        t.Check("typing with pending italic", w.B.Shadow.Cells[B.Text.IndexOf("ital", StringComparison.Ordinal) + 1].Inline.Italic, RichModel.Dump(w.B.Shadow.Cells));

        // Ctrl+Z goes to the CRDT undo manager (native undo is off).
        var before = A.Text;
        ok &= await keys.Chord(Ctrl, 0x5A);
        await Task.Delay(150);
        await VerifyAll("after Ctrl+Z");
        t.Check("Ctrl+Z undid something through the CRDT", A.Text != before && A.Text.Length < before.Length, $"«{Show(before)}» -> «{Show(A.Text)}»");
        ok &= await keys.Chord(Ctrl, 0x59);
        await Task.Delay(150);
        await VerifyAll("after Ctrl+Y");
        t.Eq("Ctrl+Y redid it", before, A.Text);

        // Remote edit while the user keeps typing: no lost keystrokes, caret stays put.
        w.Link.DelayMs = 40;
        var typing = keys.Type(" keeps typing while remote edits arrive");
        for (var i = 0; i < 8; i++)
        {
            B.Type(0, "R" + i + " ");
            await Task.Delay(45);
        }

        ok &= await typing;
        await Task.Delay(200);
        await VerifyAll("after typing during remote edits");
        t.Check("no keystroke lost or misplaced", A.Text.Contains("ital keeps typing while remote edits arrive"), A.Text);
        t.Check("all remote inserts present", Enumerable.Range(0, 8).All(i => A.Text.Contains("R" + i + " ")), A.Text);
        w.Link.DelayMs = 0;

        // Ctrl+V with plain text, Delete key, selection replace by typing.
        var dp = new DataPackage();
        dp.SetText("PASTED");
        await SetClipboard(dp);
        ok &= await keys.Press(Home);
        ok &= await keys.Chord(Ctrl, 0x56);
        await Task.Delay(200);
        await VerifyAll("after Ctrl+V");
        t.Check("Ctrl+V", B.Text.Contains("PASTED"), B.Text);
        ok &= await keys.Press(Del, 3);
        ok &= await keys.Keys((Shift, '\0', false));
        ok &= await keys.Press(Left, 4);
        ok &= await keys.Keys((Shift, '\0', true));
        ok &= await keys.Type("Z");
        await Task.Delay(150);
        await VerifyAll("after Delete key and typing over a selection");

        // Enter in a to-do and in a bullet list (native list continuation and termination).
        ok &= await keys.Press(End);
        ok &= await keys.Press(Enter);
        ok &= await keys.Type("task");
        await Task.Delay(100);
        w.A.ToggleBlock("todo");
        ok &= await keys.Press(Enter);
        ok &= await keys.Type("next");
        ok &= await keys.Press(Enter);
        ok &= await keys.Press(Enter);
        ok &= await keys.Type("after list");
        await Task.Delay(200);
        await VerifyAll("after Enter inside a to-do list");
        Checks.Note($"blocks after Enter/Enter in a to-do: [{A.Blocks()}]");
        t.Check("the foreground window was ours for every keystroke", ok);
    }
}

/// <summary>Real keyboard input through SendInput, sent only while our own window is the foreground window.</summary>
internal sealed class RealKeys(nint hwnd)
{
    [StructLayout(LayoutKind.Sequential)]
    private struct KeyboardInput
    {
        public ushort Vk;
        public ushort Scan;
        public uint Flags;
        public uint Time;
        public nint ExtraInfo;
    }

    [StructLayout(LayoutKind.Explicit, Size = 40)]
    private struct Input
    {
        [FieldOffset(0)]
        public uint Type;

        [FieldOffset(8)]
        public KeyboardInput Keyboard;

        [FieldOffset(8)]
        public MouseInput Mouse;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct MouseInput
    {
        public int X;
        public int Y;
        public uint Data;
        public uint Flags;
        public uint Time;
        public nint ExtraInfo;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct ScreenPoint
    {
        public int X;
        public int Y;
    }

    [DllImport("user32.dll")]
    private static extern bool SetCursorPos(int x, int y);

    [DllImport("user32.dll")]
    private static extern int GetSystemMetrics(int index);

    [DllImport("user32.dll")]
    private static extern bool GetCursorPos(out ScreenPoint point);

    [DllImport("user32.dll")]
    public static extern bool ClientToScreen(nint hwnd, ref ScreenPoint point);

    private bool Button(bool down)
    {
        if (!IsForeground)
        {
            return false;
        }

        var input = new Input { Type = 0, Mouse = new MouseInput { Flags = down ? 0x0002u : 0x0004u } };
        SendInput(1, [input], Marshal.SizeOf<Input>());
        return true;
    }

    /// <summary>A real left click at a screen position (only while our window is in front); the pointer is put back afterwards.</summary>
    public async Task<bool> Click(ScreenPoint at)
    {
        if (!IsForeground)
        {
            return false;
        }

        GetCursorPos(out var before);
        SetCursorPos(at.X, at.Y);
        await Task.Delay(80);
        var ok = Button(down: true);
        await Task.Delay(50);
        ok &= Button(down: false);
        await Task.Delay(120);
        SetCursorPos(before.X, before.Y);
        return ok;
    }

    /// <summary>A real drag with the left button from one screen position to another, in small steps.</summary>
    public async Task<bool> Drag(ScreenPoint from, ScreenPoint to, int steps = 24)
    {
        if (!IsForeground)
        {
            return false;
        }

        GetCursorPos(out var before);
        SetCursorPos(from.X, from.Y);
        await Task.Delay(120);
        var ok = Button(down: true);
        await Task.Delay(250);
        for (var i = 1; i <= steps && ok; i++)
        {
            // Real mouse-move input (not just a moved cursor): a drag is recognised from the input stream.
            var x = from.X + ((to.X - from.X) * i / steps);
            var y = from.Y + ((to.Y - from.Y) * i / steps);
            var move = new Input
            {
                Type = 0,
                Mouse = new MouseInput
                {
                    X = (int)((x * 65535L) / Math.Max(1, GetSystemMetrics(0) - 1)),
                    Y = (int)((y * 65535L) / Math.Max(1, GetSystemMetrics(1) - 1)),
                    Flags = 0x8001, // MOUSEEVENTF_MOVE | MOUSEEVENTF_ABSOLUTE
                },
            };
            SendInput(1, [move], Marshal.SizeOf<Input>());
            await Task.Delay(30);
        }

        await Task.Delay(300);
        Button(down: false);
        await Task.Delay(300);
        SetCursorPos(before.X, before.Y);
        return ok;
    }

    [DllImport("user32.dll", SetLastError = true)]
    private static extern uint SendInput(uint count, Input[] inputs, int size);

    [DllImport("user32.dll")]
    private static extern nint GetForegroundWindow();

    [DllImport("user32.dll")]
    public static extern bool SetForegroundWindow(nint hwnd);

    [DllImport("user32.dll")]
    private static extern uint GetWindowThreadProcessId(nint hwnd, out uint processId);

    [DllImport("kernel32.dll")]
    private static extern uint GetCurrentThreadId();

    [DllImport("user32.dll")]
    private static extern bool AttachThreadInput(uint from, uint to, bool attach);

    [DllImport("user32.dll")]
    private static extern bool BringWindowToTop(nint hwnd);

    public bool IsForeground => GetForegroundWindow() == hwnd;

    /// <summary>
    /// Brings our window to the front without sending input to anyone else (a process started in the background
    /// is not allowed to do that directly, so the calling thread borrows the foreground thread's input queue for
    /// a moment). Returns the window that was in front, for <see cref="Restore"/>.
    /// </summary>
    public nint TakeForeground()
    {
        var previous = GetForegroundWindow();
        if (previous == hwnd)
        {
            return previous;
        }

        var me = GetCurrentThreadId();
        var other = previous == 0 ? 0 : GetWindowThreadProcessId(previous, out _);
        if (other != 0 && other != me)
        {
            AttachThreadInput(me, other, true);
        }

        BringWindowToTop(hwnd);
        SetForegroundWindow(hwnd);
        if (other != 0 && other != me)
        {
            AttachThreadInput(me, other, false);
        }

        return previous;
    }

    /// <summary>Gives the foreground back to the window that had it.</summary>
    public void Restore(nint previous)
    {
        if (previous != 0 && previous != hwnd && IsForeground)
        {
            SetForegroundWindow(previous);
        }
    }

    public async Task<bool> Keys(params (ushort Vk, char Ch, bool Up)[] keys)
    {
        foreach (var k in keys)
        {
            if (!IsForeground)
            {
                return false; // never type into somebody else's window
            }

            var input = new Input { Type = 1, Keyboard = new KeyboardInput { Vk = k.Vk, Scan = k.Ch, Flags = (k.Ch != 0 ? 4u : 0u) | (k.Up ? 2u : 0u) } };
            SendInput(1, [input], Marshal.SizeOf<Input>());
            await Task.Delay(12);
        }

        return true;
    }

    public Task<bool> Type(string s) => Keys(s.SelectMany(c => new[] { ((ushort)0, c, false), ((ushort)0, c, true) }).ToArray());

    public Task<bool> Press(ushort vk, int times = 1) => Keys(Enumerable.Range(0, times).SelectMany(_ => new[] { (vk, '\0', false), (vk, '\0', true) }).ToArray());

    public Task<bool> Chord(ushort mod, ushort vk) => Keys((mod, '\0', false), (vk, '\0', false), (vk, '\0', true), (mod, '\0', true));

    public Task<bool> Chord(ushort mod1, ushort mod2, ushort vk) =>
        Keys((mod1, '\0', false), (mod2, '\0', false), (vk, '\0', false), (vk, '\0', true), (mod2, '\0', true), (mod1, '\0', true));
}
