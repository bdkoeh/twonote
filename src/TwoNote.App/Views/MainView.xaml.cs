using System.Diagnostics;
using Microsoft.UI.Input;
using Microsoft.UI.Text;
using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Controls.Primitives;
using Microsoft.UI.Xaml.Input;
using TwoNote.App.Editor;
using TwoNote.App.Logic;
using TwoNote.Core;
using TwoNote.Core.Documents;
using Windows.ApplicationModel.DataTransfer;
using Windows.System;
using Windows.UI.Core;

namespace TwoNote.App.Views;

/// <summary>The unlocked app: notebook switcher, sections, pages and the editor.</summary>
internal sealed partial class MainView : UserControl
{
    private const string Untitled = "Untitled page";

    private readonly MainWindow _shell;
    private readonly AppSession _session;
    private readonly SearchIndex _index = new();
    private TwoNoteClient? _client;
    private NotebookTree? _tree;
    private string? _notebookId;
    private string? _sectionId;
    private string? _pageId;
    private string? _wantedPageId;
    private PageDocument? _page;
    private RichEditBinding? _binding;
    private bool _refreshing;
    private bool _overlay;
    private bool _suspended;
    private bool _refreshingTree;
    private bool _refreshAgain;
    private bool _pageEdited;
    private DateTimeOffset _lastTouch;
    private Task? _indexing;
    private DateTimeOffset _indexedAt;
    private (int Start, int End)? _linkTarget;

    public MainView(MainWindow shell, AppSession session)
    {
        _shell = shell;
        _session = session;
        InitializeComponent();

        NotebookButton.Flyout = new MenuFlyout { Placement = FlyoutPlacementMode.BottomEdgeAlignedLeft };
        NotebookButton.Flyout.Opening += (_, _) => BuildNotebookMenu();
        AddSectionButton.Click += async (_, _) => await PromptNewSectionAsync();
        AddPageButton.Click += (_, _) => NewPageInteractive();
        EmptyAction.Click += async (_, _) => await OnEmptyActionAsync();
        SignInButton.Click += async (_, _) => await _shell.PromptSignInAgainAsync();

        SectionList.SelectionChanged += (_, _) =>
        {
            if (!_refreshing && SectionList.SelectedItem is ListViewItem { Tag: string id })
            {
                SelectSection(id);
            }
        };
        PageList.SelectionChanged += (_, _) =>
        {
            if (!_refreshing && PageList.SelectedItem is ListViewItem { Tag: string id })
            {
                SelectPage(id);
            }
        };
        SectionList.DragItemsStarting += (_, _) => DragsStarted++;
        PageList.DragItemsStarting += (_, _) => DragsStarted++;
        SectionList.DragItemsCompleted += (_, e) => OnDragCompleted(SectionList, e, section: true);
        PageList.DragItemsCompleted += (_, e) => OnDragCompleted(PageList, e, section: false);
        SectionList.KeyDown += async (_, e) => await OnListKeyAsync(e, section: true);
        PageList.KeyDown += async (_, e) => await OnListKeyAsync(e, section: false);

        TitleBox.LostFocus += (_, _) => CommitTitle();
        TitleBox.KeyDown += (_, e) =>
        {
            if (e.Key is VirtualKey.Enter or VirtualKey.Down)
            {
                e.Handled = true;
                CommitTitle();
                Editor.Focus(FocusState.Programmatic);
            }
        };

        // Formatting accelerators other than bold/italic/underline are handled (or swallowed) in OnEditorKey.
        Editor.PreviewKeyDown += OnEditorKey;
        Editor.SelectionChanged += (_, _) => UpdateToolbar();
        Editor.Paste += async (_, e) =>
        {
            e.Handled = true;
            await PasteAsync(plainOnly: false);
        };

        UndoButton.Click += (_, _) => Command(b => b.Undo());
        RedoButton.Click += (_, _) => Command(b => b.Redo());
        BoldButton.Click += (_, _) => Command(b => b.ToggleInline("bold"));
        ItalicButton.Click += (_, _) => Command(b => b.ToggleInline("italic"));
        UnderlineButton.Click += (_, _) => Command(b => b.ToggleInline("underline"));
        StrikeButton.Click += (_, _) => Command(b => b.ToggleInline("strike"));
        CodeButton.Click += (_, _) => Command(b => b.ToggleInline("code"));
        LinkButton.Click += (_, _) => ShowLinkFlyout();
        H1Button.Click += (_, _) => Command(b => b.ToggleBlock("h1"));
        H2Button.Click += (_, _) => Command(b => b.ToggleBlock("h2"));
        H3Button.Click += (_, _) => Command(b => b.ToggleBlock("h3"));
        BulletButton.Click += (_, _) => Command(b => b.ToggleBlock("ul"));
        NumberButton.Click += (_, _) => Command(b => b.ToggleBlock("ol"));
        TodoButton.Click += (_, _) => Command(b => b.ToggleBlock("todo"));
        CodeBlockButton.Click += (_, _) => Command(b => b.ToggleBlock("code"));
        IndentButton.Click += (_, _) => Command(b => b.Indent(1));
        OutdentButton.Click += (_, _) => Command(b => b.Indent(-1));

        LinkApplyButton.Click += (_, _) => ApplyLinkFromFlyout();
        LinkRemoveButton.Click += (_, _) =>
        {
            if (_linkTarget is { } t)
            {
                SetLink(t.Start, t.End, null);
            }

            LinkFlyout.Hide();
        };
        LinkOpenButton.Click += (_, _) => OpenLink(LinkUrlBox.Text);
        LinkUrlBox.KeyDown += (_, e) =>
        {
            if (e.Key == VirtualKey.Enter)
            {
                e.Handled = true;
                ApplyLinkFromFlyout();
            }
        };
        LinkFlyout.Closed += (_, _) => UpdateToolbar();

        // In a window too narrow for panes and page side by side, clicking a page closes the panes to show it.
        PageList.ItemClick += (_, _) =>
        {
            if (IsNarrow && !_session.Settings.HidePanes)
            {
                TogglePanes();
            }
        };
        SizeChanged += (_, _) => ApplyPanes();
        ApplyPanes();

        AddHandler(PreviewKeyDownEvent, new KeyEventHandler(OnAppKey), false);
    }

    /// <summary>True when the notebook, section and page panes are hidden.</summary>
    public bool PanesHidden => _session.Settings.HidePanes;

