// swift-tools-version:6.0
import PackageDescription

// HymnTranslate — Swift 6 / SwiftUI / AppKit / Metal / libsqlite3
//
// 2026-11-21 起为**单后端产品版**：D-1 原生 Metal (affine INT4) 与 MLX Swift
// 两个并列后端已退役，唯一推理后端是 HymnSTQ 的
// Sherry STQ1_0 1.3125 bpw 常驻 GEMV（Hy-MT2-1.8B-1.25Bit.gguf）。
//
// 工程零外部 SwiftPM 依赖：不链接 MLX、不需要 metal-cpp / .metallib / Xcode
// MetalToolchain cryptex，构建期也不访问网络，运行时全程离线。
// 权重格式如实标注 STQ1_0，绝不冒充 LUT4 / affine INT4。
let package = Package(
    name: "HymnTranslate",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "HymnCore", targets: ["HymnCore"]),
        .library(name: "HymnStore", targets: ["HymnStore"]),
        .library(name: "HymnSTQ", targets: ["HymnSTQ"]),
        .executable(name: "hymnctl", targets: ["hymnctl"]),
        .executable(name: "hymntest", targets: ["hymntest"]),
        .executable(name: "HymnTranslate", targets: ["HymnApp"]),
    ],
    targets: [
        .target(
            name: "HymnCore",
            dependencies: [],
            path: "Sources/HymnCore",
            swiftSettings: [.swiftLanguageMode(.v6)],
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .target(
            name: "HymnSTQ",
            dependencies: ["HymnCore"],
            path: "Sources/HymnSTQ",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "HymnStore",
            dependencies: ["HymnCore"],
            path: "Sources/HymnStore",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "hymnctl",
            dependencies: ["HymnCore", "HymnStore", "HymnSTQ"],
            path: "Sources/hymnctl",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "hymntest",
            dependencies: ["HymnCore", "HymnStore", "HymnSTQ"],
            path: "Sources/hymntest",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "HymnApp",
            dependencies: ["HymnCore", "HymnStore", "HymnSTQ"],
            path: "Sources/HymnApp",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
