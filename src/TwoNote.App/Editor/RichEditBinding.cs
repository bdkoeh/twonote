using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Input;
using Microsoft.UI.Xaml.Media;
using TwoNote.Core.Documents;
using Windows.Foundation;

namespace TwoNote.App.Editor;

/// <summary>
/// Two-way binding between one RichEditBox and one page document (the Yjs Text <c>c:main</c>).
///
/// Design (what experiments with the control found to be reliable):
///  * A shadow model (<see cref="RichModel"/>) holds the last state the control and the CRDT agreed on.
///    Index parity is exact: Yjs index == control character position ('\n' == RichEdit '\r', U+2028 == '\v').
///  * control -> CRDT is RECONCILIATION, not event translation: <see cref="SyncLocal"/> diffs the control against
///    the shadow (text by common prefix/suffix, formatting by re-reading the affected paragraphs) and writes the
///    difference as one document edit. It is idempotent and runs from TextChanging (which RichEditBox raises
///    synchronously, for content and format-only changes alike), from TextChanged as a safety net, and always
///    before any remote change is applied. Typing, paste, drag-drop, IME commit and built-in shortcuts therefore
///    need no special cases.
///  * CRDT -> control applies the delta of a remote change or an undo as ranged ITextRange edits, then makes the
///    formatting of the touched paragraphs match the shadow (<see cref="RenderParagraphs"/>). Echo is impossible
///    by construction: our own control writes happen under <see cref="_applying"/> and leave control == shadow,
///    so the next diff is empty.
///  * Built-in undo is switched off (UndoLimit = 0); Ctrl+Z / Ctrl+Y go to the document's undo manager, which
///    only tracks this user's edits.
///
/// Whoever applies remote updates to the document must call <see cref="PrepareForExternalChange"/> first (and
/// wait while <see cref="IsBusy"/>); the app's dispatcher hook does, and <see cref="ApplyRemoteUpdate"/> does
/// both for callers that hold the update bytes.
/// </summary>
internal sealed class RichEditBinding : IDisposable
{
    private readonly RichEditBox _box;
    private readonly RichEditTextDocument _doc;
    private readonly PageDocument _page;
    private readonly RichModel _shadow = new();
    private readonly List<byte[]> _queuedRemote = [];
    private readonly TappedEventHandler _tapped;
    private string _shadowText = "";
    private bool _applying;      // we are writing to the control ourselves
    private bool _syncing;       // re-entrancy guard for SyncLocal
    private bool _formatDirty;   // a format-only change was reported by the control
    private bool _composing;     // IME composition in progress
    private bool _changedWhileComposing;
    private bool _renderQueued;
    private bool _cleanupQueued;
    private ITextRange? _renderRange;
    private ScrollViewer? _scroll;
    private bool _disposed;
    private int _changingEvents;

    public RichEditBinding(string name, RichEditBox box, PageDocument page, bool dark)
    {
        Name = name;
        _box = box;
        _doc = box.Document;
        _page = page;
        var defaults = _doc.GetDefaultCharacterFormat();
        Style = EditorStyle.Create(dark, defaults.Name, defaults.Size, defaults.BackgroundColor);
        ApplyDefaultFormat();
        _doc.UndoLimit = 0; // native undo would also undo remote edits; the CRDT undo manager replaces it
        FullReset();
        FullResets = 0;
        box.TextChanging += OnTextChanging;
        box.TextChanged += OnTextChanged;
        box.TextCompositionStarted += OnCompositionStarted;
        box.TextCompositionEnded += OnCompositionEnded;
        box.PreviewKeyDown += OnPreviewKeyDown;
        _tapped = OnTapped;
        box.AddHandler(UIElement.TappedEvent, _tapped, true);
        _page.TextChanged += OnPageTextChanged;
    }

    /// <summary>Diagnostics sink. Messages never contain document text.</summary>
    public static Action<string>? Log { get; set; }

    public EditorStyle Style { get; private set; }

    public RichModel Shadow => _shadow;

    public PageDocument Page => _page;

    public string Name { get; }

    /// <summary>True while the binding is in the middle of its own work or an IME composition: remote changes must wait.</summary>
    public bool IsBusy => _applying || _syncing || _composing;

    /// <summary>Raised when the user Ctrl+clicks (or taps with Ctrl) a link.</summary>
    public event Action<string>? LinkActivated;

    // Counters for the self-test.
    public int LocalTransactions { get; private set; }

    public int RemoteDeltas { get; private set; }

    public int FullResets { get; private set; }

    public int RenderFixes { get; private set; }

    public int SelectionRestores { get; private set; }

    public int ScrollRestores { get; private set; }

    public int ReentrantDeliveries { get; private set; }

    public int ForbiddenCharactersRemoved { get; private set; }

    public void Dispose()
    {
        if (_disposed)
        {
            return;
        }

        _disposed = true;
        _box.RemoveHandler(UIElement.TappedEvent, _tapped);
        _box.TextChanging -= OnTextChanging;
        _box.TextChanged -= OnTextChanged;
        _box.TextCompositionStarted -= OnCompositionStarted;
        _box.TextCompositionEnded -= OnCompositionEnded;
        _box.PreviewKeyDown -= OnPreviewKeyDown;
        _page.TextChanged -= OnPageTextChanged;
    }

    /// <summary>Switches to the other theme's colours and repaints everything from the shadow.</summary>
    public void SetTheme(bool dark)
    {
        if (_disposed)
        {
            return;
        }

        if (dark != Style.Dark)
        {
            Style = EditorStyle.Create(dark, Style.BodyFont, Style.BodySize, Style.NoBg);
        }

        // Finding: when the element theme changes, RichEditBox itself repaints the foreground of ALL its text
        // (links included), and it may do so after this call. So: repaint now, and again once the control has
        // had its turn. Reading the control in between is harmless because SyncLocal never takes a link away
        // from existing text on the strength of its colour.
        Repaint();
        _box.DispatcherQueue.TryEnqueue(Microsoft.UI.Dispatching.DispatcherQueuePriority.Low, Repaint);
        var timer = _box.DispatcherQueue.CreateTimer();
        timer.Interval = TimeSpan.FromMilliseconds(250);
        timer.IsRepeating = false;
        timer.Tick += (t, _) =>
        {
            t.Stop();
            Repaint();
        };
        timer.Start();
    }

    /// <summary>Makes the whole control show the canonical rendering of the shadow in the current theme.</summary>
    private void Repaint()
    {
        if (_disposed || _composing || _applying || _syncing)
        {
            return;
        }

        WriteControl(() =>
        {
            ApplyDefaultFormat();
            if (_shadow.Length > 0 && ReadControlText().StartsWith(_shadowText, StringComparison.Ordinal))
            {
                RenderParagraphs(0, _shadow.Length - 1, checkOnly: false);
            }
        });
    }

    private void ApplyDefaultFormat()
    {
        var outer = _applying;
        _applying = true;
        try
        {
            var format = _doc.GetDefaultCharacterFormat();
            format.ForegroundColor = Style.TextFg;
            _doc.SetDefaultCharacterFormat(format);
            if (_doc.Selection.StartPosition == _doc.Selection.EndPosition)
            {
                _doc.Selection.CharacterFormat.ForegroundColor = Style.TextFg;
            }
        }
        finally
        {
            _applying = outer;
        }
    }

    // =====================================================================================================
    // Control events
    // =====================================================================================================

