// swift-tools-version: 6.2
import PackageDescription
let package = Package(name: "ProductionEvals", platforms: [.macOS(.v26), .iOS(.v26)],
    products: [.library(name: "ProductionEvals", targets: ["ProductionEvals"])],
    targets: [.target(name: "ProductionEvals"), .testTarget(name: "ProductionEvalsTests", dependencies: ["ProductionEvals"])])
