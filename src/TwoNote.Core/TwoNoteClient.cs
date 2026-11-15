using TwoNote.Core.Api;
using TwoNote.Core.Crypto;
using TwoNote.Core.Documents;
using TwoNote.Core.Storage;
using TwoNote.Core.Sync;

namespace TwoNote.Core;

/// <summary>Where a device stands with its account.</summary>
public enum ClientState
{
    /// <summary>No account on this device yet: register or enrol.</summary>
    NoAccount,

    /// <summary>An account is enrolled but the keys are not in memory: unlock with the password.</summary>
    Locked,

    /// <summary>Notebooks can be opened, edited and synced.</summary>
    Unlocked,
}

/// <summary>The password or the Secret Key is wrong (they cannot be told apart, by design).</summary>
public sealed class WrongCredentialsException : Exception
{
    /// <summary>Creates the exception.</summary>
    public WrongCredentialsException()
        : base("The password or the Secret Key is not correct.")
    {
    }
}

/// <summary>The non-secret identity of the enrolled account on this device.</summary>
public sealed record AccountInfo(string Username, string AccountId, string DeviceId, string DeviceName);

/// <summary>
/// One device's view of a TwoNote account: account flows (register, enrol, unlock, lock,
/// password change), the notebooks and pages, and the sync engine. One instance per local
/// database. Works with the server unreachable once enrolled; only register, enrol, password
/// change and sign-in need the network.
/// </summary>
public sealed class TwoNoteClient : IAsyncDisposable
{
    private readonly ClientOptions _options;
    private readonly LocalStore _store;
    private readonly ISecretStore _secrets;
    private readonly SemaphoreSlim _accountLock = new(1, 1);
    private Vault? _vault;
    private bool _disposed;

    private TwoNoteClient(ClientOptions options, LocalStore store)
    {
        _options = options;
        _store = store;
        _secrets = options.SecretStore;
        Api = new TwoNoteApi(options.ServerUrl, options.HttpHandler, options.HttpTimeout) { Token = _secrets.Get(SecretNames.SessionToken) };
        Sync = new SyncEngine(Api, store, options);
    }

    /// <summary>Opens the local database (creating it if needed). No network access happens here.</summary>
    public static TwoNoteClient Open(ClientOptions options)
    {
        ArgumentNullException.ThrowIfNull(options);
        if (!options.KdfParams.IsSupported)
        {
            throw new ArgumentException("Unsupported KDF parameters.", nameof(options));
        }

        var store = LocalStore.Open(options.DatabasePath);
        try
        {
            return new TwoNoteClient(options, store);
        }
        catch
        {
            store.Dispose();
            throw;
        }
    }

    /// <summary>Raised when <see cref="State"/> changes.</summary>
    public event Action<ClientState>? StateChanged;

    /// <summary>The typed HTTP client, for calls the UI makes directly (server status, device list, revoking a device).</summary>
    public TwoNoteApi Api { get; }

    /// <summary>The sync engine. Usable while <see cref="State"/> is <see cref="ClientState.Unlocked"/>.</summary>
    public SyncEngine Sync { get; }

    /// <summary>Where this device stands.</summary>
    public ClientState State =>
        Volatile.Read(ref _vault) is not null ? ClientState.Unlocked
        : _store.GetAccount() is not null ? ClientState.Locked
        : ClientState.NoAccount;

    /// <summary>The enrolled account, or null.</summary>
    public AccountInfo? Account =>
        _store.GetAccount() is { } a ? new AccountInfo(a.Username, a.AccountId, a.DeviceId, a.DeviceName) : null;

    // ---- account flows --------------------------------------------------------------------

