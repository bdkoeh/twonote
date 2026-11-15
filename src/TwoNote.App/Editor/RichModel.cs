using System.Text;

namespace TwoNote.App.Editor;

/// <summary>Inline attributes of PROTOCOL 5.2 for one UTF-16 code unit.</summary>
public readonly record struct InlineAttrs(bool Bold, bool Italic, bool Underline, bool Strike, bool Code, string? Link)
{
    public static readonly string[] Keys = ["bold", "italic", "underline", "strike", "code", "link"];

    public object? Get(string key) => key switch
    {
        "bold" => Bold ? true : null,
        "italic" => Italic ? true : null,
        "underline" => Underline ? true : null,
        "strike" => Strike ? true : null,
        "code" => Code ? true : null,
        "link" => Link,
        _ => null,
    };

    public InlineAttrs With(string key, object? value) => key switch
    {
        "bold" => this with { Bold = value is true },
        "italic" => this with { Italic = value is true },
        "underline" => this with { Underline = value is true },
        "strike" => this with { Strike = value is true },
        "code" => this with { Code = value is true },
        "link" => this with { Link = value as string },
        _ => this,
    };

    /// <summary>The attributes as the dictionary an insert carries (set values only).</summary>
    public Dictionary<string, object?> ToAttributes()
    {
        var d = new Dictionary<string, object?>();
        foreach (var key in Keys)
        {
            if (Get(key) is { } v)
            {
                d[key] = v;
            }
        }

        return d;
    }

    public override string ToString()
    {
        var parts = new List<string>();
        if (Bold) parts.Add("b");
        if (Italic) parts.Add("i");
        if (Underline) parts.Add("u");
        if (Strike) parts.Add("s");
        if (Code) parts.Add("code");
        if (Link != null) parts.Add("link=" + Link);
        return string.Join(",", parts);
    }
}

/// <summary>
/// Block attributes carried by the newline that ends a paragraph. Stored RAW (as found in the CRDT) so
/// values this client does not understand survive; <see cref="Effective"/> is what the control can show.
/// </summary>
public readonly record struct BlockAttrs(string? Block, int Indent, bool Checked)
{
    public static readonly string[] Keys = ["block", "indent", "checked"];
    private static readonly HashSet<string> Known = ["h1", "h2", "h3", "ul", "ol", "todo", "code"];

    public BlockAttrs Effective()
    {
        var block = Block != null && Known.Contains(Block) ? Block : null;
        return new BlockAttrs(block, Math.Clamp(Indent, 0, 8), block == "todo" && Checked);
    }

    public object? Get(string key) => key switch
    {
        "block" => Block,
        "indent" => Indent != 0 ? (double)Indent : null,
        "checked" => Checked ? true : null,
        _ => null,
    };

    public BlockAttrs With(string key, object? value) => key switch
    {
        "block" => this with { Block = value as string },
        "indent" => this with { Indent = value switch { long l => (int)l, double d when double.IsFinite(d) => (int)Math.Clamp(d, -1000, 1000), _ => 0 } },
        "checked" => this with { Checked = value is true },
        _ => this,
    };

    public override string ToString()
    {
        var parts = new List<string>();
        if (Block != null) parts.Add(Block);
        if (Indent != 0) parts.Add("indent=" + Indent);
        if (Checked) parts.Add("checked");
        return string.Join(",", parts);
    }
}

/// <summary>One UTF-16 code unit of the container text with its attributes. Block is only meaningful on '\n'.</summary>
public record struct Cell(char Ch, InlineAttrs Inline, BlockAttrs Block)
{
    public readonly object? Get(string key) => Array.IndexOf(BlockAttrs.Keys, key) >= 0 ? Block.Get(key) : Inline.Get(key);
}

