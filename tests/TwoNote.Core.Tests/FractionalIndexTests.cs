using TwoNote.Core.Documents;
using Xunit;

namespace TwoNote.Core.Tests;

public class FractionalIndexTests
{
    [Fact]
    public void First_key_and_simple_neighbours()
    {
        Assert.Equal("V", FractionalIndex.Between(null, null));
        Assert.Equal("W", FractionalIndex.Between("V", null));
        Assert.Equal("U", FractionalIndex.Between(null, "V"));
        Assert.Equal("VV", FractionalIndex.Between("V", "W"));
        Assert.Equal("VG", FractionalIndex.Between("V", "VV"));
        Assert.Equal("W", FractionalIndex.Between("V", "W1"));
        Assert.Equal("z1", FractionalIndex.Between("z", null));
        Assert.Equal("0y", FractionalIndex.Between(null, "1"));
        Assert.Equal("00y", FractionalIndex.Between(null, "01"));
    }

    [Theory]
    [InlineData("")]
    [InlineData("V0")]
    [InlineData("a-b")]
    [InlineData("é")]
    public void Malformed_keys_are_rejected(string key)
    {
        Assert.False(FractionalIndex.IsValid(key));
        Assert.Throws<ArgumentException>(() => FractionalIndex.Between(key, null));
        Assert.Throws<ArgumentException>(() => FractionalIndex.Between(null, key));
    }

    [Fact]
    public void Keys_in_the_wrong_order_are_rejected()
    {
        Assert.Throws<ArgumentException>(() => FractionalIndex.Between("W", "V"));
        Assert.Throws<ArgumentException>(() => FractionalIndex.Between("V", "V"));
    }

    [Theory]
    [InlineData(1)]
    [InlineData(2)]
    [InlineData(3)]
    public void Random_insertions_keep_a_strict_order(int seed)
    {
        var rng = new Random(seed);
        var keys = new List<string>();
        for (var i = 0; i < 3000; i++)
        {
            var at = rng.Next(keys.Count + 1);
            var key = FractionalIndex.Between(at > 0 ? keys[at - 1] : null, at < keys.Count ? keys[at] : null);
            Assert.True(FractionalIndex.IsValid(key), key);
            keys.Insert(at, key);
        }

        for (var i = 1; i < keys.Count; i++)
        {
            Assert.True(string.CompareOrdinal(keys[i - 1], keys[i]) < 0, $"{keys[i - 1]} !< {keys[i]}");
        }

        // Sorting the way any client would (bytewise) reproduces the list.
        Assert.Equal(keys, keys.OrderBy(k => k, StringComparer.Ordinal).ToList());
    }

    [Fact]
    public void Appending_and_prepending_a_thousand_items_keeps_keys_short()
    {
        string? last = null;
        string? first = null;
        for (var i = 0; i < 1000; i++)
        {
            var next = FractionalIndex.Between(last, null);
            Assert.True(last is null || string.CompareOrdinal(last, next) < 0);
            last = next;

            var previous = FractionalIndex.Between(null, first);
            Assert.True(first is null || string.CompareOrdinal(previous, first) < 0);
            first = previous;
        }

        Assert.True(last!.Length <= 20, last);
        Assert.True(first!.Length <= 40, first);
    }

    [Fact]
    public void Repeatedly_splitting_the_same_gap_always_finds_room()
    {
        var low = "V";
        var high = "W";
        for (var i = 0; i < 200; i++)
        {
            var mid = FractionalIndex.Between(low, high);
            Assert.True(string.CompareOrdinal(low, mid) < 0 && string.CompareOrdinal(mid, high) < 0);
            if (i % 2 == 0)
            {
                high = mid;
            }
            else
            {
                low = mid;
            }
        }
    }
}
