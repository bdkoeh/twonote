using System.Text.Json;
using System.Text.Json.Nodes;
using TwoNote.Core.Documents;
using Xunit;

namespace TwoNote.Core.Tests;

/// <summary>
/// docs/crdt-fixtures.json: Yjs v1 updates written by this (Yrs/YDotNet) implementation, with the
/// document state every client must read back from them (PROTOCOL.md section 5). The iOS client
/// replays the same file. Unlike the crypto vectors the bytes are not reproducible (client ids
/// and item ids are random), so the file is only rewritten on request:
/// <c>$env:TWONOTE_WRITE_CRDT_FIXTURES='1'; dotnet test tests/TwoNote.Core.Tests --filter CrdtFixture</c>
/// docs/crdt-fixtures-swift.json has the same shape and is written by the iOS test suite; when
/// present, this implementation must read it back too.
/// </summary>
public class CrdtFixtureTests
{
    private const string PageId = "00112233445566778899aabbccddeeff";
    private const string NotebookId = "0f1e2d3c4b5a69788796a5b4c3d2e1f0";

    private static readonly JsonSerializerOptions JsonOptions = new() { WriteIndented = true };

    [Fact]
    public void Generator_writes_the_file_when_asked()
    {
        if (Environment.GetEnvironmentVariable("TWONOTE_WRITE_CRDT_FIXTURES") != "1")
        {
            return;
        }

        var root = new JsonObject
        {
            ["description"] = "Yjs v1 updates written by the Windows client (Yrs via YDotNet) and the state every client must read from them. Updates are lowercase hex. Apply the updates of each step in order; 'runs' is the page text after that step as runs of equal attributes (numbers are doubles).",
            ["page"] = BuildPage(),
            ["concurrent"] = BuildConcurrent(),
            ["notebook"] = BuildNotebook(),
        };
        File.WriteAllText(Path.Combine(FindDocsDirectory(), "crdt-fixtures.json"), root.ToJsonString(JsonOptions) + "\n");
    }

    [Theory]
    [InlineData("crdt-fixtures.json", true)]
    [InlineData("crdt-fixtures-swift.json", false)]
    public void File_reads_back_as_recorded(string fileName, bool required)
    {
        var path = Path.Combine(FindDocsDirectory(), fileName);
        if (!File.Exists(path))
        {
            Assert.False(required, fileName + " is missing.");
            return;
        }

        var root = JsonNode.Parse(File.ReadAllText(path))!;

        // Page: step by step, and once more from the snapshot alone.
        var pageNode = root["page"]!;
        using (var page = new PageDocument(pageNode["docId"]!.GetValue<string>()))
        {
            foreach (var step in pageNode["steps"]!.AsArray())
            {
                foreach (var update in step!["updates"]!.AsArray())
                {
                    Assert.True(page.ApplyUpdate(Convert.FromHexString(update!.GetValue<string>())));
                }

                AssertRuns(step["runs"]!, page, step["name"]!.GetValue<string>());
            }

            using var fromSnapshot = new PageDocument(page.DocId);
            Assert.True(fromSnapshot.ApplyUpdate(Convert.FromHexString(pageNode["snapshot"]!.GetValue<string>())));
            AssertRuns(pageNode["steps"]!.AsArray()[^1]!["runs"]!, fromSnapshot, "snapshot");
        }

        // Concurrent edits: the same result whichever side arrives first.
        var concurrent = root["concurrent"]!;
        var baseUpdate = Convert.FromHexString(concurrent["base"]!.GetValue<string>());
        var a = Convert.FromHexString(concurrent["a"]!.GetValue<string>());
        var b = Convert.FromHexString(concurrent["b"]!.GetValue<string>());
        foreach (var order in new[] { new[] { a, b }, new[] { b, a } })
        {
            using var page = new PageDocument(concurrent["docId"]!.GetValue<string>());
            Assert.True(page.ApplyUpdate(baseUpdate));
            foreach (var update in order)
            {
                Assert.True(page.ApplyUpdate(update));
            }

            AssertRuns(concurrent["runs"]!, page, "concurrent");
        }

        // Notebook tree.
        var nb = root["notebook"]!;
        using var tree = new NotebookTree(nb["notebookId"]!.GetValue<string>());
        foreach (var update in nb["updates"]!.AsArray())
        {
            Assert.True(tree.ApplyUpdate(Convert.FromHexString(update!.GetValue<string>())));
        }

        Assert.Equal(nb["title"]!.GetValue<string>(), tree.Title);
        Assert.Equal(nb["sections"]!.ToJsonString(), SectionsJson(tree).ToJsonString());
        Assert.Equal(nb["pages"]!.ToJsonString(), PagesJson(tree).ToJsonString());
    }

