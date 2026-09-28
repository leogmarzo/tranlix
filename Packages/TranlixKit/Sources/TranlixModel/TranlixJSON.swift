import Foundation

/// The canonical on-disk JSON format.
///
/// Defined once, in the module that owns the on-disk contract, so that everything writing
/// into a session folder agrees on it. Files are pretty-printed with sorted keys and ISO-8601
/// dates because they are meant to be opened in a text editor and diffed, not just parsed.
public enum TranlixJSON {
    public static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    public static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    public static func encode(_ value: some Encodable) throws -> Data {
        try encoder.encode(value)
    }

    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        try decoder.decode(type, from: data)
    }
}