    private void OnTextChanging(RichEditBox sender, RichEditBoxTextChangingEventArgs e)
    {
        _changingEvents++;
        if (_applying)
        {
            return;
        }

        if (!e.IsContentChanging)
        {
            _formatDirty = true;
        }

        SyncFromEvent();
    }

    private void OnTextChanged(object sender, RoutedEventArgs e)
    {
        if (!_applying)
        {
            SyncFromEvent();
        }
    }

    private void SyncFromEvent()
    {
        try
        {
            SyncLocal();
        }
        catch (ObjectDisposedException)
        {
            // The document was closed underneath a binding nobody disposed. An exception escaping from a
            // control event would also keep every other handler of that event from running: stand down.
            Log?.Invoke($"[{Name}] the page document is gone; the binding stops");
            Dispose();
        }
    }

    private void OnCompositionStarted(RichEditBox sender, TextCompositionStartedEventArgs e) => CompositionStarted();

    private void OnCompositionEnded(RichEditBox sender, TextCompositionEndedEventArgs e) => CompositionEnded();

    /// <summary>While an IME composition is active nothing is read from or written to the document: local changes
    /// are reconciled once at the end, remote updates wait. (Public so the self-test can drive the gating without
    /// a real IME.)</summary>
    public void CompositionStarted() => _composing = true;

    public void CompositionEnded()
    {
        _composing = false;
        if (_changedWhileComposing)
        {
            // The document changed underneath an active composition (nobody waited for IsBusy). The shadow is
            // stale, so the composition's text cannot be reconciled: reload from the document.
            _changedWhileComposing = false;
            Log?.Invoke($"[{Name}] document changed during a composition; reloading the control");
            FullReset();
        }
        else
        {
            SyncLocal();
        }

        FlushQueuedRemote();
    }

    private void OnPreviewKeyDown(object sender, KeyRoutedEventArgs e)
    {
        var ctrl = Microsoft.UI.Input.InputKeyboardSource.GetKeyStateForCurrentThread(Windows.System.VirtualKey.Control)
            .HasFlag(Windows.UI.Core.CoreVirtualKeyStates.Down);
        var alt = Microsoft.UI.Input.InputKeyboardSource.GetKeyStateForCurrentThread(Windows.System.VirtualKey.Menu)
            .HasFlag(Windows.UI.Core.CoreVirtualKeyStates.Down);
        if (!ctrl || alt)
        {
            return;
        }

        if (e.Key == Windows.System.VirtualKey.Z)
        {
            Undo();
            e.Handled = true;
        }
        else if (e.Key == Windows.System.VirtualKey.Y)
        {
            Redo();
            e.Handled = true;
        }
    }

    private void OnTapped(object sender, TappedRoutedEventArgs e)
    {
        if (Scroll?.Content is not UIElement content)
        {
            return;
        }

        var point = e.GetPosition(content);
        if (TryToggleTodoAt(point))
        {
            e.Handled = true;
            return;
        }

        var ctrl = Microsoft.UI.Input.InputKeyboardSource.GetKeyStateForCurrentThread(Windows.System.VirtualKey.Control)
            .HasFlag(Windows.UI.Core.CoreVirtualKeyStates.Down);
        if (ctrl && LinkAtPoint(point) is { } url)
        {
            e.Handled = true;
            LinkActivated?.Invoke(url);
        }
    }

    // =====================================================================================================
    // control -> CRDT
    // =====================================================================================================

    /// <summary>Call before the document is changed from outside (a remote update). Returns false while the
    /// binding is busy; the caller then tries again a little later.</summary>
    public bool PrepareForExternalChange()
    {
        if (_disposed)
        {
            return true;
        }

        if (IsBusy)
        {
            return false;
        }

        SyncLocal();
        return true;
    }