    /// <summary>Hides or shows the notebook, section and page panes (Ctrl+\), leaving only the page.</summary>
    public void TogglePanes()
    {
        _session.Settings.HidePanes = !_session.Settings.HidePanes;
        SaveSettings();
        ApplyPanes();
    }

    /// <summary>True when the view is too narrow to show the side panes and a usable page side by side.</summary>
    private bool IsNarrow => ActualWidth > 0 && ActualWidth < 232 + 252 + 300;

    /// <summary>
    /// Three layouts: panes hidden (page only); wide (sections, pages, page); narrow with panes shown (sections
    /// and pages fill the window and the page waits behind them until a page is clicked or the panes are hidden).
    /// </summary>
    private void ApplyPanes()
    {
        var hidden = _session.Settings.HidePanes;
        var narrow = IsNarrow && !hidden;
        SectionsColumn.Width = hidden ? new GridLength(0) : narrow ? new GridLength(Math.Min(232, ActualWidth * 0.45)) : new GridLength(232);
        PagesColumn.Width = hidden ? new GridLength(0) : narrow ? new GridLength(1, GridUnitType.Star) : new GridLength(252);
        PageColumn.Width = narrow ? new GridLength(0) : new GridLength(1, GridUnitType.Star);
        SectionsPane.Visibility = hidden ? Visibility.Collapsed : Visibility.Visible;
        PagesPane.Visibility = hidden ? Visibility.Collapsed : Visibility.Visible;
        PagePane.Visibility = narrow ? Visibility.Collapsed : Visibility.Visible;
        PageBorder.BorderThickness = hidden ? new Thickness(0, 1, 0, 0) : new Thickness(1, 1, 0, 0);
        PageBorder.CornerRadius = hidden ? new CornerRadius(0) : new CornerRadius(8, 0, 0, 0);
        _shell.ShowPanesState(hidden);
    }

    private bool IsDark => _shell.IsDark;

    /// <summary>The window's theme changed (system setting or the Appearance setting).</summary>
    public void OnThemeChanged() => _binding?.SetTheme(IsDark);

    // ---- state the shell and the self-test read ------------------------------------------------------------

    public RichEditBinding? Binding => _binding;

    public RichEditBox EditorBox => Editor;

    public NotebookTree? Tree => _tree;

    public string? NotebookId => _notebookId;

    public string? SectionId => _sectionId;

    public string? PageId => _pageId;

    public PageDocument? Page => _page;

    public string TitleText => TitleBox.Text;

    public string NotebookTitleText => NotebookTitle.Text;

    public IReadOnlyList<string> SectionTitles => SectionList.Items.OfType<ListViewItem>().Select(i => (string)i.Content).ToList();

    public IReadOnlyList<string> PageTitles => PageList.Items.OfType<ListViewItem>().Select(i => (string)i.Content).ToList();

    public string? SelectedSectionTitle => (SectionList.SelectedItem as ListViewItem)?.Content as string;

    public string? SelectedPageTitle => (PageList.SelectedItem as ListViewItem)?.Content as string;

    public bool EditorVisible => EditorPanel.Visibility == Visibility.Visible;

    public bool AuthBarOpen => AuthBar.IsOpen;

    /// <summary>How many drags of a list item have started (self-test).</summary>
    public int DragsStarted { get; private set; }

    /// <summary>The list item of a section or page (for tests that use the mouse).</summary>
    public ListViewItem? ListItem(string title, bool section) =>
        (section ? SectionList : PageList).Items.OfType<ListViewItem>().FirstOrDefault(i => (string)i.Content == title);

    /// <summary>Names of the toolbar toggles that are lit for the current selection.</summary>
    public string ToolbarState => string.Join(",", new (string Name, ToggleButton Button)[]
    {
        ("bold", BoldButton), ("italic", ItalicButton), ("underline", UnderlineButton), ("strike", StrikeButton), ("code", CodeButton),
        ("link", LinkButton), ("h1", H1Button), ("h2", H2Button), ("h3", H3Button), ("ul", BulletButton), ("ol", NumberButton),
        ("todo", TodoButton), ("codeblock", CodeBlockButton),
    }.Where(b => b.Button.IsChecked == true).Select(b => b.Name));

    // ---- lifetime ------------------------------------------------------------------------------------------

    /// <summary>Called once the client is unlocked.</summary>
    public void Start(bool firstDevice)
    {
        _client = _session.Client!;
        _session.ActiveBinding = () => _binding;
        _client.Sync.NotebooksChanged += OnNotebooksChanged;
        if (firstDevice && _client.NotebookIds.Count == 0)
        {
            // A brand-new account starts with something to type into.
            var tree = _client.CreateNotebook("My notebook");
            var section = tree.AddSection("General");
            var page = _client.CreatePage(tree.NotebookId, section, "");
            _session.Settings.LastNotebookId = tree.NotebookId;
            _session.Settings.LastSection[tree.NotebookId] = section;
            _session.Settings.LastPage[section] = page.DocId;
            _client.ClosePage(page.DocId);
        }

        RefreshNotebooks();
    }

    /// <summary>Removes every piece of decrypted content from the view. Called before the client is locked.</summary>
    public void Teardown()
    {
        CloseCurrentPage();
        if (_client is not null)
        {
            _client.Sync.NotebooksChanged -= OnNotebooksChanged;
        }

        if (_tree is not null)
        {
            _tree.Changed -= OnTreeChanged;
        }

        _session.ActiveBinding = null;
        _client = null;
        _tree = null;
        _notebookId = _sectionId = null;
        _refreshing = true;
        SectionList.Items.Clear();
        PageList.Items.Clear();
        _refreshing = false;
        NotebookTitle.Text = "";
        TitleBox.Text = "";
        LinkTextBox.Text = LinkUrlBox.Text = "";
        LinkFlyout.Hide();
        _index.Clear();
        _indexedAt = default;
        AuthBar.IsOpen = false;
    }

    public void SetAuthRequired(bool required) => AuthBar.IsOpen = required;

    private void OnNotebooksChanged() => DispatcherQueue.TryEnqueue(() =>
    {
        if (_client is not null)
        {
            RefreshNotebooks();
        }
    });

    private void SaveSettings() => _session.Settings.Save();

    // ---- notebooks -----------------------------------------------------------------------------------------

