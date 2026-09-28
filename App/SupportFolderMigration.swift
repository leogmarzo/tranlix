import Foundation

/// Moves `Application Support/Translix` to `Application Support/Tranlix`.
///
/// The app was briefly called Translix, and installs from that time keep the user's edited
/// templates under that folder. Moving it in place keeps them rather than silently falling
/// back to the default templates.
///
/// Only moves when the destination does not exist yet: anything already under `Tranlix` stays
/// as it is, and the legacy folder is left for the user to look at rather than merged or
/// deleted.
enum SupportFolderMigration {
    static func run(fileManager: FileManager = .default) {
        guard let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        else { return }
        let legacy = base.appending(path: "Translix")
        let current = base.appending(path: "Tranlix")
        guard fileManager.fileExists(atPath: legacy.path),
              !fileManager.fileExists(atPath: current.path)
        else { return }
        try? fileManager.moveItem(at: legacy, to: current)
    }
}
