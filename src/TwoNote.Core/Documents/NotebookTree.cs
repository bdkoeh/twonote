using YDotNet.Document.Cells;
using YDotNet.Document.Transactions;
using YDotNet.Document.Types.Maps;

namespace TwoNote.Core.Documents;

/// <summary>A section of a notebook (PROTOCOL.md 5.1).</summary>
public sealed record SectionInfo(string Id, string Title, string Order, bool Deleted);

/// <summary>A page entry of a notebook (PROTOCOL.md 5.1). <see cref="Id"/> is also the docId of the page document.</summary>
public sealed record PageInfo(
    string Id, string SectionId, string Title, string Order, bool Deleted, DateTimeOffset CreatedAt, DateTimeOffset UpdatedAt);

/// <summary>
/// The notebook tree document of PROTOCOL.md 5.1 (<c>docId == notebookId</c>): the notebook
/// title, its sections and its page entries. Items are ordered by their fractional
/// <c>order</c> string, ties by id; deletion is a flag, never removal.
/// </summary>
public sealed class NotebookTree : CrdtDocument
{
    private const double FormatVersion = 1;

    private readonly Map _meta;
    private readonly Map _sections;
    private readonly Map _pages;
    private readonly TimeProvider _time;

    /// <summary>Creates an empty replica; fill it with <see cref="CrdtDocument.ApplyUpdate"/> or <see cref="Initialize"/>.</summary>
    public NotebookTree(string notebookId, TimeProvider? time = null)
        : base(notebookId)
    {
        _time = time ?? TimeProvider.System;
        _meta = Doc.Map("meta");
        _sections = Doc.Map("sections");
        _pages = Doc.Map("pages");
    }

    /// <summary>The notebook id (same as <see cref="CrdtDocument.DocId"/>).</summary>
    public string NotebookId => DocId;

    /// <summary>The notebook title; empty until the first update has arrived.</summary>
    public string Title => Read(txn => _meta.Get(txn, "title") is { Tag: OutputTag.String } o ? o.String : "");

    /// <summary>Writes the fields a brand-new notebook starts with. Only the device that creates the notebook calls this.</summary>
    public void Initialize(string title)
    {
        ArgumentNullException.ThrowIfNull(title);
        Write((txn, scope) =>
        {
            _meta.Insert(txn, "formatVersion", ToInput(FormatVersion, scope));
            _meta.Insert(txn, "title", ToInput(title, scope));
        }, system: true);
    }

    /// <summary>Renames the notebook.</summary>
    public void SetTitle(string title)
    {
        ArgumentNullException.ThrowIfNull(title);
        Write((txn, scope) => _meta.Insert(txn, "title", ToInput(title, scope)));
    }

    // ---- reading --------------------------------------------------------------------------

    /// <summary>The sections in display order.</summary>
    public IReadOnlyList<SectionInfo> GetSections(bool includeDeleted = false) =>
        Read(txn => ReadSections(txn, includeDeleted));

    /// <summary>The pages of one section in display order.</summary>
    public IReadOnlyList<PageInfo> GetPages(string sectionId, bool includeDeleted = false) =>
        Read(txn => ReadPages(txn, includeDeleted).Where(p => p.SectionId == sectionId).ToList());

    /// <summary>Every page of the notebook, ordered by section id and then display order.</summary>
    public IReadOnlyList<PageInfo> GetAllPages(bool includeDeleted = false) => Read(txn => ReadPages(txn, includeDeleted));

    /// <summary>One section, or null.</summary>
    public SectionInfo? GetSection(string sectionId) =>
        Read(txn => _sections.Get(txn, sectionId) is { Tag: OutputTag.Map } o ? ReadSection(txn, sectionId, o.Map) : null);

    /// <summary>One page entry, or null.</summary>
    public PageInfo? GetPage(string pageId) =>
        Read(txn => _pages.Get(txn, pageId) is { Tag: OutputTag.Map } o ? ReadPage(txn, pageId, o.Map) : null);

    // ---- sections -------------------------------------------------------------------------

