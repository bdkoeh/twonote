using System.Net.WebSockets;
using System.Text.Json;

namespace TwoNote.Core.Api;

/// <summary>Opens a WebSocket to the given address. The default uses <see cref="ClientWebSocket"/>.</summary>
public delegate Task<WebSocket> WebSocketConnector(Uri address, CancellationToken ct);

/// <summary>
/// Holds the <c>/ws</c> socket open (PROTOCOL.md section 3, "WebSocket") and reports every
/// <c>{ "head": n }</c> the server sends. Reconnects with exponential backoff for as long as it runs.
/// No document data travels over the socket; the listener only tells the sync engine when to pull.
/// </summary>
public sealed class HeadListener : IAsyncDisposable
{
    private const int MaxMessageBytes = 4096;

    private readonly Uri _address;
    private readonly Func<string?> _token;
    private readonly WebSocketConnector _connect;
    private readonly TimeSpan _initialBackoff;
    private readonly TimeSpan _maxBackoff;
    private readonly Lock _lock = new();
    private CancellationTokenSource? _cts;
    private Task? _loop;
    private volatile bool _connected;

    /// <summary>Creates a listener; call <see cref="Start"/> to connect.</summary>
    /// <param name="address">The <c>ws://</c> or <c>wss://</c> address of <c>/api/v1/ws</c>.</param>
    /// <param name="token">Supplies the current session token on every (re)connect.</param>
    /// <param name="connect">Optional transport, used by tests to reach an in-process server.</param>
    /// <param name="initialBackoff">Delay before the first reconnect; doubles up to <paramref name="maxBackoff"/>. Default 1 second.</param>
    /// <param name="maxBackoff">Longest delay between reconnects. Default 30 seconds.</param>
    public HeadListener(
        Uri address, Func<string?> token, WebSocketConnector? connect = null, TimeSpan? initialBackoff = null, TimeSpan? maxBackoff = null)
    {
        _address = address ?? throw new ArgumentNullException(nameof(address));
        _token = token ?? throw new ArgumentNullException(nameof(token));
        _connect = connect ?? DefaultConnect;
        _initialBackoff = initialBackoff ?? TimeSpan.FromSeconds(1);
        _maxBackoff = maxBackoff ?? TimeSpan.FromSeconds(30);
    }

    /// <summary>Raised (on a thread-pool thread) for every head value the server sends, including the one right after connecting.</summary>
    public event Action<long>? HeadReceived;

    /// <summary>Raised when the socket becomes usable (true) or is lost (false).</summary>
    public event Action<bool>? ConnectionChanged;

    /// <summary>Raised when the server closed the socket for policy reasons (code 1008): the token is missing, unknown or revoked.</summary>
    public event Action? Rejected;

    /// <summary>True while an authenticated socket is open.</summary>
    public bool IsConnected => _connected;

    /// <summary>Number of sockets opened so far (1 after the first connect; grows with every reconnect).</summary>
    public int ConnectionCount { get; private set; }

    /// <summary>Starts connecting in the background. Does nothing if already running.</summary>
    public void Start()
    {
        lock (_lock)
        {
            if (_loop is not null)
            {
                return;
            }

            _cts = new CancellationTokenSource();
            var ct = _cts.Token;
            _loop = Task.Run(() => RunAsync(ct), CancellationToken.None);
        }
    }

    /// <summary>Closes the socket and stops reconnecting.</summary>
    public async Task StopAsync()
    {
        Task? loop;
        CancellationTokenSource? cts;
        lock (_lock)
        {
            loop = _loop;
            cts = _cts;
            _loop = null;
            _cts = null;
        }

        if (loop is null)
        {
            return;
        }

        cts!.Cancel();
        try
        {
            await loop.ConfigureAwait(false);
        }
        catch (OperationCanceledException)
        {
        }

        cts.Dispose();
    }

    /// <inheritdoc />
    public async ValueTask DisposeAsync() => await StopAsync().ConfigureAwait(false);

