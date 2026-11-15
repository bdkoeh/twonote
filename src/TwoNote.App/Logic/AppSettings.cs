using System.Text.Json;
using System.Text.Json.Serialization;

namespace TwoNote.App.Logic;

/// <summary>
/// Per-profile settings, stored as JSON next to the database. Holds nothing secret and no note content: the
/// "last open" entries are random document ids.
/// </summary>
public sealed class AppSettings
{
    private static readonly JsonSerializerOptions Json = new()
    {
        WriteIndented = true,
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
    };

    /// <summary>The server this device belongs to; set once during setup.</summary>
    public string? ServerUrl { get; set; }

    /// <summary>Minutes without input before the app locks itself; 0 = never.</summary>
    public int AutoLockMinutes { get; set; } = 10;

    /// <summary>"system" (default), "light" or "dark".</summary>
    public string Theme { get; set; } = "system";

    /// <summary>"vault" (Windows Credential Locker) or "dpapi" (protected file); chosen once per profile.</summary>
    public string? SecretStore { get; set; }

    /// <summary>The notebook that was open last.</summary>
    public string? LastNotebookId { get; set; }

    /// <summary>The section that was open last, per notebook id.</summary>
    public Dictionary<string, string> LastSection { get; set; } = [];

    /// <summary>The page that was open last, per section id.</summary>
    public Dictionary<string, string> LastPage { get; set; } = [];

    /// <summary>Zoom of everything below the title bar, in percent (50-200).</summary>
    public int ZoomPercent { get; set; } = 100;

    /// <summary>True when the notebook, section and page panes are hidden, leaving only the page.</summary>
    public bool HidePanes { get; set; }

    /// <summary>Window size in device-independent pixels.</summary>
    public int WindowWidth { get; set; } = 1280;

    /// <summary>Window size in device-independent pixels.</summary>
    public int WindowHeight { get; set; } = 820;

    /// <summary>Where the settings are saved; not part of the file.</summary>
    [JsonIgnore]
    public string? FilePath { get; private set; }

    /// <summary>Loads the settings, or returns defaults when the file is missing or unreadable.</summary>
    public static AppSettings Load(string path)
    {
        AppSettings? settings = null;
        try
        {
            if (File.Exists(path))
            {
                settings = JsonSerializer.Deserialize<AppSettings>(File.ReadAllText(path), Json);
            }
        }
        catch (Exception e) when (e is JsonException or IOException or UnauthorizedAccessException)
        {
            // A damaged settings file is not worth failing over: start from defaults.
        }

        settings ??= new AppSettings();
        settings.LastSection ??= [];
        settings.LastPage ??= [];
        settings.AutoLockMinutes = Math.Clamp(settings.AutoLockMinutes, 0, 24 * 60);
        if (settings.Theme is not ("light" or "dark"))
        {
            settings.Theme = "system";
        }

        settings.FilePath = path;
        return settings;
    }

    /// <summary>Writes the settings (to a temporary file first, so a crash cannot leave half a file).</summary>
    public void Save()
    {
        if (FilePath is null)
        {
            return;
        }

        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(FilePath)!);
            var temp = FilePath + ".tmp";
            File.WriteAllText(temp, JsonSerializer.Serialize(this, Json));
            File.Move(temp, FilePath, overwrite: true);
        }
        catch (Exception e) when (e is IOException or UnauthorizedAccessException)
        {
            // Settings are a convenience; losing a write is not worth interrupting the user.
        }
    }
}
