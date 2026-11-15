using System.Text;
using TwoNote.App.Editor;
using TwoNote.App.Logic;
using TwoNote.App.Secrets;
using Xunit;

namespace TwoNote.App.Tests;

public class TextEditTests
{
    private static string Apply(string old, string now, TextEdit e) =>
        string.Concat(old.AsSpan(0, e.Start), now.AsSpan(e.Start, e.InsertCount), old.AsSpan(e.Start + e.DeleteCount));

    [Theory]
    [InlineData("abc\n", "abc\n", 0, 0, 0)]
    [InlineData("abc\n", "abXc\n", 2, 0, 1)]
    [InlineData("abc\n", "ac\n", 1, 1, 0)]
    [InlineData("abc\n", "aXYc\n", 1, 1, 2)]
    [InlineData("\n", "hello\n", 0, 0, 5)]
    [InlineData("hello\n", "\n", 0, 5, 0)]
    public void Finds_the_single_replacement(string old, string now, int start, int deleted, int inserted)
    {
        var edit = TextEdit.Diff(old, now);
        Assert.Equal(new TextEdit(start, deleted, inserted), edit);
        Assert.Equal(now, Apply(old, now, edit));
    }

    [Fact]
    public void The_final_newline_is_never_part_of_the_edit()
    {
        // Appending a paragraph: "a\n" -> "a\n\n" could be read as inserting after the final newline.
        var edit = TextEdit.Diff("a\n", "a\n\n");
        Assert.True(edit.Start + edit.DeleteCount <= 1, edit.ToString());
        Assert.Equal(new TextEdit(1, 0, 1), edit);

        edit = TextEdit.Diff("one\ntwo\n", "one\n");
        Assert.Equal("one\n", Apply("one\ntwo\n", "one\n", edit));
        Assert.True(edit.Start + edit.DeleteCount < "one\ntwo\n".Length);
    }

    [Fact]
    public void The_caret_decides_where_an_edit_in_a_run_of_equal_characters_went()
    {
        // "aaa" -> "aaaa": typed at the start (caret after 1), in the middle (caret after 2) or at the end.
        Assert.Equal(new TextEdit(0, 0, 1), TextEdit.Diff("aaa\n", "aaaa\n", caretHint: 1));
        Assert.Equal(new TextEdit(1, 0, 1), TextEdit.Diff("aaa\n", "aaaa\n", caretHint: 2));
        Assert.Equal(new TextEdit(3, 0, 1), TextEdit.Diff("aaa\n", "aaaa\n", caretHint: 4));

        // Enter in a run of empty paragraphs.
        Assert.Equal(new TextEdit(1, 0, 1), TextEdit.Diff("\n\n\n", "\n\n\n\n", caretHint: 2));
    }

    [Fact]
    public void A_surrogate_pair_is_never_cut_in_half()
    {
        // 😀 (D83D DE00) replaced by 😁 (D83D DE01): the two share the high surrogate.
        var edit = TextEdit.Diff("a😀b\n", "a😁b\n");
        Assert.Equal(new TextEdit(1, 2, 2), edit);

        // 😀 replaced by 🙀 (D83D DE40) at the very start, and a pair sharing the low half (U+1F600 / U+1FA00).
        Assert.Equal(new TextEdit(0, 2, 2), TextEdit.Diff("😀\n", "🙀\n"));
        edit = TextEdit.Diff("x\U0001F600y\n", "x\U0001FA00y\n");
        Assert.Equal(new TextEdit(1, 2, 2), edit);
    }

