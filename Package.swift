// swift-tools-version: 6.0
import PackageDescription

// Semantouch — native macOS computer-use MCP helper (clean-room, public APIs only).
//
// Language mode: Swift 5 for every target. The Accessibility C-API layer that the
// engines will grow into is hostile to strict concurrency checking, so the whole
// package pins language mode 5 (see `swiftLanguageModes` below) to keep the AX/CG
// code buildable without `@Sendable`/actor churn. Targets add no external deps.
let package = Package(
    name: "semantouch",
    platforms: [
        .macOS(.v14) // README target: macOS 14.4+
    ],
    products: [
        .executable(name: "semantouch", targets: ["SemantouchCLI"]),
        .executable(name: "computer-use-fixture", targets: ["computer-use-fixture"]),
        .library(name: "ComputerUseCore", targets: ["ComputerUseCore"]),
        .library(name: "AccessibilityEngine", targets: ["AccessibilityEngine"]),
        .library(name: "CaptureEngine", targets: ["CaptureEngine"]),
        .library(name: "ActionEngine", targets: ["ActionEngine"]),
        .library(name: "MCPServer", targets: ["MCPServer"]),
        .library(name: "CursorOverlay", targets: ["CursorOverlay"]),
        .library(name: "ComputerUseService", targets: ["ComputerUseService"]),
    ],
    targets: [
        // Shared DTOs, policies, session state, and cross-module contracts.
        .target(name: "ComputerUseCore"),

        // Native accessibility, capture, and action engines.
        .target(
            name: "AccessibilityEngine",
            dependencies: ["ComputerUseCore"]
        ),
        .target(
            name: "CaptureEngine",
            dependencies: ["ComputerUseCore"]
        ),
        .target(
            name: "ActionEngine",
            dependencies: ["ComputerUseCore", "AccessibilityEngine"]
        ),
        .target(
            name: "MCPServer",
            dependencies: ["ComputerUseCore"]
        ),

        // Virtual cursor geometry, animation, lifecycle, and a nonactivating
        // AppKit panel behind a presenter seam. Public AppKit only.
        .target(
            name: "CursorOverlay",
            dependencies: ["ComputerUseCore"]
        ),

        // Integration layer: wires the engines into tool handlers, the MCP
        // runtime, and CLI diagnostics. Exercised by ProtocolContractTests.
        .target(
            name: "ComputerUseService",
            dependencies: [
                "ComputerUseCore",
                "AccessibilityEngine",
                "CaptureEngine",
                "ActionEngine",
                "CursorOverlay",
                "MCPServer",
            ]
        ),

        // Executables.
        .executableTarget(
            name: "SemantouchCLI",
            dependencies: [
                "ComputerUseCore",
                "AccessibilityEngine",
                "CaptureEngine",
                "ActionEngine",
                "CursorOverlay",
                "MCPServer",
                "ComputerUseService",
            ],
            path: "Sources/SemantouchCLI"
        ),
        .executableTarget(
            name: "computer-use-fixture",
            path: "Sources/ComputerUseFixture"
        ),

        // Test targets (library dependencies only).
        .testTarget(
            name: "ComputerUseCoreTests",
            dependencies: ["ComputerUseCore"]
        ),
        .testTarget(
            name: "AccessibilityEngineTests",
            dependencies: ["AccessibilityEngine", "ComputerUseCore"]
        ),
        .testTarget(
            name: "CaptureEngineTests",
            dependencies: ["CaptureEngine", "ComputerUseCore"]
        ),
        .testTarget(
            name: "MCPServerTests",
            dependencies: ["MCPServer", "ComputerUseCore"]
        ),
        .testTarget(
            name: "ActionEngineTests",
            dependencies: ["ActionEngine", "ComputerUseCore"]
        ),
        .testTarget(
            name: "CursorOverlayTests",
            dependencies: ["CursorOverlay", "ComputerUseCore"]
        ),
        .testTarget(
            name: "ProtocolContractTests",
            dependencies: ["ComputerUseCore", "MCPServer", "ComputerUseService"]
        ),
    ],
    swiftLanguageModes: [.v5]
)
