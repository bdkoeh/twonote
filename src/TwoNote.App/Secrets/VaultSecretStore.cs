using TwoNote.App.Logic;
using TwoNote.Core;
using Windows.Security.Credentials;

namespace TwoNote.App.Secrets;

/// <summary>
/// An <see cref="ISecretStore"/> over the Windows Credential Locker (<see cref="PasswordVault"/>), which also
/// works for an unpackaged app and needs no account beyond the Windows sign-in. Entries are kept per profile:
/// resource = the profile's scope, user name = the secret's name.
///
/// The locker lives in another process. Calling it from the UI thread makes that thread pump messages while it
/// waits, and WinUI kills the process when that happens inside one of its own callbacks (a Loaded or Click
/// handler). So every call is made on a pool thread, and a UI thread that asks waits for it without pumping.
/// </summary>
internal sealed class VaultSecretStore(string scope) : ISecretStore
{
    private readonly Lock _gate = new();

    public string? Get(string name) => OffUiThread(() =>
    {
        lock (_gate)
        {
            try
            {
                var credential = new PasswordVault().Retrieve(scope, name);
                credential.RetrievePassword();
                return credential.Password;
            }
            catch (Exception)
            {
                return null; // "element not found" is reported as an exception
            }
        }
    });

    public void Set(string name, string value) => OffUiThread(() =>
    {
        lock (_gate)
        {
            var vault = new PasswordVault();
            RemoveCore(vault, name);
            vault.Add(new PasswordCredential(scope, name, value));
            return true;
        }
    });

    public void Remove(string name) => OffUiThread(() =>
    {
        lock (_gate)
        {
            RemoveCore(new PasswordVault(), name);
            return true;
        }
    });

    /// <summary>Removes every entry of this profile.</summary>
    public void Clear() => OffUiThread(() =>
    {
        lock (_gate)
        {
            try
            {
                var vault = new PasswordVault();
                foreach (var credential in vault.FindAllByResource(scope))
                {
                    vault.Remove(credential);
                }
            }
            catch (Exception)
            {
                // nothing stored under this scope
            }

            return true;
        }
    });

    private void RemoveCore(PasswordVault vault, string name)
    {
        try
        {
            vault.Remove(vault.Retrieve(scope, name));
        }
        catch (Exception)
        {
            // not there
        }
    }

    [System.Runtime.InteropServices.DllImport("kernel32.dll", SetLastError = true)]
    private static extern uint WaitForSingleObject(nint handle, uint milliseconds);

    private static T OffUiThread<T>(Func<T> operation)
    {
        if (Thread.CurrentThread.GetApartmentState() != ApartmentState.STA)
        {
            return operation();
        }

        T result = default!;
        Exception? error = null;
        using var done = new ManualResetEvent(false);
        ThreadPool.UnsafeQueueUserWorkItem(
            _ =>
            {
                try
                {
                    result = operation();
                }
                catch (Exception e)
                {
                    error = e;
                }
                finally
                {
                    done.Set();
                }
            },
            null);

        // Not WaitOne: a managed wait on an STA thread pumps messages, which is exactly what must not happen.
        var handle = done.SafeWaitHandle;
        var added = false;
        try
        {
            handle.DangerousAddRef(ref added);
            _ = WaitForSingleObject(handle.DangerousGetHandle(), 0xFFFFFFFF);
        }
        finally
        {
            if (added)
            {
                handle.DangerousRelease();
            }
        }

        return error is null ? result : throw new InvalidOperationException("The Windows Credential Locker call failed.", error);
    }
}
/// <summary>Chooses and creates the secret store of a profile.</summary>
internal static class SecretStores
{
    public const string Vault = "vault";
    public const string Dpapi = "dpapi";

    /// <summary>
    /// The store this profile uses. The first time, the Credential Locker is tried with a throw-away entry; if
    /// that does not round-trip, the profile uses the DPAPI file instead. The choice is remembered in the
    /// settings so that the secrets are always looked for where they were put.
    /// </summary>
    public static ISecretStore Create(AppPaths paths, AppSettings settings)
    {
        if (settings.SecretStore is not (Vault or Dpapi))
        {
            settings.SecretStore = ProbeVault(paths.SecretScope) ? Vault : Dpapi;
            settings.Save();
        }

        return settings.SecretStore == Vault
            ? new VaultSecretStore(paths.SecretScope)
            : new DpapiSecretStore(paths.DpapiSecretsPath, paths.SecretScope);
    }

    /// <summary>Removes everything either kind of store may hold for the profile.</summary>
    public static void Wipe(AppPaths paths)
    {
        try
        {
            new VaultSecretStore(paths.SecretScope).Clear();
        }
        catch (Exception)
        {
            // the locker is not available here
        }

        new DpapiSecretStore(paths.DpapiSecretsPath, paths.SecretScope).Clear();
    }

    /// <summary>True when the Credential Locker stores and returns a value in this process.</summary>
    public static bool ProbeVault(string scope)
    {
        try
        {
            var store = new VaultSecretStore(scope);
            var value = Guid.NewGuid().ToString("N");
            store.Set("probe", value);
            var ok = store.Get("probe") == value;
            store.Remove("probe");
            return ok && store.Get("probe") is null;
        }
        catch (Exception)
        {
            return false;
        }
    }
}
