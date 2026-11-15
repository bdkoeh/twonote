using System.Text.Json;

namespace TwoNote.Server.Tests;

public class AuthTests
{
    [Fact]
    public async Task Status_reports_version_protocol_and_registration_state()
    {
        using var app = new TestApp();
        var before = await app.Api.GetJson("/status");
        Assert.Equal(["protocol", "registrationOpen", "version"], T.Names(before));
        Assert.Equal(1, before.GetProperty("protocol").GetInt32());
        Assert.Equal("0.1.0", before.GetProperty("version").GetString());
        Assert.True(before.GetProperty("registrationOpen").GetBoolean());

        await new TestAccount().Register(app.Api);
        Assert.False((await app.Api.GetJson("/status")).GetProperty("registrationOpen").GetBoolean());
    }

    [Fact]
    public async Task Register_creates_the_account_once_then_is_closed()
    {
        using var app = new TestApp();
        var account = new TestAccount();
        var (deviceId, token) = await account.Register(app.Api);
        Assert.True(T.IsId(deviceId));
        Assert.Equal(32, T.FromB64(token).Length);
        Assert.DoesNotContain('=', token);

        await app.Api.Error(HttpMethod.Post, "/register", 403, "registration_closed", account.RegisterBody());
        await app.Api.Error(HttpMethod.Post, "/register", 403, "registration_closed", new TestAccount { Username = "eve" }.RegisterBody());

        // The first device's token works; only one device exists.
        var devices = await app.Api.GetJson("/devices", token);
        Assert.Equal(deviceId, Assert.Single(devices.EnumerateArray()).GetProperty("deviceId").GetString());
    }

    [Fact]
    public async Task Register_rejects_malformed_input()
    {
        using var app = new TestApp();
        var a = new TestAccount();
        object Body(Func<Dictionary<string, object?>, Dictionary<string, object?>> change) => change(new Dictionary<string, object?>
        {
            ["username"] = a.Username, ["accountId"] = a.AccountId, ["kdfSalt"] = T.B64(a.KdfSalt),
            ["kdfParams"] = TestAccount.KdfParams, ["authPublicKey"] = a.PublicKey,
            ["wrappedVaultKey"] = T.B64(a.WrappedVaultKey), ["deviceName"] = "pc",
        });

        await app.Api.Error(HttpMethod.Post, "/register", 400, "invalid_request", "not json");
        await app.Api.Error(HttpMethod.Post, "/register", 400, "invalid_request", Body(d => { d.Remove("username"); return d; }));
        await app.Api.Error(HttpMethod.Post, "/register", 400, "invalid_request", Body(d => { d["accountId"] = a.AccountId.ToUpperInvariant(); return d; }));
        await app.Api.Error(HttpMethod.Post, "/register", 400, "invalid_request", Body(d => { d["accountId"] = "abc"; return d; }));
        await app.Api.Error(HttpMethod.Post, "/register", 400, "invalid_request", Body(d => { d["kdfSalt"] = Convert.ToBase64String(a.KdfSalt); return d; })); // padded
        await app.Api.Error(HttpMethod.Post, "/register", 400, "invalid_request", Body(d => { d["authPublicKey"] = T.B64(new byte[31]); return d; }));
        await app.Api.Error(HttpMethod.Post, "/register", 400, "invalid_request", Body(d => { d["kdfParams"] = new { alg = "md5", ops = 1, memKiB = 8 }; return d; }));
        await app.Api.Error(HttpMethod.Post, "/register", 413, "blob_too_large", Body(d => { d["wrappedVaultKey"] = T.B64(new byte[5000]); return d; }));

        Assert.True((await app.Api.GetJson("/status")).GetProperty("registrationOpen").GetBoolean());
    }

