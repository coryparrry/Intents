// swift-tools-version: 6.2
import PackageDescription
let package = Package(name: "DuplicateTasksModel", platforms: [.macOS(.v26)],
    products: [.library(name: "DuplicateTasksModel", targets: ["DuplicateTasksModel"])],
    targets: [.target(name: "DuplicateTasksModel", path: "Models"),
              .testTarget(name: "DuplicateTasksModelTests", dependencies: ["DuplicateTasksModel"], path: "Tests")])
