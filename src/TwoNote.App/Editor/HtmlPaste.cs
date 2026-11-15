using System.Globalization;
using System.Net;
using System.Text;

namespace TwoNote.App.Editor;

/// <summary>A run of pasted text with one set of inline formatting.</summary>
public sealed record PastedRun(string Text, InlineAttrs Inline);

/// <summary>One pasted paragraph: its block formatting and its runs. Never empty.</summary>
public sealed record PastedParagraph(BlockAttrs Block, IReadOnlyList<PastedRun> Runs)
{
    public string Text => string.Concat(Runs.Select(r => r.Text));
}

/// <summary>
/// Turns clipboard HTML (what Slack, browsers and OneNote copy) into paragraphs a page can hold: bold, italic,
/// underline, strikethrough, inline code, links, headings, bullet / numbered / to-do lists with nesting, and
/// code blocks. Everything else (pictures, tables, colours, fonts, sizes) is reduced to its text. This is a
/// small tolerant reader for clipboard fragments, not a general HTML parser.
/// </summary>
public static class HtmlPaste
{
    private static readonly HashSet<string> BlockTags =
    [
        "p", "div", "li", "ul", "ol", "h1", "h2", "h3", "h4", "h5", "h6", "pre", "blockquote", "table", "tr", "br", "hr",
        "section", "article", "header", "footer", "dl", "dt", "dd", "body", "html",
    ];

    private static readonly HashSet<string> VoidTags = ["br", "hr", "img", "input", "meta", "link", "wbr", "col", "area", "base"];

    private static readonly HashSet<string> SkippedTags = ["script", "style", "head", "title", "noscript", "template"];

    /// <summary>
    /// The copied fragment of a CF_HTML clipboard string (the part between the StartFragment and EndFragment
    /// comments). Returns the input when it has no such markers.
    /// </summary>
    public static string ExtractFragment(string? clipboardHtml)
    {
        if (string.IsNullOrEmpty(clipboardHtml))
        {
            return "";
        }

        const string startMark = "<!--StartFragment-->";
        const string endMark = "<!--EndFragment-->";
        var start = clipboardHtml.IndexOf(startMark, StringComparison.OrdinalIgnoreCase);
        if (start < 0)
        {
            var tag = clipboardHtml.IndexOf('<');
            return tag < 0 ? "" : clipboardHtml[tag..]; // drops a CF_HTML header that has no fragment comments
        }

        start += startMark.Length;
        var end = clipboardHtml.IndexOf(endMark, start, StringComparison.OrdinalIgnoreCase);
        return end < 0 ? clipboardHtml[start..] : clipboardHtml[start..end];
    }

    /// <summary>True for HTML written by Word, whose lists are plain paragraphs; its RTF pastes better.</summary>
    public static bool IsWordHtml(string? html) =>
        html is not null
        && (html.Contains("urn:schemas-microsoft-com:office:word", StringComparison.OrdinalIgnoreCase)
            || html.Contains("content=Word.Document", StringComparison.OrdinalIgnoreCase)
            || html.Contains("content=\"Word.Document\"", StringComparison.OrdinalIgnoreCase));

    /// <summary>Reads an HTML fragment. Returns no paragraphs when it holds no text.</summary>
    public static IReadOnlyList<PastedParagraph> Parse(string? html)
    {
        var reader = new Reader();
        if (!string.IsNullOrEmpty(html))
        {
            reader.Read(html);
        }

        return reader.Finish();
    }

    private sealed class Reader
    {
        private readonly List<PastedParagraph> _result = [];
        private readonly List<(StringBuilder Text, InlineAttrs Inline)> _runs = [];
        private readonly List<(string Tag, InlineAttrs Before)> _open = [];
        private readonly List<(bool Ordered, int? Indent)> _lists = [];
        private readonly List<bool?> _items = []; // one per open <li>: null = plain item, else the to-do state
        private InlineAttrs _inline;
        private BlockAttrs _block;
        private string? _heading;
        private int _pre;


