// swift-tools-version: 6.0
import PackageDescription

/// Official librime release build, unpacked by `make deps` (see Makefile).
let rimeLib = Context.packageDirectory + "/ThirdParty/librime/dist/lib"

let package = Package(
    name: "AllInOneIME",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "AllInOneIME", targets: ["AllInOneIME"]),
        .executable(name: "allinoneime-cli", targets: ["allinoneime-cli"]),
    ],
    targets: [
        // Pure logic: AWS auth, Bedrock streaming client, prompt/parser, two-level composer, key maps.
        .target(name: "AllInOneIMECore"),

        // librime's C API; header and dylib come from ThirdParty/librime.
        .systemLibrary(name: "CRime", path: "Sources/CRime"),

        // Swift wrapper around librime: level one (local pinyin).
        .target(
            name: "AllInOneIMERime",
            dependencies: ["CRime", "AllInOneIMECore"],
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [.unsafeFlags(["-L\(rimeLib)"])]
        ),

        // The input method process (bundled into AllInOneIME.app by the Makefile).
        // AppKit/InputMethodKit glue is written in Swift 5 mode: IMK predates Swift concurrency
        // annotations and every callback arrives on the main thread anyway.
        .executableTarget(
            name: "AllInOneIME",
            dependencies: ["AllInOneIMECore", "AllInOneIMERime"],
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("InputMethodKit"),
                .linkedFramework("Carbon"),
                // Voice input: microphone capture and on-device speech recognition.
                .linkedFramework("AVFoundation"),
                .linkedFramework("Speech"),
                // @reminder: Apple Reminders.
                .linkedFramework("EventKit"),
                // librime.1.dylib is copied into Contents/Frameworks by the Makefile.
                .unsafeFlags(["-L\(rimeLib)", "-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"]),
            ]
        ),

        // Developer tool: run level two (translate/polish) from the terminal.
        .executableTarget(name: "allinoneime-cli", dependencies: ["AllInOneIMECore"]),

        // AllInOneIME Settings (「AllInOneIME 设置」): a launcher in ~/Applications that opens the settings window.
        .executableTarget(name: "AllInOneIMESettings", swiftSettings: [.swiftLanguageMode(.v5)]),

        // 「安装 AllInOneIME」: the installer on the release disk image (`make dmg`). It carries both
        // apps and installs them like `make install`; it uninstalls them too.
        .executableTarget(
            name: "AllInOneIMEInstaller",
            dependencies: ["AllInOneIMECore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),

        .testTarget(
            name: "AllInOneIMECoreTests",
            dependencies: ["AllInOneIMECore"],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(
            name: "AllInOneIMERimeTests",
            dependencies: ["AllInOneIMERime"],
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [.unsafeFlags(["-L\(rimeLib)", "-Xlinker", "-rpath", "-Xlinker", rimeLib])]
        ),
    ]
)
