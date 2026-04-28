// swift-tools-version: 6.1

import PackageDescription

let package = Package(
    name: "ArbiterShowcase",
    platforms: [.iOS(.v17), .macOS(.v14)],
    dependencies: [
        .package(path: "../../")
    ],
    targets: [
        .executableTarget(
            name: "ArbiterShowcase",
            dependencies: [
                .product(name: "Arbiter", package: "Arbiter")
            ],
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Info.plist"
                ])
            ]
        )
    ]
)
