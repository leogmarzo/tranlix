import Foundation
import Testing

@testable import TranlixExport

@Suite("NoteTimecodes")
struct NoteTimecodeTests {
    @Test("a timecode becomes a link that carries its position in seconds")
    func linksCarrySeconds() {
        let linked = NoteTimecodes.linkingTimecodes(
            in: "La fórmula [01:08] entra al parcial.", scheme: "tranlix-seek"
        )
        #expect(linked == "La fórmula [01:08](tranlix-seek://68.0) entra al parcial.")
    }

    @Test("hours are understood, since a class runs past one")
    func handlesHours() {
        let linked = NoteTimecodes.linkingTimecodes(
            in: "El repaso [1:23:45] al final.", scheme: "tranlix-seek"
        )
        #expect(linked.contains("tranlix-seek://5025.0"))
    }

    @Test("several in one line all become links")
    func handlesSeveral() {
        let linked = NoteTimecodes.linkingTimecodes(
            in: "Ver [00:30] y también [02:00].", scheme: "s"
        )
        #expect(linked == "Ver [00:30](s://30.0) y también [02:00](s://120.0).")
    }

    @Test("what is not a timecode is left alone")
    func leavesOtherBracketsAlone() {
        // Markdown links and ordinary brackets must survive: rewriting them would break the
        // note rather than enrich it.
        let text = "Ver [el capítulo 4](https://x.com) y la nota [importante]."
        #expect(NoteTimecodes.linkingTimecodes(in: text, scheme: "s") == text)
    }

    @Test("an already-linked timecode is not linked twice")
    func doesNotDoubleLink() {
        let text = "La fórmula [01:08](s://68.0) entra."
        #expect(NoteTimecodes.linkingTimecodes(in: text, scheme: "s") == text)
    }

    @Test("seconds are read back out of a link")
    func readsSecondsBack() {
        #expect(NoteTimecodes.seconds(fromLink: URL(string: "s://68.0")!) == 68)
        #expect(NoteTimecodes.seconds(fromLink: URL(string: "https://x.com")!) == nil)
    }
}
