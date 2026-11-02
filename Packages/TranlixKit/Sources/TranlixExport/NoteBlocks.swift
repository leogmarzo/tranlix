import Foundation

/// A note split into the block-level pieces the inline markdown parser cannot draw.
///
/// `AttributedString(markdown:)` with inline-only syntax handles emphasis and links, but every
/// note has headings and the minutes have an actions table, and those came out as raw `##` and
/// `| --- |` source. Splitting the blocks out here lets the view draw each one properly while
/// still handing the text inside them to the inline parser.
///
/// Lives here rather than in the view so the parsing is tested: it runs over text a language
/// model wrote, and a table with one cell too many or a stray pipe must not lose content.
public enum NoteBlock: Equatable, Sendable {
    case heading(level: Int, text: String)
    case table(header: [String], rows: [[String]])
    /// Everything else, kept as written: paragraphs and lists still go through the inline parser.
    case text(String)
}

public enum NoteBlocks {
    public static func parse(_ markdown: String) -> [NoteBlock] {
        let lines = markdown.components(separatedBy: .newlines)
        var blocks: [NoteBlock] = []
        var paragraph: [String] = []
        var inFence = false

        func flushParagraph() {
            let text = paragraph.joined(separator: "\n")
                .trimmingCharacters(in: .newlines)
            if !text.trimmingCharacters(in: .whitespaces).isEmpty {
                blocks.append(.text(text))
            }
            paragraph = []
        }

        var index = 0
        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Inside a code fence nothing is a heading or a table.
            if trimmed.hasPrefix("```") { inFence.toggle() }
            if inFence || trimmed.hasPrefix("```") {
                paragraph.append(line)
                index += 1
                continue
            }

            if let heading = heading(in: trimmed) {
                flushParagraph()
                blocks.append(heading)
                index += 1
                continue
            }

            // A table is a pipe row followed by a separator row; a lone pipe row is just text.
            if trimmed.hasPrefix("|"), index + 1 < lines.count,
               isSeparator(lines[index + 1].trimmingCharacters(in: .whitespaces)) {
                flushParagraph()
                let header = cells(of: trimmed)
                var rows: [[String]] = []
                index += 2
                while index < lines.count {
                    let row = lines[index].trimmingCharacters(in: .whitespaces)
                    guard row.hasPrefix("|") else { break }
                    rows.append(fitted(cells(of: row), to: header.count))
                    index += 1
                }
                blocks.append(.table(header: header, rows: rows))
                continue
            }

            paragraph.append(bulleted(line))
            index += 1
        }
        flushParagraph()
        return blocks
    }

    private static func heading(in line: String) -> NoteBlock? {
        let hashes = line.prefix { $0 == "#" }
        guard (1 ... 6).contains(hashes.count) else { return nil }
        let rest = line.dropFirst(hashes.count)
        guard rest.first == " " else { return nil }
        let text = rest.trimmingCharacters(in: .whitespaces)
            // A closing run of hashes is optional decoration in markdown.
            .replacingOccurrences(of: #"\s+#+$"#, with: "", options: .regularExpression)
        return .heading(level: hashes.count, text: text)
    }

    /// `|---|:--:|` and friends: only dashes, colons, pipes and spaces, with at least one dash.
    private static func isSeparator(_ line: String) -> Bool {
        guard line.contains("-"), line.contains("|") || line.hasPrefix("-") else { return false }
        return line.allSatisfy { "-:| \t".contains($0) }
    }

    /// The cells of a pipe row, honouring `\|` as a literal pipe inside a cell.
    private static func cells(of row: String) -> [String] {
        var body = Substring(row)
        if body.hasPrefix("|") { body = body.dropFirst() }
        if body.hasSuffix("|"), !body.hasSuffix("\\|") { body = body.dropLast() }

        var cells: [String] = []
        var current = ""
        var escaped = false
        for character in body {
            if escaped {
                current.append(character == "|" ? "|" : "\\\(character)")
                escaped = false
            } else if character == "\\" {
                escaped = true
            } else if character == "|" {
                cells.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
            } else {
                current.append(character)
            }
        }
        if escaped { current.append("\\") }
        cells.append(current.trimmingCharacters(in: .whitespaces))
        return cells
    }

    /// Rows padded to the header's width; extra cells are folded into the last column rather
    /// than dropped, since a stray pipe in model output should not cost the reader content.
    private static func fitted(_ cells: [String], to width: Int) -> [String] {
        guard width > 0 else { return cells }
        if cells.count < width {
            return cells + Array(repeating: "", count: width - cells.count)
        }
        if cells.count > width {
            let tail = cells[(width - 1)...].joined(separator: " | ")
            return Array(cells[..<(width - 1)]) + [tail]
        }
        return cells
    }

    /// `- item` and `* item` drawn as a bullet, keeping any indentation.
    private static func bulleted(_ line: String) -> String {
        let indent = line.prefix { $0 == " " || $0 == "\t" }
        let rest = line.dropFirst(indent.count)
        guard rest.hasPrefix("- ") || rest.hasPrefix("* ") else { return line }
        return indent + "• " + rest.dropFirst(2)
    }
}
