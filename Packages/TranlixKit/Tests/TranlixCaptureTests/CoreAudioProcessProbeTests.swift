import Foundation
import Testing

@testable import TranlixCapture

/// Working out which app a process belongs to, from its executable's path.
@Suite("Responsible app")
struct ResponsibleAppTests {
    @Test("an app's own executable resolves to that app")
    func ownExecutable() {
        let app = ResponsibleApp.enclosingApp(
            ofExecutableAt: "/System/Applications/Calculator.app/Contents/MacOS/Calculator"
        )
        #expect(app?.bundleID == "com.apple.calculator")
        #expect(app?.name.isEmpty == false)
    }

    @Test("an app nested inside another resolves to the outer one")
    func nestedHelper() {
        // The shape of a browser helper: Google Chrome.app/…/Google Chrome Helper.app/….
        let app = ResponsibleApp.enclosingApp(
            ofExecutableAt: "/System/Library/CoreServices/Finder.app/Contents/Applications/AirDrop.app/Contents/MacOS/AirDrop"
        )
        #expect(app?.bundleID == "com.apple.finder")
    }

    @Test("a Chrome code-signing clone, named .app.bundle, still resolves")
    func codeSignClone() throws {
        // Seen on a real Mac: after an update Chrome's main process runs from
        // …/com.google.Chrome.code_sign_clone/…/Google Chrome.app.bundle/Contents/MacOS/Google Chrome.
        let root = URL(filePath: NSTemporaryDirectory())
            .appending(path: "tranlix-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let bundle = root.appending(path: "Google Chrome.app.bundle")
        let contents = bundle.appending(path: "Contents")
        try FileManager.default.createDirectory(
            at: contents.appending(path: "MacOS"), withIntermediateDirectories: true
        )
        let info: [String: Any] = [
            "CFBundleIdentifier": "com.google.Chrome",
            "CFBundleName": "Chrome",
            "CFBundlePackageType": "APPL",
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try data.write(to: contents.appending(path: "Info.plist"))

        let app = ResponsibleApp.enclosingApp(
            ofExecutableAt: contents.appending(path: "MacOS/Google Chrome").path
        )
        #expect(app?.bundleID == "com.google.Chrome")
        #expect(app?.name == "Chrome")
    }

    @Test("an executable outside any app resolves to nothing")
    func notInsideAnApp() {
        #expect(ResponsibleApp.enclosingApp(ofExecutableAt: "/usr/bin/true") == nil)
        #expect(ResponsibleApp.enclosingApp(ofExecutableAt: "") == nil)
    }

    @Test("a process that does not exist resolves to nothing")
    func deadProcess() {
        #expect(ResponsibleApp.resolve(for: -1) == nil)
    }
}

/// The real probe, against the real Core Audio. Opt-in: it depends on what the machine is
/// running.
@Suite(
    "Core Audio process probe",
    .enabled(if: ProcessInfo.processInfo.environment["TRANLIX_INTEGRATION"] != nil)
)
struct CoreAudioProcessProbeTests {
    @Test("a snapshot lists processes and survives observing on and off")
    func snapshotAndObserve() async throws {
        let probe = CoreAudioProcessProbe()
        probe.startObserving {}
        let processes = await probe.snapshot()
        // Something on a running Mac always has a process object: coreaudiod's own helpers,
        // Control Center, the system sound server.
        #expect(!processes.isEmpty)
        probe.stopObserving()
        probe.startObserving {}
        probe.stopObserving()
        _ = await probe.snapshot()
    }

    @Test("print what Core Audio reports, to check the matching table against real apps")
    func diagnostic() async {
        // Run with a meeting open in Zoom, Teams or a browser to see what it looks like:
        //   TRANLIX_INTEGRATION=1 swift test --filter "Core Audio process probe"
        let probe = CoreAudioProcessProbe()
        for process in await probe.snapshot() {
            let match = MeetingApp.matching(bundleID: process.bundleID, appBundleID: process.appBundleID)
            print(
                "pid=\(process.pid)",
                "bundle=\(process.bundleID ?? "-")",
                "app=\(process.appBundleID ?? "-")",
                "name=\(process.appName ?? "-")",
                "input=\(process.isRunningInput)",
                "meeting=\(match?.rawValue ?? "-")"
            )
        }
    }
}