    [Fact]
    public async Task Login_with_a_real_signature_issues_a_new_device_and_returns_the_wrapped_vault_key()
    {
        using var app = new TestApp();
        var account = new TestAccount();
        var (firstDevice, firstToken) = await account.Register(app.Api);

        var (_, nonce, start) = await account.Start(app.Api);
        Assert.Equal(["accountId", "challengeId", "kdfParams", "kdfSalt", "nonce"], T.Names(start));
        Assert.Equal(account.AccountId, start.GetProperty("accountId").GetString());
        Assert.Equal(T.B64(account.KdfSalt), start.GetProperty("kdfSalt").GetString());
        Assert.Equal(["alg", "memKiB", "ops"], T.Names(start.GetProperty("kdfParams")));
        Assert.Equal("argon2id13", start.GetProperty("kdfParams").GetProperty("alg").GetString());
        Assert.Equal(3, start.GetProperty("kdfParams").GetProperty("ops").GetInt32());
        Assert.Equal(65536, start.GetProperty("kdfParams").GetProperty("memKiB").GetInt32());
        Assert.True(T.IsId(start.GetProperty("challengeId").GetString()));
        Assert.Equal(32, nonce.Length);

        var (deviceId, token, body) = await account.Login(app.Api, "laptop");
        Assert.True(T.IsId(deviceId));
        Assert.NotEqual(firstDevice, deviceId);
        Assert.NotEqual(firstToken, token);
        Assert.Equal(T.B64(account.WrappedVaultKey), body.GetProperty("wrappedVaultKey").GetString());

        Assert.Equal(2, (await app.Api.GetJson("/devices", token)).GetArrayLength());
        Assert.Equal(2, (await app.Api.GetJson("/devices", firstToken)).GetArrayLength());
    }

    [Fact]
    public async Task Username_matching_ignores_case_and_surrounding_space()
    {
        using var app = new TestApp();
        var account = new TestAccount { Username = "Bob" };
        await account.Register(app.Api);
        var (_, _, start) = await account.Start(app.Api, "  bOB ");
        Assert.Equal(account.AccountId, start.GetProperty("accountId").GetString());
    }

    [Fact]
    public async Task Bad_signature_is_401_and_burns_the_challenge()
    {
        using var app = new TestApp();
        var account = new TestAccount();
        await account.Register(app.Api);

        // Signed by a different key.
        var (challengeId, nonce, _) = await account.Start(app.Api);
        await app.Api.Error(HttpMethod.Post, "/auth/finish", 401, "bad_signature",
            new { challengeId, signature = account.Sign(nonce, TestAccount.NewKey()), deviceName = "x" });
        // The same challenge cannot be retried, even with the right signature.
        await app.Api.Error(HttpMethod.Post, "/auth/finish", 401, "bad_signature",
            new { challengeId, signature = account.Sign(nonce), deviceName = "x" });

        // Right key, wrong message (nonce without the domain prefix is not what 1.4 signs).
        var (challenge2, nonce2, _) = await account.Start(app.Api);
        var flipped = (byte[])nonce2.Clone();
        flipped[0] ^= 1;
        await app.Api.Error(HttpMethod.Post, "/auth/finish", 401, "bad_signature",
            new { challengeId = challenge2, signature = account.Sign(flipped), deviceName = "x" });

        // Wrong length, unknown challenge.
        var (challenge3, _, _) = await account.Start(app.Api);
        await app.Api.Error(HttpMethod.Post, "/auth/finish", 401, "bad_signature",
            new { challengeId = challenge3, signature = T.B64(new byte[10]), deviceName = "x" });
        await app.Api.Error(HttpMethod.Post, "/auth/finish", 401, "bad_signature",
            new { challengeId = T.NewId(), signature = account.Sign(nonce), deviceName = "x" });
    }

    [Fact]
    public async Task Challenge_expires_after_60_seconds()
    {
        using var app = new TestApp();
        var account = new TestAccount();
        await account.Register(app.Api);

        var (challengeId, nonce, _) = await account.Start(app.Api);
        app.Time.Advance(TimeSpan.FromSeconds(61));
        await app.Api.Error(HttpMethod.Post, "/auth/finish", 401, "bad_signature",
            new { challengeId, signature = account.Sign(nonce), deviceName = "x" });

        // Just inside the window is fine.
        var (challenge2, nonce2, _) = await account.Start(app.Api);
        app.Time.Advance(TimeSpan.FromSeconds(59));
        await app.Api.PostJson("/auth/finish", new { challengeId = challenge2, signature = account.Sign(nonce2), deviceName = "x" });
    }