        public IReadOnlyList<PastedParagraph> Finish()
        {
            Flush();
            return _result;
        }

        public void Read(string html)
        {
            var i = 0;
            while (i < html.Length)
            {
                var lt = html.IndexOf('<', i);
                if (lt < 0)
                {
                    Text(html[i..]);
                    break;
                }

                if (lt > i)
                {
                    Text(html[i..lt]);
                }

                if (string.CompareOrdinal(html, lt, "<!--", 0, 4) == 0)
                {
                    var close = html.IndexOf("-->", lt + 4, StringComparison.Ordinal);
                    i = close < 0 ? html.Length : close + 3;
                    continue;
                }

                var gt = FindTagEnd(html, lt + 1);
                if (gt < 0)
                {
                    if (lt + 1 < html.Length && !char.IsAsciiLetter(html[lt + 1]) && html[lt + 1] != '/')
                    {
                        Text(html[lt..]); // a stray '<' in text
                    }

                    break; // otherwise a tag cut off at the end of the fragment: dropped
                }

                var body = html[(lt + 1)..gt];
                i = gt + 1;
                if (body.Length == 0 || body[0] is '!' or '?')
                {
                    continue;
                }

                var closing = body[0] == '/';
                var nameEnd = closing ? 1 : 0;
                while (nameEnd < body.Length && (char.IsAsciiLetterOrDigit(body[nameEnd]) || body[nameEnd] is ':' or '-'))
                {
                    nameEnd++;
                }

                var name = body[(closing ? 1 : 0)..nameEnd].ToLowerInvariant();
                if (name.Length == 0)
                {
                    if (!closing)
                    {
                        Text("<" + body + ">"); // "a < b > c" and the like
                    }

                    continue;
                }

                if (closing)
                {
                    Close(name);
                    continue;
                }

                if (SkippedTags.Contains(name))
                {
                    var end = html.IndexOf("</" + name, i, StringComparison.OrdinalIgnoreCase);
                    var endGt = end < 0 ? -1 : html.IndexOf('>', end);
                    i = endGt < 0 ? html.Length : endGt + 1;
                    continue;
                }

                var selfClosing = body.EndsWith('/');
                Open(name, Attributes(body[nameEnd..]), selfClosing || VoidTags.Contains(name));
            }
        }

        private static int FindTagEnd(string html, int from)
        {
            var quote = '\0';
            for (var i = from; i < html.Length; i++)
            {
                var c = html[i];
                if (quote != '\0')
                {
                    if (c == quote)
                    {
                        quote = '\0';
                    }
                }
                else if (c is '"' or '\'')
                {
                    quote = c;
                }
                else if (c == '>')
                {
                    return i;
                }
            }

            return -1;
        }

        private static Dictionary<string, string> Attributes(string text)
        {
            var result = new Dictionary<string, string>(StringComparer.OrdinalIgnoreCase);
            var i = 0;
            while (i < text.Length)
            {
                while (i < text.Length && (char.IsWhiteSpace(text[i]) || text[i] == '/'))
                {
                    i++;
                }

                var start = i;
                while (i < text.Length && !char.IsWhiteSpace(text[i]) && text[i] is not ('=' or '/'))
                {
                    i++;
                }

                if (i == start)
                {
                    break;
                }

                var key = text[start..i];
                while (i < text.Length && char.IsWhiteSpace(text[i]))
                {
                    i++;
                }

                var value = "";
                if (i < text.Length && text[i] == '=')
                {
                    i++;
                    while (i < text.Length && char.IsWhiteSpace(text[i]))
                    {
                        i++;
                    }

                    if (i < text.Length && text[i] is '"' or '\'')
                    {
                        var quote = text[i++];
                        var end = text.IndexOf(quote, i);
                        end = end < 0 ? text.Length : end;
                        value = text[i..end];
                        i = Math.Min(text.Length, end + 1);
                    }
                    else
                    {
                        var vs = i;
                        while (i < text.Length && !char.IsWhiteSpace(text[i]))
                        {
                            i++;
                        }

                        value = text[vs..i];
                    }
                }

                result.TryAdd(key, WebUtility.HtmlDecode(value));
            }

            return result;
        }

