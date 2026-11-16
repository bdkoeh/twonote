import TwoNoteDocuments
import TwoNoteEditor
import UIKit

/// The formatting bar above the keyboard: a standard toolbar with SF Symbols, driven by the
/// binding's command API and showing the formatting at the selection.
///
/// How much is shown directly depends on the bar's width; everything is at most two taps away
/// at every width:
/// - narrow (the iPhone Duo's cover display, 382 points of usable width; an iPhone): paragraph
///   style menu, bold, italic, a Lists menu (bulleted, numbered, checklist, indent), a More
///   menu (underline, strikethrough, code, link, undo, redo) and the button that hides the
///   keyboard. Six items is what fits there.
/// - medium (the Duo unfolded, 669 points): the three lists and indent and outdent are buttons
///   of their own; ten items.
/// - wide (an iPad, 820 points and up): underline and undo as well; twelve items.
///   Strikethrough, code, links and redo stay in the More menu.
/// An item takes about 52 points and a gap between groups 19 (measured on the iPad simulator);
/// the layouts are sized to leave room to spare, because a toolbar that is too full moves its
/// last items - More and Hide Keyboard - into an overflow menu of its own.
@MainActor
final class FormatBar: NSObject {
    enum Layout: Equatable {
        case narrow
        case medium
        case wide

        static func forWidth(_ width: CGFloat) -> Layout {
            width >= 780 ? .wide : width >= 640 ? .medium : .narrow
        }
    }

    /// A toolbar that reports its width, so the bar can choose its layout.
    private final class Toolbar: UIToolbar {
        var onWidthChange: ((CGFloat) -> Void)?
        private var reported: CGFloat = -1

        override func layoutSubviews() {
            super.layoutSubviews()
            if abs(bounds.width - reported) > 0.5 {
                reported = bounds.width
                onWidthChange?(bounds.width)
            }
        }
    }

    let toolbar: UIToolbar
    private(set) var layout: Layout?
    private let binding: PageTextBinding
    private var toggles: [(item: UIBarButtonItem, isOn: (PageTextBinding.Formatting) -> Bool)] = []
    private var enablers: [(item: UIBarButtonItem, isEnabled: (PageTextBinding.Formatting) -> Bool)] = []

    init(binding: PageTextBinding) {
        self.binding = binding
        let toolbar = Toolbar(frame: CGRect(x: 0, y: 0, width: 320, height: 44))
        self.toolbar = toolbar
        super.init()
        toolbar.autoresizingMask = [.flexibleWidth]
        toolbar.onWidthChange = { [weak self] width in
            self?.apply(Layout.forWidth(width))
        }
        apply(.narrow)
        binding.onStateChange = { [weak self] in self?.refresh() }
    }

    /// Rebuilds the items for a layout.
    func apply(_ layout: Layout) {
        guard layout != self.layout else { return }
        self.layout = layout
        toggles = []
        enablers = []

        let style = UIBarButtonItem(image: UIImage(systemName: "textformat.size"), menu: styleMenu(lists: layout == .narrow))
        style.accessibilityLabel = "Paragraph Style"
        let bold = toggle("bold", "Bold", { $0.inline.bold }) { $0.toggleInline(PageAttribute.bold) }
        let italic = toggle("italic", "Italic", { $0.inline.italic }) { $0.toggleInline(PageAttribute.italic) }
        let more = UIBarButtonItem(image: UIImage(systemName: "ellipsis.circle"), menu: moreMenu(layout))
        more.accessibilityLabel = "More Formatting"
        let done = item("keyboard.chevron.compact.down", "Hide Keyboard") { $0.textView.resignFirstResponder() }

        switch layout {
        case .narrow:
            let lists = UIBarButtonItem(image: UIImage(systemName: "list.bullet"), menu: listMenu())
            lists.accessibilityLabel = "Lists"
            toggles.append((lists, { ["ul", "ol", "todo"].contains($0.block.block ?? "") }))
            toolbar.items = [style, bold, italic, lists, more, done]
        case .medium, .wide:
            var items = [style, bold, italic]
            if layout == .wide {
                items.append(toggle("underline", "Underline", { $0.inline.underline }) { $0.toggleInline(PageAttribute.underline) })
            }
            items.append(.fixedSpace(8))
            items.append(toggle("list.bullet", "Bulleted List", { $0.block.block == "ul" }) { $0.toggleBlock("ul") })
            items.append(toggle("list.number", "Numbered List", { $0.block.block == "ol" }) { $0.toggleBlock("ol") })
            items.append(toggle("checklist", "Checklist", { $0.block.block == "todo" }) { $0.toggleBlock("todo") })
            items.append(.fixedSpace(8))
            items.append(enabled("decrease.indent", "Decrease Indent", { $0.block.indent > 0 }) { $0.indent(by: -1) })
            items.append(enabled("increase.indent", "Increase Indent", { $0.block.indent < PageAttribute.maxIndent }) { $0.indent(by: 1) })
            if layout == .wide {
                items.append(.fixedSpace(8))
                items.append(enabled("arrow.uturn.backward", "Undo", { $0.canUndo }) { _ = $0.undo() })
            }
            items += [.flexibleSpace(), more, done]
            toolbar.items = items
        }
        refresh()
    }

