using System.Diagnostics.CodeAnalysis;
using System.Security.Cryptography;

namespace TwoNote.Core.Crypto;

/// <summary>
/// The 128-bit Secret Key (PROTOCOL.md 1.1): the second secret that never leaves the user's
/// devices. Display form <c>T2-XXXXXX-XXXXXX-XXXXXX-XXXXXXXX</c> (Crockford base32).
/// </summary>
public sealed class SecretKey : IDisposable
{
    /// <summary>Length of the raw key in bytes.</summary>
    public const int Length = 16;

    private const string Prefix = "T2";
    private const int EncodedLength = 26;
    private const string Alphabet = "0123456789ABCDEFGHJKMNPQRSTVWXYZ";

    private readonly SecretBytes _bytes;

    private SecretKey(SecretBytes bytes) => _bytes = bytes;

    /// <summary>The 16 raw bytes. Throws <see cref="ObjectDisposedException"/> after disposal.</summary>
    public ReadOnlySpan<byte> Bytes => _bytes.Span;

    /// <summary>Generates a new random Secret Key.</summary>
    public static SecretKey Generate() => new(SecretBytes.Random(Length));

    /// <summary>Wraps a copy of 16 raw bytes.</summary>
    public static SecretKey FromBytes(ReadOnlySpan<byte> bytes)
    {
        if (bytes.Length != Length)
        {
            throw new ArgumentException($"A Secret Key is exactly {Length} bytes.", nameof(bytes));
        }

        return new SecretKey(SecretBytes.CopyFrom(bytes));
    }

    /// <summary>Parses the display form. Throws <see cref="FormatException"/> (without echoing the input) on failure.</summary>
    public static SecretKey Parse(ReadOnlySpan<char> text) =>
        TryParse(text, out var key) ? key : throw new FormatException("Not a valid TwoNote Secret Key.");

    /// <summary>
    /// Parses the display form tolerantly: case, hyphens and whitespace are ignored, and
    /// <c>O</c> reads as <c>0</c>, <c>I</c> and <c>L</c> as <c>1</c>. The <c>T2</c> prefix may
    /// be omitted. Anything else (wrong length, other characters such as <c>U</c>, or stray
    /// bits in the final character) is rejected.
    /// </summary>
    public static bool TryParse(ReadOnlySpan<char> text, [NotNullWhen(true)] out SecretKey? key)
    {
        key = null;

        // Longest accepted input is far below this; refuse anything silly before touching the stack.
        if (text.Length > 256)
        {
            return false;
        }

        Span<char> symbols = stackalloc char[text.Length];
        Span<byte> raw = stackalloc byte[Length];
        try
        {
            var count = 0;
            foreach (var c in text)
            {
                if (c == '-' || char.IsWhiteSpace(c))
                {
                    continue;
                }

                symbols[count++] = c;
            }

            var body = symbols[..count];
            if (body.Length == Prefix.Length + EncodedLength
                && body[0] is 'T' or 't'
                && body[1] == '2')
            {
                body = body[Prefix.Length..];
            }

            if (body.Length != EncodedLength)
            {
                return false;
            }

            // 26 symbols carry 130 bits: the 128 key bits, most significant first, then two zero bits.
            ulong acc = 0;
            var bits = 0;
            var written = 0;
            foreach (var c in body)
            {
                var value = SymbolValue(c);
                if (value < 0)
                {
                    return false;
                }

                acc = (acc << 5) | (uint)value;
                bits += 5;
                if (bits >= 8 && written < Length)
                {
                    bits -= 8;
                    raw[written++] = (byte)(acc >> bits);
                }
            }

            if (written != Length || bits != 2 || (acc & 0b11) != 0)
            {
                return false;
            }

            key = FromBytes(raw);
            return true;
        }
        finally
        {
            CryptographicOperations.ZeroMemory(raw);
            symbols.Clear();
        }
    }

    /// <summary>Returns the display form <c>T2-XXXXXX-XXXXXX-XXXXXX-XXXXXXXX</c>. This is the secret itself: show it, never log it.</summary>
    public string Format()
    {
        Span<char> encoded = stackalloc char[EncodedLength];
        try
        {
            var source = Bytes;
            ulong acc = 0;
            var bits = 0;
            var written = 0;
            foreach (var b in source)
            {
                acc = (acc << 8) | b;
                bits += 8;
                while (bits >= 5)
                {
                    bits -= 5;
                    encoded[written++] = Alphabet[(int)((acc >> bits) & 31)];
                }
            }

            // 128 bits leave three bits over; pad with two zero bits to fill the last symbol.
            encoded[written] = Alphabet[(int)((acc << (5 - bits)) & 31)];

            return string.Create(null, stackalloc char[40],
                $"{Prefix}-{encoded[..6]}-{encoded[6..12]}-{encoded[12..18]}-{encoded[18..]}");
        }
        finally
        {
            encoded.Clear();
        }
    }

    /// <summary>Zeroes the key.</summary>
    public void Dispose() => _bytes.Dispose();

    /// <summary>Returns a placeholder; use <see cref="Format"/> for the display form.</summary>
    public override string ToString() => "SecretKey(redacted)";

    private static int SymbolValue(char c)
    {
        if (c is >= 'a' and <= 'z')
        {
            c = (char)(c - 32);
        }

        return c switch
        {
            'O' => 0,
            'I' or 'L' => 1,
            >= '0' and <= '9' => c - '0',
            >= 'A' and <= 'Z' => Alphabet.IndexOf(c),
            _ => -1,
        };
    }
}