    private static async Task<WebSocket> DefaultConnect(Uri address, CancellationToken ct)
    {
        var socket = new ClientWebSocket();
        try
        {
            socket.Options.KeepAliveInterval = TimeSpan.FromSeconds(30);
            await socket.ConnectAsync(address, ct).ConfigureAwait(false);
            return socket;
        }
        catch
        {
            socket.Dispose();
            throw;
        }
    }

    private async Task RunAsync(CancellationToken ct)
    {
        var backoff = _initialBackoff;
        while (!ct.IsCancellationRequested)
        {
            var gotHead = false;
            try
            {
                gotHead = await RunOneConnectionAsync(ct).ConfigureAwait(false);
            }
            catch (OperationCanceledException) when (ct.IsCancellationRequested)
            {
                break;
            }
            catch (Exception e) when (e is WebSocketException or IOException or HttpRequestException or InvalidOperationException
                                          or OperationCanceledException or JsonException)
            {
                // Connection refused, dropped, or a frame that is not ours: reconnect.
            }

            SetConnected(false);
            if (gotHead)
            {
                backoff = _initialBackoff; // the connection worked; the next drop starts over
            }

            try
            {
                // Jitter keeps several devices from reconnecting in step after a server restart.
                await Task.Delay(backoff + TimeSpan.FromMilliseconds(Random.Shared.Next(0, 1 + (int)(backoff.TotalMilliseconds / 4))), ct)
                    .ConfigureAwait(false);
            }
            catch (OperationCanceledException)
            {
                break;
            }

            backoff = TimeSpan.FromTicks(Math.Min(_maxBackoff.Ticks, backoff.Ticks * 2));
        }

        SetConnected(false);
    }

    /// <summary>Returns true if at least one head arrived before the connection ended.</summary>
    private async Task<bool> RunOneConnectionAsync(CancellationToken ct)
    {
        var token = _token();
        if (token is null)
        {
            return false;
        }

        var gotHead = false;
        using var socket = await _connect(_address, ct).ConfigureAwait(false);
        ConnectionCount++;
        try
        {
            var hello = JsonSerializer.SerializeToUtf8Bytes(new TokenHello(token), WireJson.Options);
            await socket.SendAsync(hello, WebSocketMessageType.Text, endOfMessage: true, ct).ConfigureAwait(false);

            var buffer = new byte[MaxMessageBytes];
            while (true)
            {
                var length = 0;
                WebSocketReceiveResult result;
                do
                {
                    result = await socket.ReceiveAsync(new ArraySegment<byte>(buffer, length, buffer.Length - length), ct).ConfigureAwait(false);
                    if (result.MessageType == WebSocketMessageType.Close)
                    {
                        if (result.CloseStatus == WebSocketCloseStatus.PolicyViolation)
                        {
                            Rejected?.Invoke();
                        }

                        return gotHead;
                    }

                    length += result.Count;
                    if (length == buffer.Length && !result.EndOfMessage)
                    {
                        return gotHead; // far larger than any head message: not our server
                    }
                }
                while (!result.EndOfMessage);

                if (result.MessageType != WebSocketMessageType.Text)
                {
                    continue;
                }

                var message = JsonSerializer.Deserialize<HeadMessage>(buffer.AsSpan(0, length), WireJson.Options);
                if (message is null)
                {
                    continue;
                }

                gotHead = true;
                SetConnected(true);
                HeadReceived?.Invoke(message.Head);
            }
        }
        finally
        {
            if (socket.State is WebSocketState.Open or WebSocketState.CloseReceived)
            {
                try
                {
                    using var closing = new CancellationTokenSource(TimeSpan.FromSeconds(2));
                    await socket.CloseOutputAsync(WebSocketCloseStatus.NormalClosure, null, closing.Token).ConfigureAwait(false);
                }
                catch (Exception e) when (e is WebSocketException or IOException or OperationCanceledException or ObjectDisposedException)
                {
                }
            }
        }
    }

    private void SetConnected(bool connected)
    {
        if (_connected == connected)
        {
            return;
        }

        _connected = connected;
        ConnectionChanged?.Invoke(connected);
    }
}
