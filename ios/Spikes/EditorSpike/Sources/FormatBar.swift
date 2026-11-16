import UIKit
import TwoNoteDocuments
import TwoNoteEditor

/// The formatting bar above the keyboard: a standard toolbar with SF Symbols, driven by the
/// binding's command API and showing the formatting at the selection.
@MainActor
final class FormatBar: NSObject {
    let toolbar = UIToolbar(frame: CGRect(x: 0, y: 0, width: 320, height: 44))
    private let binding: PageTextBinding
    private var bold: UIBarButtonItem!
    private var italic: UIBarButtonItem!
    private var todo: UIBarButtonItem!

    init(binding: PageTextBinding) {
        self.binding = binding
        super.init()
        toolbar.autoresizingMask = [.flexibleWidth]

        let style = UIBarButtonItem(image: UIImage(systemName: "textformat.size"), menu: styleMenu())
        style.accessibilityLabel = "Paragraph Style"
        bold = item("bold", "Bold") { $0.toggleInline(PageAttribute.bold) }
        italic = item("italic", "Italic") { $0.toggleInline(PageAttribute.italic) }
        todo = item("checklist", "Checklist") { $0.toggleBlock("todo") }
        let more = UIBarButtonItem(image: UIImage(systemName: "ellipsis.circle"), menu: moreMenu())
        more.accessibilityLabel = "More Formatting"
        let done = item("keyboard.chevron.compact.down", "Hide Keyboard") { $0.textView.resignFirstResponder() }
        // Six buttons: more than that does not fit the Duo's cover display, and a toolbar drops what does not fit.
        toolbar.items = [style, bold, italic, todo, more, .flexibleSpace(), done]

        binding.onStateChange = { [weak self] in self?.refresh() }
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

    private func refresh() {
        let state = binding.formatting
        bold.isSelected = state.inline.bold
        italic.isSelected = state.inline.italic
        todo.isSelected = state.block.block == "todo"
    }

    private func styleMenu() -> UIMenu {
        UIMenu(title: "", children: [UIDeferredMenuElement.uncached { [weak self] completion in
            guard let self else { return completion([]) }
            let current = self.binding.formatting.block.block
            let styles: [(String?, String, String)] = [
                ("h1", "Title", "textformat.size.larger"),
                ("h2", "Heading", "textformat.size"),
                ("h3", "Subheading", "textformat.size.smaller"),
                (nil, "Body", "text.alignleft"),
                ("ul", "Bulleted List", "list.bullet"),
                ("ol", "Numbered List", "list.number"),
                ("todo", "Checklist", "checklist"),
                ("code", "Code Block", "curlybraces"),
            ]
            completion(styles.map { block, title, symbol in
                UIAction(title: title, image: UIImage(systemName: symbol), state: current == block ? .on : .off) { [weak self] _ in
                    self?.binding.setBlock(block)
                    self?.refresh()
                }
            })
        }])
    }

    private func moreMenu() -> UIMenu {
        UIMenu(title: "", children: [UIDeferredMenuElement.uncached { [weak self] completion in
            guard let self else { return completion([]) }
            let state = self.binding.formatting
            @MainActor func toggle(_ title: String, _ symbol: String, _ on: Bool, _ key: String) -> UIAction {
                UIAction(title: title, image: UIImage(systemName: symbol), state: on ? .on : .off) { [weak self] _ in
                    self?.binding.toggleInline(key)
                    self?.refresh()
                }
            }
            let inline = UIMenu(title: "", options: .displayInline, children: [
                toggle("Underline", "underline", state.inline.underline, PageAttribute.underline),
                toggle("Strikethrough", "strikethrough", state.inline.strike, PageAttribute.strike),
                toggle("Inline Code", "chevron.left.forwardslash.chevron.right", state.inline.code, PageAttribute.code),
                UIAction(title: state.inline.link == nil ? "Add Link…" : "Edit Link…", image: UIImage(systemName: "link")) { [weak self] _ in
                    self?.editLink()
                },
            ])
            let indent = UIMenu(title: "", options: .displayInline, children: [
                UIAction(title: "Increase Indent", image: UIImage(systemName: "increase.indent"),
                         attributes: state.block.indent < PageAttribute.maxIndent ? [] : .disabled) { [weak self] _ in self?.binding.indent(by: 1) },
                UIAction(title: "Decrease Indent", image: UIImage(systemName: "decrease.indent"),
                         attributes: state.block.indent > 0 ? [] : .disabled) { [weak self] _ in self?.binding.indent(by: -1) },
            ])
            let history = UIMenu(title: "", options: .displayInline, children: [
                UIAction(title: "Undo", image: UIImage(systemName: "arrow.uturn.backward"),
                         attributes: state.canUndo ? [] : .disabled) { [weak self] _ in self?.binding.undo() },
                UIAction(title: "Redo", image: UIImage(systemName: "arrow.uturn.forward"),
                         attributes: state.canRedo ? [] : .disabled) { [weak self] _ in self?.binding.redo() },
            ])
            completion([inline, indent, history])
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
