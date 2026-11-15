using System.ComponentModel;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using TwoNote.Core;

namespace TwoNote.App.Secrets;

/// <summary>
/// An <see cref="ISecretStore"/> over one file protected with DPAPI (CryptProtectData, current-user scope): only
/// the Windows account that wrote it can read it, on this PC. Used where the Credential Locker is not available.
/// The plaintext exists only in memory.
/// </summary>
public sealed class DpapiSecretStore : ISecretStore
{
    private readonly string _path;
    private readonly byte[] _entropy;
    private readonly Lock _gate = new();

    /// <param name="path">The protected file.</param>
    /// <param name="scope">Mixed into the protection, so a file copied to another profile does not open.</param>
    public DpapiSecretStore(string path, string scope)
    {
        _path = path;
        _entropy = Encoding.UTF8.GetBytes("twonote/secret-store/" + scope);
    }

    /// <inheritdoc />
    public string? Get(string name)
    {
        lock (_gate)
        {
            return Load().GetValueOrDefault(name);
        }
    }

    /// <inheritdoc />
    public void Set(string name, string value)
    {
        lock (_gate)
        {
            var values = Load();
            values[name] = value;
            Save(values);
        }
    }

    /// <inheritdoc />
    public void Remove(string name)
    {
        lock (_gate)
        {
            var values = Load();
            if (values.Remove(name))
            {
                Save(values);
            }
        }
    }

    /// <summary>Deletes the file.</summary>
    public void Clear()
    {
        lock (_gate)
        {
            if (File.Exists(_path))
            {
                File.Delete(_path);
            }
        }
    }

    private Dictionary<string, string> Load()
    {
        if (!File.Exists(_path))
        {
            return [];
        }

        byte[]? plain = null;
        try
        {
            plain = Unprotect(File.ReadAllBytes(_path), _entropy);
            return JsonSerializer.Deserialize<Dictionary<string, string>>(plain) ?? [];
        }
        catch (Exception e) when (e is Win32Exception or JsonException)
        {
            return []; // written by another Windows account or damaged: as good as empty
        }
        finally
        {
            if (plain is not null)
            {
                CryptographicOperations.ZeroMemory(plain);
            }
        }
    }

    private void Save(Dictionary<string, string> values)
    {
        var plain = JsonSerializer.SerializeToUtf8Bytes(values);
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(_path)!);
            var temp = _path + ".tmp";
            File.WriteAllBytes(temp, Protect(plain, _entropy));
            File.Move(temp, _path, overwrite: true);
        }
        finally
        {
            CryptographicOperations.ZeroMemory(plain);
        }
    }

    // ---- DPAPI ------------------------------------------------------------------------------------------

    private const int CryptProtectUiForbidden = 0x1;

    [StructLayout(LayoutKind.Sequential)]
    private struct DataBlob
    {
        public int Size;
        public nint Data;
    }

    [DllImport("crypt32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    private static extern bool CryptProtectData(
        ref DataBlob dataIn, string? description, ref DataBlob entropy, nint reserved, nint prompt, int flags, out DataBlob dataOut);

    [DllImport("crypt32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    private static extern bool CryptUnprotectData(
        ref DataBlob dataIn, nint description, ref DataBlob entropy, nint reserved, nint prompt, int flags, out DataBlob dataOut);

    [DllImport("kernel32.dll")]
    private static extern nint LocalFree(nint handle);

    private static byte[] Protect(byte[] plain, byte[] entropy) => Transform(plain, entropy, protect: true);

    private static byte[] Unprotect(byte[] cipher, byte[] entropy) => Transform(cipher, entropy, protect: false);

    private static byte[] Transform(byte[] input, byte[] entropy, bool protect)
    {
        var inHandle = GCHandle.Alloc(input, GCHandleType.Pinned);
        var entropyHandle = GCHandle.Alloc(entropy, GCHandleType.Pinned);
        try
        {
            var dataIn = new DataBlob { Size = input.Length, Data = inHandle.AddrOfPinnedObject() };
            var dataEntropy = new DataBlob { Size = entropy.Length, Data = entropyHandle.AddrOfPinnedObject() };
            DataBlob dataOut;
            var ok = protect
                ? CryptProtectData(ref dataIn, null, ref dataEntropy, 0, 0, CryptProtectUiForbidden, out dataOut)
                : CryptUnprotectData(ref dataIn, 0, ref dataEntropy, 0, 0, CryptProtectUiForbidden, out dataOut);
            if (!ok)
            {
                throw new Win32Exception(Marshal.GetLastWin32Error());
            }

            try
            {
                var result = new byte[dataOut.Size];
                Marshal.Copy(dataOut.Data, result, 0, dataOut.Size);
                return result;
            }
            finally
            {
                Marshal.Copy(new byte[dataOut.Size], 0, dataOut.Data, dataOut.Size); // wipe the native copy
                LocalFree(dataOut.Data);
            }
        }
        finally
        {
            inHandle.Free();
            entropyHandle.Free();
        }
    }
}
