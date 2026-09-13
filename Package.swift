// swift-tools-version: 6.3
//
// PrizmX-Kit — mid-platform bridge between PrizmX-Foundation and host apps.
//
// Module layout (strict one-way dependency):
//   PrizmX-Foundation  →  PrizmXServices  →  PrizmXUIEngine  →  PrizmXUIComponents
//
// Host apps import only the layer they need:
//   * PrizmXServices     — VPN IPC, profile persistence, node probing
//   * PrizmXUIEngine     — Observation ViewModels
//   * PrizmXUIComponents — reusable SwiftUI controls

import PackageDescription

let package = Package(
    name: "PrizmX-Kit",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
        .tvOS(.v17),
    ],
    products: [
        .library(name: "PrizmXServices", targets: ["PrizmXServices"]),
        .library(name: "PrizmXUIEngine", targets: ["PrizmXUIEngine"]),
        .library(name: "PrizmXUIComponents", targets: ["PrizmXUIComponents"]),
    ],
    dependencies: [
        // Sibling checkout: PrizmX/PrizmX-Foundation
        .package(path: "../PrizmX-Foundation"),
    ],
    targets: [
        .target(
            name: "PrizmXServices",
            dependencies: [
                .product(name: "PrizmXConfig", package: "PrizmX-Foundation"),
                .product(name: "PrizmXCore", package: "PrizmX-Foundation"),
                .product(name: "PrizmXNodes", package: "PrizmX-Foundation"),
                .product(name: "PrizmXProtocols", package: "PrizmX-Foundation"),
                .product(name: "PrizmXRules", package: "PrizmX-Foundation"),
                .product(
                    name: "PrizmXAttribution",
                    package: "PrizmX-Foundation",
                    condition: .when(platforms: [.macOS])
                ),
            ]
        ),
        .target(
            name: "PrizmXUIEngine",
            dependencies: ["PrizmXServices"]
        ),
        .target(
            name: "PrizmXUIComponents",
            dependencies: ["PrizmXUIEngine", "PrizmXServices"]
        ),
        .testTarget(
            name: "PrizmXServicesTests",
            dependencies: ["PrizmXServices"]
        ),
        .testTarget(
            name: "PrizmXUIEngineTests",
            dependencies: ["PrizmXUIEngine"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
