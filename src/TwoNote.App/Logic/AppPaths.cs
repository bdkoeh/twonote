using System.Text.RegularExpressions;

namespace TwoNote.App.Logic;

/// <summary>
/// Where one profile keeps its files. The default profile lives directly under %LOCALAPPDATA%\TwoNote; a named
/// profile (<c>--profile name</c>) under %LOCALAPPDATA%\TwoNote\profiles\name, with its own database, settings
/// and secret-store entries, so two instances can run side by side as two devices.
/// </summary>
public sealed partial class AppPaths
{
    /// <summary>Environment variable that moves the data root (tests).</summary>
    public const string RootOverrideVariable = "TWONOTE_DATA_ROOT";

    private AppPaths(string? profile, string directory)
    {
        Profile = profile;
        Directory = directory;
    }

    /// <summary>The profile name, or null for the default profile.</summary>
    public string? Profile { get; }

    /// <summary>The directory that holds everything of this profile.</summary>
    public string Directory { get; }

    /// <summary>The local SQLite database (ciphertext only).</summary>
    public string DatabasePath => Path.Combine(Directory, "twonote.db");

    /// <summary>Settings (nothing secret, no note content).</summary>
    public string SettingsPath => Path.Combine(Directory, "settings.json");

    /// <summary>The DPAPI-protected secrets file, used only where the Credential Locker is not available.</summary>
    public string DpapiSecretsPath => Path.Combine(Directory, "secrets.bin");

    /// <summary>The name under which this profile's entries are kept in the secret store.</summary>
    public string SecretScope => Profile is null ? "TwoNote" : "TwoNote/profile/" + Profile;

    /// <summary>True when <paramref name="name"/> can be used as a profile name: 1-40 letters, digits, '-' or '_'.</summary>
    public static bool IsValidProfileName(string? name) => name is not null && ProfileName().IsMatch(name);

    /// <summary>The paths of a profile (null = default).</summary>
    /// <exception cref="ArgumentException">The name is not a valid profile name.</exception>
    public static AppPaths For(string? profile, string? root = null)
    {
        root ??= Environment.GetEnvironmentVariable(RootOverrideVariable) is { Length: > 0 } o
            ? o
            : Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "TwoNote");
        if (profile is null)
        {
            return new AppPaths(null, root);
        }

        if (!IsValidProfileName(profile))
        {
            throw new ArgumentException("A profile name is 1 to 40 letters, digits, '-' or '_'.", nameof(profile));
        }

        return new AppPaths(profile, Path.Combine(root, "profiles", profile));
    }

    /// <summary>The files that belong to this profile (not the profiles of others below the default directory).</summary>
    public IEnumerable<string> OwnFiles()
    {
        if (!System.IO.Directory.Exists(Directory))
        {
            return [];
        }

        return Profile is null
            ? System.IO.Directory.EnumerateFiles(Directory, "*", SearchOption.TopDirectoryOnly)
            : System.IO.Directory.EnumerateFiles(Directory, "*", SearchOption.AllDirectories);
    }

    /// <summary>Deletes this profile's files. A named profile's directory goes too.</summary>
    public void DeleteAll()
    {
        foreach (var file in OwnFiles().ToList())
        {
            File.Delete(file);
        }

        if (Profile is not null && System.IO.Directory.Exists(Directory))
        {
            System.IO.Directory.Delete(Directory, recursive: true);
        }
    }

    [GeneratedRegex("^[A-Za-z0-9_-]{1,40}$")]
    private static partial Regex ProfileName();
}