    /// <summary>Brings the CRDT (and shadow) up to date with whatever the control currently holds.</summary>
    public void SyncLocal()
    {
        if (_applying || _syncing || _composing || _disposed)
        {
            return;
        }

        _syncing = true;
        try
        {
            var now = ReadControlText();
            if (PasteFilter.ContainsForbidden(now))
            {
                // An embedded object or table structure got into the control (drag and drop, an input method).
                // It is removed again right after this event; until then nothing is written to the document.
                QueueCleanup();
                return;
            }

            if (!_shadowText.EndsWith('\n'))
            {
                // The page content has not arrived yet (or a peer deleted the final newline). The control always
                // shows a final paragraph mark; that alone is not an edit (PROTOCOL.md 5.2).
                if (!_formatDirty && now.Length == _shadowText.Length + 1 && now.StartsWith(_shadowText, StringComparison.Ordinal))
                {
                    return;
                }

                RepairFinalNewline();
            }

            var old = _shadowText;
            var edit = TextEdit.Diff(old, now, _doc.Selection.EndPosition);
            var formatOnly = _formatDirty;
            _formatDirty = false;
            if (edit.IsEmpty && !formatOnly)
            {
                return;
            }

            // Paragraphs (in NEW coordinates) whose formatting has to be re-read from the control.
            int from, to; // 'to' is the index of the newline ending the last affected paragraph
            if (edit.IsEmpty)
            {
                from = ParagraphStart(now, Math.Min(_doc.Selection.StartPosition, now.Length - 1));
                to = ParagraphEnd(now, Math.Min(_doc.Selection.EndPosition, now.Length - 1));
            }
            else
            {
                from = ParagraphStart(now, edit.Start);
                to = ParagraphEnd(now, edit.Start + edit.InsertCount);
                if (formatOnly)
                {
                    from = Math.Min(from, ParagraphStart(now, Math.Min(_doc.Selection.StartPosition, now.Length - 1)));
                    to = Math.Max(to, ParagraphEnd(now, Math.Min(_doc.Selection.EndPosition, now.Length - 1)));
                }
            }

            var insEnd = edit.Start + edit.InsertCount;
            var shift = edit.DeleteCount - edit.InsertCount; // new index + shift = old index (after the edit)
            var count = to + 1 - from;
            var cells = new Cell[count];
            var inserted = new bool[count];
            var linkStyled = new bool[count];

            Cell OldCell(int k) => _shadow.Cells[from + k < edit.Start ? from + k : from + k + shift];

            // Character formatting of the region, as the control has it now.
            foreach (var run in ReadRuns(from, to + 1))
            {
                var inline = Style.InlineFrom(run.Spec, out var styled);
                for (var i = run.Start; i < run.End; i++)
                {
                    var k = i - from;
                    inserted[k] = i >= edit.Start && i < insEnd;
                    var before = inserted[k] ? default : _shadow.Cells[i < edit.Start ? i : i + shift];
                    // Text that was already there keeps its link whatever colour the control shows: nothing the
                    // user can do in the control removes a link (that goes through SetLink), but the control
                    // itself repaints all foregrounds on a theme change. A lost colour is repainted below.
                    cells[k] = new Cell(now[i], inline with { Link = before.Inline.Link }, before.Block);
                    linkStyled[k] = styled;
                }
            }

            // A link-styled character without a URL (typed inside or at the edge of a link) takes its neighbour's URL.
            for (var k = 0; k < count; k++)
            {
                if (linkStyled[k] && cells[k].Inline.Link == null)
                {
                    var left = k > 0 ? cells[k - 1].Inline.Link : from > 0 && from - 1 < edit.Start ? _shadow.Cells[from - 1].Inline.Link : null;
                    if (left != null)
                    {
                        cells[k].Inline = cells[k].Inline with { Link = left };
                    }
                }
            }

            for (var k = count - 2; k >= 0; k--)
            {
                if (linkStyled[k] && cells[k].Inline.Link == null && cells[k + 1].Inline.Link != null)
                {
                    cells[k].Inline = cells[k].Inline with { Link = cells[k + 1].Inline.Link };
                }
            }

            // Paragraph formatting of the region.
            var ps = from;
            while (ps <= to)
            {
                var pe = ParagraphEnd(now, ps);
                var k = pe - from;
                var block = EditorStyle.BlockFrom(ReadPara(ps));

                // Keep the raw CRDT value when the control shows the same thing (preserves values we do not understand).
                if (inserted[k] || cells[k].Block.Effective() != block)
                {
                    cells[k].Block = block;
                }

                for (var i = ps; i < pe; i++)
                {
                    cells[i - from].Block = default;
                }

                ps = pe + 1;
            }

            // Write the difference: one document edit per reconciliation.
            var oldFrom = from; // from <= edit.Start, so old and new coordinates agree here
            var oldCount = count + shift;
            var ops = 0;
            _page.Edit(ed =>
            {
                if (edit.DeleteCount > 0)
                {
                    ed.Delete(edit.Start, edit.DeleteCount);
                    ops++;
                }

                // Inserted text, grouped into runs of identical attributes (each newline on its own).
                var i = edit.Start;
                while (i < insEnd)
                {
                    var c = cells[i - from];
                    var j = i + 1;
                    if (c.Ch != '\n')
                    {
                        while (j < insEnd && cells[j - from].Ch != '\n' && cells[j - from].Inline == c.Inline)
                        {
                            j++;
                        }
                    }

                    var attributes = c.Inline.ToAttributes();
                    if (c.Ch == '\n')
                    {
                        foreach (var key in BlockAttrs.Keys)
                        {
                            if (c.Block.Get(key) is { } v)
                            {
                                attributes[key] = v;
                            }
                        }
                    }

                    ed.Insert(i, now[i..j], attributes);
                    ops++;
                    i = j;
                }

                // Formatting changes on text that was already there.
                foreach (var key in InlineAttrs.Keys)
                {
                    var k = 0;
                    while (k < count)
                    {
                        if (inserted[k])
                        {
                            k++;
                            continue;
                        }

                        var value = cells[k].Inline.Get(key);
                        if (Equals(value, OldCell(k).Inline.Get(key)))
                        {
                            k++;
                            continue;
                        }

                        var m = k + 1;
                        while (m < count && !inserted[m] && Equals(cells[m].Inline.Get(key), value) && !Equals(OldCell(m).Inline.Get(key), value))
                        {
                            m++;
                        }

                        ed.Format(from + k, m - k, new Dictionary<string, object?> { [key] = value });
                        ops++;
                        k = m;
                    }
                }

                for (var k = 0; k < count; k++)
                {
                    if (inserted[k] || cells[k].Ch != '\n' || cells[k].Block == OldCell(k).Block)
                    {
                        continue;
                    }

                    // Always write all three keys so 'checked'/'indent' can never go stale against 'block'.
                    var block = cells[k].Block;
                    ed.Format(from + k, 1, BlockAttrs.Keys.ToDictionary(key => key, key => block.Get(key)));
                    ops++;
                }
            });
            if (ops > 0)
            {
                LocalTransactions++;
            }

            _shadow.Cells.RemoveRange(oldFrom, oldCount);
            _shadow.Cells.InsertRange(oldFrom, cells);
            _shadowText = now;

            // Does the control show the canonical rendering of what we just read? (pasted fonts/sizes, merged
            // paragraphs with mixed sizes, to-do neighbours, links without a URL ...). If not, fix it up afterwards:
            // the control must not be modified from inside TextChanging.
            if (RenderParagraphs(from, to, checkOnly: true) > 0)
            {
                QueueRender(from, to + 1);
            }
        }
        catch (Exception ex)
        {
            Log?.Invoke($"[{Name}] SyncLocal failed: {ex.GetType().Name} at {ex.StackTrace}");
            throw;
        }
        finally
        {
            _syncing = false;
        }
    }

    /// <summary>Appends the mandatory final newline as part of an edit (PROTOCOL.md 5.2).</summary>
    private void RepairFinalNewline()
    {
        if (_shadowText.EndsWith('\n'))
        {
            return;
        }

        _page.Edit(_ => { }); // Edit appends the missing newline itself
        _shadow.Cells.Add(new Cell('\n', default, default));
        _shadowText += "\n";
        LocalTransactions++;
    }

    private void QueueRender(int from, int toExclusive)
    {
        // A live range follows later edits, so the region stays right until the deferred pass runs.
        if (_renderRange == null)
        {
            _renderRange = _doc.GetRange(from, toExclusive);
        }
        else
        {
            _renderRange.SetRange(Math.Min(_renderRange.StartPosition, from), Math.Max(_renderRange.EndPosition, toExclusive));
        }

        if (_renderQueued)
        {
            return;
        }

        _renderQueued = true;
        _box.DispatcherQueue.TryEnqueue(RunQueuedRender);
    }

    /// <summary>Runs the deferred presentation fix-up now (also called by the self-test to settle state).</summary>
    public void RunQueuedRender()
    {
        if (!_renderQueued || _disposed)
        {
            return;
        }

        if (_composing)
        {
            _box.DispatcherQueue.TryEnqueue(RunQueuedRender);
            return;
        }

        _renderQueued = false;
        var range = _renderRange;
        _renderRange = null;
        if (range == null)
        {
            return;
        }

        SyncLocal();
        if (_shadow.Length == 0 || ReadControlText() != _shadowText)
        {
            return;
        }

        var from = Math.Clamp(range.StartPosition, 0, _shadow.Length - 1);
        var to = Math.Clamp(range.EndPosition, from, _shadow.Length - 1);
        WriteControl(() => RenderParagraphs(from, to, checkOnly: false));
    }

    private void QueueCleanup()
    {
        if (_cleanupQueued)
        {
            return;
        }

        _cleanupQueued = true;
        _box.DispatcherQueue.TryEnqueue(RemoveForbiddenCharacters);
    }

    /// <summary>Deletes embedded objects and table structure from the control (v1 is text only), then reconciles.</summary>
    public void RemoveForbiddenCharacters()
    {
        _cleanupQueued = false;
        if (_disposed)
        {
            return;
        }

        if (_composing || _applying || _syncing)
        {
            QueueCleanup();
            return;
        }

        var text = ReadControlText();
        if (PasteFilter.ContainsForbidden(text))
        {
            WriteControl(() =>
            {
                for (var i = text.Length - 1; i >= 0; i--)
                {
                    if (!PasteFilter.IsForbidden(text[i]))
                    {
                        continue;
                    }

                    var start = i;
                    while (start > 0 && PasteFilter.IsForbidden(text[start - 1]))
                    {
                        start--;
                    }

                    _doc.GetRange(start, i + 1).SetText(TextSetOptions.None, "");
                    ForbiddenCharactersRemoved += i + 1 - start;
                    i = start;
                }
            });
            if (PasteFilter.ContainsForbidden(ReadControlText()))
            {
                // RichEdit refused (a table cell mark cannot always be deleted on its own): give up on the
                // control's content rather than let it into the document.
                Log?.Invoke($"[{Name}] could not remove embedded content; reloading the control");
                FullReset();
                return;
            }
        }

        _formatDirty = true;
        SyncLocal();
    }