    // ---- generation -----------------------------------------------------------------------

    private static JsonObject BuildPage()
    {
        using var page = new PageDocument(PageId);
        var pending = new List<byte[]>();
        page.LocalUpdate += pending.Add;
        var steps = new JsonArray();

        void Step(string name, Action action)
        {
            pending.Clear();
            action();
            page.BreakUndoGroup();
            steps.Add(new JsonObject
            {
                ["name"] = name,
                ["updates"] = new JsonArray([.. pending.Select(u => (JsonNode)Convert.ToHexStringLower(u))]),
                ["runs"] = RunsJson(page),
            });
        }

        static Dictionary<string, object?> A(params (string Key, object? Value)[] items) =>
            items.ToDictionary(i => i.Key, i => i.Value);

        Step("initialize", page.Initialize);
        Step("insert plain text", () => page.Edit(e => e.Insert(0, "Hello world")));
        Step("bold a word", () => page.Edit(e => e.Format(6, 5, A(("bold", true)))));
        Step("insert with attributes", () => page.Edit(e => e.Insert(11, " and more", A(("italic", true), ("underline", true)))));
        Step("heading 1", () => page.Edit(e => e.SetBlock(20, "h1")));
        Step("second paragraph", () => page.Edit(e =>
        {
            // Text goes in before the final newline, so the heading moves back onto its own newline.
            e.Insert(20, "\nbuy milk");
            e.SetBlock(20, "h1");
            e.SetBlock(29, "todo", indent: 2, isChecked: true);
        }));
        Step("link and code", () => page.Edit(e =>
        {
            e.Insert(29, "\nsee site or run ls");
            e.SetBlock(29, "todo", indent: 2, isChecked: true);
            e.SetBlock(48, null);
            e.Format(34, 4, A(("link", "https://example.com/a?b=c")));
            e.Format(46, 2, A(("code", true), ("strike", true)));
        }));
        Step("emoji and soft break", () => page.Edit(e => e.Insert(30, "\U0001F600 line\u2028break ")));
        Step("numbered list item", () => page.Edit(e =>
        {
            var end = e.Length - 1;
            e.Insert(end, "\nfirst");
            e.SetBlock(e.Length - 1, "ol", indent: 1);
        }));
        Step("delete a range", () => page.Edit(e => e.Delete(0, 6)));
        Step("remove bold", () => page.Edit(e => e.Format(0, 5, A(("bold", null)))));
        Step("uncheck and outdent", () => page.Edit(e => e.SetBlock(e.Text.IndexOf('\n', e.Text.IndexOf('\n') + 1), "todo")));
        Step("back to paragraph", () => page.Edit(e => e.SetBlock(e.Text.IndexOf('\n'), null)));
        Step("undo", () => Assert.True(page.Undo()));
        Step("redo", () => Assert.True(page.Redo()));
        Step("undo again", () => Assert.True(page.Undo()));

        return new JsonObject
        {
            ["docId"] = PageId,
            ["steps"] = steps,
            ["snapshot"] = Convert.ToHexStringLower(page.EncodeState()),
        };
    }

    private static JsonObject BuildConcurrent()
    {
        using var one = new PageDocument(PageId);
        one.Initialize();
        one.Edit(e => e.Insert(0, "The quick brown fox"));
        var baseUpdate = one.EncodeState();

        using var two = new PageDocument(PageId);
        Assert.True(two.ApplyUpdate(baseUpdate));

        var a = new List<byte[]>();
        var b = new List<byte[]>();
        one.LocalUpdate += a.Add;
        two.LocalUpdate += b.Add;

        // One side formats and inserts in the middle, the other deletes an overlapping range and appends.
        one.Edit(e =>
        {
            e.Format(4, 11, new Dictionary<string, object?> { ["bold"] = true });
            e.Insert(10, "very ");
        });
        two.Edit(e =>
        {
            e.Delete(4, 6);
            e.Insert(e.Length - 1, " jumps");
            e.SetBlock(e.Length - 1, "ul");
        });

        Assert.Single(a);
        Assert.Single(b);
        Assert.True(one.ApplyUpdate(b[0]));
        Assert.True(two.ApplyUpdate(a[0]));
        Assert.Equal(RunsJson(one).ToJsonString(), RunsJson(two).ToJsonString());

        return new JsonObject
        {
            ["docId"] = PageId,
            ["base"] = Convert.ToHexStringLower(baseUpdate),
            ["a"] = Convert.ToHexStringLower(a[0]),
            ["b"] = Convert.ToHexStringLower(b[0]),
            ["runs"] = RunsJson(one),
        };
    }

