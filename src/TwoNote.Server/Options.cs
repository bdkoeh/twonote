namespace TwoNote.Server;

public sealed class TwoNoteOptions
{
    public string DataDir { get; set; } = "/data";
    public string DatabasePath => Path.Combine(DataDir, "twonote.db");

    public int MaxBlobBytes { get; set; } = 8 * 1024 * 1024;
    public int MaxWrappedKeyBytes { get; set; } = 4096;
    public long MaxRequestBodyBytes { get; set; } = 64L * 1024 * 1024;
    public int MaxUpdatesPerRequest { get; set; } = 1000;

    /// <summary>Soft cap on blob bytes in one /events page; a page always holds at least one event.</summary>
    public long EventsPageByteBudget { get; set; } = 16L * 1024 * 1024;
    public int EventsDefaultLimit { get; set; } = 500;
    public int EventsMaxLimit { get; set; } = 2000;

    public TimeSpan ChallengeLifetime { get; set; } = TimeSpan.FromSeconds(60);
    public int MaxPendingChallenges { get; set; } = 10_000;

    public int LoginFailureLimit { get; set; } = 5;
    public TimeSpan LoginFailureWindow { get; set; } = TimeSpan.FromMinutes(1);

    public TimeSpan WebSocketAuthTimeout { get; set; } = TimeSpan.FromSeconds(10);

    public static TwoNoteOptions FromConfiguration(IConfiguration configuration)
    {
        var options = new TwoNoteOptions();
        var dataDir = configuration["TWONOTE_DATA_DIR"];
        if (!string.IsNullOrWhiteSpace(dataDir)) options.DataDir = dataDir;
        return options;
    }
}