    [Fact]
    public void Random_edits_are_always_reproduced_and_never_split_a_pair()
    {
        var rng = new Random(20261114);
        string[] pieces = ["a", "b", "ab", " ", "\n", "😀", "😁", "é", "漢", "aa"];
        for (var round = 0; round < 3000; round++)
        {
            var old = string.Concat(Enumerable.Range(0, rng.Next(0, 8)).Select(_ => pieces[rng.Next(pieces.Length)])) + "\n";
            var cutA = rng.Next(old.Length);
            if (cutA > 0 && char.IsLowSurrogate(old[cutA]))
            {
                cutA--;
            }

            var cutB = rng.Next(cutA, old.Length);
            if (cutB < old.Length && char.IsLowSurrogate(old[cutB]))
            {
                cutB++;
            }

            cutB = Math.Min(cutB, old.Length - 1);
            var inserted = string.Concat(Enumerable.Range(0, rng.Next(0, 4)).Select(_ => pieces[rng.Next(pieces.Length)]));
            var now = old[..cutA] + inserted + old[cutB..];
            var caret = rng.Next(3) == 0 ? -1 : cutA + inserted.Length;

            var edit = TextEdit.Diff(old, now, caret);
            Assert.Equal(now, Apply(old, now, edit));
            Assert.True(edit.Start + edit.DeleteCount <= old.Length - 1, "the final newline was deleted");
            Assert.False(edit.Start > 0 && edit.Start < old.Length && char.IsLowSurrogate(old[edit.Start]) && char.IsHighSurrogate(old[edit.Start - 1]), "start splits a pair");
            var end = edit.Start + edit.DeleteCount;
            Assert.False(end > 0 && end < old.Length && char.IsLowSurrogate(old[end]) && char.IsHighSurrogate(old[end - 1]), "end splits a pair");
            var insEnd = edit.Start + edit.InsertCount;
            Assert.False(insEnd > 0 && insEnd < now.Length && char.IsLowSurrogate(now[insEnd]) && char.IsHighSurrogate(now[insEnd - 1]), "insert splits a pair");
        }
    }
}

public class RichModelTests
{
    [Fact]
    public void Cells_come_from_runs_and_block_attributes_live_on_newlines_only()
    {
        var cells = RichModel.CellsFromRuns(
        [
            ("Hi", new Dictionary<string, object?> { ["bold"] = true, ["block"] = "h1" }),
            ("\n", new Dictionary<string, object?> { ["block"] = "todo", ["checked"] = true, ["indent"] = 2.0, ["italic"] = true }),
            ("x\n", new Dictionary<string, object?> { ["link"] = "https://e.example/", ["color"] = "red" }),
        ]);
        Assert.Equal(5, cells.Count);
        Assert.True(cells[0].Inline.Bold);
        Assert.Equal(default, cells[0].Block); // a block attribute on a letter means nothing
        Assert.Equal(new BlockAttrs("todo", 2, true), cells[2].Block);
        Assert.True(cells[2].Inline.Italic);
        Assert.Equal("https://e.example/", cells[3].Inline.Link);
        Assert.Equal("Hi{b}|\\n[i|todo,indent=2,checked]\nx{link=https://e.example/}|\\n[link=https://e.example/|]\n", RichModel.Dump(cells));
        Assert.Contains("x{link=*}|", RichModel.Dump(cells, linkAsFlag: true));
    }

    [Fact]
    public void Unknown_and_out_of_range_block_values_are_kept_raw_and_shown_as_something_safe()
    {
        var raw = new BlockAttrs("quote", 12, true);
        Assert.Equal(new BlockAttrs(null, 8, false), raw.Effective());
        Assert.Equal("quote", raw.Get("block"));
        Assert.Equal(12.0, raw.Get("indent"));
        Assert.Equal(new BlockAttrs("todo", 3, true), new BlockAttrs("todo", 3, true).Effective());
        Assert.False(new BlockAttrs("ul", 0, true).Effective().Checked); // checked only counts for a to-do

        // Numbers arrive as doubles (or, from a client that broke the rules, as integers); nonsense becomes 0.
        Assert.Equal(3, default(BlockAttrs).With("indent", 3.0).Indent);
        Assert.Equal(3, default(BlockAttrs).With("indent", 3L).Indent);
        Assert.Equal(0, default(BlockAttrs).With("indent", double.NaN).Indent);
        Assert.Equal(0, default(BlockAttrs).With("indent", "3").Indent);
        Assert.Null(new BlockAttrs("h1", 0, false).With("block", null).Block);
    }

    [Fact]
    public void Inline_attributes_round_trip_through_their_dictionary_form()
    {
        var a = new InlineAttrs(true, false, true, false, true, "mailto:a@b.example");
        var d = a.ToAttributes();
        Assert.Equal(["bold", "code", "link", "underline"], d.Keys.Order());
        var back = d.Aggregate(default(InlineAttrs), (acc, kv) => acc.With(kv.Key, kv.Value));
        Assert.Equal(a, back);
        Assert.Empty(default(InlineAttrs).ToAttributes());
        Assert.Equal(default, a.With("bold", null).With("underline", null).With("code", null).With("link", null));
    }

