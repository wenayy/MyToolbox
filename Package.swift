// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "MyToolbox",
    platforms: [.macOS(.v26)],
    targets: [
        .executableTarget(
            name: "MyToolbox",
            path: "Sources/MyToolbox",
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [
                .linkedFramework("Carbon"),
                .linkedFramework("ServiceManagement"),
                .linkedFramework("MapKit"),
                .linkedFramework("Vision"),
                .linkedFramework("PDFKit"),
                .linkedFramework("Speech"),
                .linkedFramework("Translation"),
                .linkedFramework("FoundationModels"),
                .linkedFramework("QuickLookThumbnailing"),
                .linkedFramework("CoreWLAN"),
                .linkedFramework("IOKit"),
                .linkedFramework("WebKit"),
                .linkedFramework("Quartz"),
                .linkedFramework("AVKit"),
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("Photos"),
            ]
        )
    ]
)