    /// <summary>Adds a section at <paramref name="index"/> among the visible sections (null = at the end) and returns its id.</summary>
    public string AddSection(string title, int? index = null)
    {
        ArgumentNullException.ThrowIfNull(title);
        var id = WireEncoding.IdToHex(WireEncoding.NewId());
        Write((txn, scope) =>
        {
            var order = OrderFor(ReadSections(txn, false).Select(s => s.Order).ToList(), index);
            _sections.Insert(txn, id, scope.Map(new Dictionary<string, Input>
            {
                ["title"] = ToInput(title, scope),
                ["order"] = ToInput(order, scope),
                ["deleted"] = ToInput(false, scope),
            }));
        });
        return id;
    }

    /// <summary>Renames a section.</summary>
    public void RenameSection(string sectionId, string title)
    {
        ArgumentNullException.ThrowIfNull(title);
        Write((txn, scope) => Section(txn, sectionId).Insert(txn, "title", ToInput(title, scope)));
    }

    /// <summary>Moves a section to <paramref name="index"/> among the other visible sections (null = to the end).</summary>
    public void MoveSection(string sectionId, int? index)
    {
        Write((txn, scope) =>
        {
            var map = Section(txn, sectionId);
            var others = ReadSections(txn, false).Where(s => s.Id != sectionId).Select(s => s.Order).ToList();
            map.Insert(txn, "order", ToInput(OrderFor(others, index), scope));
        });
    }

    /// <summary>Sets or clears the <c>deleted</c> flag of a section. Its pages keep their own flags.</summary>
    public void SetSectionDeleted(string sectionId, bool deleted = true) =>
        Write((txn, scope) => Section(txn, sectionId).Insert(txn, "deleted", ToInput(deleted, scope)));

    // ---- pages ----------------------------------------------------------------------------

    /// <summary>
    /// Adds a page entry at <paramref name="index"/> among the visible pages of the section
    /// (null = at the end) and returns the page id, which is the docId of its page document.
    /// </summary>
    public string AddPage(string sectionId, string title, int? index = null)
    {
        ArgumentNullException.ThrowIfNull(sectionId);
        ArgumentNullException.ThrowIfNull(title);
        var id = WireEncoding.IdToHex(WireEncoding.NewId());
        Write((txn, scope) =>
        {
            var siblings = ReadPages(txn, false).Where(p => p.SectionId == sectionId).Select(p => p.Order).ToList();
            var now = Now();
            _pages.Insert(txn, id, scope.Map(new Dictionary<string, Input>
            {
                ["sectionId"] = ToInput(sectionId, scope),
                ["title"] = ToInput(title, scope),
                ["order"] = ToInput(OrderFor(siblings, index), scope),
                ["deleted"] = ToInput(false, scope),
                ["createdAt"] = ToInput(now, scope),
                ["updatedAt"] = ToInput(now, scope),
            }));
        });
        return id;
    }

    /// <summary>Renames a page and bumps its <c>updatedAt</c>.</summary>
    public void RenamePage(string pageId, string title)
    {
        ArgumentNullException.ThrowIfNull(title);
        Write((txn, scope) =>
        {
            var map = Page(txn, pageId);
            map.Insert(txn, "title", ToInput(title, scope));
            map.Insert(txn, "updatedAt", ToInput(Now(), scope));
        });
    }

    /// <summary>Moves a page into <paramref name="sectionId"/> at <paramref name="index"/> among its other visible pages (null = to the end).</summary>
    public void MovePage(string pageId, string sectionId, int? index)
    {
        ArgumentNullException.ThrowIfNull(sectionId);
        Write((txn, scope) =>
        {
            var map = Page(txn, pageId);
            var others = ReadPages(txn, false).Where(p => p.SectionId == sectionId && p.Id != pageId).Select(p => p.Order).ToList();
            map.Insert(txn, "sectionId", ToInput(sectionId, scope));
            map.Insert(txn, "order", ToInput(OrderFor(others, index), scope));
        });
    }

    /// <summary>Sets or clears the <c>deleted</c> flag of a page. The page document is removed later with <c>DELETE /docs</c>.</summary>
    public void SetPageDeleted(string pageId, bool deleted = true) =>
        Write((txn, scope) => Page(txn, pageId).Insert(txn, "deleted", ToInput(deleted, scope)));

    /// <summary>Sets <c>updatedAt</c> of a page to now. Call when the page content was edited.</summary>
    public void TouchPage(string pageId) =>
        Write((txn, scope) => Page(txn, pageId).Insert(txn, "updatedAt", ToInput(Now(), scope)));