    // =====================================================================================================
    // CRDT -> control
    // =====================================================================================================

    /// <summary>Applies an update received from another replica (used where the caller holds the update itself;
    /// the app's sync path goes through <see cref="PrepareForExternalChange"/> instead).</summary>
    public void ApplyRemoteUpdate(byte[] update)
    {
        if (_composing)
        {
            _queuedRemote.Add(update); // never touch the document under an active IME composition
            return;
        }

        if (_applying || _syncing)
        {
            // Delivered from a nested message pump while this binding is in the middle of its own work
            // (some RichEdit/OLE calls pump). Applying now would interleave two reconciliations: defer.
            ReentrantDeliveries++;
            _queuedRemote.Add(update);
            _box.DispatcherQueue.TryEnqueue(FlushQueuedRemote);
            return;
        }

        SyncLocal();
        _page.ApplyUpdate(update);
    }

    private void FlushQueuedRemote()
    {
        if (_queuedRemote.Count == 0 || _disposed || _composing || _applying || _syncing)
        {
            return;
        }

        var queued = _queuedRemote.ToArray();
        _queuedRemote.Clear();
        foreach (var u in queued)
        {
            ApplyRemoteUpdate(u);
        }
    }

    public bool Undo()
    {
        if (IsBusy)
        {
            return false;
        }

        SyncLocal();
        return _page.Undo();
    }

    public bool Redo()
    {
        if (IsBusy)
        {
            return false;
        }

        SyncLocal();
        return _page.Redo();
    }

    private void OnPageTextChanged(TextChange change)
    {
        if (change.Source == ChangeSource.Local || _disposed)
        {
            return; // made by this binding: control and shadow already agree
        }

        if (!_box.DispatcherQueue.HasThreadAccess)
        {
            _box.DispatcherQueue.TryEnqueue(() =>
            {
                if (!_disposed)
                {
                    FullReset();
                }
            });
            return;
        }

        if (_composing)
        {
            _changedWhileComposing = true;
            return;
        }

        OnCrdtChanged(change.Delta, change.Source);
    }

    private void OnCrdtChanged(IReadOnlyList<DeltaOp> delta, ChangeSource source)
    {
        RemoteDeltas++;
        var selStart = _doc.Selection.StartPosition;
        var selEnd = _doc.Selection.EndPosition;
        var caret = selStart == selEnd;
        var anchor = CaptureScrollAnchor();
        var anchorPos = anchor?.Position ?? 0;
        var touched = new List<(int From, int To)>();
        var lastChange = -1;
        var ok = true;
        WriteControl(() =>
        {
            var pos = 0;
            foreach (var op in delta)
            {
                switch (op.Kind)
                {
                    case DeltaKind.Retain:
                        if (op.Attributes != null)
                        {
                            for (var i = pos; i < pos + op.Length && i < _shadow.Length; i++)
                            {
                                _shadow.Cells[i] = WithAttrs(_shadow.Cells[i], op.Attributes);
                            }

                            touched.Add((pos, pos + op.Length));
                            lastChange = pos + op.Length;
                        }

                        pos += op.Length;
                        break;

                    case DeltaKind.Insert:
                        var text = op.Text!;
                        if (pos >= _shadow.Length)
                        {
                            ok = false; // after the final paragraph mark (or into an empty page): RichEdit cannot do that
                        }
                        else
                        {
                            _doc.GetRange(pos, pos).SetText(TextSetOptions.None, ToControl(text));
                        }

                        var cells = new Cell[text.Length];
                        for (var i = 0; i < text.Length; i++)
                        {
                            cells[i] = WithAttrs(new Cell(text[i], default, default), op.Attributes);
                        }

                        _shadow.Cells.InsertRange(Math.Min(pos, _shadow.Length), cells);

                        // Remote text at the caret goes after it; at the edges of a selection it stays outside.
                        if (selStart > pos || (selStart == pos && !caret))
                        {
                            selStart += text.Length;
                        }

                        if (selEnd > pos)
                        {
                            selEnd += text.Length;
                        }

                        if (anchorPos >= pos)
                        {
                            anchorPos += text.Length;
                        }

                        touched.Add((pos, pos + text.Length));
                        pos += text.Length;
                        lastChange = pos;
                        break;

                    case DeltaKind.Delete:
                        if (pos < _shadow.Length)
                        {
                            _doc.GetRange(pos, pos + op.Length).SetText(TextSetOptions.None, "");
                            _shadow.Cells.RemoveRange(pos, Math.Min(op.Length, _shadow.Length - pos));
                        }

                        selStart = AfterDelete(selStart, pos, op.Length);
                        selEnd = AfterDelete(selEnd, pos, op.Length);
                        anchorPos = AfterDelete(anchorPos, pos, op.Length);
                        touched.Add((pos, pos));
                        lastChange = pos;
                        break;
                }
            }

            _shadowText = _shadow.Text;

            // The cheap, decisive check: ranged edits must have produced exactly the CRDT text.
            if (!ok || ReadControlText() != _shadowText || !_shadowText.EndsWith('\n'))
            {
                FullResetCore();
                return;
            }

            foreach (var (a, b) in Merge(touched))
            {
                RenderParagraphs(Math.Min(a, _shadow.Length - 1), Math.Min(b, _shadow.Length - 1), checkOnly: false);
            }
        });

        // Caret / selection: RichEdit moves them for edits before the selection, but not the way a collaborative
        // editor wants at the boundaries, so the expected position is computed here and enforced.
        var last = Math.Max(0, _shadow.Length - 1);
        if (source == ChangeSource.Undo && lastChange >= 0)
        {
            selStart = selEnd = Math.Min(lastChange, last);
        }

        selStart = Math.Clamp(selStart, 0, last);
        selEnd = Math.Clamp(selEnd, selStart, Math.Max(selStart, _shadow.Length));
        if (_doc.Selection.StartPosition != selStart || _doc.Selection.EndPosition != selEnd)
        {
            _applying = true;
            try
            {
                _doc.Selection.SetRange(selStart, selEnd);
            }
            finally
            {
                _applying = false;
            }

            SelectionRestores++;
        }

        if (anchor is { } an && source != ChangeSource.Undo && _shadow.Length > 0)
        {
            RestoreScrollAnchor(an with { Position = anchorPos });
        }
    }

    private static int AfterDelete(int x, int pos, int len) => x <= pos ? x : x >= pos + len ? x - len : pos;

    private static Cell WithAttrs(Cell c, IReadOnlyDictionary<string, object?>? attrs)
    {
        if (attrs == null)
        {
            return c;
        }

        foreach (var (key, value) in attrs)
        {
            c.Inline = c.Inline.With(key, value);
            if (c.Ch == '\n')
            {
                c.Block = c.Block.With(key, value);
            }
        }

        return c;
    }

    private static IEnumerable<(int From, int To)> Merge(List<(int From, int To)> ranges)
    {
        if (ranges.Count == 0)
        {
            yield break;
        }

        ranges.Sort();
        var cur = ranges[0];
        foreach (var r in ranges.Skip(1))
        {
            if (r.From <= cur.To + 1)
            {
                cur = (cur.From, Math.Max(cur.To, r.To));
            }
            else
            {
                yield return cur;
                cur = r;
            }
        }

        yield return cur;
    }