    private List<(string Id, string Title)> Notebooks()
    {
        var list = new List<(string Id, string Title)>();
        if (_client is null)
        {
            return list;
        }

        foreach (var id in _client.NotebookIds)
        {
            try
            {
                var title = _client.OpenNotebook(id).Title;
                list.Add((id, title.Length == 0 ? "Untitled notebook" : title));
            }
            catch (KeyNotFoundException)
            {
                // deleted a moment ago
            }
        }

        return list.OrderBy(n => n.Title, StringComparer.CurrentCultureIgnoreCase).ThenBy(n => n.Id, StringComparer.Ordinal).ToList();
    }

    private void RefreshNotebooks()
    {
        if (_client is null)
        {
            return;
        }

        var ids = _client.NotebookIds;
        if (_notebookId is not null && !ids.Contains(_notebookId))
        {
            // The open notebook was deleted on another device.
            CloseCurrentPage();
            if (_tree is not null)
            {
                _tree.Changed -= OnTreeChanged;
            }

            _tree = null;
            _notebookId = _sectionId = null;
        }

        if (_notebookId is null)
        {
            var preferred = _session.Settings.LastNotebookId;
            var pick = preferred is not null && ids.Contains(preferred) ? preferred : Notebooks().Select(n => n.Id).FirstOrDefault();
            if (pick is not null)
            {
                SelectNotebook(pick);
                return;
            }
        }

        RefreshTree();
    }

    public void SelectNotebook(string notebookId)
    {
        if (_client is null || notebookId == _notebookId)
        {
            return;
        }

        CloseCurrentPage();
        if (_tree is not null)
        {
            _tree.Changed -= OnTreeChanged;
        }

        _tree = _client.OpenNotebook(notebookId);
        _notebookId = notebookId;
        _sectionId = null;
        _tree.Changed += OnTreeChanged;
        _session.Settings.LastNotebookId = notebookId;
        SaveSettings();
        RefreshTree();
    }

    private void BuildNotebookMenu()
    {
        var menu = (MenuFlyout)NotebookButton.Flyout;
        menu.Items.Clear();
        foreach (var (id, title) in Notebooks())
        {
            var item = new ToggleMenuFlyoutItem { Text = title, IsChecked = id == _notebookId };
            item.Click += (_, _) => SelectNotebook(id);
            menu.Items.Add(item);
        }

        if (menu.Items.Count > 0)
        {
            menu.Items.Add(new MenuFlyoutSeparator());
        }

        var add = new MenuFlyoutItem { Text = "New notebook…", Icon = new FontIcon { Glyph = "\uE710" } };
        add.Click += async (_, _) => await PromptNewNotebookAsync();
        menu.Items.Add(add);
        var rename = new MenuFlyoutItem { Text = "Rename this notebook…", Icon = new FontIcon { Glyph = "\uE8AC" }, IsEnabled = _tree is not null };
        rename.Click += async (_, _) =>
        {
            if (_tree is not null && await _shell.PromptAsync("Rename notebook", "Name", _tree.Title, "Rename") is { } name)
            {
                RenameNotebook(name);
            }
        };
        menu.Items.Add(rename);
    }

    private async Task PromptNewNotebookAsync()
    {
        if (await _shell.PromptAsync("New notebook", "Name", "", "Create") is { } name)
        {
            AddNotebook(name);
        }
    }

    /// <summary>Creates a notebook with one section and switches to it.</summary>
    public string? AddNotebook(string title)
    {
        if (_client is null || string.IsNullOrWhiteSpace(title))
        {
            return null;
        }

        var tree = _client.CreateNotebook(title.Trim());
        var section = tree.AddSection("General");
        _session.Settings.LastSection[tree.NotebookId] = section;
        SelectNotebook(tree.NotebookId);
        return tree.NotebookId;
    }

    public void RenameNotebook(string title)
    {
        if (_tree is not null && !string.IsNullOrWhiteSpace(title))
        {
            _tree.SetTitle(title.Trim());
        }
    }

    // ---- the tree: sections and pages ----------------------------------------------------------------------

    private void OnTreeChanged(ChangeSource source)
    {
        if (source == ChangeSource.Local)
        {
            _shell.RefreshSyncStatus();
        }

        if (DispatcherQueue.HasThreadAccess)
        {
            RefreshTree();
        }
        else
        {
            DispatcherQueue.TryEnqueue(RefreshTree);
        }
    }

    /// <summary>Makes the lists, the selection and the title show what the tree document says now.</summary>
    private void RefreshTree()
    {
        if (_client is null || _overlay || _suspended)
        {
            return;
        }

        if (_refreshingTree)
        {
            _refreshAgain = true; // a change arrived while the lists were being rebuilt
            return;
        }

        _refreshingTree = true;
        try
        {
            do
            {
                _refreshAgain = false;
                RefreshTreeCore();
            }
            while (_refreshAgain && _client is not null);
        }
        finally
        {
            _refreshingTree = false;
        }
    }

    private void RefreshTreeCore()
    {
        if (_client is null)
        {
            return;
        }

        if (_tree is null)
        {
            _refreshing = true;
            SectionList.Items.Clear();
            PageList.Items.Clear();
            _refreshing = false;
            NotebookTitle.Text = "No notebook";
            ShowEmpty(
                _client.Sync.Status.LastSyncedAt is null && _client.NotebookIds.Count == 0
                    ? "No notebooks on this device yet. If you have notebooks on another device, they appear here as soon as the first sync has finished."
                    : "No notebooks yet.",
                "Create a notebook");
            return;
        }

        var title = _tree.Title;
        NotebookTitle.Text = title.Length == 0 ? "Untitled notebook" : title;

        var sections = _tree.GetSections();
        if (_sectionId is null || sections.All(s => s.Id != _sectionId))
        {
            var preferred = _session.Settings.LastSection.GetValueOrDefault(_notebookId!);
            _sectionId = sections.Any(s => s.Id == preferred) ? preferred : sections.FirstOrDefault()?.Id;
        }

        Fill(SectionList, sections.Select(s => (s.Id, s.Title.Length == 0 ? "Untitled section" : s.Title)).ToList(), _sectionId, section: true);

        var pages = _sectionId is null ? [] : _tree.GetPages(_sectionId);
        var page = _pageId ?? _wantedPageId;
        _wantedPageId = null;
        if (page is null || pages.All(p => p.Id != page))
        {
            var preferred = _sectionId is null ? null : _session.Settings.LastPage.GetValueOrDefault(_sectionId);
            page = pages.Any(p => p.Id == preferred) ? preferred : pages.FirstOrDefault()?.Id;
        }

        Fill(PageList, pages.Select(p => (p.Id, p.Title.Length == 0 ? Untitled : p.Title)).ToList(), page, section: false);
        PagesEmpty.Visibility = _sectionId is not null && pages.Count == 0 ? Visibility.Visible : Visibility.Collapsed;
        OpenPage(page);

        if (_pageId is not null && (XamlRoot is null || !ReferenceEquals(FocusManager.GetFocusedElement(XamlRoot), TitleBox)))
        {
            var current = _tree.GetPage(_pageId)?.Title ?? "";
            if (TitleBox.Text != current)
            {
                TitleBox.Text = current;
            }
        }

        if (_sectionId is null)
        {
            ShowEmpty("This notebook has no sections yet.", "New section");
        }
        else if (_pageId is null)
        {
            ShowEmpty("This section has no pages yet.", "New page");
        }
    }

