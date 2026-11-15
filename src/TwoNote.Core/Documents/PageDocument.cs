using System.Text;
using YDotNet.Document.Cells;
using YDotNet.Document.Transactions;
using YDotNet.Document.Types.Events;
using YDotNet.Document.Types.Maps;
using YDotNet.Document.Types.Texts;
using YDotNet.Document.UndoManagers;

namespace TwoNote.Core.Documents;

/// <summary>The attribute names and block values of PROTOCOL.md 5.2.</summary>
public static class PageAttributes
{
    /// <summary>Inline: bold (<c>true</c> when set).</summary>
    public const string Bold = "bold";

    /// <summary>Inline: italic (<c>true</c> when set).</summary>
    public const string Italic = "italic";

    /// <summary>Inline: underline (<c>true</c> when set).</summary>
    public const string Underline = "underline";

    /// <summary>Inline: strike-through (<c>true</c> when set).</summary>
    public const string Strike = "strike";

    /// <summary>Inline: code (<c>true</c> when set).</summary>
    public const string Code = "code";

    /// <summary>Inline: link target (URL string).</summary>
    public const string Link = "link";

    /// <summary>On a newline: the block type of the paragraph it ends; absent means plain paragraph.</summary>
    public const string Block = "block";

    /// <summary>On a newline: indent level 0-8.</summary>
    public const string Indent = "indent";

    /// <summary>On a newline: whether a <c>todo</c> block is ticked.</summary>
    public const string Checked = "checked";

    /// <summary>The block values a v1 client understands.</summary>
    public static readonly IReadOnlyList<string> BlockTypes = ["h1", "h2", "h3", "ul", "ol", "todo", "code"];

    /// <summary>Highest indent level.</summary>
    public const int MaxIndent = 8;
}

/// <summary>The kind of one <see cref="DeltaOp"/>.</summary>
public enum DeltaKind
{
    /// <summary>Skip <see cref="DeltaOp.Length"/> code units, applying <see cref="DeltaOp.Attributes"/> to them if set.</summary>
    Retain,

    /// <summary>Insert <see cref="DeltaOp.Text"/> with <see cref="DeltaOp.Attributes"/>.</summary>
    Insert,

    /// <summary>Delete <see cref="DeltaOp.Length"/> code units.</summary>
    Delete,
}

/// <summary>
/// One Quill-style delta operation. Lengths are UTF-16 code units. In <see cref="Attributes"/>
/// a null value means "this attribute was removed".
/// </summary>
public sealed record DeltaOp(DeltaKind Kind, int Length, string? Text, IReadOnlyDictionary<string, object?>? Attributes);

/// <summary>A change to the page text: the delta that turns the previous text into the current one, and who caused it.</summary>
public sealed record TextChange(IReadOnlyList<DeltaOp> Delta, ChangeSource Source);

/// <summary>A run of text that shares one set of attributes. Attribute values are bool, string or double.</summary>
public sealed record TextRun(string Text, IReadOnlyDictionary<string, object?> Attributes);

/// <summary>
/// The page document of PROTOCOL.md 5.2. v1 pages have one container, <c>main</c>, whose text is
/// the root-level Yjs Text <c>c:main</c>: inline formatting is attributes on character runs,
/// block formatting is attributes on the newline that ends each paragraph. Indexes are UTF-16
/// code units, the same as .NET string indexes.
/// </summary>
public sealed class PageDocument : CrdtDocument
{
    /// <summary>The id of the single container of a v1 page.</summary>
    public const string MainContainer = "main";

    private const double FormatVersion = 1;
    private const char EmbedPlaceholder = '￼';

    private readonly Map _meta;
    private readonly Map _containers;
    private readonly Text _text;
    private readonly IDisposable _textSubscription;
    private readonly UndoManager _undo;
    private readonly List<List<DeltaOp>> _capturedDeltas = [];

