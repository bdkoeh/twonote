using System.Text;
using System.Text.RegularExpressions;

namespace TwoNote.App.Editor;

/// <summary>
/// v1 pages hold text only. This decides what may be pasted: rich text only when it carries nothing but
/// characters and simple formatting, plain text otherwise, and nothing at all for pictures and files.
/// </summary>
public static partial class PasteFilter
{
    /// <summary>U+FFFC is how RichEdit holds an embedded object or picture; the others are its table structure.</summary>
    public static bool IsForbidden(char c) => c is '\uFFFC' or '\uFFF9' or '\uFFFA' or '\uFFFB' or '\a';

    /// <summary>True when the text holds an embedded object or table structure.</summary>
    public static bool ContainsForbidden(string text)
    {
        foreach (var c in text)
        {
            if (IsForbidden(c))
            {
                return true;
            }
        }

        return false;
    }

    /// <summary>
    /// True when the RTF holds only text and character/paragraph formatting: no pictures, embedded objects,
    /// drawing shapes, tables, fields (which is how RTF carries hyperlinks; RichEdit would add hidden text for
    /// them) or binary data. Anything else is pasted as plain text instead.
    /// </summary>
    public static bool RtfIsSafe(string? rtf) =>
        !string.IsNullOrEmpty(rtf) && rtf.StartsWith(@"{\rtf", StringComparison.Ordinal) && !UnsafeRtf().IsMatch(rtf);

    [GeneratedRegex(
        @"\\(pict|shppict|nonshppict|object|objdata|objemb|objlink|objautlink|objhtml|objocx|shp|shpinst|shpgrp|do|trowd|cell|row|intbl|nestcell|nestrow|nesttableprops|field|fldinst|fldrslt|bin|datafield|datastore|themedata|colorschememapping|background|listpicture|mmath)(?![a-z])",
        RegexOptions.CultureInvariant)]
    private static partial Regex UnsafeRtf();

    /// <summary>
    /// Plain text as it may enter a page: line ends become '\n', embedded-object and table characters and all
    /// control characters except tab and newline are dropped, unpaired surrogates are dropped.
    /// </summary>
    public static string SanitizePlainText(string? text)
    {
        if (string.IsNullOrEmpty(text))
        {
            return "";
        }

        var sb = new StringBuilder(text.Length);
        for (var i = 0; i < text.Length; i++)
        {
            var c = text[i];
            if (c == '\r')
            {
                if (i + 1 < text.Length && text[i + 1] == '\n')
                {
                    continue; // the '\n' that follows is kept
                }

                sb.Append('\n');
            }
            else if (c is '\n' or '\t' or '\u2028')
            {
                sb.Append(c);
            }
            else if (c == '\v' || c == '\u2029')
            {
                sb.Append(c == '\v' ? '\u2028' : '\n');
            }
            else if (char.IsControl(c) || IsForbidden(c))
            {
                // dropped
            }
            else if (char.IsHighSurrogate(c))
            {
                if (i + 1 < text.Length && char.IsLowSurrogate(text[i + 1]))
                {
                    sb.Append(c).Append(text[i + 1]);
                    i++;
                }
            }
            else if (!char.IsLowSurrogate(c))
            {
                sb.Append(c);
            }
        }

        return sb.ToString();
    }
}
