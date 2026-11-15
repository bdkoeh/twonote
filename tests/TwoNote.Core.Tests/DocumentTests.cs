using System.Globalization;
using System.Text;
using TwoNote.Core.Documents;
using Xunit;
using YDotNet.Document;
using YDotNet.Document.Cells;
using YDotNet.Document.Options;

namespace TwoNote.Core.Tests;

internal static class Docs
{
    public static string NewId() => WireEncoding.IdToHex(WireEncoding.NewId());

    public static Dictionary<string, object?> Attrs(params (string Key, object? Value)[] attributes) =>
        attributes.ToDictionary(a => a.Key, a => a.Value);

    /// <summary>Canonical text + formatting dump: adjacent runs with equal attributes are merged, attributes sorted.</summary>
    public static string Dump(PageDocument page)
    {
        var sb = new StringBuilder();
        string? lastAttrs = null;
        foreach (var run in page.GetRuns())
        {
            var attrs = string.Join(",", run.Attributes.OrderBy(a => a.Key, StringComparer.Ordinal).Select(a => a.Key + "=" + Scalar(a.Value)));
            if (lastAttrs is not null && attrs != lastAttrs)
            {
                sb.Append('{').Append(lastAttrs).Append("}|");
            }

            sb.Append(run.Text.Replace("\n", "\\n"));
            lastAttrs = attrs;
        }

        if (lastAttrs is not null)
        {
            sb.Append('{').Append(lastAttrs).Append("}|");
        }

        return sb.ToString();
    }

    public static string Dump(NotebookTree tree)
    {
        var sb = new StringBuilder("[" + tree.Title + "]");
        foreach (var s in tree.GetSections(includeDeleted: true))
        {
            sb.Append($"\n S {s.Id} '{s.Title}' {s.Order} {(s.Deleted ? "deleted" : "")}");
            foreach (var p in tree.GetPages(s.Id, includeDeleted: true))
            {
                sb.Append($"\n  P {p.Id} '{p.Title}' {p.Order} {(p.Deleted ? "deleted" : "")} {p.CreatedAt.ToUnixTimeMilliseconds()} {p.UpdatedAt.ToUnixTimeMilliseconds()}");
            }
        }

        return sb.ToString();
    }

    /// <summary>Two-way exchange of everything the other side lacks.</summary>
    public static void Exchange(CrdtDocument a, CrdtDocument b)
    {
        var toB = a.EncodeDiff(b.EncodeStateVector());
        var toA = b.EncodeDiff(a.EncodeStateVector());
        Assert.True(b.ApplyUpdate(toB));
        Assert.True(a.ApplyUpdate(toA));
    }

    private static string Scalar(object? value) => value switch
    {
        bool b => b ? "true" : "false",
        string s => "\"" + s + "\"",
        double d => d.ToString("R", CultureInfo.InvariantCulture),
        null => "null",
        _ => value.GetType().Name,
    };
}

public class NotebookTreeTests
{
    private static (NotebookTree A, NotebookTree B) Pair()
    {
        var id = Docs.NewId();
        var a = new NotebookTree(id);
        var b = new NotebookTree(id);
        a.Initialize("Notes");
        Docs.Exchange(a, b);
        return (a, b);
    }

    [Fact]
    public void A_new_notebook_has_a_title_and_no_sections()
    {
        using var tree = new NotebookTree(Docs.NewId());
        Assert.Equal("", tree.Title);
        tree.Initialize("Work");
        Assert.Equal("Work", tree.Title);
        Assert.Empty(tree.GetSections());
        tree.SetTitle("Work 2");
        Assert.Equal("Work 2", tree.Title);
        Assert.Equal(tree.DocId, tree.NotebookId);
    }

