// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Sidetone",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "Sidetone", targets: ["Sidetone"]),
        .executable(name: "SidetoneProbe", targets: ["SidetoneProbe"]),
    ],
    targets: [
        .target(
            name: "RNNoise",
            path: "ThirdParty/RNNoise",
            exclude: ["COPYING", "ORIGIN.json"],
            publicHeadersPath: "include",
            cSettings: [
                .headerSearchPath("src"),
                .define("RNNOISE_BUILD"),
                .define("DISABLE_DEBUG_FLOAT"),
                .unsafeFlags(["-O3"]),
            ]
        ),
        .target(
            name: "AudioCore",
            dependencies: ["RNNoise"],
            publicHeadersPath: "include",
            cxxSettings: [.unsafeFlags(["-Wall", "-Wextra", "-Werror"])],
            linkerSettings: [
                .linkedFramework("CoreAudio"), .linkedFramework("AudioToolbox"),
                .linkedFramework("CoreFoundation"),
            ]
        ),
        .target(
            name: "SidetoneKit", dependencies: ["AudioCore"],
            resources: [.copy("Resources/KeyboardSounds")],
            swiftSettings: [.unsafeFlags(["-warnings-as-errors"])]),
        .executableTarget(
            name: "Sidetone", dependencies: ["SidetoneKit"],
            swiftSettings: [.unsafeFlags(["-warnings-as-errors"])]),
        .executableTarget(
            name: "SidetoneProbe", dependencies: ["AudioCore"],
            swiftSettings: [.unsafeFlags(["-warnings-as-errors"])]),
        .testTarget(name: "SidetoneKitTests", dependencies: ["SidetoneKit"]),
    ],
    cxxLanguageStandard: .cxx20
)