    [Fact]
    public void Paragraph_boundaries()
    {
        var m = new RichModel();
        m.Cells.AddRange("ab\n\ncd\n".Select(c => new Cell(c, default, default)));
        Assert.Equal(0, m.ParagraphStart(1));
        Assert.Equal(2, m.ParagraphEnd(0));
        Assert.Equal(3, m.ParagraphStart(3));
        Assert.Equal(3, m.ParagraphEnd(3));
        Assert.Equal(4, m.ParagraphStart(5));
        Assert.Equal(6, m.ParagraphEnd(4));
        Assert.Equal(6, m.ParagraphEnd(99));
        Assert.Equal("ab\n\ncd\n", m.Text);
        Assert.Equal(default, new RichModel().BlockAt(0));
    }
}

public class PasteFilterTests
{
    [Theory]
    [InlineData(@"{\rtf1\ansi plain \b bold\b0  \i italic\i0\par second\par}", true)]
    [InlineData(@"{\rtf1\ansi{\fonttbl{\f0 Arial;}}{\colortbl;\red255\green0\blue0;}\f0\fs40\cf1 big red}", true)]
    [InlineData(@"{\rtf1{\*\pn\pnlvlblt\pnf1{\pntxtb\'B7}}{\pntext\f1\'B7\tab}bullet\par}", true)]
    [InlineData(@"{\rtf1 x{\pict\pngblip 89504e47}y}", false)]
    [InlineData(@"{\rtf1 {\*\shppict{\pict\emfblip 0100}}}", false)]
    [InlineData(@"{\rtf1{\object\objemb{\*\objclass Excel.Sheet.12}{\*\objdata 0105}}}", false)]
    [InlineData(@"{\rtf1\trowd\cellx1000\cellx2000 a\cell b\cell\row}", false)]
    [InlineData(@"{\rtf1 a\par\pard\intbl b\cell}", false)]
    [InlineData(@"{\rtf1{\field{\*\fldinst{HYPERLINK ""https://e.example""}}{\fldrslt link}}}", false)]
    [InlineData(@"{\rtf1{\shp{\*\shpinst\shpleft0}}}", false)]
    [InlineData(@"{\rtf1 \bin4 abcd}", false)]
    [InlineData("just text", false)]
    [InlineData("", false)]
    [InlineData(null, false)]
    public void Rich_text_is_accepted_only_when_it_is_text_and_simple_formatting(string? rtf, bool safe) =>
        Assert.Equal(safe, PasteFilter.RtfIsSafe(rtf));

    [Fact]
    public void Control_words_that_merely_start_like_a_dangerous_one_are_fine()
    {
        Assert.True(PasteFilter.RtfIsSafe(@"{\rtf1\rowdy\cellar\binary\fieldwork text}")); // not \row, \cell, \bin, \field
        Assert.False(PasteFilter.RtfIsSafe(@"{\rtf1\row}"));
        Assert.False(PasteFilter.RtfIsSafe(@"{\rtf1\cell }"));
        Assert.False(PasteFilter.RtfIsSafe(@"{\rtf1\bin12 }"));
    }

    [Fact]
    public void Plain_text_is_cleaned()
    {
        Assert.Equal("a\nb\nc\n", PasteFilter.SanitizePlainText("a\r\nb\rc\n"));
        Assert.Equal("tab\there", PasteFilter.SanitizePlainText("tab\there"));
        Assert.Equal("ab", PasteFilter.SanitizePlainText("a\0\u0001\u001b\u007fb"));
        Assert.Equal("xy", PasteFilter.SanitizePlainText("x\uFFFC\uFFF9\uFFFA\uFFFB\ay"));
        Assert.Equal("soft\u2028break", PasteFilter.SanitizePlainText("soft\vbreak"));
        Assert.Equal("soft\u2028break", PasteFilter.SanitizePlainText("soft\u2028break"));
        Assert.Equal("para\nbreak", PasteFilter.SanitizePlainText("para\u2029break"));
        Assert.Equal("ok😀", PasteFilter.SanitizePlainText("ok😀"));
        Assert.Equal("ab", PasteFilter.SanitizePlainText("a\uD83Db")); // a lone high surrogate
        Assert.Equal("ab", PasteFilter.SanitizePlainText("a\uDE00b")); // a lone low surrogate
        Assert.Equal("", PasteFilter.SanitizePlainText(null));
        Assert.Equal("", PasteFilter.SanitizePlainText(""));
    }

