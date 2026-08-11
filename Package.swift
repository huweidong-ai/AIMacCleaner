// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "AIMacCleaner",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "ai-mac-cleaner", targets: ["AIMacCleaner"])
    ],
    dependencies: [
        // OpenAI 兼容协议（customOpenAI）的成熟社区 SDK。
        // 注意：目前指向 main 分支——所需 ChatQuery / maxCompletionTokens 等 API
        // 尚未打 release tag（最新 tag 仅 0.5.1，仍是旧 API）。待官方发版后钉到具体版本。
        .package(url: "https://github.com/MacPaw/OpenAI.git", branch: "main"),
        // Anthropic 兼容协议（customAnthropic）的成熟社区 SDK（macOS 12+，Apple 平台零外部依赖）。
        .package(url: "https://github.com/jamesrochabrun/SwiftAnthropic.git", from: "2.1.8"),
        // SwiftUI 原生 Markdown 渲染（支持 GitHub 风格表格、代码块、列表等）。
        .package(url: "https://github.com/gonzalezreal/swift-markdown-ui", from: "2.4.1")
    ],
    targets: [
        .executableTarget(
            name: "AIMacCleaner",
            dependencies: [
                .product(name: "OpenAI", package: "OpenAI"),
                .product(name: "SwiftAnthropic", package: "SwiftAnthropic"),
                .product(name: "MarkdownUI", package: "swift-markdown-ui")
            ],
            path: "Sources/AIMacCleaner"
        )
    ]
)
