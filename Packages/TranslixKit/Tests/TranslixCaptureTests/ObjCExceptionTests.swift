import Foundation
import Testing

@testable import TranslixCapture

/// Catching what Objective-C raises.
///
/// This is the only part of the crash defence that can be tested without a device storm, and
/// it is worth testing precisely because its failure mode is silent: a shim that does not
/// actually catch looks identical to one that does until the day an exception is raised, and
/// on that day the process aborts. If these tests are broken the test run itself aborts,
/// which is the correct way for this to fail.
@Suite("Objective-C exception shim")
struct ObjCExceptionTests {
    @Test("a raised exception becomes a Swift error")
    func raisedExceptionBecomesSwiftError() throws {
        var thrown: (any Error)?
        do {
            try ObjCException.catching {
                NSException(
                    name: .invalidArgumentException,
                    reason: "required condition is false: nullptr == Tap()",
                    userInfo: nil
                ).raise()
            }
        } catch {
            thrown = error
        }

        let failure = try #require(thrown as? CaptureError)
        // The reason is the whole point: it is what the crash report leaves out, and what
        // tells the next reader which assertion fired.
        #expect(failure.localizedDescription.contains("required condition is false"))
        #expect(failure.localizedDescription.contains("NSInvalidArgumentException"))
    }

    @Test("a body that raises nothing returns normally")
    func quietBodyReturnsNormally() throws {
        var ran = false
        try ObjCException.catching { ran = true }
        #expect(ran)
    }
}
