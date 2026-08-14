import Foundation
import Testing
import TranlixModel

@testable import TranlixSummarize

@Suite("Notes language policy")
struct NotesLanguageTests {
    @Test("following the session writes in whatever the session turned out to be")
    func followsTheSession() {
        #expect(NotesLanguage.session.resolved(for: .english) == .english)
        #expect(NotesLanguage.session.resolved(for: .spanish) == .spanish)
    }

    @Test("following the session falls back to Spanish when nothing could be detected")
    func fallsBackToSpanish() {
        // A short or unsupported recording should still produce notes, in the language the
        // rest of the app is written in, rather than none at all.
        #expect(NotesLanguage.session.resolved(for: nil) == .spanish)
        #expect(NotesLanguage.session.resolved(for: .auto) == .spanish)
    }

    @Test("a fixed policy ignores what the session turned out to be")
    func fixedPolicyWins() {
        // The point of the setting: minutes of an English meeting can still be read in
        // Spanish, and notes for a Spanish class can still be shared in English.
        #expect(NotesLanguage.spanish.resolved(for: .english) == .spanish)
        #expect(NotesLanguage.english.resolved(for: .spanish) == .english)
        #expect(NotesLanguage.english.resolved(for: nil) == .english)
    }

    @Test("the rule overrides a template that asks for a language itself")
    func ruleOverridesATemplateThatNamesALanguage() {
        // The templates that shipped before this setting existed say "escribí apuntes en
        // español rioplatense" in their own text, and they sit on disk in every install from
        // then, because the seeds are only ever written when the file is missing. Against an
        // explicit instruction like that, a rule that merely stated a preference lost — an
        // English meeting came out as Spanish notes under Spanish headings.
        //
        // It has to say that it wins, not just what it wants.
        #expect(NotesLanguage.rule(writingIn: .english).lowercased().contains("ignore"))
        #expect(NotesLanguage.rule(writingIn: .spanish).lowercased().contains("ignorá"))
    }

    @Test("the default is to follow the session")
    func defaultFollowsTheSession() {
        #expect(NotesLanguage.default == .session)
    }
}
