using System.Text.Json.Serialization;

namespace TwoNote.Core.Crypto;

/// <summary>
/// The <c>kdfParams</c> object of PROTOCOL.md 1.2, e.g.
/// <c>{ "alg": "argon2id13", "ops": 3, "memKiB": 65536 }</c>. Serialises with those names.
/// </summary>
public sealed record KdfParams(
    [property: JsonPropertyName("alg")] string Alg,
    [property: JsonPropertyName("ops")] int Ops,
    [property: JsonPropertyName("memKiB")] int MemKiB)
{
    /// <summary>The only algorithm in protocol v1: Argon2id version 1.3.</summary>
    public const string Argon2id13 = "argon2id13";

    /// <summary>Lowest accepted pass count.</summary>
    public const int MinOps = 1;

    /// <summary>Highest accepted pass count.</summary>
    public const int MaxOps = 16;

    /// <summary>Lowest accepted memory size (8 MiB).</summary>
    public const int MinMemKiB = 8 * 1024;

    /// <summary>Highest accepted memory size (1 GiB), so a hostile server cannot make a client allocate without bound.</summary>
    public const int MaxMemKiB = 1024 * 1024;

    /// <summary>The parameters new accounts use: 3 passes over 64 MiB.</summary>
    public static KdfParams Default { get; } = new(Argon2id13, 3, 65536);

    /// <summary>True when this library can and will run a derivation with these parameters.</summary>
    [JsonIgnore]
    public bool IsSupported =>
        Alg == Argon2id13
        && Ops is >= MinOps and <= MaxOps
        && MemKiB is >= MinMemKiB and <= MaxMemKiB;
}
