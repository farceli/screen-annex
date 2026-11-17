// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "HosMirror",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "HosMirror", targets: ["HosMirrorApp"]),
    ],
    targets: [
        .target(name: "HosMirrorCore", path: "Sources/HosMirrorCore"),
        .executableTarget(
            name: "HosMirrorApp",
            dependencies: ["HosMirrorCore"],
            path: "Sources/HosMirrorApp"
        ),
        .executableTarget(
            name: "HosMirrorProbe",
            dependencies: ["HosMirrorCore"],
            path: "Sources/HosMirrorProbe"
        ),
        .testTarget(
            name: "HosMirrorCoreTests",
            dependencies: ["HosMirrorCore"],
            path: "Tests/HosMirrorCoreTests",
            exclude: ["Resources/README.md"], // 来源说明保留在仓库，测试包只复制码流。
            resources: [.copy("Resources/sample.h264")]
        ),
    ],
    swiftLanguageModes: [.v5]
)