    [Fact]
    public void Sections_and_pages_are_ordered_by_fractional_index_and_can_be_inserted_anywhere()
    {
        using var tree = new NotebookTree(Docs.NewId());
        tree.Initialize("N");
        var s1 = tree.AddSection("one");
        var s3 = tree.AddSection("three");
        var s2 = tree.AddSection("two", index: 1);
        var s0 = tree.AddSection("zero", index: 0);
        Assert.Equal(["zero", "one", "two", "three"], tree.GetSections().Select(s => s.Title));
        Assert.All(tree.GetSections(), s => Assert.True(FractionalIndex.IsValid(s.Order)));

        tree.MoveSection(s0, null);
        Assert.Equal([s1, s2, s3, s0], tree.GetSections().Select(s => s.Id));
        tree.MoveSection(s3, 0);
        Assert.Equal([s3, s1, s2, s0], tree.GetSections().Select(s => s.Id));

        var p1 = tree.AddPage(s1, "a");
        var p2 = tree.AddPage(s1, "b");
        var p3 = tree.AddPage(s1, "c", index: 0);
        Assert.Equal(["c", "a", "b"], tree.GetPages(s1).Select(p => p.Title));
        Assert.Matches("^[0-9a-f]{32}$", p1);

        tree.MovePage(p3, s2, null);
        Assert.Equal([p1, p2], tree.GetPages(s1).Select(p => p.Id));
        Assert.Equal([p3], tree.GetPages(s2).Select(p => p.Id));
        Assert.Equal(s2, tree.GetPage(p3)!.SectionId);
    }

    [Fact]
    public void Deletion_is_a_flag_and_renames_bump_updatedAt()
    {
        var time = new FakeTime(DateTimeOffset.FromUnixTimeMilliseconds(1_800_000_000_000));
        using var tree = new NotebookTree(Docs.NewId(), time);
        tree.Initialize("N");
        var s = tree.AddSection("s");
        var p = tree.AddPage(s, "p");
        Assert.Equal(1_800_000_000_000, tree.GetPage(p)!.CreatedAt.ToUnixTimeMilliseconds());

        time.Now += TimeSpan.FromMinutes(5);
        tree.RenamePage(p, "renamed");
        var page = tree.GetPage(p)!;
        Assert.Equal("renamed", page.Title);
        Assert.Equal(1_800_000_000_000, page.CreatedAt.ToUnixTimeMilliseconds());
        Assert.Equal(1_800_000_300_000, page.UpdatedAt.ToUnixTimeMilliseconds());

        tree.SetPageDeleted(p);
        Assert.Empty(tree.GetPages(s));
        Assert.True(Assert.Single(tree.GetPages(s, includeDeleted: true)).Deleted);
        tree.SetPageDeleted(p, false);
        Assert.Single(tree.GetPages(s));

        tree.SetSectionDeleted(s);
        Assert.Empty(tree.GetSections());
        Assert.True(tree.GetSection(s)!.Deleted);
        Assert.Throws<KeyNotFoundException>(() => tree.RenameSection(Docs.NewId(), "x"));
        Assert.Throws<KeyNotFoundException>(() => tree.RenamePage(Docs.NewId(), "x"));
    }

    [Fact]
    public void The_wire_shape_is_section_5_1_with_numbers_as_doubles()
    {
        using var tree = new NotebookTree(Docs.NewId());
        tree.Initialize("Title");
        var s = tree.AddSection("sec");
        var p = tree.AddPage(s, "page");

        // Read the state with plain YDotNet, as another implementation would.
        using var raw = new Doc(new DocOptions { Encoding = DocEncoding.Utf16 });
        var meta = raw.Map("meta");
        var sections = raw.Map("sections");
        var pages = raw.Map("pages");
        using (var w = raw.WriteTransaction())
        {
            w.ApplyV1(tree.EncodeState());
        }

        using var r = raw.ReadTransaction();
        Assert.Equal("Title", meta.Get(r, "title")!.String);
        Assert.Equal(OutputTag.Double, meta.Get(r, "formatVersion")!.Tag);
        Assert.Equal(1.0, meta.Get(r, "formatVersion")!.Double);

        var section = sections.Get(r, s)!.Map;
        Assert.Equal(3u, section.Length(r));
        Assert.Equal("sec", section.Get(r, "title")!.String);
        Assert.Equal(OutputTag.String, section.Get(r, "order")!.Tag);
        Assert.False(section.Get(r, "deleted")!.Boolean);

        var page = pages.Get(r, p)!.Map;
        Assert.Equal(6u, page.Length(r));
        Assert.Equal(s, page.Get(r, "sectionId")!.String);
        Assert.Equal("page", page.Get(r, "title")!.String);
        Assert.False(page.Get(r, "deleted")!.Boolean);
        Assert.Equal(OutputTag.Double, page.Get(r, "createdAt")!.Tag);
        Assert.Equal(OutputTag.Double, page.Get(r, "updatedAt")!.Tag);
        Assert.True(page.Get(r, "createdAt")!.Double > 1.7e12); // milliseconds since the Unix epoch
    }

