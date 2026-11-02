import Foundation
import Testing

@testable import TranlixExport

@Suite("NoteBlocks")
struct NoteBlocksTests {
    @Test("the actions table becomes a table, not pipe-separated text")
    func parsesTable() {
        let markdown = """
        ## 4. Actions

        | Action | Owner | Due |
        |---|---|---|
        | Build three CSV demo files | Leo | Unassigned |
        | Write terms and conditions | Unassigned | Unassigned |

        ## 5. Pending topics
        """
        #expect(NoteBlocks.parse(markdown) == [
            .heading(level: 2, text: "4. Actions"),
            .table(
                header: ["Action", "Owner", "Due"],
                rows: [
                    ["Build three CSV demo files", "Leo", "Unassigned"],
                    ["Write terms and conditions", "Unassigned", "Unassigned"],
                ]
            ),
            .heading(level: 2, text: "5. Pending topics"),
        ])
    }

    @Test("cell contents keep their inline markdown and timecodes")
    func keepsInlineContent() {
        let markdown = """
        | Action | Owner |
        | :--- | ---: |
        | Look into **Meta** scope [41:31] | Persona 2 |
        """
        #expect(NoteBlocks.parse(markdown) == [
            .table(header: ["Action", "Owner"], rows: [["Look into **Meta** scope [41:31]", "Persona 2"]]),
        ])
    }

    @Test("short rows are padded and extra cells are kept in the last column")
    func fitsRowsToHeader() {
        let markdown = """
        | A | B |
        |---|---|
        | only one |
        | x | y | z |
        """
        #expect(NoteBlocks.parse(markdown) == [
            .table(header: ["A", "B"], rows: [["only one", ""], ["x", "y | z"]]),
        ])
    }

    @Test("an escaped pipe stays inside its cell")
    func escapedPipe() {
        let markdown = """
        | A | B |
        |---|---|
        | a \\| b | c |
        """
        #expect(NoteBlocks.parse(markdown) == [
            .table(header: ["A", "B"], rows: [["a | b", "c"]]),
        ])
    }

    @Test("a pipe line without a separator is ordinary text")
    func lonePipeRowIsText() {
        #expect(NoteBlocks.parse("| not a table |") == [.text("| not a table |")])
    }

    @Test("paragraphs between headings are grouped and list markers become bullets")
    func paragraphsAndBullets() {
        let markdown = """
        # Title
        - **Demo accounts:** add several
        - Scoring tool
        Plain line.
        """
        #expect(NoteBlocks.parse(markdown) == [
            .heading(level: 1, text: "Title"),
            .text("• **Demo accounts:** add several\n• Scoring tool\nPlain line."),
        ])
    }

    @Test("a hash without a space, or inside a code fence, is not a heading")
    func notHeadings() {
        let markdown = """
        #hashtag
        ```
        # comment
        | a | b |
        |---|---|
        ```
        """
        #expect(NoteBlocks.parse(markdown) == [.text(markdown)])
    }
}
