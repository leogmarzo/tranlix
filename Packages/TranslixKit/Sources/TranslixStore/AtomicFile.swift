import Foundation

/// Crash-safe file replacement.
///
/// `manifest.json` is the source of truth for a session and is rewritten on every closed
/// chunk, which means the app is very likely to be killed in the middle of one of those
/// writes at some point. Writing in place would eventually leave a truncated file and lose
/// the recording it describes.
///
/// The sequence here is the standard durable-replace: write a uniquely named temporary file
/// in the same directory, flush it to the platter, `rename` it over the target, then flush the
/// directory itself. `rename(2)` is atomic, so a reader either sees the whole old file or the
/// whole new one, never a mixture. `Data.write(options: .atomic)` gets the rename right but
/// skips both flushes, which is enough for a crash and not enough for a power cut.
enum AtomicFile {
    static func write(_ data: Data, to url: URL) throws {
        let directory = url.deletingLastPathComponent()
        // A unique temp name means two concurrent writers cannot clobber each other's
        // scratch file, and a leftover temp from a crash is never mistaken for a real one.
        let temp = directory.appendingPathComponent(
            ".\(url.lastPathComponent).\(UUID().uuidString).tmp"
        )

        guard FileManager.default.createFile(atPath: temp.path, contents: nil) else {
            throw StoreError.cannotWrite(temp, reason: "could not create the temporary file")
        }

        do {
            let handle = try FileHandle(forWritingTo: temp)
            do {
                try handle.write(contentsOf: data)
                try handle.synchronize()
            }
            try handle.close()

            guard rename(temp.path, url.path) == 0 else {
                throw StoreError.cannotWrite(
                    url, reason: "rename failed: \(String(cString: strerror(errno)))"
                )
            }
        } catch {
            try? FileManager.default.removeItem(at: temp)
            throw error
        }

        // The rename itself is only durable once the directory entry is flushed.
        try? flushDirectory(directory)
    }

    private static func flushDirectory(_ directory: URL) throws {
        let fd = open(directory.path, O_RDONLY)
        guard fd >= 0 else { return }
        defer { close(fd) }
        _ = fsync(fd)
    }

    /// Removes any temporary files left behind by a write that was interrupted.
    ///
    /// They are harmless — the real file is always either the old or the new one — but a
    /// session folder is meant to be readable by a human, and stray scratch files are noise.
    static func cleanUpTemporaries(in directory: URL) {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        )) ?? []
        for url in contents where url.lastPathComponent.hasPrefix(".")
            && url.pathExtension == "tmp"
        {
            try? FileManager.default.removeItem(at: url)
        }
    }
}