    private static JsonObject BuildNotebook()
    {
        using var tree = new NotebookTree(NotebookId);
        var updates = new List<byte[]>();
        tree.LocalUpdate += updates.Add;

        tree.Initialize("Work \u2013 notes");
        var inbox = tree.AddSection("Inbox");
        var ideas = tree.AddSection("Ideas \U0001F4A1");
        var first = tree.AddSection("First", index: 0);
        var p1 = tree.AddPage(inbox, "Shopping");
        var p2 = tree.AddPage(inbox, "Top of the list", index: 0);
        var p3 = tree.AddPage(ideas, "Moved here later");
        tree.RenamePage(p1, "Shopping list");
        tree.MovePage(p3, inbox, 1);
        tree.RenameSection(first, "Very first");
        tree.MoveSection(first, null);
        tree.SetPageDeleted(p2);
        tree.SetSectionDeleted(ideas);
        tree.SetTitle("Work notes");

        return new JsonObject
        {
            ["notebookId"] = NotebookId,
            ["updates"] = new JsonArray([.. updates.Select(u => (JsonNode)Convert.ToHexStringLower(u))]),
            ["title"] = tree.Title,
            ["sections"] = SectionsJson(tree),
            ["pages"] = PagesJson(tree),
        };
    }

    // ---- shared ---------------------------------------------------------------------------

    private static JsonArray RunsJson(PageDocument page)
    {
        var runs = new JsonArray();
        foreach (var run in page.GetRuns())
        {
            var attributes = new JsonObject();
            foreach (var (key, value) in run.Attributes.OrderBy(p => p.Key, StringComparer.Ordinal))
            {
                attributes[key] = value switch
                {
                    bool b => b,
                    string s => s,
                    double d => d,
                    _ => null,
                };
            }

            runs.Add(new JsonObject { ["text"] = run.Text, ["attributes"] = attributes });
        }

        return runs;
    }

    /// <summary>Sections in display order, deleted ones included.</summary>
    private static JsonArray SectionsJson(NotebookTree tree) => new(
        [.. tree.GetSections(includeDeleted: true).Select(s => (JsonNode)new JsonObject
        {
            ["id"] = s.Id, ["title"] = s.Title, ["order"] = s.Order, ["deleted"] = s.Deleted,
        })]);

    /// <summary>Pages section by section (sections in display order), each section's pages in display order, deleted ones included.</summary>
    private static JsonArray PagesJson(NotebookTree tree)
    {
        var pages = new JsonArray();
        foreach (var section in tree.GetSections(includeDeleted: true))
        {
            foreach (var p in tree.GetPages(section.Id, includeDeleted: true))
            {
                pages.Add(new JsonObject
                {
                    ["id"] = p.Id, ["sectionId"] = p.SectionId, ["title"] = p.Title, ["order"] = p.Order, ["deleted"] = p.Deleted,
                    ["createdAt"] = (double)p.CreatedAt.ToUnixTimeMilliseconds(),
                    ["updatedAt"] = (double)p.UpdatedAt.ToUnixTimeMilliseconds(),
                });
            }
        }

        return pages;
    }

    private static void AssertRuns(JsonNode expected, PageDocument page, string step)
    {
        // Compare as merged runs: where a run boundary falls between equal attributes is not part of the contract.
        Assert.True(Normalise(expected.AsArray()).ToJsonString() == Normalise(RunsJson(page)).ToJsonString(),
            $"Step '{step}': expected {expected.ToJsonString()} but read {RunsJson(page).ToJsonString()}");
    }

    private static JsonArray Normalise(JsonArray runs)
    {
        var merged = new JsonArray();
        foreach (var run in runs)
        {
            var attributes = run!["attributes"]!.ToJsonString();
            if (merged.Count > 0 && merged[^1]!["attributes"]!.ToJsonString() == attributes)
            {
                merged[^1]!["text"] = merged[^1]!["text"]!.GetValue<string>() + run["text"]!.GetValue<string>();
            }
            else
            {
                merged.Add(run.DeepClone());
            }
        }

        return merged;
    }

    private static string FindDocsDirectory()
    {
        for (var dir = new DirectoryInfo(AppContext.BaseDirectory); dir is not null; dir = dir.Parent)
        {
            var docs = Path.Combine(dir.FullName, "docs");
            if (File.Exists(Path.Combine(docs, "PROTOCOL.md")))
            {
                return docs;
            }
        }

        throw new InvalidOperationException("docs/PROTOCOL.md was not found above the test directory.");
    }
}