    [Fact]
    public async Task Challenge_is_single_use()
    {
        using var app = new TestApp();
        var account = new TestAccount();
        await account.Register(app.Api);

        var (challengeId, nonce, _) = await account.Start(app.Api);
        var body = new { challengeId, signature = account.Sign(nonce), deviceName = "x" };
        await app.Api.PostJson("/auth/finish", body);
        await app.Api.Error(HttpMethod.Post, "/auth/finish", 401, "bad_signature", body);
    }

    [Fact]
    public async Task Failed_logins_are_rate_limited_to_five_per_minute()
    {
        using var app = new TestApp();
        var account = new TestAccount();
        await account.Register(app.Api);

        for (var i = 0; i < 5; i++)
        {
            var (challengeId, nonce, _) = await account.Start(app.Api);
            await app.Api.Error(HttpMethod.Post, "/auth/finish", 401, "bad_signature",
                new { challengeId, signature = account.Sign(nonce, TestAccount.NewKey()), deviceName = "x" });
            app.Time.Advance(TimeSpan.FromSeconds(1));
        }

        // The sixth attempt is refused even though it is correct.
        var (goodChallenge, goodNonce, _) = await account.Start(app.Api);
        var good = new { challengeId = goodChallenge, signature = account.Sign(goodNonce), deviceName = "x" };
        using (var blocked = await app.Api.Post("/auth/finish", good))
        {
            Assert.Equal(429, (int)blocked.StatusCode);
            Assert.True(blocked.Headers.Contains("Retry-After"));
            var error = JsonDocument.Parse(await blocked.Content.ReadAsStringAsync()).RootElement;
            Assert.Equal("rate_limited", error.GetProperty("error").GetString());
        }

        // Still blocked until the oldest failure is a minute old (5 s elapsed so far)...
        app.Time.Advance(TimeSpan.FromSeconds(50));
        await app.Api.Error(HttpMethod.Post, "/auth/finish", 429, "rate_limited", good);

        // ...then attempts are accepted again. The blocked request did not consume the challenge,
        // but it has expired by now, so start over.
        app.Time.Advance(TimeSpan.FromSeconds(6));
        await account.Login(app.Api);
    }

    [Fact]
    public async Task Successful_logins_are_not_rate_limited()
    {
        using var app = new TestApp();
        var account = new TestAccount();
        await account.Register(app.Api);
        for (var i = 0; i < 8; i++) await account.Login(app.Api, $"device {i}");
    }

    [Fact]
    public async Task Unknown_username_gets_a_stable_fake_shaped_like_a_real_response()
    {
        using var app = new TestApp();
        var account = new TestAccount();

        // Before any account exists the endpoint already answers.
        var early = (await account.Start(app.Api, "nobody")).Body;
        await account.Register(app.Api);

        var real = (await account.Start(app.Api)).Body;
        var fake1 = (await account.Start(app.Api, "nobody")).Body;
        var fake2 = (await account.Start(app.Api, "nobody")).Body;
        var other = (await account.Start(app.Api, "somebody-else")).Body;

        foreach (var fake in new[] { early, fake1, fake2, other })
        {
            Assert.Equal(T.Names(real), T.Names(fake));
            Assert.True(T.IsId(fake.GetProperty("accountId").GetString()));
            Assert.Equal(16, T.FromB64(fake.GetProperty("kdfSalt").GetString()!).Length);
            Assert.Equal(32, T.FromB64(fake.GetProperty("nonce").GetString()!).Length);
            Assert.True(T.IsId(fake.GetProperty("challengeId").GetString()));
            Assert.Equal(real.GetProperty("kdfParams").GetRawText(), fake.GetProperty("kdfParams").GetRawText());
        }

        // Deterministic per username...
        foreach (var field in new[] { "accountId", "kdfSalt" })
        {
            Assert.Equal(early.GetProperty(field).GetString(), fake1.GetProperty(field).GetString());
            Assert.Equal(fake1.GetProperty(field).GetString(), fake2.GetProperty(field).GetString());
            Assert.NotEqual(fake1.GetProperty(field).GetString(), other.GetProperty(field).GetString());
            Assert.NotEqual(fake1.GetProperty(field).GetString(), real.GetProperty(field).GetString());
        }

        // ...while the challenge is fresh every time, as for a real account.
        Assert.NotEqual(fake1.GetProperty("challengeId").GetString(), fake2.GetProperty("challengeId").GetString());
        Assert.NotEqual(fake1.GetProperty("nonce").GetString(), fake2.GetProperty("nonce").GetString());

        // A fake challenge can never be finished, not even by the real key.
        await app.Api.Error(HttpMethod.Post, "/auth/finish", 401, "bad_signature", new
        {
            challengeId = fake1.GetProperty("challengeId").GetString(),
            signature = account.Sign(T.FromB64(fake1.GetProperty("nonce").GetString()!)),
            deviceName = "x",
        });
    }