    /// <summary>The page document as cells (text plus attributes per code unit).</summary>
    public static List<Cell> ReadCells(PageDocument page) =>
        RichModel.CellsFromRuns(page.GetRuns().Select(r => (r.Text, r.Attributes)));

    /// <summary>Loads the whole control from the CRDT. Used once at start and as the safety net when a ranged
    /// apply did not produce the expected text (counted in <see cref="FullResets"/>).</summary>
    public void FullReset() => WriteControl(FullResetCore);

    private void FullResetCore()
    {
        FullResets++;
        _shadow.Cells.Clear();
        _shadow.Cells.AddRange(ReadCells(_page));
        _shadowText = _shadow.Text;
        var body = _shadowText.EndsWith('\n') ? _shadowText[..^1] : _shadowText; // the control supplies the final mark itself
        _doc.SetText(TextSetOptions.None, ToControl(body));
        ResetCaretFormat();
        if (_shadow.Length > 0 && ReadControlText().StartsWith(_shadowText, StringComparison.Ordinal))
        {
            // Also when the CRDT text lacks its final newline (content still arriving): the paragraphs that are
            // there are shown properly; the next real edit appends the newline.
            RenderParagraphs(0, _shadow.Length - 1, checkOnly: false);
        }
    }

    /// <summary>RichEdit keeps a pending "typing format" at the caret that survives SetText (finding: text typed into
    /// a freshly loaded page came out bold because the previous page ended in bold). Reset it on load.</summary>
    private void ResetCaretFormat()
    {
        _doc.Selection.SetRange(0, 0);
        var want = Style.Char(default, _shadow.BlockAt(0).Effective(), false);
        var cf = _doc.Selection.CharacterFormat;
        cf.Bold = want.Bold ? FormatEffect.On : FormatEffect.Off;
        cf.Italic = want.Italic ? FormatEffect.On : FormatEffect.Off;
        cf.Underline = want.Underline ? UnderlineType.Single : UnderlineType.None;
        cf.Strikethrough = want.Strike ? FormatEffect.On : FormatEffect.Off;
        cf.BackgroundColor = want.Bg;
        cf.ForegroundColor = want.Fg;
        cf.Size = want.Size;
        cf.Name = want.Font;
    }

    private void WriteControl(Action action)
    {
        var outer = _applying;
        _applying = true;
        _doc.BatchDisplayUpdates();
        try
        {
            action();
        }
        finally
        {
            _doc.ApplyDisplayUpdates();
            _applying = outer;
        }
    }

    // =====================================================================================================
    // Rendering: make the control's formatting of whole paragraphs equal the canonical rendering of the shadow
    // =====================================================================================================

    /// <summary>
    /// For every paragraph touching [from, to] (shadow positions) compares what the control holds with the
    /// canonical rendering of the shadow and writes only the differences. With <paramref name="checkOnly"/> it
    /// just counts them. Requires the control text to start with the shadow text. Returns the number of differences.
    /// </summary>
    private int RenderParagraphs(int from, int to, bool checkOnly)
    {
        var diffs = 0;
        var ps = _shadow.ParagraphStart(from);

        // Always look one paragraph past the region, and keep going through a run of to-dos: their marker
        // alignment depends on the paragraph before them, which may just have changed, appeared or gone.
        var cascade = true;
        while (ps < _shadow.Length)
        {
            var beyond = ps > to;
            if (beyond && !cascade)
            {
                break;
            }

            var pe = _shadow.ParagraphEnd(ps);
            var block = _shadow.Cells[pe].Block.Effective();
            var want = EditorStyle.Para(block, block.Block == "todo" ? ExpectedTodoAlign(ps, block.Checked) : MarkerAlignment.Left);
            var have = ReadPara(ps);
            cascade = !beyond || block.Block == "todo";
            if (!want.Matches(have))
            {
                diffs++;
                if (!checkOnly)
                {
                    WritePara(ps, want);
                }
            }

            foreach (var run in ReadRuns(ps, pe + 1))
            {
                var i = run.Start;
                while (i < run.End)
                {
                    var inline = _shadow.Cells[i].Inline;
                    var j = i + 1;
                    if (i != pe)
                    {
                        while (j < run.End && j != pe && _shadow.Cells[j].Inline == inline)
                        {
                            j++;
                        }
                    }

                    var spec = Style.Char(inline, block, i == pe && _shadow.Cells[pe].Ch == '\n');
                    if (spec != run.Spec)
                    {
                        diffs++;
                        if (!checkOnly)
                        {
                            WriteChars(i, j, spec, run.Spec);
                        }
                    }

                    i = j;
                }
            }

            ps = pe + 1;
        }

        if (!checkOnly)
        {
            RenderFixes += diffs;
        }

        return diffs;
    }

    /// <summary>Adjacent to-dos in the same state must alternate marker alignment or RichEdit numbers them ☐ ☑ ☒.</summary>
    private MarkerAlignment ExpectedTodoAlign(int paragraphStart, bool isChecked)
    {
        var same = 0;
        var p = paragraphStart;
        while (p > 0)
        {
            var prev = _shadow.Cells[p - 1].Block.Effective();
            if (prev.Block != "todo" || prev.Checked != isChecked)
            {
                break;
            }

            same++;
            p = _shadow.ParagraphStart(p - 1);
        }

        return same % 2 == 0 ? MarkerAlignment.Left : MarkerAlignment.Center;
    }

    // =====================================================================================================
    // Commands (toolbar / shortcuts)
    // =====================================================================================================

    /// <summary>Reconciles and makes sure the text ends in its newline, so a command has something to work on.</summary>
    private bool BeginCommand()
    {
        if (IsBusy || _disposed)
        {
            return false;
        }

        SyncLocal();
        RepairFinalNewline();
        return true;
    }

    /// <summary>The current selection, clamped to the text.</summary>
    public (int Start, int End) Selection
    {
        get
        {
            var s = _doc.Selection;
            return (s.StartPosition, s.EndPosition);
        }
    }

    /// <summary>Bold/italic/underline/strike: applied to the control exactly like the built-in shortcut would, and
    /// picked up by <see cref="SyncLocal"/> (this is the path native Ctrl+B takes too).</summary>
    private void ToggleInlineViaControl(string key)
    {
        var sel = _doc.Selection;
        var caret = sel.StartPosition == sel.EndPosition;
        var cf = sel.CharacterFormat;
        bool on;
        if (caret)
        {
            on = key switch
            {
                "bold" => cf.Bold != FormatEffect.On,
                "italic" => cf.Italic != FormatEffect.On,
                "underline" => cf.Underline is UnderlineType.None or UnderlineType.Undefined,
                _ => cf.Strikethrough != FormatEffect.On,
            };
        }
        else
        {
            on = !AllHave(sel.StartPosition, sel.EndPosition, key);
        }

        var eventsBefore = _changingEvents;

        switch (key)
        {
            case "bold": cf.Bold = on ? FormatEffect.On : FormatEffect.Off; break;
            case "italic": cf.Italic = on ? FormatEffect.On : FormatEffect.Off; break;
            case "underline": cf.Underline = on ? UnderlineType.Single : UnderlineType.None; break;
            case "strike": cf.Strikethrough = on ? FormatEffect.On : FormatEffect.Off; break;
            default: throw new ArgumentException("Not a native inline attribute.", nameof(key));
        }

        if (_changingEvents == eventsBefore && !caret)
        {
            // The control did not report the change (seen when another handler of the event had thrown).
            Log?.Invoke($"[{Name}] no TextChanging for native {key}; reconciling explicitly");
            _formatDirty = true;
        }

        SyncLocal();
    }