        private void Open(string name, Dictionary<string, string> attrs, bool isVoid)
        {
            if (BlockTags.Contains(name))
            {
                Flush();
            }

            switch (name)
            {
                case "ul" or "ol":
                    int? indent = attrs.TryGetValue("data-indent", out var di)
                        && int.TryParse(di, NumberStyles.None, CultureInfo.InvariantCulture, out var n) ? n : null;
                    _lists.Add((name == "ol", indent));
                    break;
                case "li":
                    _items.Add(attrs.TryGetValue("data-checked", out var dc) ? dc.Equals("true", StringComparison.OrdinalIgnoreCase) : null);
                    break;
                case "h1" or "h2" or "h3":
                    _heading = name;
                    break;
                case "h4" or "h5" or "h6":
                    _heading = "h3";
                    break;
                case "pre":
                    _pre++;
                    break;
                case "td" or "th":
                    Space();
                    break;
                case "input":
                    if (_items.Count > 0 && attrs.TryGetValue("type", out var type) && type.Equals("checkbox", StringComparison.OrdinalIgnoreCase))
                    {
                        _items[^1] = attrs.ContainsKey("checked");
                    }

                    break;
                case "img":
                    // Slack and others copy an emoji as a picture whose alt text is the emoji; other pictures are dropped.
                    if (attrs.TryGetValue("alt", out var alt) && alt.Length is > 0 and <= 16
                        && (attrs.ContainsKey("data-stringify-emoji") || (attrs.TryGetValue("class", out var cls) && cls.Contains("emoji", StringComparison.OrdinalIgnoreCase))))
                    {
                        Text(WebUtility.HtmlEncode(alt));
                    }

                    break;
            }

            if (isVoid)
            {
                return;
            }

            _open.Add((name, _inline));
            _inline = name switch
            {
                "b" or "strong" => _inline with { Bold = true },
                "i" or "em" => _inline with { Italic = true },
                "u" or "ins" => _inline with { Underline = true },
                "s" or "strike" or "del" => _inline with { Strike = true },
                "code" or "kbd" or "samp" or "tt" when _pre == 0 => _inline with { Code = true },
                "a" when attrs.TryGetValue("href", out var href) && SafeLink(href) is { } url => _inline with { Link = url },
                _ => _inline,
            };
            if (attrs.TryGetValue("style", out var style))
            {
                ApplyStyle(style);
            }
        }

        private void Close(string name)
        {
            if (BlockTags.Contains(name))
            {
                Flush();
            }

            switch (name)
            {
                case "ul" or "ol" when _lists.Count > 0:
                    _lists.RemoveAt(_lists.Count - 1);
                    break;
                case "li" when _items.Count > 0:
                    _items.RemoveAt(_items.Count - 1);
                    break;
                case "h1" or "h2" or "h3" or "h4" or "h5" or "h6":
                    _heading = null;
                    break;
                case "pre" when _pre > 0:
                    _pre--;
                    break;
            }

            for (var i = _open.Count - 1; i >= 0; i--)
            {
                if (_open[i].Tag == name)
                {
                    _inline = _open[i].Before;
                    _open.RemoveRange(i, _open.Count - i);
                    break;
                }
            }
        }

        /// <summary>Only web and mail addresses become links; scripts, files and the rest stay plain text.</summary>
        private static string? SafeLink(string href)
        {
            href = href.Trim();
            return href.Length is > 0 and <= 2000
                && (href.StartsWith("https://", StringComparison.OrdinalIgnoreCase)
                    || href.StartsWith("http://", StringComparison.OrdinalIgnoreCase)
                    || href.StartsWith("mailto:", StringComparison.OrdinalIgnoreCase))
                ? href
                : null;
        }

