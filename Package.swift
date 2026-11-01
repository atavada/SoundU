// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SoundU",
    platforms: [.macOS("14.4")],
    products: [
        .executable(name: "SoundU", targets: ["SoundU"]),
    ],
    targets: [
        .target(
            name: "CSoundUDSP",
            linkerSettings: [.linkedFramework("Accelerate")]
        ),
        .target(
            name: "SoundUCore",
            dependencies: ["CSoundUDSP"],
            linkerSettings: [
                .linkedFramework("Accelerate"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("AudioToolbox"),
            ]
        ),
        .executableTarget(
            name: "SoundU",
            dependencies: ["SoundUCore"]
        ),
        .testTarget(
            name: "SoundUDSPTests",
            dependencies: ["CSoundUDSP"]
        ),
        .testTarget(
            name: "SoundUCoreTests",
            dependencies: ["SoundUCore"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