    private void Fill(ListView list, List<(string Id, string Title)> items, string? selected, bool section)
    {
        var current = list.Items.OfType<ListViewItem>().Select(i => ((string)i.Tag, (string)i.Content)).ToList();
        _refreshing = true;
        try
        {
            if (!current.SequenceEqual(items))
            {
                list.Items.Clear();
                foreach (var (id, title) in items)
                {
                    var item = new ListViewItem { Content = title, Tag = id };
                    item.ContextFlyout = BuildItemMenu(id, section);
                    list.Items.Add(item);
                }
            }

            var want = list.Items.OfType<ListViewItem>().FirstOrDefault(i => (string)i.Tag == selected);
            if (!ReferenceEquals(list.SelectedItem, want))
            {
                list.SelectedItem = want;
            }
        }
        finally
        {
            _refreshing = false;
        }
    }

    private MenuFlyout BuildItemMenu(string id, bool section)
    {
        var menu = new MenuFlyout();
        MenuFlyoutItem Item(string text, string glyph, Action action)
        {
            var item = new MenuFlyoutItem { Text = text, Icon = new FontIcon { Glyph = glyph } };
            item.Click += (_, _) => action();
            menu.Items.Add(item);
            return item;
        }

        Item("Rename…", "\uE8AC", async () => await PromptRenameAsync(id, section)).KeyboardAcceleratorTextOverride = "F2";
        Item("Move up", "\uE74A", () => Move(id, -1, section)).KeyboardAcceleratorTextOverride = "Alt+Up";
        Item("Move down", "\uE74B", () => Move(id, 1, section)).KeyboardAcceleratorTextOverride = "Alt+Down";
        if (!section)
        {
            var moveTo = new MenuFlyoutSubItem { Text = "Move to section", Icon = new FontIcon { Glyph = "\uE8DE" } };
            menu.Opening += (_, _) =>
            {
                moveTo.Items.Clear();
                foreach (var s in _tree?.GetSections() ?? [])
                {
                    if (s.Id == _sectionId)
                    {
                        continue;
                    }

                    var target = new MenuFlyoutItem { Text = s.Title.Length == 0 ? "Untitled section" : s.Title };
                    target.Click += (_, _) => MovePageToSection(id, s.Id);
                    moveTo.Items.Add(target);
                }

                moveTo.IsEnabled = moveTo.Items.Count > 0;
            };
            menu.Items.Add(moveTo);
        }

        menu.Items.Add(new MenuFlyoutSeparator());
        Item("Delete", "\uE74D", async () => await ConfirmDeleteAsync(id, section)).KeyboardAcceleratorTextOverride = "Del";
        return menu;
    }

    private async Task OnListKeyAsync(KeyRoutedEventArgs e, bool section)
    {
        var id = section ? _sectionId : _pageId;
        if (id is null)
        {
            return;
        }

        var alt = IsDown(VirtualKey.Menu);
        if (e.Key == VirtualKey.F2)
        {
            e.Handled = true;
            await PromptRenameAsync(id, section);
        }
        else if (e.Key == VirtualKey.Delete)
        {
            e.Handled = true;
            await ConfirmDeleteAsync(id, section);
        }
        else if (alt && e.Key is VirtualKey.Up or VirtualKey.Down)
        {
            e.Handled = true;
            Move(id, e.Key == VirtualKey.Up ? -1 : 1, section);
        }
    }

    private void OnDragCompleted(ListView list, DragItemsCompletedEventArgs e, bool section)
    {
        if (_tree is null || (!section && _sectionId is null))
        {
            return;
        }

        // What was dragged is read off the list itself (the event's item list is not dependable for items that
        // are their own containers): the one entry whose removal makes the list and the tree agree again.
        var shown = list.Items.OfType<ListViewItem>().Select(i => (string)i.Tag).ToList();
        var stored = section ? _tree.GetSections().Select(s => s.Id).ToList() : _tree.GetPages(_sectionId!).Select(p => p.Id).ToList();
        if (shown.SequenceEqual(stored) || shown.Count != stored.Count)
        {
            return;
        }

        var moved = shown.FirstOrDefault(id => shown.Where(x => x != id).SequenceEqual(stored.Where(x => x != id)));
        if (moved is null)
        {
            RefreshTree(); // not a single move: put the list back to what the tree says
            return;
        }

        var index = shown.IndexOf(moved);
        if (section)
        {
            _tree.MoveSection(moved, index);
        }
        else
        {
            _tree.MovePage(moved, _sectionId!, index);
        }
    }

    private async Task PromptRenameAsync(string id, bool section)
    {
        if (_tree is null)
        {
            return;
        }

        var current = section ? _tree.GetSection(id)?.Title : _tree.GetPage(id)?.Title;
        if (await _shell.PromptAsync(section ? "Rename section" : "Rename page", "Name", current ?? "", "Rename") is { } name)
        {
            if (section)
            {
                RenameSection(id, name);
            }
            else
            {
                RenamePage(id, name);
            }
        }
    }

    private async Task ConfirmDeleteAsync(string id, bool section)
    {
        if (_tree is null)
        {
            return;
        }

        var name = section ? _tree.GetSection(id)?.Title : _tree.GetPage(id)?.Title;
        var what = section ? "section" : "page";
        var detail = section ? " and all its pages" : "";
        if (await _shell.ConfirmAsync($"Delete this {what}?", $"\"{(string.IsNullOrEmpty(name) ? "Untitled" : name)}\"{detail} will disappear from all your devices.", "Delete"))
        {
            if (section)
            {
                DeleteSection(id);
            }
            else
            {
                DeletePage(id);
            }
        }
    }