    [Fact]
    public void Embedded_objects_and_table_marks_are_recognised()
    {
        Assert.True(PasteFilter.ContainsForbidden("a\uFFFCb"));
        Assert.True(PasteFilter.ContainsForbidden("\uFFF9\ncell\a\uFFFB\n"));
        Assert.False(PasteFilter.ContainsForbidden("plain text\twith tabs\nand lines\u2028"));
        Assert.False(PasteFilter.ContainsForbidden(""));
    }
}

public class EmergencyKitTests
{
    [Fact]
    public void The_kit_holds_what_is_needed_to_get_back_in_and_never_the_password()
    {
        var html = EmergencyKit.BuildHtml("http://nas.local:8080", "bob", "T2-ABCDEF-GHJKMN-PQRSTV-WXYZ0123", new DateTimeOffset(2026, 11, 14, 12, 0, 0, TimeSpan.Zero));
        Assert.Contains("http://nas.local:8080", html);
        Assert.Contains(">bob<", html);
        Assert.Contains("T2-ABCDEF-GHJKMN-PQRSTV-WXYZ0123", html);
        Assert.Contains("write it here by hand", html);
        Assert.Contains("There is no recovery", html);
        Assert.Contains("14 November 2026", html.Replace("13 November 2026", "14 November 2026").Replace("15 November 2026", "14 November 2026")); // local time zone
        Assert.DoesNotContain("password\" value", html);
        Assert.DoesNotContain("<input", html);
    }

    [Fact]
    public void The_kit_is_one_self_contained_file_that_prints()
    {
        var html = EmergencyKit.BuildHtml("https://notes.example", "user", "T2-AAAAAA-AAAAAA-AAAAAA-AAAAAAAA", DateTimeOffset.UnixEpoch);
        Assert.StartsWith("<!DOCTYPE html>", html);
        Assert.DoesNotContain("<script", html, StringComparison.OrdinalIgnoreCase);
        Assert.DoesNotMatch("(?i)(src|href)\\s*=", html);
        Assert.DoesNotContain("@import", html);
        Assert.DoesNotContain("url(", html);
        Assert.Contains("@page", html);
        Assert.Contains("@media print", html);
        Assert.Contains("charset=\"utf-8\"", html);
    }

    [Fact]
    public void Values_are_encoded()
    {
        var html = EmergencyKit.BuildHtml("http://h/?a=1&b=<2>", "<script>alert(1)</script>", "T2-X", DateTimeOffset.UnixEpoch);
        Assert.DoesNotContain("<script>alert", html);
        Assert.Contains("&lt;script&gt;alert(1)&lt;/script&gt;", html);
        Assert.Contains("a=1&amp;b=&lt;2&gt;", html);
    }

    [Theory]
    [InlineData("bob", "TwoNote Emergency Kit - bob.html")]
    [InlineData("a/b\\c:d*e?", "TwoNote Emergency Kit - abcde.html")]
    [InlineData("../..", "TwoNote Emergency Kit.html")]
    [InlineData("", "TwoNote Emergency Kit.html")]
    public void The_suggested_file_name_is_safe(string username, string expected) =>
        Assert.Equal(expected, EmergencyKit.SuggestedFileName(username));
}

public class PasswordStrengthTests
{
    [Theory]
    [InlineData("", 0)]
    [InlineData("password", 0)]
    [InlineData("Password1", 0)]
    [InlineData("qwerty12", 0)]
    [InlineData("abc", 0)]
    [InlineData("aaaaaaaaaaaaaaaa", 0)]
    public void Hopeless_passwords_score_zero(string password, int score) =>
        Assert.Equal(score, PasswordStrength.Evaluate(password).Score);