    [Fact]
    public void Two_replicas_converge_after_concurrent_tree_edits()
    {
        var (a, b) = Pair();
        using var _a = a;
        using var _b = b;
        var s = a.AddSection("shared");
        var p = a.AddPage(s, "page");
        Docs.Exchange(a, b);

        // Concurrently: different fields of the same page, a rename race, and new items on both sides.
        a.RenamePage(p, "renamed on A");
        b.SetPageDeleted(p);
        a.RenameSection(s, "A's name");
        b.RenameSection(s, "B's name");
        var sa = a.AddSection("from A");
        var sb = b.AddSection("from B");
        a.AddPage(s, "page A");
        b.AddPage(s, "page B");
        b.SetTitle("B's notebook");

        Docs.Exchange(a, b);
        Assert.Equal(Docs.Dump(a), Docs.Dump(b));
        Assert.Equal("B's notebook", a.Title);

        // The delete flag survived the concurrent rename (no half-deleted, resurrected item).
        var page = a.GetPage(p)!;
        Assert.True(page.Deleted);
        Assert.Equal("renamed on A", page.Title);
        Assert.Contains(a.GetSection(s)!.Title, new[] { "A's name", "B's name" });

        // Both new sections exist; equal order keys are broken by id, identically on both sides.
        var ids = a.GetSections().Select(x => x.Id).ToList();
        Assert.Contains(sa, ids);
        Assert.Contains(sb, ids);
        Assert.Equal(ids, b.GetSections().Select(x => x.Id).ToList());
        Assert.Equal(2, a.GetPages(s).Count);

        // Inserting next to a tie still works and lands in the same place everywhere.
        a.AddSection("after the tie", index: 2);
        Docs.Exchange(a, b);
        Assert.Equal(Docs.Dump(a), Docs.Dump(b));
    }

    [Fact]
    public void Changes_are_announced_with_their_source_and_local_ones_produce_updates()
    {
        var (a, b) = Pair();
        using var _a = a;
        using var _b = b;
        var updates = new List<byte[]>();
        var sources = new List<ChangeSource>();
        a.LocalUpdate += updates.Add;
        a.Changed += sources.Add;
        var remote = new List<ChangeSource>();
        b.Changed += remote.Add;

        var s = a.AddSection("s");
        a.RenameSection(s, "t");
        Assert.Equal(2, updates.Count);
        Assert.Equal([ChangeSource.Local, ChangeSource.Local], sources);

        foreach (var u in updates)
        {
            Assert.True(b.ApplyUpdate(u));
        }

        Assert.Equal([ChangeSource.Remote, ChangeSource.Remote], remote);
        Assert.Equal("t", b.GetSection(s)!.Title);

        // Applying remote updates produces nothing to send, and a repeat changes nothing.
        var before = updates.Count;
        Assert.True(a.ApplyUpdate(b.EncodeState()));
        Assert.True(b.ApplyUpdate(updates[0]));
        Assert.Equal(before, updates.Count);
        Assert.Equal(2, remote.Count);

        Assert.False(b.ApplyUpdate([0xff, 0xff, 0xff, 0x01, 0x02]));
    }

    private sealed class FakeTime(DateTimeOffset now) : TimeProvider
    {
        public DateTimeOffset Now { get; set; } = now;

        public override DateTimeOffset GetUtcNow() => Now;
    }
}

public class PageDocumentTests
{
    private static readonly Dictionary<string, object?> Bold = Docs.Attrs((PageAttributes.Bold, true));

    private static (PageDocument A, PageDocument B) Pair()
    {
        var id = Docs.NewId();
        var a = new PageDocument(id, undoCaptureMilliseconds: 0);
        var b = new PageDocument(id, undoCaptureMilliseconds: 0);
        a.Initialize();
        Docs.Exchange(a, b);
        return (a, b);
    }

