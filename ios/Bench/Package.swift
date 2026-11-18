// swift-tools-version: 6.0
import PackageDescription

// A macOS command-line benchmark that runs the app's own recap engines
// (Apple's on-device model and the Anthropic API) over the same transcripts.
//
// The engine sources are symlinked from ios/CatchMeUp (see Sources/BenchCore/App)
// so the benchmark exercises the code that ships, not a copy of it.
let shared: [SwiftSetting] = [
    // Compiles the app's engine files without the settings/UI layer.
    .define("CATCHMEUP_BENCH"),
    // The app's @Generable guides use /regex/ literals.
    .enableUpcomingFeature("BareSlashRegexLiterals"),
]

let package = Package(
    name: "Bench",
    platforms: [.macOS("26.0")],
    products: [
        .executable(name: "bench", targets: ["bench"]),
    ],
    targets: [
        .target(name: "BenchCore", path: "Sources/BenchCore", swiftSettings: shared),
        .executableTarget(name: "bench", dependencies: ["BenchCore"], path: "Sources/bench"),
        .testTarget(
            name: "BenchCoreTests",
            dependencies: ["BenchCore"],
            path: "Tests/BenchCoreTests",
            exclude: [],
            swiftSettings: shared
        ),
    ],
    swiftLanguageModes: [.v5]
)
