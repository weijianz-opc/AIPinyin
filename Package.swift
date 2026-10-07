// swift-tools-version: 6.0
import PackageDescription

/// Official librime release build, unpacked by `make deps` (see Makefile).
let rimeLib = Context.packageDirectory + "/ThirdParty/librime/dist/lib"

let package = Package(
    name: "AIPinyin",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "AIPinyin", targets: ["AIPinyin"]),
        .executable(name: "aipinyin-cli", targets: ["aipinyin-cli"]),
    ],
    targets: [
        // Pure logic: AWS auth, Bedrock streaming client, prompt/parser, two-level composer, key maps.
        .target(name: "AIPinyinCore"),

        // librime's C API; header and dylib come from ThirdParty/librime.
        .systemLibrary(name: "CRime", path: "Sources/CRime"),

        // Swift wrapper around librime: level one (local pinyin).
        .target(
            name: "AIPinyinRime",
            dependencies: ["CRime", "AIPinyinCore"],
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [.unsafeFlags(["-L\(rimeLib)"])]
        ),

        // The input method process (bundled into AIPinyin.app by the Makefile).
        // AppKit/InputMethodKit glue is written in Swift 5 mode: IMK predates Swift concurrency
        // annotations and every callback arrives on the main thread anyway.
        .executableTarget(
            name: "AIPinyin",
            dependencies: ["AIPinyinCore", "AIPinyinRime"],
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("InputMethodKit"),
                .linkedFramework("Carbon"),
                // librime.1.dylib is copied into Contents/Frameworks by the Makefile.
                .unsafeFlags(["-L\(rimeLib)", "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"]),
            ]
        ),

        // Developer tool: run level two (translate/polish) from the terminal.
        .executableTarget(name: "aipinyin-cli", dependencies: ["AIPinyinCore"]),

        // 「AI 拼音设置」: a launcher in ~/Applications that opens the input method's settings window.
        .executableTarget(name: "AIPinyinSettings", swiftSettings: [.swiftLanguageMode(.v5)]),

        .testTarget(
            name: "AIPinyinCoreTests",
            dependencies: ["AIPinyinCore"],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(
            name: "AIPinyinRimeTests",
            dependencies: ["AIPinyinRime"],
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [.unsafeFlags(["-L\(rimeLib)", "-Xlinker", "-rpath", "-Xlinker", rimeLib])]
        ),
    ]
)
