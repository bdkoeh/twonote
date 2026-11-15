using System.Net.WebSockets;
using System.Text;
using System.Text.Json;

namespace TwoNote.Server;

/// <summary>
/// GET /api/v1/ws. The first client frame is {"token": "..."}; afterwards the server only
/// ever sends {"head": n}. No document data travels over the socket.
/// </summary>
internal static class WebSocketEndpoint
{
    private const int MaxHelloBytes = 4096;

    public static async Task Handle(
        HttpContext ctx, HeadHub hub, TwoNoteOptions options, IHostApplicationLifetime lifetime)
    {
        if (!ctx.WebSockets.IsWebSocketRequest)
            throw ApiException.Invalid("This endpoint only accepts WebSocket upgrades");

        using var ws = await ctx.WebSockets.AcceptWebSocketAsync();
        using var stop = CancellationTokenSource.CreateLinkedTokenSource(ctx.RequestAborted, lifetime.ApplicationStopping);
        try
        {
            var device = await Authenticate(ws, ctx.RequestServices, options, stop.Token);
            if (device is null) return;
            await Pump(ws, hub, device.DeviceId, stop.Token);
        }
        catch (Exception e) when (e is OperationCanceledException or WebSocketException or IOException)
        {
            // Client went away or the server is stopping.
        }
    }

    private static async Task<DeviceRow?> Authenticate(
        WebSocket ws, IServiceProvider services, TwoNoteOptions options, CancellationToken stop)
    {
        // The receive is not cancelled on timeout (that would abort the socket before a close
        // frame could be sent); it is raced against a timer instead.
        var hello = ReceiveText(ws, MaxHelloBytes, stop);
        if (await Task.WhenAny(hello, Task.Delay(options.WebSocketAuthTimeout, stop)) != hello)
        {
            stop.ThrowIfCancellationRequested();
            await Reject(ws, "No token received in time", stop);
            return null;
        }

        string? token = null;
        if (await hello is { } text)
        {
            try
            {
                token = JsonSerializer.Deserialize<WsHello>(text, Json.Options)?.Token;
            }
            catch (JsonException)
            {
            }
        }

        var device = token is null ? null : Endpoints.AuthenticateToken(token, services);
        if (device is null) await Reject(ws, "A valid token is required", stop);
        return device;
    }

    private static async Task Pump(WebSocket ws, HeadHub hub, string deviceId, CancellationToken stop)
    {
        var subscription = hub.Subscribe(deviceId);
        try
        {
            var closed = DrainUntilClosed(ws, stop);
            var sent = hub.Head; // read after subscribing, so no advance can be missed
            await SendHead(ws, sent, stop);

            while (true)
            {
                var next = subscription.Heads.WaitToReadAsync(stop).AsTask();
                if (await Task.WhenAny(closed, next) == closed)
                {
                    if (ws.State == WebSocketState.CloseReceived)
                        await ws.CloseOutputAsync(WebSocketCloseStatus.NormalClosure, null, stop);
                    return;
                }

                if (!await next)
                {
                    await Reject(ws, "Token revoked", stop);
                    return;
                }

                while (subscription.Heads.TryRead(out var head))
                {
                    if (head <= sent) continue;
                    sent = head;
                    await SendHead(ws, head, stop);
                }
            }
        }
        finally
        {
            hub.Unsubscribe(subscription);
        }
    }

    private static Task SendHead(WebSocket ws, long head, CancellationToken stop) =>
        ws.SendAsync(JsonSerializer.SerializeToUtf8Bytes(new HeadResponse(head), Json.Options),
            WebSocketMessageType.Text, endOfMessage: true, stop);

    private static async Task Reject(WebSocket ws, string reason, CancellationToken stop)
    {
        if (ws.State is WebSocketState.Open or WebSocketState.CloseReceived)
            await ws.CloseOutputAsync(WebSocketCloseStatus.PolicyViolation, reason, stop);
    }

    /// <summary>Reads one text message; null if it is not text, too large, or the peer closed.</summary>
    private static async Task<string?> ReceiveText(WebSocket ws, int maxBytes, CancellationToken stop)
    {
        var buffer = new byte[maxBytes];
        var length = 0;
        while (true)
        {
            var result = await ws.ReceiveAsync(buffer.AsMemory(length), stop);
            if (result.MessageType != WebSocketMessageType.Text) return null;
            length += result.Count;
            if (result.EndOfMessage) return Encoding.UTF8.GetString(buffer, 0, length);
            if (length == maxBytes) return null;
        }
    }

    /// <summary>After login the client has nothing to say; frames are read and dropped until it closes.</summary>
    private static async Task DrainUntilClosed(WebSocket ws, CancellationToken stop)
    {
        var buffer = new byte[1024];
        try
        {
            while (ws.State == WebSocketState.Open)
            {
                var result = await ws.ReceiveAsync(buffer.AsMemory(), stop);
                if (result.MessageType == WebSocketMessageType.Close) return;
            }
        }
        catch (Exception e) when (e is OperationCanceledException or WebSocketException or IOException)
        {
        }
    }
}
