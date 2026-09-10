// swift-tools-version: 6.2
import PackageDescription

// Modules are added here as each milestone lands, so the package always describes
// something real. Dependency direction is one-way: TranslixModel is a leaf that every
// other module depends on, and TranslixStore is the only module that knows the on-disk
// layout.
let package = Package(
    name: "TranslixKit",
    platforms: [.macOS(.v26)],
    products: [
        .library(
            name: "TranslixKit",
            targets: [
                "TranslixModel",
                "TranslixStore",
                "TranslixCapture",
                "TranslixTranscribe",
                "TranslixDiarize",
                "TranslixExport",
                "TranslixSummarize",
                "TranslixPlayback",
                "TranslixPipeline",
            ]
        ),
    ],
    dependencies: [
        // Whisper large-v3-turbo running on CoreML, as a Swift package. The scope asked for
        // whisper.cpp; this is the same model without a C build system to feed, which matters
        // a great deal once the app has to be notarized.
        .package(url: "https://github.com/argmaxinc/WhisperKit", from: "1.0.0"),
        // Pyannote diarization converted to CoreML. Chosen over sherpa-onnx, which is CPU-only
        // and has no Swift integration; this runs on the Neural Engine and its offline pipeline
        // is built for exactly our case, a finished file rather than a live stream.
        .package(url: "https://github.com/FluidInference/FluidAudio", from: "0.15.5"),
    ],
    targets: [
        .target(name: "TranslixModel"),
        .testTarget(name: "TranslixModelTests", dependencies: ["TranslixModel"]),

        .target(name: "TranslixStore", dependencies: ["TranslixModel"]),
        .testTarget(
            name: "TranslixStoreTests",
            dependencies: ["TranslixStore", "TranslixModel", "TranslixTestSupport"]
        ),

        // Converting a raised NSException into a Swift error. Its own target because a
        // SwiftPM target is single-language, and it is a dependency of Capture rather than a
        // member of the product: nothing outside Capture has any business raising or
        // catching Objective-C exceptions.
        .target(name: "TranslixObjC"),

        .target(
            name: "TranslixCapture",
            dependencies: ["TranslixModel", "TranslixStore", "TranslixObjC"]
        ),
        .testTarget(
            name: "TranslixCaptureTests",
            dependencies: ["TranslixCapture", "TranslixStore", "TranslixModel", "TranslixTestSupport"]
        ),

        .target(
            name: "TranslixTranscribe",
            dependencies: [
                "TranslixModel",
                "TranslixStore",
                .product(name: "WhisperKit", package: "WhisperKit"),
            ]
        ),
        .testTarget(
            name: "TranslixTranscribeTests",
            dependencies: ["TranslixTranscribe", "TranslixStore", "TranslixModel", "TranslixTestSupport"]
        ),

        .target(
            name: "TranslixDiarize",
            dependencies: [
                "TranslixModel",
                "TranslixStore",
                .product(name: "FluidAudio", package: "FluidAudio"),
            ]
        ),
        .testTarget(
            name: "TranslixDiarizeTests",
            dependencies: ["TranslixDiarize", "TranslixStore", "TranslixModel", "TranslixTestSupport"]
        ),

        // Rendering only, and deliberately dependency-free beyond the model: the same
        // renderer produces the Markdown the user exports and the text sent to be
        // summarised, so what the model reads is exactly what the user can read.
        .target(name: "TranslixExport", dependencies: ["TranslixModel"]),
        .testTarget(
            name: "TranslixExportTests",
            dependencies: ["TranslixExport", "TranslixModel"]
        ),

        .target(name: "TranslixSummarize", dependencies: ["TranslixModel", "TranslixStore"]),
        .testTarget(
            name: "TranslixSummarizeTests",
            dependencies: ["TranslixSummarize", "TranslixStore", "TranslixModel", "TranslixTestSupport"]
        ),

        // Reading the audio back. Depends on Store rather than the other way around: the
        // waveform cache lives beside the archives and is written by the transcription
        // pipeline, so the digest itself belongs in Store and only the player lives here.
        .target(name: "TranslixPlayback", dependencies: ["TranslixModel", "TranslixStore"]),
        .testTarget(
            name: "TranslixPlaybackTests",
            dependencies: ["TranslixPlayback", "TranslixStore", "TranslixModel", "TranslixTestSupport"]
        ),

        // The only module that knows all three stages exist. Kept out of the app layer for
        // the reason SummaryPipeline already gives about its own invariant: a rule that lives
        // only in the UI is one refactor away from being gone, and it can be tested here.
        .target(
            name: "TranslixPipeline",
            dependencies: [
                "TranslixModel",
                "TranslixStore",
                "TranslixTranscribe",
                "TranslixDiarize",
                "TranslixSummarize",
                "TranslixExport",
            ]
        ),
        .testTarget(
            name: "TranslixPipelineTests",
            dependencies: ["TranslixPipeline", "TranslixStore", "TranslixModel", "TranslixTestSupport"]
        ),

        // Shared test helpers. Deliberately not part of the TranslixKit product, so nothing
        // here can be linked into the app by accident. It depends on the stage modules so the
        // stubs can live in one place: the chain has to drive all three at once, and three
        // private copies of the same fake is how they drift apart.
        .target(
            name: "TranslixTestSupport",
            dependencies: ["TranslixTranscribe", "TranslixDiarize", "TranslixSummarize"]
        ),
    ]
)
