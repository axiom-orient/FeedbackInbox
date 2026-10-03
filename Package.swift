// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "FeedbackInbox",
    defaultLocalization: "en",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "FeedbackInbox", targets: ["FeedbackInbox"])],
    targets: [
        .target(name: "FeedbackInbox", resources: [.process("Resources")]),
        .testTarget(name: "FeedbackInboxTests", dependencies: ["FeedbackInbox"])
    ],
    swiftLanguageModes: [.v6]
)