    /// <summary>Inline attribute set model-first (needed for code and link, whose value the control cannot hold).</summary>
    public void SetInline(int start, int end, string key, object? value)
    {
        if (!BeginCommand())
        {
            return;
        }

        start = Math.Clamp(start, 0, _shadow.Length);
        end = Math.Clamp(end, start, _shadow.Length);
        if (end == start)
        {
            return;
        }

        _page.Edit(ed => ed.Format(start, end - start, new Dictionary<string, object?> { [key] = value }));
        LocalTransactions++;
        for (var i = start; i < end; i++)
        {
            var c = _shadow.Cells[i];
            c.Inline = c.Inline.With(key, value);
            _shadow.Cells[i] = c;
        }

        WriteControl(() => RenderParagraphs(start, Math.Min(end, _shadow.Length - 1), checkOnly: false));
    }

    /// <summary>Toggles bold, italic, underline, strike or code on the selection (or, at a caret, for what is typed next).</summary>
    public void ToggleInline(string key)
    {
        if (!BeginCommand())
        {
            return;
        }

        var (s, e) = Selection;
        if (key == "code")
        {
            if (s == e)
            {
                // Typing format at the caret: the marker background is what SyncLocal reads back as "code".
                var cf = _doc.Selection.CharacterFormat;
                var on = cf.BackgroundColor != Style.CodeBg;
                cf.BackgroundColor = on ? Style.CodeBg : Style.Char(default, _shadow.BlockAt(s).Effective(), false).Bg;
                cf.Name = on ? EditorStyle.MonoFont : Style.Char(default, _shadow.BlockAt(s).Effective(), false).Font;
                return;
            }

            SetInline(s, e, key, AllHave(s, e, key) ? null : true);
        }
        else
        {
            ToggleInlineViaControl(key);
        }
    }

    /// <summary>True when every character of the range (paragraph marks aside) carries the attribute.</summary>
    public bool AllHave(int start, int end, string key)
    {
        if (end <= start)
        {
            return false;
        }

        for (var i = start; i < end && i < _shadow.Length; i++)
        {
            if (_shadow.Cells[i].Ch != '\n' && _shadow.Cells[i].Inline.Get(key) == null)
            {
                return false;
            }
        }

        return true;
    }

    /// <summary>The inline attributes that hold for the whole selection (at a caret: of the character before it).</summary>
    public InlineAttrs InlineAtSelection()
    {
        var (s, e) = Selection;
        if (_shadow.Length == 0)
        {
            return default;
        }

        if (s == e)
        {
            var cf = _doc.Selection.CharacterFormat;
            return new InlineAttrs(
                cf.Bold == FormatEffect.On, cf.Italic == FormatEffect.On,
                cf.Underline is not (UnderlineType.None or UnderlineType.Undefined), cf.Strikethrough == FormatEffect.On,
                cf.BackgroundColor == Style.CodeBg, LinkRangeAt(s)?.Url);
        }

        return new InlineAttrs(
            AllHave(s, e, "bold"), AllHave(s, e, "italic"), AllHave(s, e, "underline"), AllHave(s, e, "strike"), AllHave(s, e, "code"),
            LinkRangeAt(s)?.Url);
    }

    /// <summary>Block attributes of the paragraph the selection starts in.</summary>
    public BlockAttrs BlockAtSelection() => _shadow.BlockAt(Math.Min(Selection.Start, Math.Max(0, _shadow.Length - 1))).Effective();

    /// <summary>The link around a position: the run of characters carrying the same URL.</summary>
    public (int Start, int End, string Url)? LinkRangeAt(int pos)
    {
        if (_shadow.Length == 0)
        {
            return null;
        }

        string? UrlAt(int i) => i >= 0 && i < _shadow.Length ? _shadow.Cells[i].Inline.Link : null;
        var at = UrlAt(pos) != null ? pos : UrlAt(pos - 1) != null ? pos - 1 : -1;
        if (at < 0)
        {
            return null;
        }

        var url = UrlAt(at)!;
        var start = at;
        while (UrlAt(start - 1) == url)
        {
            start--;
        }

        var end = at + 1;
        while (UrlAt(end) == url)
        {
            end++;
        }

        return (start, end, url);
    }

    /// <summary>Sets (or with null removes) the link on a range.</summary>
    public void SetLink(int start, int end, string? url) => SetInline(start, end, "link", string.IsNullOrWhiteSpace(url) ? null : url.Trim());

    /// <summary>Inserts <paramref name="text"/> at the selection as a link to <paramref name="url"/>.</summary>
    public void InsertLink(string text, string url)
    {
        if (!BeginCommand() || text.Length == 0)
        {
            return;
        }

        text = PasteFilter.SanitizePlainText(text).Replace("\n", " ", StringComparison.Ordinal);
        var start = Math.Min(Selection.Start, _shadow.Length - 1);
        _doc.Selection.SetRange(start, Math.Min(Selection.End, _shadow.Length - 1));
        _doc.Selection.TypeText(text);
        SyncLocal();
        SetLink(start, start + text.Length, url);
        _doc.Selection.SetRange(start + text.Length, start + text.Length);
    }

    private string? LinkAtPoint(Point p)
    {
        SyncLocal();
        if (_shadow.Length == 0)
        {
            return null;
        }

        var range = _doc.GetRangeFromPoint(p, PointOptions.ClientCoordinates);
        var pos = Math.Clamp(range.StartPosition, 0, _shadow.Length - 1);
        return _shadow.Cells[pos].Inline.Link ?? (pos > 0 ? _shadow.Cells[pos - 1].Inline.Link : null);
    }

    /// <summary>Changes block attributes of every paragraph touching the selection (model-first).</summary>
    public void UpdateBlocks(Func<BlockAttrs, BlockAttrs> change) =>
        UpdateBlocks(_doc.Selection.StartPosition, _doc.Selection.EndPosition, change);

    public void UpdateBlocks(int start, int end, Func<BlockAttrs, BlockAttrs> change)
    {
        if (!BeginCommand())
        {
            return;
        }

        start = Math.Clamp(start, 0, _shadow.Length - 1);
        end = Math.Clamp(end, start, _shadow.Length - 1);
        if (end > start && _shadow.Cells[end - 1].Ch == '\n')
        {
            end--; // a selection ending right after a paragraph mark does not include the next paragraph
        }

        var changes = new List<(int Pos, BlockAttrs Block)>();
        var ps = _shadow.ParagraphStart(start);
        while (ps <= end && ps < _shadow.Length)
        {
            var pe = _shadow.ParagraphEnd(ps);
            var before = _shadow.Cells[pe].Block;
            var after = change(before.Effective());
            if (after != before)
            {
                changes.Add((pe, after));
            }

            ps = pe + 1;
        }

        if (changes.Count == 0)
        {
            return;
        }

        _page.Edit(ed =>
        {
            foreach (var (pos, block) in changes)
            {
                ed.Format(pos, 1, BlockAttrs.Keys.ToDictionary(k => k, k => block.Get(k)));
            }
        });
        LocalTransactions++;
        foreach (var (pos, block) in changes)
        {
            var c = _shadow.Cells[pos];
            c.Block = block;
            _shadow.Cells[pos] = c;
        }

        WriteControl(() => RenderParagraphs(changes[0].Pos, changes[^1].Pos, checkOnly: false));
    }