    /// <summary>Creates an empty replica; fill it with <see cref="CrdtDocument.ApplyUpdate"/> or <see cref="Initialize"/>.</summary>
    /// <param name="pageId">The page id from the notebook tree.</param>
    /// <param name="undoCaptureMilliseconds">Edits closer together than this merge into one undo step.</param>
    public PageDocument(string pageId, int undoCaptureMilliseconds = 500)
        : base(pageId)
    {
        ArgumentOutOfRangeException.ThrowIfNegative(undoCaptureMilliseconds);
        _meta = Doc.Map("meta");
        _containers = Doc.Map("containers");
        _text = Doc.Text("c:" + MainContainer);
        _textSubscription = _text.Observe(e =>
        {
            // Runs inside Commit: copy everything out, the event object dies with the callback.
            var list = new List<DeltaOp>();
            foreach (var d in e.Delta)
            {
                switch (d.Tag)
                {
                    case EventDeltaTag.Retain:
                        list.Add(new DeltaOp(DeltaKind.Retain, (int)d.Length, null, ConvertAttributes(d.Attributes)));
                        break;
                    case EventDeltaTag.Remove:
                        list.Add(new DeltaOp(DeltaKind.Delete, (int)d.Length, null, null));
                        break;
                    case EventDeltaTag.Add:
                        var s = d.Insert is { Tag: OutputTag.String } o ? o.String : EmbedPlaceholder.ToString();
                        list.Add(new DeltaOp(DeltaKind.Insert, s.Length, s, ConvertAttributes(d.Attributes)));
                        break;
                }
            }

            _capturedDeltas.Add(list);
        });
        _undo = new UndoManager(Doc, _text, new UndoManagerOptions { CaptureTimeoutMilliseconds = (uint)undoCaptureMilliseconds });
        _undo.AddOrigin(LocalOrigin);
    }

    /// <summary>
    /// The text changed. Not raised while a document is being filled before anyone listens. For <see cref="ChangeSource.Remote"/> and <see cref="ChangeSource.Undo"/>
    /// an editor applies the delta to its control; for <see cref="ChangeSource.Local"/> the editor
    /// made the change itself and normally ignores the event.
    /// </summary>
    public event Action<TextChange>? TextChanged;

    /// <summary>Writes what a brand-new page starts with: the format version, the <c>main</c> container entry and the final newline. Only the device that creates the page calls this.</summary>
    public void Initialize()
    {
        Write((txn, scope) =>
        {
            _meta.Insert(txn, "formatVersion", ToInput(FormatVersion, scope));
            _containers.Insert(txn, MainContainer, scope.Map(new Dictionary<string, Input> { ["kind"] = ToInput("flow", scope) }));
            if (_text.Length(txn) == 0)
            {
                _text.Insert(txn, 0, "\n", scope.Object(new Dictionary<string, Input>()));
            }
        }, system: true);
    }

    // ---- reading --------------------------------------------------------------------------

    /// <summary>The whole text of the container, paragraphs ending in <c>\n</c>.</summary>
    public string GetText() => Read(txn => _text.String(txn));

    /// <summary>Length of the text in UTF-16 code units.</summary>
    public int Length => Read(txn => (int)_text.Length(txn));

    /// <summary>The text as runs of equal attributes, in order. Attributes this client does not know are included unchanged.</summary>
    public IReadOnlyList<TextRun> GetRuns() => Read(txn =>
    {
        var runs = new List<TextRun>();
        foreach (var chunk in _text.Chunks(txn))
        {
            var s = chunk.Data.Tag == OutputTag.String ? chunk.Data.String : EmbedPlaceholder.ToString();
            runs.Add(new TextRun(s, ConvertAttributes(chunk.Attributes, keepNulls: false) ?? EmptyAttributes));
        }

        return runs;
    });

    // ---- editing --------------------------------------------------------------------------

    /// <summary>
    /// Makes one user edit: everything <paramref name="edit"/> does is one transaction, one
    /// update for the other replicas and (within the capture window) one undo step. If the
    /// text does not end in a newline yet (a page whose content has not arrived), one is
    /// appended first.
    /// </summary>
    public void Edit(Action<PageEditor> edit)
    {
        ArgumentNullException.ThrowIfNull(edit);
        Write((txn, scope) =>
        {
            var mirror = new StringBuilder(_text.String(txn));
            if (mirror.Length == 0 || mirror[^1] != '\n')
            {
                _text.Insert(txn, (uint)mirror.Length, "\n", scope.Object(new Dictionary<string, Input>()));
                mirror.Append('\n');
            }

            edit(new PageEditor(_text, txn, scope, mirror));
        });
    }

