// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PrettyFolderKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "PrettyFolderKit", targets: ["PrettyFolderKit"]),
        .library(name: "PrettyFolderIPC", targets: ["PrettyFolderIPC"]),
    ],
    targets: [
        // Tiny module shared with the Finder extension: the command format only.
        .target(name: "PrettyFolderIPC"),
        // Everything that touches images and folders.
        .target(name: "PrettyFolderKit", dependencies: ["PrettyFolderIPC"]),
        .testTarget(name: "PrettyFolderKitTests", dependencies: ["PrettyFolderKit"]),
    ]
)