    private async Task PromptNewSectionAsync()
    {
        if (_tree is not null && await _shell.PromptAsync("New section", "Name", "", "Create") is { } name)
        {
            AddSection(name);
        }
    }

    private void NewPageInteractive()
    {
        if (AddPage("") is not null)
        {
            TitleBox.Focus(FocusState.Programmatic);
        }
    }

    private async Task OnEmptyActionAsync()
    {
        if (_tree is null)
        {
            await PromptNewNotebookAsync();
        }
        else if (_sectionId is null)
        {
            await PromptNewSectionAsync();
        }
        else
        {
            NewPageInteractive();
        }
    }

    public string? AddSection(string title)
    {
        if (_tree is null || string.IsNullOrWhiteSpace(title))
        {
            return null;
        }

        var id = _tree.AddSection(title.Trim());
        SelectSection(id);
        return id;
    }

    public void RenameSection(string id, string title)
    {
        if (_tree?.GetSection(id) is not null && !string.IsNullOrWhiteSpace(title))
        {
            _tree.RenameSection(id, title.Trim());
        }
    }

    public void DeleteSection(string id)
    {
        if (_tree?.GetSection(id) is null)
        {
            return;
        }

        if (id == _sectionId)
        {
            CloseCurrentPage();
        }

        _tree.SetSectionDeleted(id);
    }

    public void SelectSection(string id)
    {
        if (_tree is null || id == _sectionId)
        {
            return;
        }

        CloseCurrentPage();
        _sectionId = id;
        _session.Settings.LastSection[_notebookId!] = id;
        SaveSettings();
        RefreshTree();
    }

    /// <summary>Adds a page to the open section and opens it.</summary>
    public string? AddPage(string title)
    {
        if (_client is null || _tree is null || _sectionId is null)
        {
            return null;
        }

        CloseCurrentPage();

        // CreatePage first adds the entry to the tree (which raises Changed) and only then creates the page
        // document. Opening the page from that notification would get in its way, so the lists wait.
        string id;
        _suspended = true;
        try
        {
            var page = _client.CreatePage(_notebookId!, _sectionId, title.Trim());
            id = page.DocId;
            _client.ClosePage(id); // reopened through the normal path below
        }
        finally
        {
            _suspended = false;
        }

        SelectPage(id);
        return id;
    }

    public void RenamePage(string id, string title)
    {
        if (_tree?.GetPage(id) is { } page && page.Title != title.Trim())
        {
            _tree.RenamePage(id, title.Trim());
        }
    }

    public void DeletePage(string id)
    {
        if (_tree?.GetPage(id) is null)
        {
            return;
        }

        if (id == _pageId)
        {
            CloseCurrentPage();
        }

        _tree.SetPageDeleted(id);
    }

    public void SelectPage(string id)
    {
        if (_tree is null || _sectionId is null || id == _pageId)
        {
            return;
        }

        CloseCurrentPage();
        _session.Settings.LastPage[_sectionId] = id;
        SaveSettings();
        _wantedPageId = id; // RefreshTree opens it if it is in this section
        RefreshTree();
    }

    /// <summary>Moves a section or page one place up (-1) or down (+1).</summary>
    public void Move(string id, int delta, bool section)
    {
        if (_tree is null)
        {
            return;
        }

        if (section)
        {
            var ids = _tree.GetSections().Select(s => s.Id).ToList();
            var at = ids.IndexOf(id);
            if (at >= 0 && at + delta >= 0 && at + delta < ids.Count)
            {
                _tree.MoveSection(id, at + delta);
            }
        }
        else if (_tree.GetPage(id) is { } page)
        {
            var ids = _tree.GetPages(page.SectionId).Select(p => p.Id).ToList();
            var at = ids.IndexOf(id);
            if (at >= 0 && at + delta >= 0 && at + delta < ids.Count)
            {
                _tree.MovePage(id, page.SectionId, at + delta);
            }
        }
    }

    public void MovePageToSection(string pageId, string sectionId)
    {
        if (_tree?.GetPage(pageId) is null || _tree.GetSection(sectionId) is null)
        {
            return;
        }

        if (pageId == _pageId)
        {
            CloseCurrentPage();
        }

        _tree.MovePage(pageId, sectionId, null);
    }

    /// <summary>Opens a page anywhere in the vault (search results).</summary>
    public void Navigate(string notebookId, string sectionId, string pageId)
    {
        if (_client is null || !_client.NotebookIds.Contains(notebookId))
        {
            return;
        }

        SelectNotebook(notebookId);
        if (_tree?.GetSection(sectionId) is { Deleted: false })
        {
            SelectSection(sectionId);
            SelectPage(pageId);
            Editor.Focus(FocusState.Programmatic);
        }
    }

    // ---- the open page -------------------------------------------------------------------------------------

    private void ShowEmpty(string text, string action)
    {
        EditorPanel.Visibility = Visibility.Collapsed;
        EmptyPanel.Visibility = Visibility.Visible;
        EmptyText.Text = text;
        EmptyAction.Content = action;
    }

    private void OpenPage(string? pageId)
    {
        if (pageId == _pageId && _binding is not null)
        {
            return;
        }

        CloseCurrentPage();
        if (pageId is null || _client is null || _tree is null)
        {
            return;
        }

        _page = _client.OpenPage(_notebookId!, pageId);
        _pageId = pageId;
        _page.Changed += OnPageChanged;
        _page.Deleted += OnPageDeletedOnServer;
        TitleBox.Text = _tree.GetPage(pageId)?.Title ?? "";
        EmptyPanel.Visibility = Visibility.Collapsed;
        EditorPanel.Visibility = Visibility.Visible;
        EditorPanel.UpdateLayout(); // the editor's template must be in place before the binding reads its defaults
        _binding = new RichEditBinding("editor", Editor, _page, IsDark);
        _binding.LinkActivated += OpenLink;
        _pageEdited = false;
        UpdateToolbar();
    }

