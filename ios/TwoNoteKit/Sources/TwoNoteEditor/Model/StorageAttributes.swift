// How the page's attributes are kept in a text storage, shared by the UIKit and the AppKit
// binding (moved here unchanged from UIKit/EditorTheme.swift).

import Foundation
import TwoNoteDocuments

// The page's attributes live in the text storage under these keys; everything visual (fonts,
// colours, paragraph styles) is derived from them and never read back.
extension NSAttributedString.Key {
    static let tnBold = NSAttributedString.Key("tn.bold")
    static let tnItalic = NSAttributedString.Key("tn.italic")
    static let tnUnderline = NSAttributedString.Key("tn.underline")
    static let tnStrike = NSAttributedString.Key("tn.strike")
    static let tnCode = NSAttributedString.Key("tn.code")
    static let tnLink = NSAttributedString.Key("tn.link")
    /// On "\n" only: raw block name, raw indent, checked.
    static let tnBlock = NSAttributedString.Key("tn.block")
    static let tnIndent = NSAttributedString.Key("tn.indent")
    static let tnChecked = NSAttributedString.Key("tn.checked")
    /// On "\n" only, presentation: the number a numbered item shows, and whether a code
    /// paragraph is the first (1) and/or last (2) of its run. Changing them re-lays the paragraph.
    static let tnOrdinal = NSAttributedString.Key("tn.ordinal")
    static let tnCodeEdge = NSAttributedString.Key("tn.codeEdge")
}

extension InlineAttrs {
    /// Reads the inline attributes a text storage holds for one character.
    init(storage attributes: [NSAttributedString.Key: Any]) {
        self.init(bold: attributes[.tnBold] != nil, italic: attributes[.tnItalic] != nil,
                  underline: attributes[.tnUnderline] != nil, strike: attributes[.tnStrike] != nil,
                  code: attributes[.tnCode] != nil, link: attributes[.tnLink] as? String)
    }
}

extension BlockAttrs {
    init(storage attributes: [NSAttributedString.Key: Any]) {
        self.init(block: attributes[.tnBlock] as? String, indent: (attributes[.tnIndent] as? Int) ?? 0,
                  checked: attributes[.tnChecked] != nil)
    }
}

/// Presentation facts about a paragraph that are not in its own attributes.
struct ParagraphContext: Equatable {
    var ordinal = 0
    var codeEdge = 0
}
