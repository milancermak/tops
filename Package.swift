// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Tops",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "Tops", targets: ["Tops"])],
    targets: [
        .executableTarget(name: "Tops"),
        .testTarget(name: "TopsTests", dependencies: ["Tops"])
    ]
)