    /// <summary>
    /// Creates the account on a fresh server from this, its first, device: generates the Secret
    /// Key, account id and salt, derives the keys, creates and wraps the vault key, registers.
    /// Leaves the client unlocked and returns the Secret Key in its display form, to be shown
    /// once for the Emergency Kit (it is also kept in the secret store).
    /// </summary>
    /// <exception cref="ApiException"><c>registration_closed</c> when the server already has an account.</exception>
    public async Task<string> RegisterAsync(string username, string password, string deviceName, CancellationToken ct = default)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(username);
        ArgumentNullException.ThrowIfNull(password);
        ArgumentException.ThrowIfNullOrWhiteSpace(deviceName);
        await _accountLock.WaitAsync(ct).ConfigureAwait(false);
        try
        {
            RequireState(ClientState.NoAccount);
            using var secretKey = SecretKey.Generate();
            var accountId = WireEncoding.NewId();
            var salt = KeyDerivation.NewSalt();
            using var keys = await DeriveAsync(password, secretKey, accountId, salt, _options.KdfParams).ConfigureAwait(false);
            var vaultKey = KeyHierarchy.CreateVaultKey();
            try
            {
                var wrapped = KeyHierarchy.WrapVaultKey(keys.UnlockKey, accountId, vaultKey.Span);
                var display = secretKey.Format();

                // The Secret Key is stored before the server learns of the account: once the
                // registration exists, losing the key would lose the account.
                _secrets.Set(SecretNames.SecretKey, display);
                DeviceSession session;
                try
                {
                    session = await Api.RegisterAsync(
                        new RegisterRequest(username.Trim(), WireEncoding.IdToHex(accountId), salt, _options.KdfParams,
                            keys.AuthPublicKey.ToArray(), wrapped, deviceName.Trim()), ct).ConfigureAwait(false);
                }
                catch (ApiException)
                {
                    _secrets.Remove(SecretNames.SecretKey); // the server refused: no account uses this key
                    throw;
                }

                _secrets.Set(SecretNames.SessionToken, session.Token);
                Api.Token = session.Token;
                _store.SaveAccount(new AccountRecord(
                    username.Trim(), WireEncoding.IdToHex(accountId), session.DeviceId, deviceName.Trim(), salt, _options.KdfParams, wrapped));
                BecomeUnlocked(vaultKey, session.DeviceId);
                return display;
            }
            catch
            {
                if (Volatile.Read(ref _vault) is null)
                {
                    vaultKey.Dispose();
                }

                throw;
            }
        }
        finally
        {
            _accountLock.Release();
        }
    }

    /// <summary>
    /// Adds this device to an existing account: username, password and the Secret Key from
    /// another device or the Emergency Kit. Leaves the client unlocked; the first
    /// <see cref="SyncEngine.SyncNowAsync"/> then downloads everything.
    /// </summary>
    /// <exception cref="FormatException"><paramref name="secretKey"/> is not a well-formed Secret Key.</exception>
    /// <exception cref="WrongCredentialsException">The server rejected the login.</exception>
    public async Task EnrolAsync(string username, string password, string secretKey, string deviceName, CancellationToken ct = default)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(username);
        ArgumentNullException.ThrowIfNull(password);
        ArgumentNullException.ThrowIfNull(secretKey);
        ArgumentException.ThrowIfNullOrWhiteSpace(deviceName);
        await _accountLock.WaitAsync(ct).ConfigureAwait(false);
        try
        {
            RequireState(ClientState.NoAccount);
            using var key = SecretKey.Parse(secretKey);
            var (challenge, result, vaultKey) = await LoginAsync(username.Trim(), password, key, deviceName.Trim(), deviceId: null, ct).ConfigureAwait(false);
            try
            {
                _secrets.Set(SecretNames.SecretKey, key.Format());
                _secrets.Set(SecretNames.SessionToken, result.Token);
                Api.Token = result.Token;
                _store.SaveAccount(new AccountRecord(
                    username.Trim(), challenge.AccountId, result.DeviceId, deviceName.Trim(), challenge.KdfSalt, challenge.KdfParams, result.WrappedVaultKey));
                BecomeUnlocked(vaultKey, result.DeviceId);
            }
            catch
            {
                if (Volatile.Read(ref _vault) is null)
                {
                    vaultKey.Dispose();
                }

                throw;
            }
        }
        finally
        {
            _accountLock.Release();
        }
    }

    /// <summary>
    /// Unlocks from local state only - no network: derives the keys from the password and the
    /// stored Secret Key and opens the locally stored wrapped vault key.
    /// </summary>
    /// <exception cref="WrongCredentialsException">The password is wrong (or the Secret Key in the secret store is not this account's).</exception>
    public async Task UnlockAsync(string password, CancellationToken ct = default)
    {
        ArgumentNullException.ThrowIfNull(password);
        await _accountLock.WaitAsync(ct).ConfigureAwait(false);
        try
        {
            RequireState(ClientState.Locked);
            var account = _store.GetAccount()!;
            var vaultKey = await OpenLocalVaultKeyAsync(account, password).ConfigureAwait(false);
            Api.Token = _secrets.Get(SecretNames.SessionToken);
            BecomeUnlocked(vaultKey, account.DeviceId);
        }
        finally
        {
            _accountLock.Release();
        }
    }

    /// <summary>Stops syncing, closes every open document and wipes the keys from memory.</summary>
    public async Task LockAsync()
    {
        await _accountLock.WaitAsync().ConfigureAwait(false);
        try
        {
            await LockCoreAsync().ConfigureAwait(false);
        }
        finally
        {
            _accountLock.Release();
        }
    }

    /// <summary>
    /// Changes the password: re-wraps the vault key under keys derived from the new password and
    /// a new salt and replaces the credentials on the server (<c>POST /account/rekey</c>). The
    /// Secret Key and all data stay as they are. Every other device is signed out and must call
    /// <see cref="SignInAgainAsync"/> with the new password.
    /// </summary>
    /// <exception cref="WrongCredentialsException"><paramref name="currentPassword"/> is wrong.</exception>
    public async Task ChangePasswordAsync(string currentPassword, string newPassword, CancellationToken ct = default)
    {
        ArgumentNullException.ThrowIfNull(currentPassword);
        ArgumentNullException.ThrowIfNull(newPassword);
        await _accountLock.WaitAsync(ct).ConfigureAwait(false);
        try
        {
            RequireState(ClientState.Unlocked);
            var account = _store.GetAccount()!;
            using (await OpenLocalVaultKeyAsync(account, currentPassword).ConfigureAwait(false))
            {
                // Opening it proves the caller knows the current password.
            }

            using var secretKey = LoadSecretKey();
            var accountId = WireEncoding.IdFromHex(account.AccountId);
            var salt = KeyDerivation.NewSalt();
            using var keys = await DeriveAsync(newPassword, secretKey, accountId, salt, _options.KdfParams).ConfigureAwait(false);
            var wrapped = KeyHierarchy.WrapVaultKey(keys.UnlockKey, accountId, _vault!.VaultKey.Span);
            await Api.RekeyAsync(new RekeyRequest(salt, _options.KdfParams, keys.AuthPublicKey.ToArray(), wrapped), ct).ConfigureAwait(false);
            _store.SaveAccount(account with { KdfSalt = salt, KdfParams = _options.KdfParams, WrappedVaultKey = wrapped });
        }
        finally
        {
            _accountLock.Release();
        }
    }

    /// <summary>
    /// Logs this already enrolled device in again, keeping its device id: needed when the server
    /// answers 401 (<see cref="SyncState.AuthRequired"/>) because the token was revoked or the
    /// password was changed on another device. Fetches the current salt and wrapped vault key,
    /// so afterwards <paramref name="password"/> is also the one that unlocks locally. Leaves
    /// the client unlocked.
    /// </summary>
    /// <exception cref="WrongCredentialsException">The server rejected the login.</exception>
    public async Task SignInAgainAsync(string password, CancellationToken ct = default)
    {
        ArgumentNullException.ThrowIfNull(password);
        await _accountLock.WaitAsync(ct).ConfigureAwait(false);
        try
        {
            if (State == ClientState.NoAccount)
            {
                throw new InvalidOperationException("No account is enrolled on this device.");
            }

            var account = _store.GetAccount()!;
            using var secretKey = LoadSecretKey();
            var (challenge, result, vaultKey) =
                await LoginAsync(account.Username, password, secretKey, account.DeviceName, account.DeviceId, ct).ConfigureAwait(false);
            var keep = false;
            try
            {
                if (challenge.AccountId != account.AccountId || result.DeviceId != account.DeviceId)
                {
                    throw new ProtocolViolationException("The server answered for a different account or device.");
                }

                _secrets.Set(SecretNames.SessionToken, result.Token);
                Api.Token = result.Token;
                _store.SaveAccount(account with { KdfSalt = challenge.KdfSalt, KdfParams = challenge.KdfParams, WrappedVaultKey = result.WrappedVaultKey });
                if (Volatile.Read(ref _vault) is null)
                {
                    BecomeUnlocked(vaultKey, account.DeviceId);
                    keep = true;
                }

                Sync.RequestSync(); // a loop that was waiting for credentials carries on
            }
            finally
            {
                if (!keep)
                {
                    vaultKey.Dispose();
                }
            }
        }
        finally
        {
            _accountLock.Release();
        }
    }

    /// <summary>
    /// Checks a password against the locally stored wrapped vault key, without the network and
    /// without changing any state. For re-asking the password before something sensitive is shown.
    /// </summary>
    public async Task<bool> VerifyPasswordAsync(string password, CancellationToken ct = default)
    {
        ArgumentNullException.ThrowIfNull(password);
        await _accountLock.WaitAsync(ct).ConfigureAwait(false);
        try
        {
            if (State == ClientState.NoAccount)
            {
                throw new InvalidOperationException("No account is enrolled on this device.");
            }

            try
            {
                using var vaultKey = await OpenLocalVaultKeyAsync(_store.GetAccount()!, password).ConfigureAwait(false);
                return true;
            }
            catch (WrongCredentialsException)
            {
                return false;
            }
        }
        finally
        {
            _accountLock.Release();
        }
    }

    /// <summary>
    /// Renames this device. The protocol renames a device when it logs in again under its id
    /// (PROTOCOL.md section 3, "Devices"), so this needs the password and the server. The
    /// session token is replaced; everything else stays as it is.
    /// </summary>
    /// <exception cref="WrongCredentialsException">The server rejected the login.</exception>
    public async Task RenameDeviceAsync(string password, string newName, CancellationToken ct = default)
    {
        ArgumentNullException.ThrowIfNull(password);
        ArgumentException.ThrowIfNullOrWhiteSpace(newName);
        await _accountLock.WaitAsync(ct).ConfigureAwait(false);
        try
        {
            RequireState(ClientState.Unlocked);
            var account = _store.GetAccount()!;
            using var secretKey = LoadSecretKey();
            var (challenge, result, vaultKey) =
                await LoginAsync(account.Username, password, secretKey, newName.Trim(), account.DeviceId, ct).ConfigureAwait(false);
            using (vaultKey)
            {
                if (challenge.AccountId != account.AccountId || result.DeviceId != account.DeviceId)
                {
                    throw new ProtocolViolationException("The server answered for a different account or device.");
                }

                _secrets.Set(SecretNames.SessionToken, result.Token);
                Api.Token = result.Token;
                _store.SaveAccount(account with
                {
                    DeviceName = newName.Trim(), KdfSalt = challenge.KdfSalt, KdfParams = challenge.KdfParams, WrappedVaultKey = result.WrappedVaultKey,
                });
                Sync.RequestSync();
            }
        }
        finally
        {
            _accountLock.Release();
        }
    }

    /// <summary>The Secret Key in its display form, for showing or printing the Emergency Kit. Requires an unlocked client.</summary>
    public string GetSecretKeyForDisplay()
    {
        RequireState(ClientState.Unlocked);
        using var key = LoadSecretKey();
        return key.Format();
    }

    // ---- notebooks and pages --------------------------------------------------------------

    /// <summary>Ids of the notebooks usable on this device, in a stable order.</summary>
    public IReadOnlyList<string> NotebookIds => RequireVault().NotebookIds;

    /// <summary>
    /// Creates a notebook (works offline): a new notebook key wrapped under the vault key, and a
    /// tree document with the given title. The next sync sends both.
    /// </summary>
    public NotebookTree CreateNotebook(string title)
    {
        ArgumentNullException.ThrowIfNull(title);
        var tree = RequireVault().CreateNotebook(title);
        Sync.RaiseNotebooksChanged();
        return tree;
    }

    /// <summary>
    /// The tree of a notebook, loaded from the local store on first use and kept up to date by
    /// sync from then on. The same instance is returned until the client is locked.
    /// </summary>
    /// <exception cref="KeyNotFoundException">The notebook is not on this device.</exception>
    public NotebookTree OpenNotebook(string notebookId) => RequireVault().OpenNotebook(notebookId);

    /// <summary>Adds a page to a section of a notebook and creates its (initialised) page document. Works offline.</summary>
    public PageDocument CreatePage(string notebookId, string sectionId, string title, int? index = null)
    {
        var vault = RequireVault();
        var pageId = vault.OpenNotebook(notebookId).AddPage(sectionId, title, index);
        return vault.CreatePage(notebookId, pageId);
    }

    /// <summary>
    /// The document of an existing page, loaded from the local store on first use and kept up
    /// to date by sync until <see cref="ClosePage"/>. The same instance is returned while open.
    /// A page whose content has not been synced to this device yet opens empty and fills in later.
    /// </summary>
    public PageDocument OpenPage(string notebookId, string pageId) => RequireVault().OpenPage(notebookId, pageId);

    /// <summary>Releases an open page document. Its content stays in the local store.</summary>
    public void ClosePage(string pageId) => Volatile.Read(ref _vault)?.Close(pageId);

    /// <summary>
    /// Deletes a notebook with everything in it, on the server and locally. Needs the server
    /// (unless the notebook was never synced). Cannot be undone.
    /// </summary>
    public Task DeleteNotebookAsync(string notebookId, CancellationToken ct = default)
    {
        var vault = RequireVault();
        return Sync.ExclusiveAsync(async () =>
        {
            var neverPushed = _store.GetNotebooks().Any(n => n.NotebookId == notebookId && n.PendingPut);
            if (!neverPushed)
            {
                try
                {
                    await Api.DeleteNotebookAsync(notebookId, ct).ConfigureAwait(false);
                }
                catch (ApiException e) when (e.Code == ErrorCodes.UnknownNotebook)
                {
                }
            }

            await Sync.DropLocallyAsync(vault, [], notebookId, notebookGone: true, issueMessage: null).ConfigureAwait(false);
            return true;
        }, ct);
    }

    /// <summary>
    /// Removes the document of a page for good (<c>DELETE /docs</c>), on the server and locally.
    /// Meant for pages whose <c>deleted</c> flag has been set in the tree for a while. Needs the server.
    /// </summary>
    public Task PurgePageAsync(string notebookId, string pageId, CancellationToken ct = default)
    {
        var vault = RequireVault();
        return Sync.ExclusiveAsync(async () =>
        {
            try
            {
                await Api.DeleteDocAsync(pageId, ct).ConfigureAwait(false);
            }
            catch (ApiException e) when (e.Code == ErrorCodes.UnknownDoc)
            {
            }

            await Sync.DropLocallyAsync(vault, [pageId], notebookId, notebookGone: false, issueMessage: null).ConfigureAwait(false);
            return true;
        }, ct);
    }

    /// <inheritdoc />
    public async ValueTask DisposeAsync()
    {
        if (_disposed)
        {
            return;
        }

        _disposed = true;
        await LockCoreAsync().ConfigureAwait(false);
        await Sync.DisposeAsync().ConfigureAwait(false);
        Api.Dispose();
        _store.Dispose();
    }

    // ---- internals ------------------------------------------------------------------------

    private static Task<DerivedKeys> DeriveAsync(string password, SecretKey secretKey, byte[] accountId, byte[] salt, KdfParams kdfParams) =>
        Task.Run(() => KeyDerivation.Derive(password, secretKey, accountId, salt, kdfParams)); // 64 MiB of Argon2: off the caller's thread

    private SecretKey LoadSecretKey() =>
        SecretKey.TryParse(_secrets.Get(SecretNames.SecretKey), out var key)
            ? key
            : throw new InvalidOperationException("The Secret Key is missing from the secret store; enrol this device again.");

    private async Task<SecretBytes> OpenLocalVaultKeyAsync(AccountRecord account, string password)
    {
        using var secretKey = LoadSecretKey();
        var accountId = WireEncoding.IdFromHex(account.AccountId);
        using var keys = await DeriveAsync(password, secretKey, accountId, account.KdfSalt, account.KdfParams).ConfigureAwait(false);
        return KeyHierarchy.TryUnwrapVaultKey(keys.UnlockKey, accountId, account.WrappedVaultKey, out var vaultKey)
            ? vaultKey!
            : throw new WrongCredentialsException();
    }

    /// <summary>auth/start, derive, sign, auth/finish, unwrap (PROTOCOL.md section 3 and 1.2-1.4).</summary>
    private async Task<(AuthChallenge Challenge, AuthResult Result, SecretBytes VaultKey)> LoginAsync(
        string username, string password, SecretKey secretKey, string deviceName, string? deviceId, CancellationToken ct)
    {
        var challenge = await Api.AuthStartAsync(username, ct).ConfigureAwait(false);

        // The server chooses these; refuse anything that would make this device do unbounded work.
        if (challenge.KdfParams is null || !challenge.KdfParams.IsSupported
            || !WireEncoding.TryIdFromHex(challenge.AccountId, out var accountId)
            || challenge.KdfSalt is not { Length: KeyDerivation.SaltLength }
            || challenge.Nonce is not { Length: LoginSignature.NonceLength }
            || !WireEncoding.TryIdFromHex(challenge.ChallengeId, out _))
        {
            throw new ProtocolViolationException("The server sent a login challenge this client refuses to use.");
        }

        using var keys = await DeriveAsync(password, secretKey, accountId, challenge.KdfSalt, challenge.KdfParams).ConfigureAwait(false);
        var signature = LoginSignature.Sign(keys.AuthPrivateKey, challenge.Nonce);
        AuthResult result;
        try
        {
            result = await Api.AuthFinishAsync(challenge.ChallengeId, signature, deviceName, deviceId, ct).ConfigureAwait(false);
        }
        catch (ApiException e) when (e.Code == ErrorCodes.BadSignature)
        {
            throw new WrongCredentialsException();
        }

        if (result.Token is null || !WireEncoding.TryIdFromHex(result.DeviceId, out _) || result.WrappedVaultKey is null
            || !KeyHierarchy.TryUnwrapVaultKey(keys.UnlockKey, accountId, result.WrappedVaultKey, out var vaultKey))
        {
            // The signature was accepted, so the credentials are right; the stored vault key is not theirs.
            throw new ProtocolViolationException("The server's wrapped vault key does not open with this account's keys.");
        }

        return (challenge, result, vaultKey!);
    }

    private void BecomeUnlocked(SecretBytes vaultKey, string deviceId)
    {
        var vault = new Vault(_store, vaultKey, Sync.Report, Sync.NotifyLocalChange, _options.Dispatcher, _options.UndoCaptureMilliseconds);
        Sync.Attach(vault, deviceId);
        Volatile.Write(ref _vault, vault);
        StateChanged?.Invoke(ClientState.Unlocked);
    }

    private async Task LockCoreAsync()
    {
        var vault = Volatile.Read(ref _vault);
        if (vault is null)
        {
            return;
        }

        await Sync.DetachAsync().ConfigureAwait(false);
        Volatile.Write(ref _vault, null);
        vault.Dispose();
        if (!_disposed)
        {
            StateChanged?.Invoke(ClientState.Locked);
        }
    }

    private Vault RequireVault() =>
        Volatile.Read(ref _vault) ?? throw new InvalidOperationException("The account is locked.");

    private void RequireState(ClientState expected)
    {
        ObjectDisposedException.ThrowIf(_disposed, this);
        var state = State;
        if (state != expected)
        {
            throw new InvalidOperationException($"This needs the client to be {expected}; it is {state}.");
        }
    }
}
