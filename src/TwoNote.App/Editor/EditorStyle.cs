using Microsoft.UI.Text;
using Windows.UI;

namespace TwoNote.App.Editor;

/// <summary>Everything the control stores for one character-format run that the binding cares about.</summary>
internal readonly record struct CharSpec(bool Bold, bool Italic, bool Underline, bool Strike, Color Bg, Color Fg, float Size, string Font);

/// <summary>Everything the control stores for one paragraph that the binding cares about.</summary>
internal readonly record struct ParaSpec(
    ParagraphStyle Style, MarkerType ListType, MarkerStyle ListStyle, int ListStart, float ListTab,
    MarkerAlignment Align, float Left, float First, float Right, float SpaceBefore, float SpaceAfter, ParagraphAlignment Alignment)
{
    private static bool Near(float a, float b) => Math.Abs(a - b) < 0.05f;

    /// <summary>True when <paramref name="observed"/> already renders this spec (ignores fields RichEdit does not use for the list type).</summary>
    public bool Matches(ParaSpec observed)
    {
        if (Style != observed.Style || ListType != observed.ListType) return false;
        if (observed.Alignment is ParagraphAlignment.Center or ParagraphAlignment.Right or ParagraphAlignment.Justify) return false;
        if (!Near(Left, observed.Left) || !Near(First, observed.First) || !Near(Right, observed.Right)) return false;
        if (!Near(SpaceBefore, observed.SpaceBefore) || !Near(SpaceAfter, observed.SpaceAfter)) return false;
        if (ListType == MarkerType.None) return true;
        if (!Near(ListTab, observed.ListTab)) return false;
        if (ListType == MarkerType.Bullet) return true;
        if (ListStyle != observed.ListStyle || ListStart != observed.ListStart) return false;
        return ListType != MarkerType.UnicodeSequence || Align == observed.Align;
    }
}

/// <summary>
/// The single place that decides how PROTOCOL 5.2 attributes look in a RichEditBox and how control state is
/// read back as attributes. Findings behind the choices, from probing the control:
///  - inline code  = marker background colour (font is cosmetic);     link = marker foreground colour
///    (the native ITextRange.Link inserts hidden 'HYPERLINK "url"' text and breaks index parity, so it is not used);
///  - h1..h3       = ParagraphStyle.Heading1..3 (a tag only) + font size on the paragraph's characters;
///  - ul / ol      = native MarkerType.Bullet / Arabic;
///  - todo         = MarkerType.UnicodeSequence with ListStart U+2610/U+2611; the marker glyph takes the font of the
///                   paragraph mark, so that one character is set to Segoe UI Symbol; neighbours in the same state
///                   alternate ListAlignment, otherwise RichEdit counts the sequence up (☐ ☑ ☒);
///  - code block   = ParagraphStyle.Heading9 (a tag only) + monospace font + a second, cosmetic background colour;
///  - indent       = LeftIndent in steps of <see cref="IndentStep"/> points.
/// The marker colours differ between the light and the dark theme; a style object is one theme's set.
/// </summary>
internal sealed class EditorStyle
{
    public const float IndentStep = 24f;
    public const float ListTab = 18f;
    public const int Unchecked = 0x2610;
    public const int CheckedBox = 0x2611;
    public const string MonoFont = "Consolas";
    public const string SymbolFont = "Segoe UI Symbol";

    public required bool Dark { get; init; }
    public required string BodyFont { get; init; }
    public required float BodySize { get; init; }
    public required Color TextFg { get; init; }
    public required Color NoBg { get; init; }
    public required Color CodeBg { get; init; }
    public required Color CodeBlockBg { get; init; }
    public required Color LinkFg { get; init; }

    /// <summary>The style for one theme. Font, size and "no background" come from the control's defaults.</summary>
    public static EditorStyle Create(bool dark, string bodyFont, float bodySize, Color noBackground) => new()
    {
        Dark = dark,
        BodyFont = bodyFont,
        BodySize = bodySize,
        NoBg = noBackground,
        TextFg = dark ? Color.FromArgb(255, 0xF3, 0xF3, 0xF3) : Color.FromArgb(255, 0x1B, 0x1B, 0x1B),
        LinkFg = dark ? Color.FromArgb(255, 0x60, 0xCD, 0xFF) : Color.FromArgb(255, 0x00, 0x5F, 0xB8),
        CodeBg = dark ? Color.FromArgb(255, 0x45, 0x45, 0x45) : Color.FromArgb(255, 0xE4, 0xE4, 0xE4),
        CodeBlockBg = dark ? Color.FromArgb(255, 0x33, 0x33, 0x33) : Color.FromArgb(255, 0xEE, 0xEE, 0xEE),
    };

