// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "TinyPrinter",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "TinyPrinter", targets: ["TinyPrinterApp"]),
        .executable(name: "tinyprint", targets: ["tinyprint"]),
        .library(name: "TinyPrinterKit", targets: ["TinyPrinterKit"]),
    ],
    targets: [
        .target(name: "TinyPrinterKit"),
        .executableTarget(name: "TinyPrinterApp", dependencies: ["TinyPrinterKit"]),
        .executableTarget(name: "tinyprint", dependencies: ["TinyPrinterKit"]),
        .testTarget(name: "TinyPrinterKitTests", dependencies: ["TinyPrinterKit"]),
    ]
)
