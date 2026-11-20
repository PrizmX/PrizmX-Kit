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
//   * PrizmXProxyHelper  — macOS privileged helper XPC contract and writer

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
        .library(name: "PrizmXMacUI", targets: ["PrizmXMacUI"]),
        // Linked by the app's privileged helper tool; no other dependencies.
        .library(name: "PrizmXProxyHelper", targets: ["PrizmXProxyHelper"]),
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
                .product(name: "PrizmXScripts", package: "PrizmX-Foundation"),
                .product(
                    name: "PrizmXAttribution",
                    package: "PrizmX-Foundation",
                    condition: .when(platforms: [.macOS])
                ),
                .target(name: "PrizmXProxyHelper", condition: .when(platforms: [.macOS])),
            ]
        ),
        .target(name: "PrizmXProxyHelper"),
        .target(
            name: "PrizmXUIEngine",
            dependencies: ["PrizmXServices"]
        ),
        .target(
            name: "PrizmXUIComponents",
            dependencies: ["PrizmXUIEngine", "PrizmXServices"]
        ),
        .target(
            name: "PrizmXMacUI",
            dependencies: [
                "PrizmXServices",
                "PrizmXUIEngine",
                "PrizmXUIComponents",
                .product(name: "PrizmXConfig", package: "PrizmX-Foundation"),
                .product(name: "PrizmXNodes", package: "PrizmX-Foundation"),
                .product(name: "PrizmXProtocols", package: "PrizmX-Foundation"),
                .product(name: "PrizmXScripts", package: "PrizmX-Foundation"),
            ],
            swiftSettings: [
                .defaultIsolation(MainActor.self),
                .swiftLanguageMode(.v5),
            ]
        ),
        .testTarget(
            name: "PrizmXServicesTests",
            dependencies: ["PrizmXServices", "PrizmXProxyHelper"]
        ),
        .testTarget(
            name: "PrizmXUIEngineTests",
            dependencies: ["PrizmXUIEngine"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
