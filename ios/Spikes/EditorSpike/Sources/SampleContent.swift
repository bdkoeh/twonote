import TwoNoteDocuments

/// A page that uses every block and inline type of PROTOCOL.md 5.2.
enum SampleContent {
    static let runs: [TextRun] = {
        var runs: [TextRun] = []
        func text(_ text: String, _ attributes: Attributes = [:]) { runs.append(TextRun(text: text, attributes: attributes)) }
        func end(_ block: String? = nil, indent: Int = 0, checked: Bool = false) {
            var attributes: Attributes = [:]
            if let block { attributes[PageAttribute.block] = .string(block) }
            if indent != 0 { attributes[PageAttribute.indent] = .number(Double(indent)) }
            if checked { attributes[PageAttribute.checked] = .bool(true) }
            runs.append(TextRun(text: "\n", attributes: attributes))
        }
        let bold: Attributes = [PageAttribute.bold: .bool(true)]
        let italic: Attributes = [PageAttribute.italic: .bool(true)]

        text("Trip to Lisbon"); end("h1")
        text("Notes kept in sync between two devices. Type in either editor: "); text("bold", bold); text(", ")
        text("italic", italic); text(", "); text("underline", [PageAttribute.underline: .bool(true)]); text(", ")
        text("strikethrough", [PageAttribute.strike: .bool(true)]); text(", "); text("inline code", [PageAttribute.code: .bool(true)])
        text(" and a "); text("link", [PageAttribute.link: .string("https://example.com")]); text(" all travel as attributes.")
        end()
        text("Packing"); end("h2")
        text("Passport and tickets"); end("todo", checked: true)
        text("Charger, adapter"); end("todo")
        text("Sunscreen 🧴"); end("todo")
        text("Places"); end("h2")
        text("Alfama"); end("ul")
        text("Miradouro de Santa Luzia"); end("ul", indent: 1)
        text("Fado in the evening"); end("ul", indent: 1)
        text("Belém"); end("ul")
        text("Plan"); end("h3")
        text("Land at 10:40, metro to Baixa"); end("ol")
        text("Lunch at Time Out Market"); end("ol")
        text("Tram 28"); end("ol")
        text("Soft break inside a paragraph:\u{2028}second line of the same paragraph."); end()
        text("Budget script"); end("h3")
        text("let nights = 4"); end("code")
        text("let total = nights * 95 + 120"); end("code")
        text("print(total)"); end("code")
        text("That is everything v1 can show."); end()
        return runs
    }()
}
