using TwoNote.App.Editor;
using Xunit;

namespace TwoNote.App.Tests;

public class HtmlPasteTests
{
    private static string Dump(IReadOnlyList<PastedParagraph> paragraphs) =>
        string.Join("\n", paragraphs.Select(p =>
            $"[{p.Block.Block ?? "p"}{(p.Block.Indent > 0 ? $">{p.Block.Indent}" : "")}{(p.Block.Checked ? " x" : "")}] "
            + string.Concat(p.Runs.Select(r =>
            {
                var marks = (r.Inline.Bold ? "b" : "") + (r.Inline.Italic ? "i" : "") + (r.Inline.Underline ? "u" : "")
                    + (r.Inline.Strike ? "s" : "") + (r.Inline.Code ? "c" : "") + (r.Inline.Link is null ? "" : $"@{r.Inline.Link}");
                return marks.Length == 0 ? r.Text : $"{{{marks}:{r.Text}}}";
            }))));

    [Fact]
    public void Slack_message_keeps_inline_formats_and_lists()
    {
        const string html = """
            <meta charset='utf-8'><b data-stringify-type="bold">Bold</b> then <i data-stringify-type="italic">italic</i>,
            <s data-stringify-type="strike">gone</s> and <code class="c-mrkdwn__code">x = 1</code>
            <ul data-stringify-type="unordered-list" class="p-rich_text_list" data-indent="0" data-border="0"><li data-stringify-indent="0">one</li><li data-stringify-indent="0">two</li></ul>
            <ul data-stringify-type="unordered-list" class="p-rich_text_list" data-indent="1" data-border="0"><li data-stringify-indent="1">nested</li></ul>
            <ol data-stringify-type="ordered-list" class="p-rich_text_list" data-indent="0" data-border="0"><li>first</li><li>second <b>strong</b></li></ol>
            """;
        Assert.Equal(
            """
            [p] {b:Bold} then {i:italic}, {s:gone} and {c:x = 1}
            [ul] one
            [ul] two
            [ul>1] nested
            [ol] first
            [ol] second {b:strong}
            """.ReplaceLineEndings("\n"),
            Dump(HtmlPaste.Parse(html)));
    }

    [Fact]
    public void OneNote_style_spans_and_nested_lists()
    {
        const string html = """
            <html xmlns:o="urn:schemas-microsoft-com:office:office"><head><meta name=ProgId content=OneNote.File><style>p {margin:0}</style></head>
            <body lang=en-US style='font-family:Calibri;font-size:11.0pt'>
            <p style='margin:0in'><span style='font-weight:bold'>Heading-ish</span> and <span style='font-style:italic;text-decoration:underline'>both</span>
            and <span style='text-decoration:line-through'>struck</span></p>
            <ul type=disc style='margin-left:.375in'><li><span>outer</span>
              <ul type=circle><li><span style='font-weight:bold'>inner</span></li></ul></li>
              <li>after</li></ul>
            <ol type=1><li value=1>num</li></ol>
            <h1>Title</h1><h5>Small</h5>
            </body></html>
            """;
        Assert.Equal(
            """
            [p] {b:Heading-ish} and {iu:both} and {s:struck}
            [ul] outer
            [ul>1] {b:inner}
            [ul] after
            [ol] num
            [h1] Title
            [h3] Small
            """.ReplaceLineEndings("\n"),
            Dump(HtmlPaste.Parse(html)));
        Assert.False(HtmlPaste.IsWordHtml(html));
    }

    [Fact]
    public void Tags_links_code_blocks_todos_and_entities()
    {
        const string html = """
            <p>a &amp; b &lt;tag&gt;&nbsp;<a href="https://example.com/x?y=1&amp;z=2">site</a> <a href="javascript:alert(1)">bad</a>
            <strong><em>both</em></strong> <u>under</u> <del>del</del></p>
            <pre><code>line 1
              line 2</code></pre>
            <ul><li><input type="checkbox" checked> done</li><li><input type=checkbox> open</li></ul>
            <div>one<br>two</div>
            <p>   </p>
            """;
        Assert.Equal(
            """
            [p] a & b <tag> {@https://example.com/x?y=1&z=2:site} bad {bi:both} {u:under} {s:del}
            [code] line 1
            [code]   line 2
            [todo x] done
            [todo] open
            [p] one
            [p] two
            """.ReplaceLineEndings("\n"),
            Dump(HtmlPaste.Parse(html)));
    }

    [Fact]
    public void Google_docs_wrapper_does_not_make_everything_bold()
    {
        const string html = """<b style="font-weight:normal;" id="docs-internal-guid-1"><p><span style="font-weight:400">plain </span><span style="font-weight:700">bold</span></p></b>""";
        Assert.Equal("[p] plain {b:bold}", Dump(HtmlPaste.Parse(html)));
    }

    [Fact]
    public void Scripts_styles_comments_pictures_and_tables_leave_only_text()
    {
        const string html = """
            <style>p{color:red}</style><script>alert('<p>x</p>')</script><!-- <b>hidden</b> -->
            <img src="https://example.com/p.png" alt="a picture"><img class="c-emoji" data-stringify-emoji=":+1:" alt="👍" src="x">
            <table><tr><td>a</td><td>b</td></tr><tr><td>c</td></tr></table>
            """;
        Assert.Equal("[p] 👍\n[p] a b\n[p] c", Dump(HtmlPaste.Parse(html)));
    }

    [Fact]
    public void Empty_or_textless_html_gives_nothing()
    {
        Assert.Empty(HtmlPaste.Parse(null));
        Assert.Empty(HtmlPaste.Parse(""));
        Assert.Empty(HtmlPaste.Parse("<div><p> </p><br><img src='x'></div>"));
    }

    [Fact]
    public void Malformed_html_does_not_throw()
    {
        Assert.Equal("[p] a < b", Dump(HtmlPaste.Parse("a < b")));
        Assert.Equal("[p] {b:open}", Dump(HtmlPaste.Parse("<b>open")));
        Assert.Equal("[p] x\n[p] y", Dump(HtmlPaste.Parse("</i>x</b></ul></li> y<a href=")));
    }

    [Fact]
    public void Fragment_is_cut_out_of_the_clipboard_format()
    {
        const string cf = "Version:0.9\r\nStartHTML:0000000105\r\nEndHTML:0000000200\r\nStartFragment:0000000141\r\nEndFragment:0000000164\r\n"
            + "<html><body><!--StartFragment--><b>hi</b> there<!--EndFragment--></body></html>";
        Assert.Equal("<b>hi</b> there", HtmlPaste.ExtractFragment(cf));
        Assert.Equal("<p>x</p>", HtmlPaste.ExtractFragment("Version:1.0\r\nStartHTML:1\r\n<p>x</p>"));
        Assert.Equal("", HtmlPaste.ExtractFragment(null));
    }

    [Fact]
    public void Word_html_is_recognised()
    {
        Assert.True(HtmlPaste.IsWordHtml("<html xmlns:w=\"urn:schemas-microsoft-com:office:word\"><meta name=ProgId content=Word.Document>"));
        Assert.False(HtmlPaste.IsWordHtml("<b>slack</b>"));
        Assert.False(HtmlPaste.IsWordHtml(null));
    }
}