    [Fact]
    public void Longer_and_more_varied_is_better()
    {
        var weak = PasswordStrength.Evaluate("sunshine1").Score;
        var medium = PasswordStrength.Evaluate("Sunshine-19x").Score;
        var strong = PasswordStrength.Evaluate("correct horse battery staple lamp").Score;
        Assert.True(weak <= medium && medium <= strong, $"{weak} {medium} {strong}");
        Assert.True(weak <= 1, weak.ToString());
        Assert.True(strong >= 3, strong.ToString());
        Assert.Equal(4, PasswordStrength.Evaluate("v9$Kq!2mZx#7Lp@4Wd&8Rt").Score);
        Assert.All(new[] { "", "password", "sunshine1", "correct horse battery staple lamp" }, p => Assert.NotEmpty(PasswordStrength.Evaluate(p).Hint));
    }
}

public class SearchIndexTests
{
    private static SearchIndex Sample()
    {
        var index = new SearchIndex();
        index.Set(new SearchEntry("n1", "Home", "s1", "Recipes", "p1", "Pancakes", "Flour, eggs and milk.\nFry in butter.\n"));
        index.Set(new SearchEntry("n1", "Home", "s1", "Recipes", "p2", "Crêpes Suzette", "Like pancakes, but thin. Orange sauce.\n"));
        index.Set(new SearchEntry("n2", "Work", "s2", "Meetings", "p3", "Monday", "Budget review; pancake day is on Tuesday.\n"));
        index.Set(new SearchEntry("n2", "Work", "s2", "Meetings", "p4", "Empty", "\n"));
        return index;
    }

    [Fact]
    public void Finds_in_titles_and_text_ignoring_case_and_accents_with_title_matches_first()
    {
        var hits = Sample().Search("PANCAKE");
        Assert.Equal(["p1", "p2", "p3"], hits.Select(h => h.Entry.PageId));
        Assert.True(hits[0].TitleMatch);
        Assert.False(hits[1].TitleMatch);
        Assert.Equal(["p2"], Sample().Search("crepes").Select(h => h.Entry.PageId));
        Assert.Equal(["p2"], Sample().Search("CRÊPES").Select(h => h.Entry.PageId));
    }

    [Fact]
    public void Every_word_must_occur_somewhere_in_the_page()
    {
        Assert.Equal(["p1"], Sample().Search("pancakes butter").Select(h => h.Entry.PageId));
        Assert.Equal(["p3"], Sample().Search("  monday   budget ").Select(h => h.Entry.PageId)); // one word in the title, one in the text
        Assert.Empty(Sample().Search("pancakes spaceship"));
        Assert.Empty(Sample().Search(""));
        Assert.Empty(Sample().Search("   "));
        Assert.Empty(Sample().Search(null));
    }

    [Fact]
    public void Snippets_show_the_text_around_the_match_on_one_line()
    {
        var hit = Assert.Single(Sample().Search("butter"));
        Assert.Contains("Fry in butter", hit.Snippet);
        Assert.DoesNotContain("\n", hit.Snippet);
        var title = Assert.Single(Sample().Search("monday"));
        Assert.StartsWith("Budget review", title.Snippet); // matched in the title only: the page's beginning
        Assert.Equal("", SearchIndex.Snippet("", -1, 0));
        var longText = new string('x', 200) + " needle " + new string('y', 200);
        var snippet = SearchIndex.Snippet(longText, 201, 6);
        Assert.StartsWith("…", snippet);
        Assert.EndsWith("…", snippet);
        Assert.Contains("needle", snippet);
        Assert.True(snippet.Length < 100);
    }

    [Fact]
    public void Pages_are_replaced_removed_and_capped()
    {
        var index = Sample();
        index.Set(new SearchEntry("n1", "Home", "s1", "Recipes", "p1", "Waffles", "No more of the other thing.\n"));
        Assert.Equal(4, index.Count);
        Assert.DoesNotContain("p1", index.Search("pancake").Select(h => h.Entry.PageId));
        index.RemoveWhere(e => e.NotebookId == "n2");
        Assert.Equal(2, index.Count);
        Assert.Empty(index.Search("monday"));
        for (var i = 0; i < 50; i++)
        {
            index.Set(new SearchEntry("n", "N", "s", "S", "x" + i, "Bulk " + i, "bulk\n"));
        }

        Assert.Equal(30, index.Search("bulk").Count);
        Assert.Equal(5, index.Search("bulk", max: 5).Count);
        index.Clear();
        Assert.Equal(0, index.Count);
    }
}