    public static TheoryData<string, string> AuthenticatedRoutes()
    {
        var id = "00112233445566778899aabbccddeeff";
        return new TheoryData<string, string>
        {
            { "GET", "/devices" },
            { "DELETE", $"/devices/{id}" },
            { "POST", "/account/rekey" },
            { "GET", "/notebooks" },
            { "PUT", $"/notebooks/{id}" },
            { "DELETE", $"/notebooks/{id}" },
            { "GET", "/docs" },
            { "POST", $"/docs/{id}/updates" },
            { "GET", $"/docs/{id}/snapshot" },
            { "PUT", $"/docs/{id}/snapshot" },
            { "DELETE", $"/docs/{id}" },
            { "GET", "/events" },
        };
    }

    [Theory]
    [MemberData(nameof(AuthenticatedRoutes))]
    public async Task Authenticated_routes_require_a_valid_bearer_token(string method, string path)
    {
        using var app = new TestApp();
        var (_, token) = await new TestAccount().Register(app.Api);
        var m = new HttpMethod(method);
        object? body = method is "POST" or "PUT" ? new { } : null;

        await app.Api.Error(m, path, 401, "unauthorized", body);                                   // no header
        await app.Api.Error(m, path, 401, "unauthorized", body, token: "nonsense");                 // not a token
        await app.Api.Error(m, path, 401, "unauthorized", body, token: T.B64(T.Blob(32)));          // well-formed, unknown
        await app.Api.Error(m, path, 401, "unauthorized", body, token: token[..^1] + (token[^1] == 'A' ? 'B' : 'A'));

        using var basic = new HttpRequestMessage(m, "/api/v1" + path);
        basic.Headers.TryAddWithoutValidation("Authorization", "Basic " + token);
        using var response = await app.Api.Http.SendAsync(basic);
        Assert.Equal(401, (int)response.StatusCode);
        Assert.Contains("Bearer", response.Headers.WwwAuthenticate.ToString());

        // With the real token the request gets past authentication (whatever else it then says).
        using var authed = await app.Api.Send(m, path, body, token);
        Assert.NotEqual(401, (int)authed.StatusCode);
    }

    [Fact]
    public async Task Unknown_routes_return_the_protocol_error_shape()
    {
        using var app = new TestApp();
        await app.Api.Error(HttpMethod.Get, "/nope", 404, "not_found");
    }

