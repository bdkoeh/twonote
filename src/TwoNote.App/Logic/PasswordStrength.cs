namespace TwoNote.App.Logic;

/// <summary>A rough, local estimate of how hard a master password is to guess, for the hint under the password box.</summary>
public static class PasswordStrength
{
    private static readonly string[] Common =
    [
        "password", "passwort", "123456", "12345678", "123456789", "qwerty", "qwertz", "letmein", "welcome", "admin",
        "iloveyou", "monkey", "dragon", "abc123", "111111", "000000", "twonote", "onenote", "secret", "master",
    ];

    /// <summary>0 = far too weak … 4 = strong, with a one-line hint.</summary>
    public static (int Score, string Hint) Evaluate(string? password)
    {
        if (string.IsNullOrEmpty(password))
        {
            return (0, "Use a long password or a phrase of several words.");
        }

        var lower = password.ToLowerInvariant();
        if (Common.Any(c => lower == c || (lower.StartsWith(c, StringComparison.Ordinal) && lower.Length - c.Length <= 3)))
        {
            return (0, "This is one of the first passwords anyone would try.");
        }

        var classes = 0;
        if (password.Any(char.IsLower)) classes++;
        if (password.Any(char.IsUpper)) classes++;
        if (password.Any(char.IsDigit)) classes++;
        if (password.Any(c => !char.IsLetterOrDigit(c))) classes++;
        var distinct = password.Distinct().Count();
        var words = password.Split(' ', StringSplitOptions.RemoveEmptyEntries).Length;

        // Bits, very roughly: characters times the size of the alphabet in use, discounted for repetition.
        var alphabet = classes switch { 1 => 26, 2 => 52, 3 => 62, _ => 80 };
        var effectiveLength = Math.Min(password.Length, distinct * 2);
        var bits = effectiveLength * Math.Log2(alphabet) * (words >= 3 ? 0.6 : 0.8);

        if (password.Length < 8 || distinct < 5)
        {
            return (0, "Too short. Aim for at least 12 characters.");
        }

        if (bits < 45)
        {
            return (1, "Weak. Make it longer - a phrase of four or more words works well.");
        }

        if (bits < 60)
        {
            return (2, "Fair. A few more characters or another word would help.");
        }

        return bits < 80 ? (3, "Good.") : (4, "Strong.");
    }
}