    public void ToggleBlock(string block) =>
        UpdateBlocks(b => b with { Block = b.Block == block ? null : block, Checked = false });

    /// <summary>
    /// Call when Space is pressed. If the caret follows a list shortcut typed at the start of a plain paragraph
    /// ("-" or "*" bullet, "1." numbered, "[]" to-do) the shortcut is removed and the paragraph becomes that
    /// list. Returns true when it did, in which case the space must not be typed.
    /// </summary>
    public bool TryAutoList()
    {
        if (!BeginCommand())
        {
            return false;
        }

        var (s, e) = Selection;
        if (s != e || s <= 0 || s > _shadow.Length - 1)
        {
            return false;
        }

        var ps = _shadow.ParagraphStart(s);
        var length = s - ps;
        if (length is < 1 or > 2 || _shadow.BlockAt(ps).Effective().Block is not null)
        {
            return false;
        }

        var typed = string.Concat(Enumerable.Range(ps, length).Select(i => _shadow.Cells[i].Ch));
        var block = typed switch
        {
            "-" or "*" => "ul",
            "1." => "ol",
            "[]" => "todo",
            _ => null,
        };
        if (block is null)
        {
            return false;
        }

        // Removed through the control, exactly as Backspace would, so it is one ordinary local edit.
        _doc.GetRange(ps, s).SetText(TextSetOptions.None, "");
        SyncLocal();
        UpdateBlocks(ps, ps, b => b with { Block = block, Checked = false });
        _doc.Selection.SetRange(ps, ps);
        return true;
    }

    /// <summary>
    /// Inserts pasted paragraphs at the selection with their formatting. The text goes in through the control
    /// like a plain paste, then blocks and inline formats are set model-first. The first paragraph joins the
    /// line the caret is on, and the last one joins whatever followed the caret.
    /// </summary>
    public bool InsertRich(IReadOnlyList<PastedParagraph> paragraphs)
    {
        if (paragraphs.Count == 0 || !BeginCommand())
        {
            return false;
        }

        var start = Math.Clamp(_doc.Selection.StartPosition, 0, _shadow.Length - 1);
        var end = Math.Clamp(_doc.Selection.EndPosition, start, _shadow.Length - 1);
        var atParagraphStart = start == _shadow.ParagraphStart(start);
        var nothingFollows = _shadow.Cells[end].Ch == '\n';
        var joined = string.Join("\n", paragraphs.Select(p => p.Text));

        _doc.Selection.SetRange(start, end);
        _doc.Selection.TypeText(joined.Replace('\n', '\r'));
        SyncLocal();
        var caret = start + joined.Length;
        if (caret > _shadow.Length - 1 || string.Concat(Enumerable.Range(start, joined.Length).Select(i => _shadow.Cells[i].Ch)) != joined)
        {
            return true; // the control changed what was typed; it stays as plain text rather than risk misplaced formats
        }

        var pos = start;
        for (var i = 0; i < paragraphs.Count; i++)
        {
            var paragraph = paragraphs[i];
            var first = i == 0;
            var last = i == paragraphs.Count - 1;
            var plain = paragraph.Block == default;
            var setBlock = paragraphs.Count == 1
                ? atParagraphStart && !plain
                : (!first || atParagraphStart) && (!last || nothingFollows || !plain);
            if (setBlock)
            {
                var block = paragraph.Block;
                UpdateBlocks(pos, pos, _ => block);
            }

            foreach (var run in paragraph.Runs)
            {
                var runEnd = pos + run.Text.Length;
                foreach (var key in InlineAttrs.Keys)
                {
                    var want = run.Inline.Get(key);
                    var same = true;
                    for (var c = pos; c < runEnd && same; c++)
                    {
                        same = Equals(_shadow.Cells[c].Inline.Get(key), want);
                    }

                    if (!same)
                    {
                        SetInline(pos, runEnd, key, want);
                    }
                }

                pos = runEnd;
            }

            pos++; // the paragraph mark
        }

        _doc.Selection.SetRange(caret, caret);
        return true;
    }

    public void Indent(int delta) => UpdateBlocks(b => b with { Indent = Math.Clamp(b.Indent + delta, 0, 8) });

    /// <summary>Toggles a to-do when <paramref name="p"/> (document coordinates) is on its checkbox marker.</summary>
    public bool TryToggleTodoAt(Point p)
    {
        if (IsBusy)
        {
            return false;
        }

        SyncLocal();
        if (_shadow.Length == 0 || !_shadowText.EndsWith('\n'))
        {
            return false;
        }

        var pos = Math.Clamp(_doc.GetRangeFromPoint(p, PointOptions.ClientCoordinates).StartPosition, 0, _shadow.Length - 1);
        var ps = _shadow.ParagraphStart(pos);
        if (_shadow.BlockAt(ps).Effective().Block != "todo")
        {
            return false;
        }

        _doc.GetRange(ps, ps).GetRect(PointOptions.ClientCoordinates, out var rect, out _);
        if (p.X >= rect.X || p.Y < rect.Y || p.Y > rect.Y + rect.Height)
        {
            return false;
        }

        UpdateBlocks(ps, ps, b => b with { Checked = !b.Checked });
        return true;
    }

    /// <summary>Document-space point in the middle of the checkbox marker of the paragraph at <paramref name="pos"/> (for tests).</summary>
    public Point MarkerPoint(int pos)
    {
        var ps = _shadow.ParagraphStart(pos);
        _doc.GetRange(ps, ps).GetRect(PointOptions.ClientCoordinates, out var rect, out _);
        return new Point(rect.X - 8, rect.Y + rect.Height / 2);
    }

    // =====================================================================================================
    // Scroll anchoring
    // =====================================================================================================

    private ScrollViewer? Scroll => _scroll ??= FindDescendant<ScrollViewer>(_box);

    internal static T? FindDescendant<T>(DependencyObject root)
        where T : DependencyObject
    {
        var count = VisualTreeHelper.GetChildrenCount(root);
        for (var i = 0; i < count; i++)
        {
            var child = VisualTreeHelper.GetChild(root, i);
            if (child is T match)
            {
                return match;
            }

            if (FindDescendant<T>(child) is { } nested)
            {
                return nested;
            }
        }

        return null;
    }

    private readonly record struct ScrollAnchor(int Position, double OffsetInView);

    private ScrollAnchor? CaptureScrollAnchor()
    {
        var sv = Scroll;
        if (sv == null || sv.VerticalOffset <= 0.5)
        {
            return null; // at the top: stay at the top
        }

        var top = _doc.GetRangeFromPoint(new Point(2, sv.VerticalOffset + 2), PointOptions.ClientCoordinates);
        top.GetRect(PointOptions.ClientCoordinates, out var rect, out _);
        return new ScrollAnchor(top.StartPosition, rect.Y - sv.VerticalOffset);
    }

    private void RestoreScrollAnchor(ScrollAnchor anchor)
    {
        var sv = Scroll;
        if (sv == null)
        {
            return;
        }

        var pos = Math.Clamp(anchor.Position, 0, _shadow.Length - 1);
        _doc.GetRange(pos, pos).GetRect(PointOptions.ClientCoordinates, out var rect, out _);
        var target = Math.Max(0, rect.Y - anchor.OffsetInView);
        if (Math.Abs(target - sv.VerticalOffset) < 0.5)
        {
            return;
        }

        _box.UpdateLayout(); // the extent must know about the new text before we can scroll into it
        sv.ChangeView(null, target, null, true);
        ScrollRestores++;
    }

