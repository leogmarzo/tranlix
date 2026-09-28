import Testing
@testable import TranlixSummarize

@Suite("Summary metadata")
struct SummaryMetadataTests {
    @Test("extracts names and title without leaking metadata into Markdown")
    func structuredResponse() {
        let result = SummaryMetadata.parse("""
        <tranlix-metadata>{"sessionTitle":"Planning","speakerNames":[{"speakerID":"system-1","name":"Alex","evidence":"I am Alex."}]}</tranlix-metadata>
        <!-- tranlix-notes -->
        ## Decisions
        Ship tomorrow.
        """)
        #expect(result.title == "Planning")
        #expect(result.speakerNames.first?.name == "Alex")
        #expect(result.markdown == "## Decisions\nShip tomorrow.")
    }

    @Test("bad or missing metadata preserves usable notes", arguments: [
        "<tranlix-metadata>broken</tranlix-metadata>\n<!-- tranlix-notes -->\nKeep this.",
        "<tranlix-metadata>broken\n<!-- tranlix-notes -->\nKeep this.",
        "<tranlix-metadata>{}</tranlix-metadata>\nKeep this.",
        "Keep this.",
        "<session-title>Planning</session-title>Keep this.",
    ])
    func fallback(_ response: String) {
        #expect(SummaryMetadata.parse(response).markdown == "Keep this.")
    }

    @Test("metadata-only responses do not become notes")
    func metadataOnly() {
        #expect(SummaryMetadata.parse("<tranlix-metadata>{}</tranlix-metadata>").markdown.isEmpty)
    }

    @Test("does not parse tags inside ordinary notes")
    func bodyTags() {
        let text = "## Example\n<tranlix-metadata>literal</tranlix-metadata>"
        #expect(SummaryMetadata.parse(text).markdown == text)
    }

    @Test("a delimiter example in the body does not discard preceding notes")
    func bodyDelimiter() {
        let body = "Keep this.\n<!-- tranlix-notes -->\nMore."
        #expect(SummaryMetadata.parse("<tranlix-metadata>{}</tranlix-metadata>\n" + body).markdown == body)
    }
}
