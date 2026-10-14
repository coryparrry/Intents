// swift-tools-version: 6.2
import PackageDescription
let package = Package(name: "AutomationFixtureModel", platforms: [.macOS(.v26)],
    products: [.library(name: "AutomationFixtureModel", targets: ["AutomationFixtureModel"])],
    targets: [.target(name: "AutomationFixtureModel", path: "Models"),
              .testTarget(name: "AutomationFixtureModelTests", dependencies: ["AutomationFixtureModel"], path: "Tests")])
