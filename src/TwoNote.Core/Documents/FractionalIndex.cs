using System.Text;

namespace TwoNote.Core.Documents;

/// <summary>
/// Fractional index strings for the <c>order</c> field of PROTOCOL.md 5.1.
/// A key is one or more characters of <c>0-9 A-Z a-z</c> (which is also their byte order) that
/// does not end in <c>0</c>; read it as the digits of a base-62 fraction between 0 and 1. Keys
/// are compared as plain byte strings (ordinal), so any client can sort them without this code.
/// Between any two different keys there is always another one.
/// </summary>
public static class FractionalIndex
{
    private const string Digits = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz";
    private const int Base = 62;

    /// <summary>The key given to the first item of an empty list.</summary>
    public const string First = "V";

    /// <summary>True when <paramref name="key"/> is a well-formed key.</summary>
    public static bool IsValid(string? key)
    {
        if (string.IsNullOrEmpty(key) || key[^1] == '0')
        {
            return false;
        }

        foreach (var c in key)
        {
            if (Digit(c) < 0)
            {
                return false;
            }
        }

        return true;
    }

    /// <summary>Orders two keys the way every client must: by UTF-16 code unit, which for valid keys is byte order.</summary>
    public static int Compare(string? a, string? b) => string.CompareOrdinal(a, b);

    /// <summary>
    /// Returns a key that sorts strictly between <paramref name="before"/> and <paramref name="after"/>.
    /// Null means "no neighbour on that side".
    /// </summary>
    /// <exception cref="ArgumentException">A key is malformed, or <paramref name="before"/> does not sort before <paramref name="after"/>.</exception>
    public static string Between(string? before, string? after)
    {
        if (before is not null && !IsValid(before))
        {
            throw new ArgumentException("Not a valid fractional index.", nameof(before));
        }

        if (after is not null && !IsValid(after))
        {
            throw new ArgumentException("Not a valid fractional index.", nameof(after));
        }

        if (before is null)
        {
            return after is null ? First : Before(after);
        }

        if (after is null)
        {
            return After(before);
        }

        if (Compare(before, after) >= 0)
        {
            throw new ArgumentException("The lower key must sort before the upper key.", nameof(before));
        }

        return Midpoint(before, after);
    }

    /// <summary>
    /// A key just above <paramref name="key"/>. Appending to a list grows the key by one character
    /// roughly every 60 items instead of every few, which plain bisection would do.
    /// </summary>
    private static string After(string key)
    {
        for (var i = 0; i < key.Length; i++)
        {
            var d = Digit(key[i]);
            if (d < Base - 1)
            {
                return string.Concat(key.AsSpan(0, i), Digits.AsSpan(d + 1, 1));
            }
        }

        return key + "1"; // all 'z': go one digit deeper
    }

    /// <summary>A key just below <paramref name="key"/>; the mirror image of <see cref="After"/>.</summary>
    private static string Before(string key)
    {
        for (var i = 0; i < key.Length; i++)
        {
            var d = Digit(key[i]);
            if (d >= 2)
            {
                return string.Concat(key.AsSpan(0, i), Digits.AsSpan(d - 1, 1));
            }
        }

        // Only 0s and 1s (and it cannot end in 0, so there is a 1): replace the first 1 by "0y".
        var one = key.IndexOf('1');
        return string.Concat(key.AsSpan(0, one), "0y");
    }

    /// <summary>The shortest key between two keys, biased to the middle. <paramref name="b"/> null means 1.</summary>
    private static string Midpoint(string a, string? b)
    {
        var result = new StringBuilder();
        while (true)
        {
            if (b is not null)
            {
                // Copy the common prefix (a is padded with zeros).
                var n = 0;
                while (n < b.Length && (n < a.Length ? a[n] : '0') == b[n])
                {
                    n++;
                }

                if (n > 0)
                {
                    result.Append(b, 0, n);
                    a = n < a.Length ? a[n..] : "";
                    b = b[n..];
                }
            }

            var digitA = a.Length > 0 ? Digit(a[0]) : 0;
            var digitB = b is not null ? Digit(b[0]) : Base;
            if (digitB - digitA > 1)
            {
                result.Append(Digits[(digitA + digitB + 1) / 2]);
                return result.ToString();
            }

            // The first digits are adjacent.
            if (b is { Length: > 1 })
            {
                result.Append(b[0]);
                return result.ToString();
            }

            // Keep a's first digit and find something above the rest of a.
            result.Append(Digits[digitA]);
            a = a.Length > 1 ? a[1..] : "";
            b = null;
        }
    }

    private static int Digit(char c) => c switch
    {
        >= '0' and <= '9' => c - '0',
        >= 'A' and <= 'Z' => c - 'A' + 10,
        >= 'a' and <= 'z' => c - 'a' + 36,
        _ => -1,
    };
}