    // ---- helpers --------------------------------------------------------------------------

    /// <summary>Timestamps are milliseconds since the Unix epoch, written as doubles.</summary>
    private double Now() => _time.GetUtcNow().ToUnixTimeMilliseconds();

    private Map Section(Transaction txn, string sectionId) =>
        _sections.Get(txn, sectionId) is { Tag: OutputTag.Map } o ? o.Map : throw new KeyNotFoundException("No such section.");

    private Map Page(Transaction txn, string pageId) =>
        _pages.Get(txn, pageId) is { Tag: OutputTag.Map } o ? o.Map : throw new KeyNotFoundException("No such page.");

    /// <summary>
    /// The order key for position <paramref name="index"/> in a sorted list of sibling keys.
    /// Keys this client cannot parse, and neighbours with identical keys (two devices inserted
    /// at the same place while offline), are stepped over: the item then lands after the tied
    /// group, which is the closest position that can be expressed.
    /// </summary>
    private static string OrderFor(List<string> siblingOrders, int? index)
    {
        var keys = siblingOrders.Where(FractionalIndex.IsValid).ToList(); // already sorted
        var at = Math.Clamp(index ?? keys.Count, 0, keys.Count);
        var before = at > 0 ? keys[at - 1] : null;
        string? after = null;
        for (var i = at; i < keys.Count; i++)
        {
            if (before is null || FractionalIndex.Compare(keys[i], before) > 0)
            {
                after = keys[i];
                break;
            }
        }

        return FractionalIndex.Between(before, after);
    }

    private List<SectionInfo> ReadSections(Transaction txn, bool includeDeleted)
    {
        var list = new List<SectionInfo>();
        foreach (var (id, value) in Entries(_sections, txn))
        {
            if (value.Tag == OutputTag.Map && ReadSection(txn, id, value.Map) is { } s && (includeDeleted || !s.Deleted))
            {
                list.Add(s);
            }
        }

        list.Sort((a, b) => CompareItems(a.Order, a.Id, b.Order, b.Id));
        return list;
    }

    private List<PageInfo> ReadPages(Transaction txn, bool includeDeleted)
    {
        var list = new List<PageInfo>();
        foreach (var (id, value) in Entries(_pages, txn))
        {
            if (value.Tag == OutputTag.Map && ReadPage(txn, id, value.Map) is { } p && (includeDeleted || !p.Deleted))
            {
                list.Add(p);
            }
        }

        list.Sort((a, b) =>
        {
            var bySection = string.CompareOrdinal(a.SectionId, b.SectionId);
            return bySection != 0 ? bySection : CompareItems(a.Order, a.Id, b.Order, b.Id);
        });
        return list;
    }

    private static List<KeyValuePair<string, Output>> Entries(Map map, Transaction txn)
    {
        using var iterator = map.Iterate(txn);
        return [.. iterator];
    }

    private static int CompareItems(string orderA, string idA, string orderB, string idB)
    {
        var byOrder = FractionalIndex.Compare(orderA, orderB);
        return byOrder != 0 ? byOrder : string.CompareOrdinal(idA, idB);
    }

    private static SectionInfo ReadSection(Transaction txn, string id, Map map) =>
        new(id, Str(map, txn, "title"), Str(map, txn, "order"), Flag(map, txn, "deleted"));

    private static PageInfo ReadPage(Transaction txn, string id, Map map) =>
        new(id, Str(map, txn, "sectionId"), Str(map, txn, "title"), Str(map, txn, "order"), Flag(map, txn, "deleted"),
            Time(map, txn, "createdAt"), Time(map, txn, "updatedAt"));

    private static string Str(Map map, Transaction txn, string key) => FromOutput(map.Get(txn, key)) as string ?? "";

    private static bool Flag(Map map, Transaction txn, string key) => FromOutput(map.Get(txn, key)) is true;

    private static DateTimeOffset Time(Map map, Transaction txn, string key)
    {
        var ms = FromOutput(map.Get(txn, key)) as double? ?? 0;
        return double.IsFinite(ms) && ms is > -6.2e13 and < 2.5e14 // the range DateTimeOffset can hold
            ? DateTimeOffset.FromUnixTimeMilliseconds((long)ms)
            : DateTimeOffset.UnixEpoch;
    }
}