public sealed class ProfileTests : IDisposable
{
    private readonly string _root = Path.Combine(Path.GetTempPath(), "twonote-app-tests", Guid.NewGuid().ToString("N"));

    public void Dispose()
    {
        if (Directory.Exists(_root))
        {
            Directory.Delete(_root, recursive: true);
        }
    }

    [Fact]
    public void Profiles_are_isolated_from_each_other_and_from_the_default()
    {
        var def = AppPaths.For(null, _root);
        var a = AppPaths.For("a", _root);
        var b = AppPaths.For("b", _root);
        Assert.Equal(_root, def.Directory);
        Assert.Equal(Path.Combine(_root, "profiles", "a"), a.Directory);
        Assert.Equal(6, new[] { def.DatabasePath, a.DatabasePath, b.DatabasePath, def.SettingsPath, a.SettingsPath, b.SettingsPath }.Distinct().Count());
        Assert.Equal(3, new[] { def.SecretScope, a.SecretScope, b.SecretScope }.Distinct().Count());
        Assert.Equal("TwoNote", def.SecretScope);
        Assert.Null(def.Profile);
        Assert.Equal("a", a.Profile);
    }

    [Theory]
    [InlineData("work", true)]
    [InlineData("Device_2-b", true)]
    [InlineData("", false)]
    [InlineData("..", false)]
    [InlineData("a/b", false)]
    [InlineData("a\\b", false)]
    [InlineData("with space", false)]
    [InlineData("C:", false)]
    [InlineData("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", false)]
    [InlineData(null, false)]
    public void Profile_names_cannot_escape_the_profiles_folder(string? name, bool valid)
    {
        Assert.Equal(valid, AppPaths.IsValidProfileName(name));
        if (!valid && name is not null)
        {
            Assert.Throws<ArgumentException>(() => AppPaths.For(name, _root));
        }
    }