    /// <summary>Access to the text during <see cref="Edit"/>. Indexes refer to the text as changed so far within the edit.</summary>
    public sealed class PageEditor
    {
        private readonly Text _text;
        private readonly Transaction _txn;
        private readonly InputScope _scope;
        private readonly StringBuilder _mirror;

        internal PageEditor(Text text, Transaction txn, InputScope scope, StringBuilder mirror)
        {
            _text = text;
            _txn = txn;
            _scope = scope;
            _mirror = mirror;
        }

        /// <summary>Current length in UTF-16 code units.</summary>
        public int Length => _mirror.Length;

        /// <summary>Current text.</summary>
        public string Text => _mirror.ToString();

        /// <summary>
        /// Inserts <paramref name="text"/> at <paramref name="index"/> with exactly the given
        /// attributes (nothing is inherited from the neighbours). The position must be before the
        /// final newline and must not split a surrogate pair.
        /// </summary>
        public void Insert(int index, string text, IReadOnlyDictionary<string, object?>? attributes = null)
        {
            ArgumentNullException.ThrowIfNull(text);
            if (text.Length == 0)
            {
                return;
            }

            if (index < 0 || index > _mirror.Length - 1)
            {
                throw new ArgumentOutOfRangeException(nameof(index), "Text is inserted before the final newline.");
            }

            CheckBoundary(index, nameof(index));
            for (var i = 0; i < text.Length; i++)
            {
                var paired = char.IsHighSurrogate(text[i])
                    ? i + 1 < text.Length && char.IsLowSurrogate(text[i + 1])
                    : !char.IsLowSurrogate(text[i]) || (i > 0 && char.IsHighSurrogate(text[i - 1]));
                if (!paired)
                {
                    throw new ArgumentException("The text contains an unpaired surrogate.", nameof(text));
                }
            }

            var fields = new Dictionary<string, Input>();
            if (attributes is not null)
            {
                foreach (var (key, value) in attributes)
                {
                    if (value is not null)
                    {
                        fields[key] = ToInput(value, _scope);
                    }
                }
            }

            _text.Insert(_txn, (uint)index, text, _scope.Object(fields));
            _mirror.Insert(index, text);
        }

        /// <summary>Deletes a range. The final newline cannot be deleted and a surrogate pair cannot be split.</summary>
        public void Delete(int index, int length)
        {
            if (length == 0)
            {
                return;
            }

            if (index < 0 || length < 0 || index + length > _mirror.Length - 1)
            {
                throw new ArgumentOutOfRangeException(nameof(length), "The range is outside the text, or includes the final newline.");
            }

            CheckBoundary(index, nameof(index));
            CheckBoundary(index + length, nameof(length));
            _text.RemoveRange(_txn, (uint)index, (uint)length);
            _mirror.Remove(index, length);
        }

        /// <summary>
        /// Sets (value) or removes (null) attributes on a range; attributes not mentioned are left
        /// alone, including ones this client does not know.
        /// </summary>
        public void Format(int index, int length, IReadOnlyDictionary<string, object?> attributes)
        {
            ArgumentNullException.ThrowIfNull(attributes);
            if (length == 0 || attributes.Count == 0)
            {
                return;
            }

            if (index < 0 || length < 0 || index + length > _mirror.Length)
            {
                throw new ArgumentOutOfRangeException(nameof(length), "The range is outside the text.");
            }

            CheckBoundary(index, nameof(index));
            CheckBoundary(index + length, nameof(length));
            var fields = new Dictionary<string, Input>();
            foreach (var (key, value) in attributes)
            {
                fields[key] = ToInput(value, _scope);
            }

            _text.Format(_txn, (uint)index, (uint)length, _scope.Object(fields));
        }

