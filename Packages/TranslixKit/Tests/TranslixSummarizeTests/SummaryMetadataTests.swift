import Testing
@testable import TranslixSummarize

@Suite("Summary metadata")
struct SummaryMetadataTests {
    @Test("extracts names and title without leaking metadata into Markdown")
    func structuredResponse() {
        let result = SummaryMetadata.parse("""
        <translix-metadata>{"sessionTitle":"Planning","speakerNames":[{"speakerID":"system-1","name":"Alex","evidence":"I am Alex."}]}</translix-metadata>
        <!-- translix-notes -->
        ## Decisions
        Ship tomorrow.
        """)
        #expect(result.title == "Planning")
        #expect(result.speakerNames.first?.name == "Alex")
        #expect(result.markdown == "## Decisions\nShip tomorrow.")
    }

    @Test("bad or missing metadata preserves usable notes", arguments: [
        "<translix-metadata>broken</translix-metadata>\n<!-- translix-notes -->\nKeep this.",
        "<translix-metadata>broken\n<!-- translix-notes -->\nKeep this.",
        "<translix-metadata>{}</translix-metadata>\nKeep this.",
        "Keep this.",
        "<session-title>Planning</session-title>Keep this.",
    ])
    func fallback(_ response: String) {
        #expect(SummaryMetadata.parse(response).markdown == "Keep this.")
    }

    @Test("metadata-only responses do not become notes")
    func metadataOnly() {
        #expect(SummaryMetadata.parse("<translix-metadata>{}</translix-metadata>").markdown.isEmpty)
    }

    @Test("does not parse tags inside ordinary notes")
    func bodyTags() {
        let text = "## Example\n<translix-metadata>literal</translix-metadata>"
        #expect(SummaryMetadata.parse(text).markdown == text)
    }

    @Test("a delimiter example in the body does not discard preceding notes")
    func bodyDelimiter() {
        let body = "Keep this.\n<!-- translix-notes -->\nMore."
        #expect(SummaryMetadata.parse("<translix-metadata>{}</translix-metadata>\n" + body).markdown == body)
    }
}
