// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Foldera",
    platforms: [.macOS(.v14)],
    targets: [
        // libarchive, which macOS ships without a header: opens RAR, 7z, zip, tar…
        .target(
            name: "CArchive",
            path: "Sources/CArchive",
            linkerSettings: [.linkedLibrary("archive")]
        ),
        .executableTarget(
            name: "Foldera",
            dependencies: ["CArchive"],
            path: "Sources/Foldera",
            // The whole interface lives on the main thread; Swift 6's strict
            // isolation would only add ceremony here.
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "FolderaTests",
            dependencies: ["Foldera"],
            path: "Tests/FolderaTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