    public CharSpec Char(InlineAttrs a, BlockAttrs effectiveBlock, bool isParagraphMark)
    {
        var block = effectiveBlock.Block;
        var font = a.Code || block == "code" ? MonoFont : BodyFont;
        if (isParagraphMark && block == "todo") font = SymbolFont;
        // Whole half points only: RichEdit stores sizes in twips and anything finer would never read back equal.
        var size = block switch { "h1" => HalfPoints(BodySize * 2f), "h2" => HalfPoints(BodySize * 1.5f), "h3" => HalfPoints(BodySize * 1.2f), _ => BodySize };
        var bg = a.Code ? CodeBg : block == "code" ? CodeBlockBg : NoBg;
        return new CharSpec(a.Bold, a.Italic, a.Underline, a.Strike, bg, a.Link != null ? LinkFg : TextFg, size, font);
    }

    private static float HalfPoints(float size) => MathF.Round(size * 2f) / 2f;

    public static ParaSpec Para(BlockAttrs effectiveBlock, MarkerAlignment todoAlign)
    {
        var b = effectiveBlock;
        var style = b.Block switch
        {
            "h1" => ParagraphStyle.Heading1,
            "h2" => ParagraphStyle.Heading2,
            "h3" => ParagraphStyle.Heading3,
            "code" => ParagraphStyle.Heading9,
            _ => ParagraphStyle.Normal,
        };
        var heading = b.Block is "h1" or "h2" or "h3";
        var (type, lstyle, start) = b.Block switch
        {
            "ul" => (MarkerType.Bullet, MarkerStyle.Plain, 0),
            "ol" => (MarkerType.Arabic, MarkerStyle.Period, 1),
            "todo" => (MarkerType.UnicodeSequence, MarkerStyle.Plain, b.Checked ? CheckedBox : Unchecked),
            _ => (MarkerType.None, MarkerStyle.Plain, 0),
        };

        // To-dos keep RichEdit's default marker tab (0): with an explicit tab the Center-aligned marker of every
        // second to-do is drawn partly outside the left edge.
        return new ParaSpec(style, type, lstyle, start, type is MarkerType.None or MarkerType.UnicodeSequence ? 0 : ListTab,
            type == MarkerType.UnicodeSequence ? todoAlign : MarkerAlignment.Left,
            b.Indent * IndentStep, 0, 0, heading ? 8 : 0, heading ? 3 : 0, ParagraphAlignment.Left);
    }

    /// <summary>Reads block attributes back from what the control holds for a paragraph.</summary>
    public static BlockAttrs BlockFrom(ParaSpec p)
    {
        var indent = Math.Clamp((int)Math.Round(p.Left / IndentStep), 0, 8);
        switch (p.ListType)
        {
            case MarkerType.Bullet: return new BlockAttrs("ul", indent, false);
            case MarkerType.UnicodeSequence: return new BlockAttrs("todo", indent, p.ListStart == CheckedBox);
            case MarkerType.None:
            case MarkerType.Undefined:
                var block = p.Style switch
                {
                    ParagraphStyle.Heading1 => "h1",
                    ParagraphStyle.Heading2 => "h2",
                    ParagraphStyle.Heading3 => "h3",
                    ParagraphStyle.Heading9 => "code",
                    _ => null,
                };
                return new BlockAttrs(block, indent, false);
            default: return new BlockAttrs("ol", indent, false); // any other native numbering
        }
    }

    /// <summary>Reads inline attributes back from a character run. linkStyled only says "looks like a link";
    /// the URL lives in the model.</summary>
    public InlineAttrs InlineFrom(CharSpec c, out bool linkStyled)
    {
        linkStyled = c.Fg == LinkFg;
        return new InlineAttrs(c.Bold, c.Italic, c.Underline, c.Strike, c.Bg == CodeBg, null);
    }
}
