using System.Threading.Channels;

namespace TwoNote.Server;

/// <summary>Tracks the account-wide head and fans it out to connected WebSockets.</summary>
public sealed class HeadHub
{
    public sealed class Subscription(string deviceId)
    {
        public string DeviceId { get; } = deviceId;

        // Only the newest head matters, so one slot that drops the older value is enough.
        internal Channel<long> Channel { get; } = System.Threading.Channels.Channel.CreateBounded<long>(
            new BoundedChannelOptions(1) { FullMode = BoundedChannelFullMode.DropOldest });

        /// <summary>Yields head values; completes when the device is revoked.</summary>
        public ChannelReader<long> Heads => Channel.Reader;
    }

    private readonly Lock _lock = new();
    private readonly HashSet<Subscription> _subscriptions = [];
    private long _head;

    public long Head => Interlocked.Read(ref _head);

    public void Publish(long head)
    {
        lock (_lock)
        {
            if (head <= _head) return;
            Interlocked.Exchange(ref _head, head);
            foreach (var s in _subscriptions) s.Channel.Writer.TryWrite(head);
        }
    }

    public Subscription Subscribe(string deviceId)
    {
        var subscription = new Subscription(deviceId);
        lock (_lock) _subscriptions.Add(subscription);
        return subscription;
    }

    public void Unsubscribe(Subscription subscription)
    {
        lock (_lock) _subscriptions.Remove(subscription);
    }

    /// <summary>Ends the sockets of devices whose tokens were revoked.</summary>
    public void Revoke(IReadOnlyCollection<string> deviceIds)
    {
        lock (_lock)
        {
            foreach (var s in _subscriptions)
                if (deviceIds.Contains(s.DeviceId)) s.Channel.Writer.TryComplete();
        }
    }
}