        /// <summary>OneNote, Google Docs and others express formatting as CSS on spans rather than as tags.</summary>
        private void ApplyStyle(string style)
        {
            foreach (var declaration in style.Split(';', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries))
            {
                var colon = declaration.IndexOf(':');
                if (colon <= 0)
                {
                    continue;
                }

                var property = declaration[..colon].Trim().ToLowerInvariant();
                var value = declaration[(colon + 1)..].Trim().ToLowerInvariant();
                switch (property)
                {
                    case "font-weight":
                        if (value is "bold" or "bolder" || (int.TryParse(value, NumberStyles.None, CultureInfo.InvariantCulture, out var weight) && weight >= 600))
                        {
                            _inline = _inline with { Bold = true };
                        }
                        else if (value is "normal" or "lighter" || int.TryParse(value, NumberStyles.None, CultureInfo.InvariantCulture, out _))
                        {
                            _inline = _inline with { Bold = false }; // Google Docs wraps everything in <b style="font-weight:normal">
                        }

                        break;
                    case "font-style":
                        _inline = _inline with { Italic = value is "italic" or "oblique" };
                        break;
                    case "text-decoration" or "text-decoration-line":
                        if (value.Contains("underline", StringComparison.Ordinal))
                        {
                            _inline = _inline with { Underline = true };
                        }

                        if (value.Contains("line-through", StringComparison.Ordinal))
                        {
                            _inline = _inline with { Strike = true };
                        }

                        break;
                }
            }
        }

        private BlockAttrs CurrentBlock()
        {
            if (_pre > 0)
            {
                return new BlockAttrs("code", 0, false);
            }

            if (_heading is not null)
            {
                return new BlockAttrs(_heading, 0, false);
            }

            if (_items.Count == 0)
            {
                return default;
            }

            var (ordered, dataIndent) = _lists.Count > 0 ? _lists[^1] : (false, null);
            var indent = Math.Clamp(dataIndent ?? Math.Max(0, _lists.Count - 1), 0, 8);
            return _items[^1] is { } done ? new BlockAttrs("todo", indent, done) : new BlockAttrs(ordered ? "ol" : "ul", indent, false);
        }

        private void Text(string raw)
        {
            var text = WebUtility.HtmlDecode(raw);
            if (_pre > 0)
            {
                var lines = text.Replace("\r\n", "\n", StringComparison.Ordinal).Replace('\r', '\n').Split('\n');
                for (var i = 0; i < lines.Length; i++)
                {
                    if (i > 0)
                    {
                        Flush();
                    }

                    foreach (var c in lines[i])
                    {
                        Append(c == (char)0xA0 ? ' ' : c);
                    }
                }

                return;
            }

            foreach (var c in text)
            {
                if (char.IsWhiteSpace(c) || c == (char)0xA0)
                {
                    Space();
                    continue;
                }

                Append(c);
            }
        }

        /// <summary>Collapsed white space: one space, formatted like the text it follows, never at the start of a paragraph.</summary>
        private void Space()
        {
            if (_runs.Count > 0 && _runs[^1].Text[^1] != ' ')
            {
                Append(' ');
            }
        }

        private void Append(char c)
        {
            if (_runs.Count == 0)
            {
                _block = CurrentBlock();
            }

            if (_runs.Count == 0 || _runs[^1].Inline != _inline)
            {
                _runs.Add((new StringBuilder(), _inline));
            }

            _runs[^1].Text.Append(c);
        }

        private void Flush()
        {
            if (_runs.Count == 0)
            {
                return;
            }

            if (_pre == 0 && _block.Block != "code")
            {
                var tail = _runs[^1].Text;
                while (tail.Length > 0 && tail[^1] == ' ')
                {
                    tail.Length--;
                }
            }

            var runs = new List<PastedRun>();
            foreach (var (text, inline) in _runs)
            {
                var clean = PasteFilter.SanitizePlainText(text.ToString()).Replace('\n', ' ').Replace((char)0x2028, ' ');
                if (clean.Length > 0)
                {
                    runs.Add(new PastedRun(clean, inline));
                }
            }

            _runs.Clear();
            if (runs.Count > 0)
            {
                _result.Add(new PastedParagraph(_block, runs));
            }
        }
    }
}