    [Fact]
    public void A_new_page_is_one_empty_paragraph_in_the_root_text_c_main()
    {
        using var page = new PageDocument(Docs.NewId());
        Assert.Equal("", page.GetText());
        page.Initialize();
        Assert.Equal("\n", page.GetText());
        Assert.Equal(1, page.Length);

        using var raw = new Doc(new DocOptions { Encoding = DocEncoding.Utf16 });
        var meta = raw.Map("meta");
        var containers = raw.Map("containers");
        var text = raw.Text("c:main");
        using (var w = raw.WriteTransaction())
        {
            w.ApplyV1(page.EncodeState());
        }

        using var r = raw.ReadTransaction();
        Assert.Equal(OutputTag.Double, meta.Get(r, "formatVersion")!.Tag);
        Assert.Equal(1.0, meta.Get(r, "formatVersion")!.Double);
        var main = containers.Get(r, "main")!.Map;
        Assert.Equal("flow", main.Get(r, "kind")!.String);
        Assert.Equal(1u, main.Length(r)); // metadata only: the text is not nested in the map
        Assert.Equal("\n", text.String(r));
    }

    [Fact]
    public void Insert_delete_and_format_with_explicit_attributes()
    {
        using var page = new PageDocument(Docs.NewId());
        page.Initialize();
        page.Edit(e =>
        {
            e.Insert(0, "Hello world");
            e.Format(0, 5, Bold);
            e.Insert(5, ",", Docs.Attrs((PageAttributes.Italic, true)));
            e.Delete(6, 1);
            Assert.Equal("Hello,world\n", e.Text);
            Assert.Equal(12, e.Length);
        });
        Assert.Equal("Hello,world\n", page.GetText());
        Assert.Equal("Hello{bold=true}|,{italic=true}|world\\n{}|", Docs.Dump(page));

        // Text typed inside a bold run with no attributes is not bold: nothing is inherited.
        page.Edit(e => e.Insert(2, "__"));
        Assert.Equal("He{bold=true}|__{}|llo{bold=true}|,{italic=true}|world\\n{}|", Docs.Dump(page));

        // Null removes an attribute; link is a string.
        page.Edit(e =>
        {
            e.Format(0, 7, Docs.Attrs((PageAttributes.Bold, null)));
            e.Format(8, 5, Docs.Attrs((PageAttributes.Link, "https://example.com")));
        });
        Assert.Equal("He__llo{}|,{italic=true}|world{link=\"https://example.com\"}|\\n{}|", Docs.Dump(page));
    }

    [Fact]
    public void Block_formatting_lives_on_the_newline_and_is_written_together()
    {
        using var page = new PageDocument(Docs.NewId());
        page.Initialize();
        page.Edit(e =>
        {
            e.Insert(0, "Title\nitem\nplain");
            e.SetBlock(5, "h1");
            e.SetBlock(10, "todo", indent: 2, isChecked: true);
        });
        Assert.Equal("Title{}|\\n{block=\"h1\"}|item{}|\\n{block=\"todo\",checked=true,indent=2}|plain\\n{}|", Docs.Dump(page));

        // indent is a double on the wire, never an integer.
        var indent = page.GetRuns().Single(r => r.Attributes.ContainsKey(PageAttributes.Indent)).Attributes[PageAttributes.Indent];
        Assert.IsType<double>(indent);

        // Changing the block rewrites all three, so stale indent/checked do not linger.
        page.Edit(e => e.SetBlock(10, "ul"));
        Assert.Contains("item{}|\\n{block=\"ul\"}|", Docs.Dump(page));
        page.Edit(e => e.SetBlock(10, null));
        Assert.Contains("item\\nplain\\n{}|", Docs.Dump(page));

        page.Edit(e =>
        {
            Assert.Throws<ArgumentException>(() => e.SetBlock(0, "h1"));                    // not a newline
            Assert.Throws<ArgumentOutOfRangeException>(() => e.SetBlock(5, "ul", indent: 9));
        });
    }