    [Fact]
    public async Task Devices_can_be_listed_and_revoked()
    {
        using var app = new TestApp();
        var account = new TestAccount();
        var (device1, token1) = await account.Register(app.Api, "desktop");
        var (device2, token2, _) = await account.Login(app.Api, "laptop");

        var list = await app.Api.GetJson("/devices", token1);
        Assert.Equal(2, list.GetArrayLength());
        foreach (var d in list.EnumerateArray())
        {
            Assert.Equal(["createdAt", "current", "deviceId", "lastSeenAt", "name"], T.Names(d));
            Assert.True(DateTimeOffset.TryParse(d.GetProperty("createdAt").GetString(), out _));
            Assert.True(DateTimeOffset.TryParse(d.GetProperty("lastSeenAt").GetString(), out _));
        }

        JsonElement Find(JsonElement devices, string id) => devices.EnumerateArray().Single(d => d.GetProperty("deviceId").GetString() == id);
        Assert.Equal("desktop", Find(list, device1).GetProperty("name").GetString());
        Assert.Equal("laptop", Find(list, device2).GetProperty("name").GetString());
        Assert.True(Find(list, device1).GetProperty("current").GetBoolean());
        Assert.False(Find(list, device2).GetProperty("current").GetBoolean());

        var fromLaptop = await app.Api.GetJson("/devices", token2);
        Assert.True(Find(fromLaptop, device2).GetProperty("current").GetBoolean());

        // lastSeenAt moves when the device is used later.
        var seenBefore = Find(list, device2).GetProperty("lastSeenAt").GetString();
        app.Time.Advance(TimeSpan.FromMinutes(5));
        await app.Api.GetJson("/notebooks", token2);
        Assert.NotEqual(seenBefore, Find(await app.Api.GetJson("/devices", token1), device2).GetProperty("lastSeenAt").GetString());

        // Revoke the laptop: its token dies, the desktop's does not.
        await app.Api.DeleteJson($"/devices/{device2}", token1, expect: 204);
        await app.Api.Error(HttpMethod.Get, "/devices", 401, "unauthorized", token: token2);
        Assert.Equal(device1, Assert.Single((await app.Api.GetJson("/devices", token1)).EnumerateArray()).GetProperty("deviceId").GetString());

        await app.Api.Error(HttpMethod.Delete, $"/devices/{device2}", 404, "unknown_device", token: token1);
        await app.Api.Error(HttpMethod.Delete, "/devices/not-an-id", 400, "invalid_request", token: token1);
    }

    [Fact]
    public async Task Logging_in_again_with_a_device_id_keeps_the_device_and_replaces_its_token()
    {
        using var app = new TestApp();
        var account = new TestAccount();
        var (device1, token1) = await account.Register(app.Api, "desktop");

        var (again, token2, _) = await account.Login(app.Api, "desktop renamed", deviceId: device1);
        Assert.Equal(device1, again);
        await app.Api.Error(HttpMethod.Get, "/devices", 401, "unauthorized", token: token1);
        var only = Assert.Single((await app.Api.GetJson("/devices", token2)).EnumerateArray());
        Assert.Equal("desktop renamed", only.GetProperty("name").GetString());
    }

    [Fact]
    public async Task Rekey_replaces_credentials_and_revokes_other_devices()
    {
        using var app = new TestApp();
        var account = new TestAccount();
        var (device1, token1) = await account.Register(app.Api, "desktop");
        var (_, token2, _) = await account.Login(app.Api, "laptop");
        var oldKey = account.Key;

        await app.Api.Error(HttpMethod.Post, "/account/rekey", 400, "invalid_request", new { kdfSalt = "x" }, token1);

        await app.Api.PostJson("/account/rekey", account.Rekey(), token1, expect: 204);

        // Caller keeps its session; the other device is gone.
        var only = Assert.Single((await app.Api.GetJson("/devices", token1)).EnumerateArray());
        Assert.Equal(device1, only.GetProperty("deviceId").GetString());
        await app.Api.Error(HttpMethod.Get, "/devices", 401, "unauthorized", token: token2);

        // auth/start now hands out the new salt; the old key no longer logs in, the new one does.
        var (challengeId, nonce, start) = await account.Start(app.Api);
        Assert.Equal(T.B64(account.KdfSalt), start.GetProperty("kdfSalt").GetString());
        Assert.Equal(account.AccountId, start.GetProperty("accountId").GetString());
        await app.Api.Error(HttpMethod.Post, "/auth/finish", 401, "bad_signature",
            new { challengeId, signature = account.Sign(nonce, oldKey), deviceName = "laptop" });

        var (_, _, login) = await account.Login(app.Api, "laptop");
        Assert.Equal(T.B64(account.WrappedVaultKey), login.GetProperty("wrappedVaultKey").GetString());
    }
}
