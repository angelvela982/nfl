// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "NFLPulseCore",
    platforms: [.macOS(.v13), .iOS(.v17)],
    products: [.library(name: "NFLPulseCore", targets: ["NFLPulseCore"])],
    targets: [
        .target(name: "NFLPulseCore", path: "NFLPulse",
                exclude: ["AppStore.swift", "NFLPulseApp.swift", "Views.swift", "Info.plist"],
                sources: ["Models.swift", "CSV.swift", "DataService.swift", "ProjectionEngine.swift", "WeatherService.swift", "LiveContextService.swift"]),
        .testTarget(name: "NFLPulseCoreTests", dependencies: ["NFLPulseCore"], path: "NFLPulseTests")
    ]
)
