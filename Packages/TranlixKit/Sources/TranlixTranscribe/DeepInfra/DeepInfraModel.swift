import Foundation

/// Which model DeepInfra runs a transcription on.
///
/// Both answer the same request with the same response shape, so everything but the model path
/// is shared. Each model files its results under its own engine id: a session re-transcribed
/// with the other model must not be handed the first model's cached batches as if they were
/// its own.
public enum DeepInfraModel: String, CaseIterable, Codable, Sendable, Identifiable {
    /// The default. The full model rather than `-turbo`: turbo is a pruned distillation that
    /// gives up the most on languages other than English.
    case whisperLargeV3 = "openai/whisper-large-v3"

    /// Measured on 2026-09-28 against a thirty-minute English meeting: about three times
    /// faster per batch at the same price, better on domain vocabulary, and nothing invented
    /// from silence. It writes short backchannels ("mm-hmm", "ok") in Chinese, which
    /// `HallucinationFilter` removes.
    case qwen3ASR = "Qwen/Qwen3-ASR-1.7B"

    public static let `default`: DeepInfraModel = .whisperLargeV3

    public var id: String { rawValue }

    /// The path DeepInfra's inference endpoint expects after `v1/inference/`.
    public var path: String { rawValue }

    /// Whisper keeps the id every existing DeepInfra session was filed under.
    public var engineID: EngineID {
        switch self {
        case .whisperLargeV3: .deepInfra
        case .qwen3ASR: .deepInfraQwen
        }
    }

    public var displayName: String {
        switch self {
        case .whisperLargeV3: "Whisper large-v3"
        case .qwen3ASR: "Qwen3-ASR 1.7B"
        }
    }

    /// The model that produced results filed under `engineID`, if it is one of these.
    public init?(engineID: String) {
        guard let model = Self.allCases.first(where: { $0.engineID.rawValue == engineID }) else {
            return nil
        }
        self = model
    }
}