    /// <summary>Stops editing the open page: last keystrokes are reconciled, the title is saved, the control is emptied.</summary>
    public void CloseCurrentPage()
    {
        if (_pageId is null)
        {
            return;
        }

        // Everything about the open page is let go first; only then is the tree written (title, "last
        // edited"). The tree raises Changed from inside those writes, and a list refresh that found a half-closed
        // page would reopen it under our feet - so the lists wait until the page is gone.
        var id = _pageId;
        var title = TitleBox.Text;
        var edited = _pageEdited;
        var outer = _suspended;
        _suspended = true;
        try
        {
            if (_binding is not null)
            {
                try
                {
                    _binding.SyncLocal();
                }
                catch (ObjectDisposedException)
                {
                    // the document went away with the vault
                }

                _binding.LinkActivated -= OpenLink;
                _binding.Dispose();
                _binding = null;
            }

            if (_page is not null)
            {
                _page.Changed -= OnPageChanged;
                _page.Deleted -= OnPageDeletedOnServer;
            }

            _page = null;
            _pageId = null;
            _pageEdited = false;
            _client?.ClosePage(id);
            Editor.Document.SetText(TextSetOptions.None, "");
            TitleBox.Text = "";
            EditorPanel.Visibility = Visibility.Collapsed;
            EmptyPanel.Visibility = Visibility.Visible;
            EmptyText.Text = "";
            EmptyAction.Content = "New page";

            var treeWritten = false;
            try
            {
                if (_tree?.GetPage(id) is { } entry)
                {
                    if (entry.Title != title.Trim())
                    {
                        _tree.RenamePage(id, title.Trim());
                        treeWritten = true;
                    }

                    if (edited)
                    {
                        _tree.TouchPage(id);
                        _lastTouch = DateTimeOffset.UtcNow;
                    }
                }
            }
            catch (ObjectDisposedException)
            {
                // the tree went away with the vault
            }

            if (treeWritten)
            {
                DispatcherQueue.TryEnqueue(RefreshTree); // the page list shows the new title
            }
        }
        finally
        {
            _suspended = outer;
        }
    }
    /// <summary>Another view (settings) takes the window: the page is closed so nothing edits a control that is not shown.</summary>
    public void CloseCurrentPageForOverlay()
    {
        var id = _pageId;
        _overlay = true;
        CloseCurrentPage();
        _wantedPageId = id;
    }

    /// <summary>The view is shown again: reopen what was open.</summary>
    public void ReturnFromOverlay()
    {
        _overlay = false;
        RefreshTree();
    }

    private void TouchPage(string id)
    {
        _pageEdited = false;
        _lastTouch = DateTimeOffset.UtcNow;
        try
        {
            if (_tree?.GetPage(id) is not null)
            {
                _tree.TouchPage(id);
            }
        }
        catch (ObjectDisposedException)
        {
        }
    }

    private void OnPageChanged(ChangeSource source)
    {
        if (source == ChangeSource.Remote)
        {
            return;
        }

        _pageEdited = true;
        _shell.NoteActivity();
        _shell.RefreshSyncStatus();
        if (_pageId is not null && DateTimeOffset.UtcNow - _lastTouch > TimeSpan.FromMinutes(1))
        {
            // Keeps "last edited" roughly current without one tree update per keystroke. Deferred: the tree must
            // not be written from inside the page's change notification.
            var id = _pageId;
            _lastTouch = DateTimeOffset.UtcNow;
            DispatcherQueue.TryEnqueue(() =>
            {
                if (_pageId == id)
                {
                    TouchPage(id);
                    _pageEdited = false;
                }
            });
        }
    }

    private void OnPageDeletedOnServer() => DispatcherQueue.TryEnqueue(() =>
    {
        if (_page is { IsDeleted: true })
        {
            CloseCurrentPage();
            RefreshTree();
        }
    });

    private void CommitTitle()
    {
        if (_pageId is null || _tree is null)
        {
            return;
        }

        try
        {
            RenamePage(_pageId, TitleBox.Text);
        }
        catch (ObjectDisposedException)
        {
        }
    }

    /// <summary>Sets the page title as if typed and confirmed (self-test).</summary>
    public void SetTitle(string title)
    {
        TitleBox.Text = title;
        CommitTitle();
    }

    // ---- editor commands -----------------------------------------------------------------------------------

    private void Command(Action<RichEditBinding> action)
    {
        if (_binding is not null)
        {
            action(_binding);
            UpdateToolbar();
        }
    }

    /// <summary>Runs an editor command by name (toolbar buttons, shortcuts and the self-test all end up here).</summary>
    public void Run(string command)
    {
        switch (command)
        {
            case "bold" or "italic" or "underline" or "strike" or "code": Command(b => b.ToggleInline(command)); break;
            case "h1" or "h2" or "h3" or "ul" or "ol" or "todo": Command(b => b.ToggleBlock(command)); break;
            case "codeblock": Command(b => b.ToggleBlock("code")); break;
            case "paragraph": Command(b => b.UpdateBlocks(x => x with { Block = null, Checked = false })); break;
            case "indent": Command(b => b.Indent(1)); break;
            case "outdent": Command(b => b.Indent(-1)); break;
            case "undo": Command(b => b.Undo()); break;
            case "redo": Command(b => b.Redo()); break;
            default: throw new ArgumentException("Unknown editor command.", nameof(command));
        }
    }

    private void UpdateToolbar()
    {
        if (_binding is null)
        {
            return;
        }

        var inline = _binding.InlineAtSelection();
        var block = _binding.BlockAtSelection().Block;
        BoldButton.IsChecked = inline.Bold;
        ItalicButton.IsChecked = inline.Italic;
        UnderlineButton.IsChecked = inline.Underline;
        StrikeButton.IsChecked = inline.Strike;
        CodeButton.IsChecked = inline.Code;
        LinkButton.IsChecked = inline.Link is not null;
        H1Button.IsChecked = block == "h1";
        H2Button.IsChecked = block == "h2";
        H3Button.IsChecked = block == "h3";
        BulletButton.IsChecked = block == "ul";
        NumberButton.IsChecked = block == "ol";
        TodoButton.IsChecked = block == "todo";
        CodeBlockButton.IsChecked = block == "code";
        UndoButton.IsEnabled = _page?.CanUndo ?? false;
        RedoButton.IsEnabled = _page?.CanRedo ?? false;
    }

    private static bool IsDown(VirtualKey key) =>
        InputKeyboardSource.GetKeyStateForCurrentThread(key).HasFlag(CoreVirtualKeyStates.Down);

    /// <summary>App-wide shortcuts. Runs before the focused control sees the key.</summary>
    private void OnAppKey(object sender, KeyRoutedEventArgs e)
    {
        _shell.NoteActivity();
        if (HandleAppKey(e.Key, IsDown(VirtualKey.Control), IsDown(VirtualKey.Shift), IsDown(VirtualKey.Menu)))
        {
            e.Handled = true;
        }
    }

