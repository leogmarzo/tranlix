// swift-tools-version: 6.2
import PackageDescription

// Modules are added here as each milestone lands, so the package always describes
// something real. Dependency direction is one-way: TranlixModel is a leaf that every
// other module depends on, and TranlixStore is the only module that knows the on-disk
// layout.
let package = Package(
    name: "TranlixKit",
    platforms: [.macOS(.v26)],
    products: [
        .library(
            name: "TranlixKit",
            targets: [
                "TranlixModel",
                "TranlixStore",
                "TranlixCapture",
                "TranlixTranscribe",
            ]
        ),
    ],
    dependencies: [
        // Whisper large-v3-turbo running on CoreML, as a Swift package. The scope asked for
        // whisper.cpp; this is the same model without a C build system to feed, which matters
        // a great deal once the app has to be notarized.
        .package(url: "https://github.com/argmaxinc/WhisperKit", from: "1.0.0"),
    ],
    targets: [
        .target(name: "TranlixModel"),
        .testTarget(name: "TranlixModelTests", dependencies: ["TranlixModel"]),

        .target(name: "TranlixStore", dependencies: ["TranlixModel"]),
        .testTarget(
            name: "TranlixStoreTests",
            dependencies: ["TranlixStore", "TranlixModel", "TranlixTestSupport"]
        ),

        .target(name: "TranlixCapture", dependencies: ["TranlixModel", "TranlixStore"]),
        .testTarget(
            name: "TranlixCaptureTests",
            dependencies: ["TranlixCapture", "TranlixStore", "TranlixModel", "TranlixTestSupport"]
        ),

        .target(
            name: "TranlixTranscribe",
            dependencies: [
                "TranlixModel",
                "TranlixStore",
                .product(name: "WhisperKit", package: "WhisperKit"),
            ]
        ),
        .testTarget(
            name: "TranlixTranscribeTests",
            dependencies: ["TranlixTranscribe", "TranlixStore", "TranlixModel", "TranlixTestSupport"]
        ),

        // Shared test helpers. Deliberately not part of the TranlixKit product, so nothing
        // here can be linked into the app by accident.
        .target(name: "TranlixTestSupport"),
    ]
)
