using Microsoft.Extensions.DependencyInjection.Extensions;
using TwoNote.Server;

// `dotnet TwoNote.Server.dll --healthcheck` is what the container HEALTHCHECK runs, so the
// image needs no curl or wget.
if (args.Contains("--healthcheck"))
{
    try
    {
        using var http = new HttpClient { Timeout = TimeSpan.FromSeconds(3) };
        var url = Environment.GetEnvironmentVariable("TWONOTE_HEALTHCHECK_URL") ?? "http://127.0.0.1:8080/api/v1/status";
        using var response = await http.GetAsync(url);
        return response.IsSuccessStatusCode ? 0 : 1;
    }
    catch (Exception)
    {
        return 1;
    }
}

var builder = WebApplication.CreateBuilder(args);

// Plain HTTP on 8080 unless the operator says otherwise (ASPNETCORE_URLS / ASPNETCORE_HTTP_PORTS).
if (string.IsNullOrEmpty(builder.Configuration["URLS"]) && string.IsNullOrEmpty(builder.Configuration["HTTP_PORTS"]))
    builder.WebHost.UseUrls("http://*:8080");

builder.WebHost.ConfigureKestrel(kestrel =>
{
    kestrel.AddServerHeader = false;
    kestrel.Limits.MaxRequestBodySize = new TwoNoteOptions().MaxRequestBodyBytes;
});

builder.Services.TryAddSingleton(TimeProvider.System);
builder.Services.TryAddSingleton(sp => TwoNoteOptions.FromConfiguration(sp.GetRequiredService<IConfiguration>()));
builder.Services.AddSingleton<HeadHub>();
builder.Services.AddSingleton<Store>();
builder.Services.AddSingleton<ChallengeStore>();
builder.Services.AddSingleton<LoginRateLimiter>();

var app = builder.Build();

// Open (and if needed create or migrate) the database before accepting requests.
app.Services.GetRequiredService<Store>();

app.Use(async (ctx, next) =>
{
    try
    {
        await next(ctx);
    }
    catch (Exception e) when (!ctx.Response.HasStarted && !ctx.RequestAborted.IsCancellationRequested)
    {
        var (status, code, message) = e switch
        {
            ApiException api => (api.Status, api.Code, api.Message),
            BadHttpRequestException { StatusCode: 413 } => (413, "payload_too_large", "The request body is too large"),
            BadHttpRequestException bad => (bad.StatusCode, "invalid_request", "The request could not be read"),
            _ => (500, "internal", "Internal server error"),
        };
        if (status == 500)
            app.Logger.LogError(e, "Unhandled error on {Method} {Path}", ctx.Request.Method, ctx.Request.Path);

        ctx.Response.StatusCode = status;
        await ctx.Response.WriteAsJsonAsync(new ErrorResponse(code, message), Json.Options);
    }
});

app.UseWebSockets(new WebSocketOptions { KeepAliveInterval = TimeSpan.FromSeconds(30) });
app.MapTwoNoteApi();

app.Run();
return 0;

public partial class Program;