    /// <summary>Ctrl+N new page, Ctrl+Shift+N new section, Ctrl+F search, Ctrl+L lock. Returns true when the key was used.</summary>
    public bool HandleAppKey(VirtualKey key, bool ctrl, bool shift, bool alt)
    {
        if (!ctrl || alt)
        {
            return false;
        }

        switch (key)
        {
            case VirtualKey.N when shift:
                _ = PromptNewSectionAsync();
                return true;
            case VirtualKey.N:
                NewPageInteractive();
                return true;
            case VirtualKey.F when !shift:
                _shell.FocusSearch();
                return true;
            case VirtualKey.L when !shift:
                _ = _shell.LockAsync();
                return true;
            case (VirtualKey)187 or VirtualKey.Add: // Ctrl+plus
                _shell.StepZoom(+1);
                return true;
            case (VirtualKey)189 or VirtualKey.Subtract: // Ctrl+minus
                _shell.StepZoom(-1);
                return true;
            case VirtualKey.Number0 or VirtualKey.NumberPad0 when !shift:
                _shell.SetZoom(100);
                return true;
            case (VirtualKey)220 when !shift: // the backslash key
                TogglePanes();
                return true;
            default:
                return false;
        }
    }

    private void OnEditorKey(object sender, KeyRoutedEventArgs e)
    {
        if (e.Handled || IsDown(VirtualKey.RightMenu))
        {
            return; // AltGr: the key types a character on many keyboard layouts
        }

        if (HandleEditorKey(e.Key, IsDown(VirtualKey.Control), IsDown(VirtualKey.Shift), IsDown(VirtualKey.Menu)))
        {
            e.Handled = true;
        }
    }

    /// <summary>
    /// Formatting shortcuts of the editor (bold, italic, underline, undo and redo are handled by the control and
    /// the binding). RichEdit's own accelerators for things a page cannot hold - alignment, line spacing,
    /// sub/superscript, all caps, its own list styles - are swallowed. Returns true when the key was used.
    /// </summary>
    public bool HandleEditorKey(VirtualKey key, bool ctrl, bool shift, bool alt)
    {
        if (_binding is null)
        {
            return false;
        }

        if (key == VirtualKey.Space && !ctrl && !alt && !shift && _binding.TryAutoList())
        {
            UpdateToolbar();
            return true; // "- " and friends at the start of a line became a list; the space is not typed
        }

        string? command = null;
        if (key == VirtualKey.Tab && !ctrl && !alt)
        {
            var block = _binding.BlockAtSelection();
            var (s, end) = _binding.Selection;
            var multi = s != end && _binding.Shadow.ParagraphEnd(s) < end - 1;
            if (shift)
            {
                if (block.Indent == 0 && !multi)
                {
                    return false; // lets Shift+Tab move the focus out of the editor
                }

                command = "outdent";
            }
            else if (block.Block is "ul" or "ol" or "todo" || multi)
            {
                command = "indent";
            }
            else
            {
                Editor.Document.Selection.TypeText("\t");
                return true;
            }
        }
        else if (ctrl && alt && !shift)
        {
            command = key switch
            {
                VirtualKey.Number1 => "h1",
                VirtualKey.Number2 => "h2",
                VirtualKey.Number3 => "h3",
                VirtualKey.Number0 => "paragraph",
                _ => null,
            };
        }
        else if (ctrl && !alt && shift)
        {
            switch (key)
            {
                case VirtualKey.X: command = "strike"; break;
                case VirtualKey.C: command = "codeblock"; break;
                case VirtualKey.M: command = "outdent"; break;
                case VirtualKey.V:
                    _ = PasteAsync(plainOnly: true);
                    return true;
                case VirtualKey.A or VirtualKey.L or (VirtualKey)187: return true;
            }
        }
        else if (ctrl && !alt)
        {
            switch (key)
            {
                case VirtualKey.E: command = "code"; break;
                case VirtualKey.K:
                    ShowLinkFlyout();
                    return true;
                case VirtualKey.M: command = "indent"; break;
                case VirtualKey.Number1: command = "todo"; break;
                case (VirtualKey)190: command = "ul"; break;
                case (VirtualKey)191: command = "ol"; break;
                case VirtualKey.R or VirtualKey.J or VirtualKey.Number2 or VirtualKey.Number5 or (VirtualKey)187: return true;
            }
        }

        if (command is null)
        {
            return false;
        }

        Run(command);
        return true;
    }
    // ---- links ---------------------------------------------------------------------------------------------

    private void ShowLinkFlyout()
    {
        if (_binding is null)
        {
            return;
        }

        _binding.SyncLocal();
        var (s, e) = _binding.Selection;
        var existing = _binding.LinkRangeAt(s);
        LinkError.Visibility = Visibility.Collapsed;
        if (existing is { } link && (s == e || e <= link.End))
        {
            _linkTarget = (link.Start, link.End);
            LinkUrlBox.Text = link.Url;
            LinkTextBox.Visibility = Visibility.Collapsed;
        }
        else if (s != e)
        {
            _linkTarget = (s, e);
            LinkUrlBox.Text = "";
            LinkTextBox.Visibility = Visibility.Collapsed;
        }
        else
        {
            _linkTarget = null; // nothing selected: insert new text
            LinkUrlBox.Text = "";
            LinkTextBox.Text = "";
            LinkTextBox.Visibility = Visibility.Visible;
        }

        LinkRemoveButton.IsEnabled = existing is not null;
        LinkOpenButton.IsEnabled = existing is not null;
        FlyoutBase.ShowAttachedFlyout(LinkButton);
        (LinkTextBox.Visibility == Visibility.Visible ? LinkTextBox : LinkUrlBox).Focus(FocusState.Programmatic);
    }

    private void ApplyLinkFromFlyout()
    {
        if (NormalizeLink(LinkUrlBox.Text) is not { } url)
        {
            LinkError.Text = "Enter a web address (http or https) or a mailto: address.";
            LinkError.Visibility = Visibility.Visible;
            return;
        }

        if (_linkTarget is { } t)
        {
            SetLink(t.Start, t.End, url);
        }
        else
        {
            InsertLink(LinkTextBox.Text.Length == 0 ? url : LinkTextBox.Text, url);
        }

        LinkFlyout.Hide();
        Editor.Focus(FocusState.Programmatic);
    }