    [Fact]
    public void Inline_attributes_on_the_newline_and_unknown_attributes_are_preserved()
    {
        var (a, b) = Pair();
        using var _a = a;
        using var _b = b;
        a.Edit(e =>
        {
            e.Insert(0, "x");
            e.Format(1, 1, Docs.Attrs((PageAttributes.Bold, true), ("futureThing", "kept"), (PageAttributes.Block, "callout")));
        });
        Docs.Exchange(a, b);

        // B changes something else on the same newline; the attributes it does not know stay.
        b.Edit(e => e.Format(1, 1, Docs.Attrs((PageAttributes.Italic, true))));
        Docs.Exchange(a, b);
        Assert.Equal("x{}|\\n{block=\"callout\",bold=true,futureThing=\"kept\",italic=true}|", Docs.Dump(a));
        Assert.Equal(Docs.Dump(a), Docs.Dump(b));
    }

    [Fact]
    public void Indexes_are_utf16_code_units_and_surrogate_pairs_are_never_split()
    {
        using var page = new PageDocument(Docs.NewId());
        page.Initialize();
        const string s = "a😀é漢b";
        page.Edit(e =>
        {
            e.Insert(0, s);
            e.Insert(s.IndexOf('é'), "X");
        });
        Assert.Equal(s.Insert(s.IndexOf('é'), "X") + "\n", page.GetText());
        Assert.Equal(s.Length + 2, page.Length);

        page.Edit(e =>
        {
            Assert.Throws<ArgumentException>(() => e.Insert(2, "x"));          // between the two halves of 😀
            Assert.Throws<ArgumentException>(() => e.Delete(1, 1));            // the high surrogate alone
            Assert.Throws<ArgumentException>(() => e.Delete(2, 1));            // the low surrogate alone
            Assert.Throws<ArgumentException>(() => e.Format(0, 2, Bold));      // ends inside the pair
            Assert.Throws<ArgumentException>(() => e.Insert(0, "\ud83d"));     // unpaired high surrogate
            Assert.Throws<ArgumentException>(() => e.Insert(0, "\ude00x"));    // unpaired low surrogate
            e.Delete(1, 2);                                                    // the whole pair is fine
        });
        Assert.Equal("aXé漢b\n", page.GetText());
    }

    [Fact]
    public void The_final_newline_cannot_be_deleted_or_written_past()
    {
        using var page = new PageDocument(Docs.NewId());
        page.Initialize();
        page.Edit(e => e.Insert(0, "ab\ncd"));
        page.Edit(e =>
        {
            Assert.Throws<ArgumentOutOfRangeException>(() => e.Delete(5, 1));     // the final newline
            Assert.Throws<ArgumentOutOfRangeException>(() => e.Delete(3, 3));     // a range that includes it
            Assert.Throws<ArgumentOutOfRangeException>(() => e.Insert(6, "x"));   // after it
            Assert.Throws<ArgumentOutOfRangeException>(() => e.Delete(-1, 1));
            e.Delete(2, 1);                                                       // an inner newline may go
        });
        Assert.Equal("abcd\n", page.GetText());
    }

    [Fact]
    public void A_page_whose_content_has_not_arrived_gets_its_newline_on_the_first_edit_only()
    {
        using var page = new PageDocument(Docs.NewId());
        Assert.Equal("", page.GetText());         // opening does not write anything
        Assert.Empty(page.EncodeState().Skip(2)); // still an empty document
        page.Edit(e => e.Insert(0, "typed early"));
        Assert.Equal("typed early\n", page.GetText());
    }

    [Fact]
    public void Soft_line_breaks_are_ordinary_characters()
    {
        using var page = new PageDocument(Docs.NewId());
        page.Initialize();
        page.Edit(e => e.Insert(0, "line one\u2028line two"));
        Assert.Equal("line one\u2028line two\n", page.GetText());
        Assert.Single(page.GetRuns());
    }

