using TwoNote.Core.Api;
using TwoNote.Core.Crypto;

namespace TwoNote.Core;

/// <summary>
/// Where the two device secrets live: the Secret Key and the session token. The Windows app
/// backs this with the Credential Locker; tests use <see cref="InMemorySecretStore"/>. Nothing
/// handed to this interface is ever written to the local database or to a log.
/// </summary>
public interface ISecretStore
{
    /// <summary>Returns the stored value, or null.</summary>
    string? Get(string name);

    /// <summary>Stores or replaces a value.</summary>
    void Set(string name, string value);

    /// <summary>Removes a value; does nothing if it is not there.</summary>
    void Remove(string name);
}

/// <summary>The names <see cref="TwoNoteClient"/> uses in its <see cref="ISecretStore"/>.</summary>
public static class SecretNames
{
    /// <summary>The Secret Key in its display form (<c>T2-…</c>).</summary>
    public const string SecretKey = "secret-key";

    /// <summary>The session token issued by the server for this device.</summary>
    public const string SessionToken = "session-token";
}

/// <summary>An <see cref="ISecretStore"/> that forgets everything when the process ends.</summary>
public sealed class InMemorySecretStore : ISecretStore
{
    private readonly Dictionary<string, string> _values = [];

    /// <inheritdoc />
    public string? Get(string name)
    {
        lock (_values)
        {
            return _values.GetValueOrDefault(name);
        }
    }

    /// <inheritdoc />
    public void Set(string name, string value)
    {
        lock (_values)
        {
            _values[name] = value;
        }
    }

    /// <inheritdoc />
    public void Remove(string name)
    {
        lock (_values)
        {
            _values.Remove(name);
        }
    }
}

/// <summary>Everything a <see cref="TwoNoteClient"/> needs to know about its surroundings.</summary>
public sealed class ClientOptions
{
    /// <summary>The server, e.g. <c>http://nas.local:8080</c>.</summary>
    public required Uri ServerUrl { get; init; }

    /// <summary>Path of this device's SQLite file. Created on first use.</summary>
    public required string DatabasePath { get; init; }

    /// <summary>Holds the Secret Key and the session token.</summary>
    public required ISecretStore SecretStore { get; init; }

    /// <summary>
    /// Runs an action on the thread that owns the documents (the UI thread) and completes when it
    /// has run. Remote changes are applied through it, so document events arrive on that thread.
    /// Null runs them on the sync engine's thread; the documents are thread safe either way.
    /// </summary>
    public Func<Action, Task>? Dispatcher { get; init; }

    /// <summary>HTTP transport override (tests).</summary>
    public HttpMessageHandler? HttpHandler { get; init; }

    /// <summary>WebSocket transport override (tests).</summary>
    public WebSocketConnector? WebSocketConnector { get; init; }

    /// <summary>KDF parameters for a new account or a password change. Defaults to <see cref="KdfParams.Default"/>.</summary>
    public KdfParams KdfParams { get; init; } = KdfParams.Default;

    /// <summary>A document is snapshotted once it has more than this many acknowledged updates (PROTOCOL.md section 4 step 4).</summary>
    public int CompactionThreshold { get; init; } = 200;

    /// <summary>How often the background loop syncs when nothing wakes it earlier.</summary>
    public TimeSpan PollInterval { get; init; } = TimeSpan.FromSeconds(60);

    /// <summary>How long the background loop waits after a local edit before pushing, so a burst of typing travels together.</summary>
    public TimeSpan PushDebounce { get; init; } = TimeSpan.FromMilliseconds(300);

    /// <summary>First retry delay after a failed sync; doubles up to <see cref="MaxRetryDelay"/>.</summary>
    public TimeSpan InitialRetryDelay { get; init; } = TimeSpan.FromSeconds(1);

    /// <summary>Longest delay between retries, for sync and for the WebSocket.</summary>
    public TimeSpan MaxRetryDelay { get; init; } = TimeSpan.FromSeconds(30);

    /// <summary>Per-request HTTP timeout.</summary>
    public TimeSpan HttpTimeout { get; init; } = TimeSpan.FromSeconds(30);

    /// <summary>Events requested per page (server maximum 2000).</summary>
    public int EventsPageSize { get; init; } = 500;

    /// <summary>Most updates sent in one push (server maximum 1000).</summary>
    public int PushBatchSize { get; init; } = 200;

    /// <summary>False disables the WebSocket; the loop then relies on <see cref="PollInterval"/>.</summary>
    public bool UseWebSocket { get; init; } = true;

    /// <summary>Edits to a page closer together than this merge into one undo step.</summary>
    public int UndoCaptureMilliseconds { get; init; } = 500;
}