    /// <summary>Accepts http, https and mailto links; a bare host name gets https://. Returns null for anything else.</summary>
    public static string? NormalizeLink(string? text)
    {
        text = text?.Trim() ?? "";
        if (text.Length == 0 || text.Any(char.IsControl))
        {
            return null;
        }

        if (!text.Contains(':', StringComparison.Ordinal))
        {
            text = (text.Contains('@', StringComparison.Ordinal) && !text.Contains('/', StringComparison.Ordinal) ? "mailto:" : "https://") + text;
        }

        return Uri.TryCreate(text, UriKind.Absolute, out var uri) && uri.Scheme is "http" or "https" or "mailto" ? text : null;
    }

    public void SetLink(int start, int end, string? url) => Command(b => b.SetLink(start, end, url));

    public void InsertLink(string text, string url) => Command(b => b.InsertLink(text, url));

    private async void OpenLink(string url)
    {
        // Only schemes that open a browser or a mail program: a link must not be able to start anything else.
        if (NormalizeLink(url) is { } safe && Uri.TryCreate(safe, UriKind.Absolute, out var uri))
        {
            try
            {
                await Launcher.LaunchUriAsync(uri);
            }
            catch (Exception)
            {
                // no handler registered
            }
        }
    }

    // ---- paste ---------------------------------------------------------------------------------------------

    /// <summary>
    /// The only way clipboard content gets into a page: rich text when it is nothing but text and simple
    /// formatting, otherwise the plain text; pictures, files and everything else are ignored.
    /// </summary>
    public async Task PasteAsync(bool plainOnly)
    {
        if (_binding is null)
        {
            return;
        }

        string? rtf = null;
        string? text = null;
        string? html = null;
        try
        {
            var content = Clipboard.GetContent();
            if (!plainOnly && content.Contains(StandardDataFormats.Html))
            {
                html = await content.GetHtmlFormatAsync();
            }

            if (!plainOnly && content.Contains(StandardDataFormats.Rtf))
            {
                rtf = await content.GetRtfAsync();
            }

            if (content.Contains(StandardDataFormats.Text))
            {
                text = await content.GetTextAsync();
            }
        }
        catch (Exception)
        {
            return; // the clipboard is busy or its owner went away
        }

        if (_binding is null)
        {
            return;
        }

        // Browsers and Electron apps (Slack) put only HTML on the clipboard, and OneNote's HTML carries its lists
        // and formatting, so HTML goes first. Word is the exception: its HTML writes lists as plain paragraphs,
        // while its RTF pastes natively.
        var selection = Editor.Document.Selection;
        var rtfSafe = rtf is not null && PasteFilter.RtfIsSafe(rtf);
        IReadOnlyList<PastedParagraph> rich = html is null || (rtfSafe && HtmlPaste.IsWordHtml(html)) ? [] : HtmlPaste.Parse(HtmlPaste.ExtractFragment(html));
        if (rich.Count > 0 && _binding.InsertRich(rich))
        {
            // inserted with its formatting
        }
        else if (rtfSafe)
        {
            selection.SetText(TextSetOptions.FormatRtf, rtf!);
            selection.SetRange(selection.EndPosition, selection.EndPosition);
        }
        else if (PasteFilter.SanitizePlainText(text) is { Length: > 0 } plain)
        {
            selection.TypeText(plain.Replace('\n', '\r').Replace('\u2028', '\v'));
        }

        _binding.SyncLocal();
    }

    // ---- search --------------------------------------------------------------------------------------------

    /// <summary>Searches titles and text of every page in the unlocked vault.</summary>
    public async Task<IReadOnlyList<SearchHit>> SearchAsync(string query)
    {
        await EnsureIndexAsync();
        return _index.Search(query);
    }

    /// <summary>Marks the index stale, so the next search reads the pages again.</summary>
    public void InvalidateIndex() => _indexedAt = default;

    private async Task EnsureIndexAsync()
    {
        if (_indexing is null)
        {
            if (DateTimeOffset.UtcNow - _indexedAt < TimeSpan.FromSeconds(4))
            {
                return;
            }

            _indexing = BuildIndexAsync();
        }

        try
        {
            await _indexing;
        }
        finally
        {
            _indexing = null;
        }
    }

    /// <summary>
    /// Reads every page from the (encrypted) local store into memory, a few at a time so the window stays
    /// responsive. A page is never held open across a pause: either it is the page in the editor, which is read
    /// in place, or it is opened, read and closed in one go.
    /// </summary>
    private async Task BuildIndexAsync()
    {
        var client = _client;
        if (client is null)
        {
            return;
        }

        var seen = new HashSet<string>();
        var clock = Stopwatch.StartNew();
        foreach (var (notebookId, notebookTitle) in Notebooks())
        {
            NotebookTree tree;
            try
            {
                tree = client.OpenNotebook(notebookId);
            }
            catch (Exception e) when (e is KeyNotFoundException or InvalidOperationException or ObjectDisposedException)
            {
                continue;
            }

            var sections = tree.GetSections().ToDictionary(s => s.Id);
            foreach (var page in tree.GetAllPages())
            {
                if (!sections.TryGetValue(page.SectionId, out var section))
                {
                    continue;
                }

                if (clock.ElapsedMilliseconds > 12)
                {
                    await Task.Delay(1);
                    clock.Restart();
                }

                if (!ReferenceEquals(_client, client))
                {
                    return; // locked meanwhile
                }

                string text;
                try
                {
                    if (page.Id == _pageId && _page is not null)
                    {
                        _binding?.SyncLocal();
                        text = _page.GetText();
                    }
                    else
                    {
                        var doc = client.OpenPage(notebookId, page.Id);
                        try
                        {
                            text = doc.GetText();
                        }
                        finally
                        {
                            client.ClosePage(page.Id);
                        }
                    }
                }
                catch (Exception e) when (e is KeyNotFoundException or InvalidOperationException or ObjectDisposedException)
                {
                    continue;
                }

                seen.Add(page.Id);
                _index.Set(new SearchEntry(
                    notebookId, notebookTitle, section.Id, section.Title.Length == 0 ? "Untitled section" : section.Title,
                    page.Id, page.Title.Length == 0 ? Untitled : page.Title, text));
            }
        }

        _index.RemoveWhere(e => !seen.Contains(e.PageId));
        _indexedAt = DateTimeOffset.UtcNow;
    }
}