    /// <summary>The element document coordinates are relative to (for tests that click).</summary>
    public UIElement? ContentElement => Scroll?.Content as UIElement;

    public double VerticalOffset => Scroll?.VerticalOffset ?? 0;

    public void ScrollTo(double offset)
    {
        _box.UpdateLayout();
        Scroll?.ChangeView(null, offset, null, true);
    }

    /// <summary>Y of a character relative to the top of the viewport (for tests).</summary>
    public double ViewY(int pos)
    {
        _doc.GetRange(pos, pos).GetRect(PointOptions.ClientCoordinates, out var rect, out _);
        return rect.Y - VerticalOffset;
    }

    // =====================================================================================================
    // Raw control access
    // =====================================================================================================

    private static string ToControl(string s) => s.Replace('\n', '\r').Replace('\u2028', '\v');

    private string ReadControlText()
    {
        _doc.GetText(TextGetOptions.None, out var s);
        return s.Replace('\r', '\n').Replace('\v', '\u2028');
    }

    private static int ParagraphStart(string text, int pos) => pos <= 0 ? 0 : text.LastIndexOf('\n', pos - 1) + 1;

    private static int ParagraphEnd(string text, int pos)
    {
        var i = text.IndexOf('\n', Math.Clamp(pos, 0, text.Length - 1));
        return i < 0 ? text.Length - 1 : i;
    }

    private readonly record struct Run(int Start, int End, CharSpec Spec);

    private List<Run> ReadRuns(int from, int toExclusive)
    {
        var runs = new List<Run>();
        var r = _doc.GetRange(from, from);
        var pos = from;
        while (pos < toExclusive)
        {
            r.SetRange(pos, pos);
            r.Expand(TextRangeUnit.CharacterFormat);
            var end = Math.Min(r.EndPosition, toExclusive);
            if (end <= pos)
            {
                end = pos + 1;
            }

            var cf = r.CharacterFormat;
            var u = cf.Underline;
            runs.Add(new Run(pos, end, new CharSpec(
                cf.Bold == FormatEffect.On, cf.Italic == FormatEffect.On, u != UnderlineType.None && u != UnderlineType.Undefined,
                cf.Strikethrough == FormatEffect.On, cf.BackgroundColor, cf.ForegroundColor, cf.Size, cf.Name)));
            pos = end;
        }

        return runs;
    }

    private void WriteChars(int from, int toExclusive, CharSpec want, CharSpec have)
    {
        var cf = _doc.GetRange(from, toExclusive).CharacterFormat;
        if (want.Bold != have.Bold) cf.Bold = want.Bold ? FormatEffect.On : FormatEffect.Off;
        if (want.Italic != have.Italic) cf.Italic = want.Italic ? FormatEffect.On : FormatEffect.Off;
        if (want.Underline != have.Underline) cf.Underline = want.Underline ? UnderlineType.Single : UnderlineType.None;
        if (want.Strike != have.Strike) cf.Strikethrough = want.Strike ? FormatEffect.On : FormatEffect.Off;
        if (want.Bg != have.Bg) cf.BackgroundColor = want.Bg;
        if (want.Fg != have.Fg) cf.ForegroundColor = want.Fg;
        if (want.Size != have.Size) cf.Size = want.Size;
        if (want.Font != have.Font) cf.Name = want.Font;
    }

    private ParaSpec ReadPara(int paragraphStart)
    {
        var pf = _doc.GetRange(paragraphStart, paragraphStart).ParagraphFormat;
        return new ParaSpec(pf.Style, pf.ListType, pf.ListStyle, pf.ListStart, pf.ListTab, pf.ListAlignment,
            pf.LeftIndent, pf.FirstLineIndent, pf.RightIndent, pf.SpaceBefore, pf.SpaceAfter, pf.Alignment);
    }

    private void WritePara(int paragraphStart, ParaSpec want)
    {
        var pf = _doc.GetRange(paragraphStart, paragraphStart).ParagraphFormat;
        pf.Style = want.Style; // first: setting the style resets list properties and spacing
        pf.Alignment = want.Alignment;
        pf.SpaceBefore = want.SpaceBefore;
        pf.SpaceAfter = want.SpaceAfter;
        pf.ListType = want.ListType;
        if (want.ListType != MarkerType.None)
        {
            pf.ListStyle = want.ListStyle;
            pf.ListStart = want.ListStart;
            pf.ListTab = want.ListTab;
            pf.ListAlignment = want.Align;
        }

        pf.SetIndents(want.First, want.Left, want.Right);
    }

    // =====================================================================================================
    // Verification (self-test)
    // =====================================================================================================

    /// <summary>Reads the whole control back as cells, exactly the way SyncLocal interprets it (link = "*").</summary>
    public List<Cell> ReadControlCells()
    {
        var text = ReadControlText();
        var cells = new Cell[text.Length];
        foreach (var run in ReadRuns(0, text.Length))
        {
            var inline = Style.InlineFrom(run.Spec, out var styled);
            for (var i = run.Start; i < run.End; i++)
            {
                cells[i] = new Cell(text[i], inline with { Link = styled ? "*" : null }, default);
            }
        }

        var ps = 0;
        while (ps < text.Length)
        {
            var pe = ParagraphEnd(text, ps);
            cells[pe].Block = EditorStyle.BlockFrom(ReadPara(ps));
            ps = pe + 1;
        }

        return cells.ToList();
    }

    /// <summary>Checks control == shadow == CRDT (text and formatting) and that nothing is left to render.
    /// Returns null when everything agrees, otherwise a description of the first disagreement.</summary>
    public string? Verify()
    {
        SyncLocal();
        RunQueuedRender();
        if (!_shadowText.EndsWith('\n'))
        {
            return $"[{Name}] text does not end with a newline";
        }

        var control = RichModel.Dump(ReadControlCells(), linkAsFlag: true);
        var shadow = RichModel.Dump(_shadow.Cells, linkAsFlag: true);
        if (control != shadow)
        {
            return $"[{Name}] control != shadow\n  control: {FirstDiff(control, shadow)}";
        }

        var crdt = RichModel.Dump(ReadCells(_page), effectiveBlocks: false);
        var shadowRaw = RichModel.Dump(_shadow.Cells, effectiveBlocks: false);
        if (crdt != shadowRaw)
        {
            return $"[{Name}] shadow != CRDT\n  shadow: {FirstDiff(shadowRaw, crdt)}";
        }

        var pending = _shadow.Length == 0 ? 0 : RenderParagraphs(0, _shadow.Length - 1, checkOnly: true);
        return pending != 0 ? $"[{Name}] control is not in canonical rendering ({pending} differences)" : null;
    }

    public static string FirstDiff(string a, string b)
    {
        var i = 0;
        while (i < a.Length && i < b.Length && a[i] == b[i])
        {
            i++;
        }

        string Cut(string s) => s.Substring(Math.Max(0, i - 40), Math.Min(s.Length - Math.Max(0, i - 40), 120)).Replace("\n", "⏎");
        return $"at {i}: «{Cut(a)}»\n  other: «{Cut(b)}»";
    }
}