        /// <summary>
        /// Changes the block formatting of the paragraph ended by the newline at
        /// <paramref name="newlineIndex"/>. <c>block</c>, <c>indent</c> and <c>checked</c> are always
        /// written together; default values (paragraph, indent 0, unchecked) are written as removals.
        /// </summary>
        public void SetBlock(int newlineIndex, string? block, int indent = 0, bool isChecked = false)
        {
            if (newlineIndex < 0 || newlineIndex >= _mirror.Length || _mirror[newlineIndex] != '\n')
            {
                throw new ArgumentException("Block attributes belong on the newline that ends the paragraph.", nameof(newlineIndex));
            }

            ArgumentOutOfRangeException.ThrowIfNegative(indent);
            ArgumentOutOfRangeException.ThrowIfGreaterThan(indent, PageAttributes.MaxIndent);
            Format(newlineIndex, 1, new Dictionary<string, object?>
            {
                [PageAttributes.Block] = block,
                [PageAttributes.Indent] = indent == 0 ? null : (double)indent,
                [PageAttributes.Checked] = isChecked ? true : null,
            });
        }

        private void CheckBoundary(int index, string parameter)
        {
            if (index > 0 && index < _mirror.Length && char.IsHighSurrogate(_mirror[index - 1]) && char.IsLowSurrogate(_mirror[index]))
            {
                throw new ArgumentException("The position is inside a surrogate pair.", parameter);
            }
        }
    }

    // ---- undo -----------------------------------------------------------------------------

    /// <summary>True when there is a local edit to undo.</summary>
    public bool CanUndo
    {
        get
        {
            lock (SyncRoot)
            {
                ThrowIfDisposed();
                return _undo.CanUndo();
            }
        }
    }

    /// <summary>True when there is an undone edit to redo.</summary>
    public bool CanRedo
    {
        get
        {
            lock (SyncRoot)
            {
                ThrowIfDisposed();
                return _undo.CanRedo();
            }
        }
    }

    /// <summary>Undoes this replica's latest edit (never somebody else's). The change is reported like a remote one, with source <see cref="ChangeSource.Undo"/>.</summary>
    public bool Undo()
    {
        lock (SyncRoot)
        {
            ThrowIfDisposed();
            if (!_undo.CanUndo())
            {
                return false;
            }

            Run(ChangeSource.Undo, () => _undo.Undo());
            return true;
        }
    }

    /// <summary>Redoes the latest undone edit.</summary>
    public bool Redo()
    {
        lock (SyncRoot)
        {
            ThrowIfDisposed();
            if (!_undo.CanRedo())
            {
                return false;
            }

            Run(ChangeSource.Undo, () => _undo.Redo());
            return true;
        }
    }

    /// <summary>Closes the current undo step so the next edit starts a new one.</summary>
    public void BreakUndoGroup()
    {
        lock (SyncRoot)
        {
            ThrowIfDisposed();
            _undo.Stop();
        }
    }

    // ---- plumbing -------------------------------------------------------------------------

    private static readonly IReadOnlyDictionary<string, object?> EmptyAttributes = new Dictionary<string, object?>();

    private protected override void OnCommitted(ChangeSource source)
    {
        // Normally one delta per operation. Should an undo ever commit more than one transaction,
        // the deltas are reported in order, each relative to the text left by the one before.
        var deltas = _capturedDeltas.ToArray();
        _capturedDeltas.Clear();
        foreach (var delta in deltas)
        {
            if (delta.Count > 0)
            {
                TextChanged?.Invoke(new TextChange(delta, source));
            }
        }
    }

    private protected override void DisposeCore()
    {
        _textSubscription.Dispose();
        _undo.Dispose();
    }

    private static Dictionary<string, object?>? ConvertAttributes(IEnumerable<KeyValuePair<string, Output>>? attributes, bool keepNulls = true)
    {
        if (attributes is null)
        {
            return null;
        }

        var result = new Dictionary<string, object?>();
        foreach (var (key, value) in attributes)
        {
            var converted = FromOutput(value);
            if (converted is not null || (keepNulls && value.Tag is OutputTag.Null or OutputTag.Undefined))
            {
                result[key] = converted;
            }
        }

        return result.Count == 0 ? null : result;
    }
}
