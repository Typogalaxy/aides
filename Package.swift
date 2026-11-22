// swift-tools-version: 6.0
import Foundation
import PackageDescription

let enableSparkle = ProcessInfo.processInfo.environment["AIDES_ENABLE_SPARKLE"] == "1"

var dependencies: [Package.Dependency] = [
    .package(url: "https://github.com/vapor/vapor.git", exact: "4.115.1"),
    .package(url: "https://github.com/swift-server/async-http-client.git", exact: "1.37.0")
]

var desktopDependencies: [Target.Dependency] = ["AidesCore"]
if enableSparkle {
    dependencies.append(.package(url: "https://github.com/sparkle-project/Sparkle.git", exact: "2.9.1"))
    desktopDependencies.append(.product(name: "Sparkle", package: "Sparkle"))
}

let package = Package(
    name: "Aides",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "AidesServer", targets: ["AidesServer"]),
        .executable(name: "AidesDesktop", targets: ["AidesDesktop"])
    ],
    dependencies: dependencies,
    targets: [
        .target(name: "AidesCore"),
        .target(name: "AidesExecution", dependencies: ["AidesCore"]),
        .executableTarget(
            name: "AidesServer",
            dependencies: [
                "AidesCore", "AidesExecution",
                .product(name: "Vapor", package: "vapor"),
                .product(name: "AsyncHTTPClient", package: "async-http-client")
            ]
        ),
        .executableTarget(name: "AidesDesktop", dependencies: desktopDependencies),
        .testTarget(name: "AidesCoreTests", dependencies: ["AidesCore"]),
        .testTarget(name: "AidesExecutionTests", dependencies: ["AidesExecution"])
    ]
)