    [Fact]
    public void The_data_root_can_be_moved_with_an_environment_variable()
    {
        var before = Environment.GetEnvironmentVariable(AppPaths.RootOverrideVariable);
        try
        {
            Environment.SetEnvironmentVariable(AppPaths.RootOverrideVariable, _root);
            Assert.Equal(_root, AppPaths.For(null).Directory);
            Environment.SetEnvironmentVariable(AppPaths.RootOverrideVariable, null);
            Assert.Equal(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "TwoNote"), AppPaths.For(null).Directory);
        }
        finally
        {
            Environment.SetEnvironmentVariable(AppPaths.RootOverrideVariable, before);
        }
    }

    [Fact]
    public void Wiping_the_default_profile_leaves_named_profiles_alone_and_the_other_way_round()
    {
        var def = AppPaths.For(null, _root);
        var named = AppPaths.For("other", _root);
        Directory.CreateDirectory(def.Directory);
        Directory.CreateDirectory(named.Directory);
        File.WriteAllText(def.DatabasePath, "default db");
        File.WriteAllText(def.SettingsPath, "{}");
        File.WriteAllText(named.DatabasePath, "named db");
        File.WriteAllText(named.DatabasePath + "-wal", "named wal");

        Assert.Equal(2, def.OwnFiles().Count());
        Assert.Equal(2, named.OwnFiles().Count());
        def.DeleteAll();
        Assert.False(File.Exists(def.DatabasePath));
        Assert.True(File.Exists(named.DatabasePath));

        File.WriteAllText(def.DatabasePath, "default db again");
        named.DeleteAll();
        Assert.False(Directory.Exists(named.Directory));
        Assert.True(File.Exists(def.DatabasePath));
        named.DeleteAll(); // nothing there: fine
        Assert.Empty(named.OwnFiles());
    }

    [Fact]
    public void Settings_round_trip_and_survive_a_damaged_file()
    {
        var path = Path.Combine(_root, "settings.json");
        var fresh = AppSettings.Load(path);
        Assert.Null(fresh.ServerUrl);
        Assert.Equal(10, fresh.AutoLockMinutes);
        Assert.Equal("system", fresh.Theme);

        fresh.ServerUrl = "http://nas.local:8080";
        fresh.AutoLockMinutes = 5;
        fresh.Theme = "dark";
        fresh.SecretStore = "vault";
        fresh.LastNotebookId = "0123456789abcdef0123456789abcdef";
        fresh.LastSection["0123456789abcdef0123456789abcdef"] = "11111111111111111111111111111111";
        fresh.LastPage["11111111111111111111111111111111"] = "22222222222222222222222222222222";
        fresh.Save();
        Assert.False(File.Exists(path + ".tmp"));

        var loaded = AppSettings.Load(path);
        Assert.Equal("http://nas.local:8080", loaded.ServerUrl);
        Assert.Equal(5, loaded.AutoLockMinutes);
        Assert.Equal("dark", loaded.Theme);
        Assert.Equal("vault", loaded.SecretStore);
        Assert.Equal("22222222222222222222222222222222", loaded.LastPage[loaded.LastSection[loaded.LastNotebookId!]]);

        File.WriteAllText(path, "{ this is not json");
        Assert.Equal(10, AppSettings.Load(path).AutoLockMinutes);
        File.WriteAllText(path, """{ "autoLockMinutes": -5, "theme": "purple", "lastSection": null }""");
        var odd = AppSettings.Load(path);
        Assert.Equal(0, odd.AutoLockMinutes);
        Assert.Equal("system", odd.Theme);
        Assert.Empty(odd.LastSection);
    }

    [Fact]
    public void The_protected_file_keeps_secrets_and_holds_no_plaintext()
    {
        if (!OperatingSystem.IsWindows())
        {
            return; // DPAPI is a Windows facility
        }

        var path = Path.Combine(_root, "profile", "secrets.bin");
        const string key = "T2-ABCDEF-GHJKMN-PQRSTV-WXYZ0123";
        const string token = "token-3f9a8c7e6d5b4a39281706f5e4d3c2b1";
        var store = new DpapiSecretStore(path, "TwoNote/profile/x");
        Assert.Null(store.Get(SecretNamesForTest.SecretKey));
        store.Remove(SecretNamesForTest.SecretKey); // nothing there: fine
        Assert.False(File.Exists(path));

        store.Set(SecretNamesForTest.SecretKey, key);
        store.Set(SecretNamesForTest.SessionToken, token);
        store.Set(SecretNamesForTest.SessionToken, token + "-2");
        Assert.Equal(key, store.Get(SecretNamesForTest.SecretKey));
        Assert.Equal(token + "-2", store.Get(SecretNamesForTest.SessionToken));

        // Another instance over the same file reads the same values; the file itself shows nothing.
        Assert.Equal(key, new DpapiSecretStore(path, "TwoNote/profile/x").Get(SecretNamesForTest.SecretKey));
        var bytes = File.ReadAllBytes(path);
        foreach (var secret in new[] { key, token, "secret-key", "session-token" })
        {
            Assert.True(bytes.AsSpan().IndexOf(Encoding.UTF8.GetBytes(secret)) < 0, "UTF-8 plaintext in the file");
            Assert.True(bytes.AsSpan().IndexOf(Encoding.Unicode.GetBytes(secret)) < 0, "UTF-16 plaintext in the file");
        }

        Assert.False(File.Exists(path + ".tmp"));

        // The scope is part of the protection: the file copied to another profile does not open there.
        Assert.Null(new DpapiSecretStore(path, "TwoNote/profile/y").Get(SecretNamesForTest.SecretKey));

        // A damaged file is as good as empty rather than a crash.
        File.WriteAllBytes(path, [1, 2, 3, 4, 5]);
        Assert.Null(store.Get(SecretNamesForTest.SecretKey));
        store.Set(SecretNamesForTest.SecretKey, key);
        Assert.Equal(key, store.Get(SecretNamesForTest.SecretKey));

        store.Remove(SecretNamesForTest.SecretKey);
        Assert.Null(store.Get(SecretNamesForTest.SecretKey));
        store.Clear();
        Assert.False(File.Exists(path));
        store.Clear();
    }

    private static class SecretNamesForTest
    {
        public const string SecretKey = TwoNote.Core.SecretNames.SecretKey;
        public const string SessionToken = TwoNote.Core.SecretNames.SessionToken;
    }
}