    [Fact]
    public void Remote_changes_arrive_as_deltas_and_local_ones_as_updates()
    {
        var (a, b) = Pair();
        using var _a = a;
        using var _b = b;
        a.Edit(e => e.Insert(0, "Hello world"));
        Docs.Exchange(a, b);

        var updates = new List<byte[]>();
        a.LocalUpdate += updates.Add;
        var seen = new List<string>();
        b.TextChanged += change =>
        {
            Assert.Equal(ChangeSource.Remote, change.Source);
            foreach (var op in change.Delta)
            {
                var attrs = op.Attributes is null ? "" : string.Join(",", op.Attributes.OrderBy(x => x.Key).Select(x => x.Key + "=" + (x.Value ?? "null")));
                seen.Add(op.Kind switch
                {
                    DeltaKind.Retain => $"retain {op.Length} [{attrs}]",
                    DeltaKind.Insert => $"insert '{op.Text!.Replace("\n", "\\n")}' [{attrs}]",
                    _ => $"delete {op.Length}",
                });
            }
        };
        var localEvents = 0;
        a.TextChanged += change =>
        {
            Assert.Equal(ChangeSource.Local, change.Source);
            localEvents++;
        };

        a.Edit(e =>
        {
            e.Insert(6, "big ", Bold);
            e.Delete(0, 1);
            e.Format(1, 3, Docs.Attrs((PageAttributes.Italic, true)));
            e.SetBlock(14, "ul");
        });
        Assert.Single(updates);          // one edit, one update
        Assert.Equal(1, localEvents);
        Assert.True(b.ApplyUpdate(updates[0]));

        Assert.Equal(Docs.Dump(a), Docs.Dump(b));
        Assert.Contains("delete 1", seen);
        Assert.Contains("retain 3 [italic=True]", seen);
        Assert.Contains("insert 'big ' [bold=True]", seen);
        Assert.Contains("retain 1 [block=ul]", seen);

        // Replaying the delta against the old text gives the new text.
        var again = new List<TextChange>();
        b.TextChanged += again.Add;
        var before = b.GetText();
        a.Edit(e =>
        {
            e.Delete(2, 4);
            e.Insert(0, "¶ ");
        });
        Assert.True(b.ApplyUpdate(updates[1]));
        var replayed = new StringBuilder(before);
        var at = 0;
        foreach (var op in Assert.Single(again).Delta)
        {
            switch (op.Kind)
            {
                case DeltaKind.Retain: at += op.Length; break;
                case DeltaKind.Delete: replayed.Remove(at, op.Length); break;
                case DeltaKind.Insert: replayed.Insert(at, op.Text); at += op.Length; break;
            }
        }

        Assert.Equal(b.GetText(), replayed.ToString());
    }

    [Fact]
    public void Undo_only_touches_local_edits_and_travels_as_ordinary_updates()
    {
        var (a, b) = Pair();
        using var _a = a;
        using var _b = b;
        a.LocalUpdate += u => Assert.True(b.ApplyUpdate(u));
        b.LocalUpdate += u => Assert.True(a.ApplyUpdate(u));
        var undoDeltas = 0;
        a.TextChanged += c => undoDeltas += c.Source == ChangeSource.Undo ? 1 : 0;

        Assert.False(a.CanUndo);                 // initialisation is not an undo step
        a.Edit(e => e.Insert(0, "mine"));
        b.Edit(e => e.Insert(e.Length - 1, " theirs"));
        Assert.Throws<InvalidOperationException>(() => b.Edit(_ => b.GetText())); // inside an edit, read through the editor
        a.Edit(e => e.Format(0, 4, Bold));
        Assert.Equal("mine{bold=true}| theirs\\n{}|", Docs.Dump(a));

        Assert.True(a.Undo());                   // the bold
        Assert.Equal("mine theirs\\n{}|", Docs.Dump(a));
        Assert.True(a.Undo());                   // "mine" - B's text stays
        Assert.Equal(" theirs\n", a.GetText());
        Assert.False(a.CanUndo);
        Assert.False(a.Undo());
        Assert.Equal(" theirs\n", b.GetText());  // B followed
        Assert.Equal(2, undoDeltas);

        Assert.True(a.CanRedo);
        Assert.True(a.Redo());
        Assert.True(a.Redo());
        Assert.False(a.Redo());
        Assert.Equal("mine{bold=true}| theirs\\n{}|", Docs.Dump(b));
    }

    [Fact]
    public void Undo_groups_edits_inside_the_capture_window_until_the_group_is_broken()
    {
        using var page = new PageDocument(Docs.NewId(), undoCaptureMilliseconds: 60_000);
        page.Initialize();
        page.Edit(e => e.Insert(0, "a"));
        page.Edit(e => e.Insert(1, "b"));
        page.BreakUndoGroup();
        page.Edit(e => e.Insert(2, "c"));
        Assert.True(page.Undo());
        Assert.Equal("ab\n", page.GetText());
        Assert.True(page.Undo());
        Assert.Equal("\n", page.GetText());
    }