    private func item(_ symbol: String, _ label: String, _ action: @escaping @MainActor (PageTextBinding) -> Void) -> UIBarButtonItem {
        let item = UIBarButtonItem(image: UIImage(systemName: symbol), primaryAction: UIAction { [weak self] _ in
            guard let self else { return }
            action(self.binding)
            self.refresh()
        })
        item.accessibilityLabel = label
        return item
    }

    private func toggle(
        _ symbol: String, _ label: String, _ isOn: @escaping (PageTextBinding.Formatting) -> Bool,
        _ action: @escaping @MainActor (PageTextBinding) -> Void
    ) -> UIBarButtonItem {
        let item = item(symbol, label, action)
        toggles.append((item, isOn))
        return item
    }

    private func enabled(
        _ symbol: String, _ label: String, _ isEnabled: @escaping (PageTextBinding.Formatting) -> Bool,
        _ action: @escaping @MainActor (PageTextBinding) -> Void
    ) -> UIBarButtonItem {
        let item = item(symbol, label, action)
        enablers.append((item, isEnabled))
        return item
    }

    private func refresh() {
        let state = binding.formatting
        for (item, isOn) in toggles {
            item.isSelected = isOn(state)
        }
        for (item, isEnabled) in enablers {
            item.isEnabled = isEnabled(state)
        }
    }

    // MARK: Menus (built when opened, so they show the current state)

    private func blockAction(_ block: String?, _ title: String, _ symbol: String, current: String?) -> UIAction {
        UIAction(title: title, image: UIImage(systemName: symbol), state: current == block ? .on : .off) { [weak self] _ in
            guard let self else { return }
            if let block, block == current {
                self.binding.setBlock(nil) // choosing the list a paragraph already is turns it off
            } else {
                self.binding.setBlock(block)
            }
            self.refresh()
        }
    }

    private func indentActions(_ state: PageTextBinding.Formatting) -> [UIAction] {
        [
            UIAction(title: "Increase Indent", image: UIImage(systemName: "increase.indent"),
                     attributes: state.block.indent < PageAttribute.maxIndent ? [] : .disabled) { [weak self] _ in
                self?.binding.indent(by: 1)
                self?.refresh()
            },
            UIAction(title: "Decrease Indent", image: UIImage(systemName: "decrease.indent"),
                     attributes: state.block.indent > 0 ? [] : .disabled) { [weak self] _ in
                self?.binding.indent(by: -1)
                self?.refresh()
            },
        ]
    }

    private func listActions(current: String?) -> [UIAction] {
        [
            blockAction("ul", "Bulleted List", "list.bullet", current: current),
            blockAction("ol", "Numbered List", "list.number", current: current),
            blockAction("todo", "Checklist", "checklist", current: current),
        ]
    }

