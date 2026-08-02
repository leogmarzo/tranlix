import Foundation

public enum StoreError: Error, LocalizedError, Equatable {
    case cannotWrite(URL, reason: String)
    case cannotRead(URL, reason: String)
    case notASession(URL)
    case insufficientDiskSpace(requiredBytes: Int64, availableBytes: Int64)

    public var errorDescription: String? {
        switch self {
        case let .cannotWrite(url, reason):
            "No se pudo escribir \(url.lastPathComponent): \(reason)"
        case let .cannotRead(url, reason):
            "No se pudo leer \(url.lastPathComponent): \(reason)"
        case let .notASession(url):
            "\(url.lastPathComponent) no es una sesión: falta manifest.json"
        case let .insufficientDiskSpace(required, available):
            """
            Espacio insuficiente en disco: hacen falta \
            \(ByteCountFormatter.string(fromByteCount: required, countStyle: .file)) \
            y hay \
            \(ByteCountFormatter.string(fromByteCount: available, countStyle: .file)).
            """
        }
    }
}