/// <summary>A single contiguous replacement that turns one string into another.</summary>
public readonly record struct TextEdit(int Start, int DeleteCount, int InsertCount)
{
    public bool IsEmpty => DeleteCount == 0 && InsertCount == 0;

    /// <summary>
    /// Common-prefix/suffix diff. The suffix is matched first and always keeps at least the final character
    /// (both strings end with the paragraph mark), so the trailing newline of the CRDT text is never deleted.
    /// <paramref name="caretHint"/> (caret position in <paramref name="now"/>) resolves the ambiguity of
    /// edits inside runs of identical characters: the edit is placed so that it ends at the caret.
    /// </summary>
    public static TextEdit Diff(string old, string now, int caretHint = -1)
    {
        if (ReferenceEquals(old, now) || old == now)
        {
            return default;
        }

        var maxCommon = Math.Min(old.Length, now.Length);
        var suffixCap = maxCommon;
        if (caretHint >= 0 && caretHint <= now.Length)
        {
            suffixCap = Math.Min(suffixCap, now.Length - caretHint);
        }

        var minSuffix = old.Length > 0 && now.Length > 0 && old[^1] == now[^1] ? 1 : 0;
        suffixCap = Math.Max(suffixCap, minSuffix);
        var suffix = 0;
        while (suffix < suffixCap && old[old.Length - 1 - suffix] == now[now.Length - 1 - suffix])
        {
            suffix++;
        }

        var prefix = 0;
        var prefixCap = maxCommon - suffix;
        while (prefix < prefixCap && old[prefix] == now[prefix])
        {
            prefix++;
        }

        // The caret hint may have stopped the suffix early; if the prefix did not use the slack, extend the suffix.
        while (suffix < maxCommon - prefix && old[old.Length - 1 - suffix] == now[now.Length - 1 - suffix])
        {
            suffix++;
        }

        // Never cut a surrogate pair in half (e.g. replacing 😀 with 😁 shares the high surrogate): Yrs stores
        // UTF-8 and cannot hold a lone surrogate.
        if (prefix > 0 && char.IsHighSurrogate(old[prefix - 1]))
        {
            prefix--;
        }

        if (suffix > 0 && char.IsLowSurrogate(old[old.Length - suffix]))
        {
            suffix--;
        }

        return new TextEdit(prefix, old.Length - prefix - suffix, now.Length - prefix - suffix);
    }
}

/// <summary>The last known state of the editor in CRDT terms ("shadow"). Index == Yjs Text index == control index.</summary>
public sealed class RichModel
{
    public readonly List<Cell> Cells = [];

    public int Length => Cells.Count;

    public string Text
    {
        get
        {
            var sb = new StringBuilder(Cells.Count);
            foreach (var c in Cells)
            {
                sb.Append(c.Ch);
            }

            return sb.ToString();
        }
    }

    public int ParagraphStart(int pos)
    {
        pos = Math.Clamp(pos, 0, Cells.Count);
        while (pos > 0 && Cells[pos - 1].Ch != '\n')
        {
            pos--;
        }

        return pos;
    }

    /// <summary>Index of the newline that ends the paragraph containing <paramref name="pos"/> (or Length-1).</summary>
    public int ParagraphEnd(int pos)
    {
        pos = Math.Clamp(pos, 0, Math.Max(0, Cells.Count - 1));
        while (pos < Cells.Count - 1 && Cells[pos].Ch != '\n')
        {
            pos++;
        }

        return pos;
    }

    public BlockAttrs BlockAt(int pos) => Cells.Count == 0 ? default : Cells[ParagraphEnd(pos)].Block;

    /// <summary>Converts attributed runs (as a page document reports them) into cells.</summary>
    public static List<Cell> CellsFromRuns(IEnumerable<(string Text, IReadOnlyDictionary<string, object?> Attributes)> runs)
    {
        var cells = new List<Cell>();
        foreach (var (text, attributes) in runs)
        {
            var inline = default(InlineAttrs);
            var block = default(BlockAttrs);
            foreach (var (key, value) in attributes)
            {
                inline = inline.With(key, value);
                block = block.With(key, value);
            }

            foreach (var ch in text)
            {
                cells.Add(new Cell(ch, inline, ch == '\n' ? block : default));
            }
        }

        return cells;
    }

    /// <summary>Canonical dump used for convergence assertions. Runs are merged; defaults are omitted.</summary>
    public static string Dump(IReadOnlyList<Cell> cells, bool linkAsFlag = false, bool effectiveBlocks = true)
    {
        var sb = new StringBuilder();
        var i = 0;
        while (i < cells.Count)
        {
            var c = cells[i];
            if (c.Ch == '\n')
            {
                var b = effectiveBlocks ? c.Block.Effective() : c.Block;
                sb.Append("\\n[").Append(Inl(c.Inline, linkAsFlag)).Append('|').Append(b).Append("]\n");
                i++;
                continue;
            }

            var j = i;
            while (j < cells.Count && cells[j].Ch != '\n' && Inl(cells[j].Inline, linkAsFlag) == Inl(c.Inline, linkAsFlag))
            {
                j++;
            }

            for (var k = i; k < j; k++)
            {
                sb.Append(cells[k].Ch);
            }

            var a = Inl(c.Inline, linkAsFlag);
            if (a.Length > 0)
            {
                sb.Append('{').Append(a).Append('}');
            }

            sb.Append('|');
            i = j;
        }

        return sb.ToString();
    }

    private static string Inl(InlineAttrs a, bool linkAsFlag) =>
        (linkAsFlag && a.Link != null ? a with { Link = "*" } : a).ToString();
}