    [Fact]
    public void Two_devices_that_both_touch_a_fresh_page_do_not_replace_each_others_text()
    {
        // The reason section 5.2 uses a root-level Text: both replicas write before they ever meet.
        var id = Docs.NewId();
        using var a = new PageDocument(id);
        using var b = new PageDocument(id);
        a.Initialize();
        a.Edit(e => e.Insert(0, "from A"));
        b.Edit(e => e.Insert(0, "from B")); // B never saw A's initialisation
        Docs.Exchange(a, b);
        Assert.Equal(Docs.Dump(a), Docs.Dump(b));
        Assert.Contains("from A", a.GetText());
        Assert.Contains("from B", a.GetText());
        Assert.EndsWith("\n", a.GetText());
    }

    [Theory]
    [InlineData(1)]
    [InlineData(2)]
    [InlineData(3)]
    [InlineData(4)]
    public void Concurrent_random_edits_converge_in_text_and_formatting(int seed)
    {
        var rng = new Random(seed);
        var id = Docs.NewId();
        var pages = new[] { new PageDocument(id), new PageDocument(id), new PageDocument(id) };
        pages[0].Initialize();
        Docs.Exchange(pages[0], pages[1]);
        Docs.Exchange(pages[0], pages[2]);
        string[] inline = [PageAttributes.Bold, PageAttributes.Italic, PageAttributes.Underline, PageAttributes.Strike, PageAttributes.Code];

        for (var round = 0; round < 45; round++)
        {
            foreach (var page in pages)
            {
                for (var k = rng.Next(1, 5); k > 0; k--)
                {
                    page.Edit(e =>
                    {
                        var body = e.Length - 1; // everything before the final newline
                        switch (rng.Next(5))
                        {
                            case 0:
                            case 1:
                                e.Insert(rng.Next(body + 1), rng.Next(6) == 0 ? "\n" : new string((char)('a' + rng.Next(26)), rng.Next(1, 4)),
                                    rng.Next(3) == 0 ? Bold : null);
                                break;
                            case 2 when body > 0:
                            {
                                var at = rng.Next(body);
                                e.Delete(at, rng.Next(1, Math.Min(4, body - at) + 1));
                                break;
                            }
                            case 3 when body > 0:
                            {
                                var at = rng.Next(body);
                                e.Format(at, rng.Next(1, body - at + 1), Docs.Attrs((inline[rng.Next(inline.Length)], rng.Next(3) == 0 ? null : true)));
                                break;
                            }
                            case 4:
                            {
                                var text = e.Text;
                                var newlines = Enumerable.Range(0, text.Length).Where(i => text[i] == '\n').ToArray();
                                e.SetBlock(newlines[rng.Next(newlines.Length)], rng.Next(4) == 0 ? null : PageAttributes.BlockTypes[rng.Next(7)], rng.Next(0, 9), rng.Next(2) == 0);
                                break;
                            }
                        }
                    });
                }
            }

            if (round % 3 == 2)
            {
                Docs.Exchange(pages[0], pages[1]);
                Docs.Exchange(pages[1], pages[2]);
                Docs.Exchange(pages[0], pages[2]);
                Docs.Exchange(pages[0], pages[1]);
            }
        }

        var expected = Docs.Dump(pages[0]);
        Assert.Equal(expected, Docs.Dump(pages[1]));
        Assert.Equal(expected, Docs.Dump(pages[2]));
        Assert.All(pages, p => Assert.EndsWith("\n", p.GetText()));
        foreach (var page in pages)
        {
            page.Dispose();
        }
    }

    [Fact]
    public void A_document_cannot_be_used_after_dispose_and_ids_are_checked()
    {
        var page = new PageDocument(Docs.NewId());
        page.Dispose();
        Assert.Throws<ObjectDisposedException>(() => page.GetText());
        Assert.Throws<ObjectDisposedException>(() => page.Edit(_ => { }));
        Assert.True(page.ApplyUpdate([0, 0])); // late remote updates are ignored quietly
        Assert.Throws<ArgumentException>(() => new PageDocument("not-an-id"));
        Assert.Throws<ArgumentException>(() => new NotebookTree("ABCDEF0123456789ABCDEF0123456789"));
    }
}
