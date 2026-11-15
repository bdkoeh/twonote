using System.Globalization;

namespace TwoNote.App.Logic;

/// <summary>One page as the search sees it.</summary>
public sealed record SearchEntry(string NotebookId, string NotebookTitle, string SectionId, string SectionTitle, string PageId, string Title, string Text);

/// <summary>One search result: where it is and a short piece of the text around the first match.</summary>
public sealed record SearchHit(SearchEntry Entry, bool TitleMatch, string Snippet);

/// <summary>
/// In-memory search over page titles and page text. Exists only while the vault is unlocked and is thrown
/// away on lock; nothing is ever written to disk.
/// </summary>
public sealed class SearchIndex
{
    private static readonly CompareInfo Compare = CultureInfo.InvariantCulture.CompareInfo;
    private const CompareOptions Options = CompareOptions.IgnoreCase | CompareOptions.IgnoreNonSpace | CompareOptions.IgnoreKanaType | CompareOptions.IgnoreWidth;

    private readonly List<SearchEntry> _entries = [];

    /// <summary>Number of pages indexed.</summary>
    public int Count => _entries.Count;

    /// <summary>Forgets everything.</summary>
    public void Clear() => _entries.Clear();

    /// <summary>Drops the pages that match (deleted since the last pass).</summary>
    public void RemoveWhere(Predicate<SearchEntry> match) => _entries.RemoveAll(match);

    /// <summary>Adds or replaces a page.</summary>
    public void Set(SearchEntry entry)
    {
        var i = _entries.FindIndex(e => e.PageId == entry.PageId);
        if (i >= 0)
        {
            _entries[i] = entry;
        }
        else
        {
            _entries.Add(entry);
        }
    }

    /// <summary>
    /// Pages in which every word of <paramref name="query"/> occurs in the title or the text (ignoring case and
    /// accents). Title matches come first.
    /// </summary>
    public IReadOnlyList<SearchHit> Search(string? query, int max = 30)
    {
        var terms = (query ?? "").Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries);
        if (terms.Length == 0)
        {
            return [];
        }

        var hits = new List<SearchHit>();
        foreach (var entry in _entries)
        {
            var allInTitle = true;
            var all = true;
            var firstTextMatch = -1;
            var firstTextLength = 0;
            foreach (var term in terms)
            {
                var inTitle = Compare.IndexOf(entry.Title, term, Options) >= 0;
                var at = Compare.IndexOf(entry.Text.AsSpan(), term.AsSpan(), Options, out var matchLength);
                if (!inTitle)
                {
                    allInTitle = false;
                }

                if (!inTitle && at < 0)
                {
                    all = false;
                    break;
                }

                if (at >= 0 && (firstTextMatch < 0 || at < firstTextMatch))
                {
                    firstTextMatch = at;
                    firstTextLength = matchLength;
                }
            }

            if (all)
            {
                hits.Add(new SearchHit(entry, allInTitle, Snippet(entry.Text, firstTextMatch, firstTextLength)));
            }
        }

        return hits
            .OrderByDescending(h => h.TitleMatch)
            .ThenBy(h => h.Entry.Title, StringComparer.CurrentCultureIgnoreCase)
            .Take(max)
            .ToList();
    }

    /// <summary>About 80 characters around a match, on one line.</summary>
    public static string Snippet(string text, int matchAt, int matchLength)
    {
        if (text.Length == 0)
        {
            return "";
        }

        var start = matchAt < 0 ? 0 : Math.Max(0, matchAt - 30);
        var end = Math.Min(text.Length, (matchAt < 0 ? 0 : matchAt + matchLength) + 50);
        if (start > 0 && char.IsLowSurrogate(text[start]))
        {
            start--;
        }

        if (end < text.Length && char.IsLowSurrogate(text[end]))
        {
            end++;
        }

        var piece = text[start..end].Replace('\n', ' ').Replace('\u2028', ' ').Replace('\t', ' ').Trim();
        return (start > 0 ? "…" : "") + piece + (end < text.Length - 1 ? "…" : "");
    }
}