    /// Headings, body and code block - and, where the lists have no place of their own, the lists.
    private func styleMenu(lists: Bool) -> UIMenu {
        UIMenu(title: "", children: [UIDeferredMenuElement.uncached { [weak self] completion in
            guard let self else { return completion([]) }
            let current = self.binding.formatting.block.block
            var groups = [UIMenu(title: "", options: .displayInline, children: [
                self.blockAction("h1", "Title", "textformat.size.larger", current: current),
                self.blockAction("h2", "Heading", "textformat.size", current: current),
                self.blockAction("h3", "Subheading", "textformat.size.smaller", current: current),
                self.blockAction(nil, "Body", "text.alignleft", current: current),
            ])]
            if lists {
                groups.append(UIMenu(title: "", options: .displayInline, children: self.listActions(current: current)))
            }
            groups.append(UIMenu(title: "", options: .displayInline, children: [
                self.blockAction("code", "Code Block", "curlybraces", current: current),
            ]))
            completion(groups)
        }])
    }

    /// The narrow layout's Lists button: the three lists and the indentation that goes with them.
    private func listMenu() -> UIMenu {
        UIMenu(title: "", children: [UIDeferredMenuElement.uncached { [weak self] completion in
            guard let self else { return completion([]) }
            let state = self.binding.formatting
            completion([
                UIMenu(title: "", options: .displayInline, children: self.listActions(current: state.block.block)),
                UIMenu(title: "", options: .displayInline, children: self.indentActions(state)),
            ])
        }])
    }

    /// Whatever has no button of its own in this layout.
    private func moreMenu(_ layout: Layout) -> UIMenu {
        UIMenu(title: "", children: [UIDeferredMenuElement.uncached { [weak self] completion in
            guard let self else { return completion([]) }
            let state = self.binding.formatting
            @MainActor func toggle(_ title: String, _ symbol: String, _ on: Bool, _ key: String) -> UIAction {
                UIAction(title: title, image: UIImage(systemName: symbol), state: on ? .on : .off) { [weak self] _ in
                    self?.binding.toggleInline(key)
                    self?.refresh()
                }
            }
            var inline: [UIMenuElement] = []
            if layout != .wide {
                inline.append(toggle("Underline", "underline", state.inline.underline, PageAttribute.underline))
            }
            inline.append(toggle("Strikethrough", "strikethrough", state.inline.strike, PageAttribute.strike))
            inline.append(toggle("Inline Code", "chevron.left.forwardslash.chevron.right", state.inline.code, PageAttribute.code))
            inline.append(UIAction(title: state.inline.link == nil ? "Add Link…" : "Edit Link…", image: UIImage(systemName: "link")) { [weak self] _ in
                self?.editLink()
            })
            var groups = [UIMenu(title: "", options: .displayInline, children: inline)]

            var history: [UIMenuElement] = []
            if layout != .wide {
                history.append(UIAction(title: "Undo", image: UIImage(systemName: "arrow.uturn.backward"),
                                        attributes: state.canUndo ? [] : .disabled) { [weak self] _ in
                    _ = self?.binding.undo()
                    self?.refresh()
                })
            }
            history.append(UIAction(title: "Redo", image: UIImage(systemName: "arrow.uturn.forward"),
                                    attributes: state.canRedo ? [] : .disabled) { [weak self] _ in
                _ = self?.binding.redo()
                self?.refresh()
            })
            groups.append(UIMenu(title: "", options: .displayInline, children: history))
            completion(groups)
        }])
    }

    private func editLink() {
        let state = binding.formatting
        let selection = binding.selectedRange
        let alert = UIAlertController(title: state.inline.link == nil ? "Add Link" : "Edit Link", message: nil, preferredStyle: .alert)
        alert.addTextField { field in
            field.placeholder = "https://example.com"
            field.text = state.inline.link
            field.keyboardType = .URL
            field.autocapitalizationType = .none
            field.autocorrectionType = .no
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        if state.inline.link != nil {
            alert.addAction(UIAlertAction(title: "Remove Link", style: .destructive) { [weak self] _ in
                self?.binding.setLink(nil, in: selection)
            })
        }
        alert.addAction(UIAlertAction(title: "Done", style: .default) { [weak self, weak alert] _ in
            guard let self, let url = alert?.textFields?.first?.text, !url.isEmpty else { return }
            if selection.isEmpty && state.inline.link == nil {
                self.binding.insertLink(text: url, url: url)
            } else {
                self.binding.setLink(url, in: selection)
            }
        })
        var presenter = binding.textView.window?.rootViewController
        while let next = presenter?.presentedViewController { presenter = next }
        presenter?.present(alert, animated: true)
    }
}
