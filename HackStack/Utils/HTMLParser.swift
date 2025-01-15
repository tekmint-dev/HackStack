import Foundation
import SwiftUI
import SwiftSoup

final class HTMLParser {
    // MARK: - Types
    
    struct Configuration {
        let defaultFontSize: CGFloat
        let defaultFontFamily: String
        let codeFontFamily: String
        let linkColor: String
        
        static let `default` = Configuration(
            defaultFontSize: 13,
            defaultFontFamily: "-apple-system, BlinkMacSystemFont, sans-serif",
            codeFontFamily: "ui-monospace, SF Mono, Menlo, monospace",
            linkColor: "#007bff"
        )
    }
    
    // MARK: - Properties
    
    private static let cssTemplate = """
    <style>
    :root {
        color-scheme: light dark;
        --link-color: %@;
        --code-bg-color: rgba(0, 0, 0, 0.05);
        --pre-bg-color: rgba(0, 0, 0, 0.03);
        --border-color: rgba(0, 0, 0, 0.1);
    }
    @media (prefers-color-scheme: dark) {
        :root {
            --code-bg-color: rgba(255, 255, 255, 0.1);
            --pre-bg-color: rgba(255, 255, 255, 0.05);
            --border-color: rgba(255, 255, 255, 0.1);
        }
    }
    body {
        font-family: %@;
        font-size: %@px;
        line-height: 1.5;
        margin: 0;
        padding: 0;
    }
    p {
        padding: 0;
        line-height: 1.6;
    }
    /* First paragraph shouldn't have top margin */
    body > p:first-child,
    blockquote > p:first-child {
        margin-top: 0;
    }
    /* Last paragraph shouldn't have bottom margin */
    body > p:last-child,
    blockquote > p:last-child {
        margin-bottom: 0;
    }
    /* Add extra spacing when paragraphs are followed by other block elements */
    p + pre, p + ul, p + ol, p + blockquote {
        margin-top: 2em;
    }
    /* Add extra spacing when paragraphs follow block elements */
    pre + p, ul + p, ol + p, blockquote + p {
        margin-top: 2em;
    }
    a {
        font-size: %@px;
        text-decoration: underline;
        color: var(--link-color);
    }
    a:hover {
        text-decoration: none;
    }
    pre {
        font-family: %@;
        font-size: %@px;
        background-color: var(--pre-bg-color);
        color: -apple-system-label;
        padding: 1em;
        border-radius: 8px;
        margin: 2em 0;
        border: 1px solid var(--border-color);
        overflow-x: auto;
        line-height: 1.45;
        position: relative;
    }
    pre code {
        font-family: %@;
        font-size: %@px;
        white-space: pre;
        display: block;
        padding: 0;
        margin: 0;
        background: none;
        border: none;
        tab-size: 4;
    }
    :not(pre) > code {
        font-family: %@;
        font-size: %@px;
        background-color: var(--code-bg-color);
        padding: 0.2em 0.4em;
        border-radius: 4px;
        white-space: pre-wrap;
        word-wrap: break-word;
    }
    pre::-webkit-scrollbar {
        height: 8px;
        background-color: transparent;
    }
    pre::-webkit-scrollbar-thumb {
        background-color: var(--border-color);
        border-radius: 4px;
    }
    pre::-webkit-scrollbar-track {
        background-color: transparent;
    }
    </style>
    """
    
    // MARK: - Public Methods
    
    static func parseHTML(
        _ text: String,
        configuration: Configuration = .default
    ) -> AttributedString {
        do {
            // Parse the HTML using SwiftSoup
            let doc = try SwiftSoup.parse(text)
            
            // Clean and format the document
            try cleanDocument(doc)
            
            // Apply our custom styling
            let styledHTML = try applyStyles(to: doc.html(), with: configuration)
            
            // Convert to AttributedString
            guard let data = styledHTML.data(using: .utf8) else {
                throw NSError(domain: "HTMLParserError", code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "Failed to convert HTML to data"])
            }
            
            let nsAttributedString = try NSAttributedString(
                data: data,
                options: [
                    .documentType: NSAttributedString.DocumentType.html,
                    .characterEncoding: String.Encoding.utf8.rawValue
                ],
                documentAttributes: nil
            )
            
            return AttributedString(nsAttributedString)
        } catch {
            Logger.error("HTML parsing failed: \(error)")
            return AttributedString(text)
        }
    }
    
    // MARK: - Private Methods
    
    private static func cleanDocument(_ doc: Document) throws {
        // Convert line breaks to paragraphs
        // let elements = try doc.body()?.getAllElements() ?? Elements()
        // for element in elements {
        //     if element.tagName() != "pre" && element.tagName() != "code" {
        //         // Handle text nodes with multiple line breaks
        //         let text = try element.ownText()
        //         if text.contains("\n") {
        //             let paragraphs = text.components(separatedBy: "\n\n")
        //                 .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
                    
        //             if paragraphs.count > 1 {
        //                 try element.empty()
        //                 for paragraph in paragraphs {
        //                     try element.append("<p>\(paragraph.trimmingCharacters(in: .whitespacesAndNewlines))</p>")
        //                 }
        //             }
        //         }
        //     }
        // }
        
        // Wrap standalone text nodes in paragraphs
//        try doc.body()?.textNodes().forEach { node in
//            let text = node.text().trimmingCharacters(in: .whitespacesAndNewlines)
//            if !text.isEmpty {
//                try node.wrap("<p></p>")
//            }
//        }

        // Add <br> before <p> tags, starting second occurence
        try doc.select("p").forEach { node in
            let index = try node.elementSiblingIndex()
            if index > 0 {
                try node.before("<br>")
            }
        }

        // Process code blocks
        try doc.select("pre code").forEach { codeBlock in
            // Preserve indentation and whitespace
            let code = try codeBlock.html()
                .replacingOccurrences(of: "\n", with: "&#10;")  // Preserve newlines
                .replacingOccurrences(of: " ", with: "&nbsp;")  // Preserve spaces
                .replacingOccurrences(of: "\t", with: "&nbsp;&nbsp;&nbsp;&nbsp;")  // Convert tabs to spaces
            
            try codeBlock.html(code)
        }
        
        // Process inline code
        try doc.select(":not(pre) > code").forEach { inlineCode in
            let code = try inlineCode.html()
                .replacingOccurrences(of: " ", with: "&nbsp;")
            try inlineCode.html(code)
        }
    }
    
    private static func applyStyles(
        to html: String,
        with configuration: Configuration
    ) -> String {
        let css = String(
            format: cssTemplate,
            configuration.linkColor,
            configuration.defaultFontFamily,
            "\(Int(configuration.defaultFontSize))",
            "\(Int(configuration.defaultFontSize))",
            configuration.codeFontFamily,
            "\(Int(configuration.defaultFontSize))",
            configuration.codeFontFamily,
            "\(Int(configuration.defaultFontSize))",
            configuration.codeFontFamily,
            "\(Int(configuration.defaultFontSize))",
            configuration.codeFontFamily,
            "\(Int(configuration.defaultFontSize))"
        )
        
        return """
        \(css)
        <body>
        \(html)
        </body>
        """
    }
}

// MARK: - Logger

private enum Logger {
    static func error(_ message: String) {
        #if DEBUG
        print("HTMLParser Error: \(message)")
        #endif
    }
}
