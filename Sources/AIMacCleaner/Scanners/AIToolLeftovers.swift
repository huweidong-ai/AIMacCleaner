import Foundation

// ───────────────────────────────────────────────────────────────────────────
// AI / 开发工具残留 —— 声明式注册表
//
// 数据来源：Prashant-123/aiclean（MIT 许可，https://github.com/Prashant-123/aiclean），
// 2026-08 搬运其 darwin 路径清单。仅取 macOS 相关路径。
//
// 设计定位（与现有扫描器互补，不重复）：
//   • `AIAgentScanner` 负责 `~` 根下的 AI 工具「点文件」痕迹（.claude / .cursor …），
//     且刻意不扫 `~/Library/Application Support` 与 `~/Library/Caches`、也不覆盖
//     ML 模型运行时和开发包管理器缓存。
//   • 本表正好补它不扫的部分：
//       1. macOS 下 AI 工具的 `~/Library/Application Support` / `~/Library/Caches`
//          GUI 应用缓存（Claude 桌面端、Cursor、Windsurf、VS Code、Zed… 的 Electron 缓存）；
//       2. ML 模型运行时（Ollama / Hugging Face / LM Studio / PyTorch / TensorFlow）；
//       3. 开发包管理器缓存（npm / yarn / pnpm / pip / cargo / gradle / maven / conda / Homebrew…）。
//   因此与 `AIAgentScanner` 同目录不会重复上报、不会把同一块磁盘算两遍。
//
// 已剔除的 aiclean 条目（避免误伤 / 重复）：
//   • `temp`(/tmp、/var/tmp)、`trash`(~/.Trash) —— 范围过广或有不可逆风险；
//   • Claude/Cursor/Windsurf/Aider/Continue/Copilot/Amazon Q 的 `~/.` 点文件与
//     `~/.config`、`~/.cache`、`~/.local/share` 路径 —— 已被 `AIAgentScanner` 覆盖，
//     这里只保留它们各自的 `~/Library/...` GUI 缓存，避免重复。
//
// 风险分级沿用 aiclean 三级：low（纯缓存，可安全删）/ medium（重建耗时）/
// high（模型等大文件，删了很贵）。本表只读、不直接删除；调用方负责展示与确认。
// ───────────────────────────────────────────────────────────────────────────

enum AIToolLeftovers {

    /// 风险三级（与 aiclean 对齐）。
    enum Risk: String, CaseIterable {
        case low, medium, high
        var symbol: String {
            switch self {
            case .low:    return "🟢"
            case .medium: return "🟠"
            case .high:   return "🔴"
            }
        }
        var label: String {
            switch self {
            case .low:    return "安全"
            case .medium: return "注意"
            case .high:   return "危险"
            }
        }
    }

    /// 一条具名路径（path 可含 ~，运行时展开）。
    struct NamedPath {
        let name: String
        let path: String
    }

    /// 一个工具的残留定义。
    struct Entry: Identifiable {
        let id: String          // aiclean 的 tool id
        let name: String
        let category: String
        let risk: Risk
        let riskReason: String
        let processNames: [String]
        let paths: [NamedPath]
    }

    /// 扫描后命中的结果。
    struct Found: Identifiable {
        let id: String
        let entry: Entry
        let hits: [(path: String, size: Int64)]
        var total: Int64 { hits.reduce(0) { $0 + $1.size } }
    }

    // MARK: - 注册表（darwin 路径，来自 aiclean）

    static let registry: [Entry] = [
        // ── AI Tools ───────────────────────────────────────────────
        Entry(id: "claude", name: "Claude Code / Desktop", category: "AI Tools", risk: .low,
              riskReason: "桌面端缓存与日志，下次启动自动重建",
              processNames: ["claude", "Claude"],
              paths: [
                NamedPath(name: "桌面端缓存", path: "~/Library/Application Support/Claude/Cache"),
                NamedPath(name: "Blob 存储", path: "~/Library/Application Support/Claude/blob_storage"),
                NamedPath(name: "代码缓存", path: "~/Library/Application Support/Claude/Code Cache"),
                NamedPath(name: "GPU 缓存", path: "~/Library/Application Support/Claude/GPUCache"),
                NamedPath(name: "日志", path: "~/Library/Application Support/Claude/logs"),
                NamedPath(name: "更新器缓存", path: "~/Library/Caches/com.anthropic.claudefordesktop"),
                NamedPath(name: "更新器 ShipIt", path: "~/Library/Caches/com.anthropic.claudefordesktop.ShipIt"),
              ]),
        Entry(id: "cursor", name: "Cursor", category: "AI Tools", risk: .low,
              riskReason: "Electron 缓存与日志，启动即重建",
              processNames: ["Cursor", "cursor"],
              paths: [
                NamedPath(name: "应用缓存", path: "~/Library/Application Support/Cursor/Cache"),
                NamedPath(name: "缓存数据", path: "~/Library/Application Support/Cursor/CachedData"),
                NamedPath(name: "缓存扩展", path: "~/Library/Application Support/Cursor/CachedExtensionVSIXs"),
                NamedPath(name: "缓存配置", path: "~/Library/Application Support/Cursor/CachedConfigurations"),
                NamedPath(name: "缓存配置数据", path: "~/Library/Application Support/Cursor/CachedProfilesData"),
                NamedPath(name: "代码缓存", path: "~/Library/Application Support/Cursor/Code Cache"),
                NamedPath(name: "Blob 存储", path: "~/Library/Application Support/Cursor/blob_storage"),
                NamedPath(name: "日志", path: "~/Library/Application Support/Cursor/logs"),
                NamedPath(name: "GPU 缓存", path: "~/Library/Application Support/Cursor/GPUCache"),
                NamedPath(name: "Service Worker", path: "~/Library/Application Support/Cursor/Service Worker"),
                NamedPath(name: "备份", path: "~/Library/Application Support/Cursor/Backups"),
              ]),
        Entry(id: "windsurf", name: "Windsurf (Codeium)", category: "AI Tools", risk: .low,
              riskReason: "Electron 缓存，启动即重建",
              processNames: ["Windsurf", "windsurf"],
              paths: [
                NamedPath(name: "应用缓存", path: "~/Library/Application Support/Windsurf/Cache"),
                NamedPath(name: "缓存数据", path: "~/Library/Application Support/Windsurf/CachedData"),
                NamedPath(name: "缓存扩展", path: "~/Library/Application Support/Windsurf/CachedExtensionVSIXs"),
                NamedPath(name: "代码缓存", path: "~/Library/Application Support/Windsurf/Code Cache"),
                NamedPath(name: "日志", path: "~/Library/Application Support/Windsurf/logs"),
                NamedPath(name: "Blob 存储", path: "~/Library/Application Support/Windsurf/blob_storage"),
                NamedPath(name: "GPU 缓存", path: "~/Library/Application Support/Windsurf/GPUCache"),
              ]),
        Entry(id: "cody", name: "Cody (Sourcegraph)", category: "AI Tools", risk: .low,
              riskReason: "Embeddings 缓存，下次索引重建",
              processNames: [],
              paths: [
                NamedPath(name: "embeddings", path: "~/.sourcegraph/cody"),
              ]),
        Entry(id: "tabnine", name: "Tabnine", category: "AI Tools", risk: .medium,
              riskReason: "含 ML 模型，重下约 500MB",
              processNames: ["TabNine"],
              paths: [
                NamedPath(name: "模型", path: "~/.tabnine/models"),
                NamedPath(name: "日志", path: "~/.tabnine/logs"),
                NamedPath(name: "缓存", path: "~/.tabnine/cache"),
                NamedPath(name: "系统缓存", path: "~/Library/Caches/TabNine"),
              ]),
        Entry(id: "amazon-q", name: "Amazon Q", category: "AI Tools", risk: .low,
              riskReason: "应用与系统缓存，使用即重建",
              processNames: ["amazon-q"],
              paths: [
                NamedPath(name: "应用缓存", path: "~/Library/Application Support/amazon-q"),
                NamedPath(name: "系统缓存", path: "~/Library/Caches/amazon-q"),
              ]),

        // ── ML Frameworks ──────────────────────────────────────────
        Entry(id: "huggingface", name: "Hugging Face", category: "ML Frameworks", risk: .high,
              riskReason: "模型 hub 可达 5–100+ GB，重下极慢",
              processNames: [],
              paths: [
                NamedPath(name: "模型 hub", path: "~/.cache/huggingface/hub"),
                NamedPath(name: "数据集", path: "~/.cache/huggingface/datasets"),
                NamedPath(name: "模块", path: "~/.cache/huggingface/modules"),
                NamedPath(name: "accelerate", path: "~/.cache/huggingface/accelerate"),
                NamedPath(name: "transformers(旧)", path: "~/.cache/huggingface/transformers"),
              ]),
        Entry(id: "pytorch", name: "PyTorch", category: "ML Frameworks", risk: .high,
              riskReason: "预训练模型 0.5–5GB，重下依赖网速",
              processNames: ["python", "python3"],
              paths: [
                NamedPath(name: "hub 模型", path: "~/.cache/torch/hub"),
                NamedPath(name: "编译内核", path: "~/.cache/torch/kernels"),
              ]),
        Entry(id: "tensorflow", name: "TensorFlow / Keras", category: "ML Frameworks", risk: .high,
              riskReason: "预训练模型与数据集数 GB，重下慢",
              processNames: ["python", "python3"],
              paths: [
                NamedPath(name: "Keras 模型", path: "~/.keras/models"),
                NamedPath(name: "Keras 数据集", path: "~/.keras/datasets"),
                NamedPath(name: "TF 缓存", path: "~/.cache/tensorflow"),
              ]),
        Entry(id: "ollama", name: "Ollama", category: "ML Frameworks", risk: .high,
              riskReason: "LLM 模型每个 2–50GB，重下 10–60+ 分钟",
              processNames: ["ollama"],
              paths: [
                NamedPath(name: "模型", path: "~/.ollama/models"),
                NamedPath(name: "日志", path: "~/.ollama/logs"),
              ]),
        Entry(id: "lm-studio", name: "LM Studio", category: "ML Frameworks", risk: .high,
              riskReason: "GGUF 模型每个 2–30GB，重下极慢",
              processNames: ["lms", "LM Studio"],
              paths: [
                NamedPath(name: "运行时缓存", path: "~/.cache/lm-studio"),
                NamedPath(name: "模型", path: "~/.lmstudio/models"),
              ]),

        // ── Editors ────────────────────────────────────────────────
        Entry(id: "vscode", name: "VS Code", category: "Editors", risk: .low,
              riskReason: "缓存与日志，重启即重建",
              processNames: ["code", "Code", "Electron"],
              paths: [
                NamedPath(name: "应用缓存", path: "~/Library/Application Support/Code/Cache"),
                NamedPath(name: "缓存数据", path: "~/Library/Application Support/Code/CachedData"),
                NamedPath(name: "缓存扩展", path: "~/Library/Application Support/Code/CachedExtensionVSIXs"),
                NamedPath(name: "缓存配置", path: "~/Library/Application Support/Code/CachedConfigurations"),
                NamedPath(name: "缓存配置数据", path: "~/Library/Application Support/Code/CachedProfilesData"),
                NamedPath(name: "代码缓存", path: "~/Library/Application Support/Code/Code Cache"),
                NamedPath(name: "Blob 存储", path: "~/Library/Application Support/Code/blob_storage"),
                NamedPath(name: "日志", path: "~/Library/Application Support/Code/logs"),
                NamedPath(name: "GPU 缓存", path: "~/Library/Application Support/Code/GPUCache"),
                NamedPath(name: "系统缓存", path: "~/Library/Caches/com.microsoft.VSCode"),
                NamedPath(name: "更新器缓存", path: "~/Library/Caches/com.microsoft.VSCode.ShipIt"),
              ]),
        Entry(id: "jetbrains", name: "JetBrains IDEs", category: "Editors", risk: .medium,
              riskReason: "索引与缓存重建在大项目上需数分钟",
              processNames: ["idea", "pycharm", "webstorm", "phpstorm", "goland", "clion", "datagrip", "rider", "rubymine", "studio"],
              paths: [
                NamedPath(name: "缓存", path: "~/Library/Caches/JetBrains"),
                NamedPath(name: "日志", path: "~/Library/Logs/JetBrains"),
                NamedPath(name: "配置与系统", path: "~/Library/Application Support/JetBrains"),
              ]),
        Entry(id: "zed", name: "Zed", category: "Editors", risk: .low,
              riskReason: "日志与语言服务缓存，下次使用重下",
              processNames: ["zed", "Zed"],
              paths: [
                NamedPath(name: "日志", path: "~/Library/Application Support/Zed/logs"),
                NamedPath(name: "embeddings", path: "~/Library/Application Support/Zed/embeddings"),
                NamedPath(name: "copilot 缓存", path: "~/Library/Application Support/Zed/copilot"),
                NamedPath(name: "languages", path: "~/Library/Application Support/Zed/languages"),
                NamedPath(name: "系统缓存", path: "~/Library/Caches/dev.zed.Zed"),
              ]),
        Entry(id: "xcode", name: "Xcode", category: "Editors", risk: .high,
              riskReason: "DerivedData 5–20GB，重建 10–30 分钟；Archives 可能含送审包",
              processNames: ["Xcode", "xcodebuild"],
              paths: [
                NamedPath(name: "DerivedData", path: "~/Library/Developer/Xcode/DerivedData"),
                NamedPath(name: "模拟器缓存", path: "~/Library/Developer/CoreSimulator/Caches"),
                NamedPath(name: "Archives", path: "~/Library/Developer/Xcode/Archives"),
              ]),
        Entry(id: "android-studio", name: "Android Studio", category: "Editors", risk: .high,
              riskReason: "AVD 镜像每个 2–8GB，重下 30+ 分钟",
              processNames: ["studio", "Android Studio", "qemu-system"],
              paths: [
                NamedPath(name: "AVD 镜像", path: "~/.android/avd"),
                NamedPath(name: "gradle 构建缓存", path: "~/.android/build-cache"),
                NamedPath(name: "调试 keystore", path: "~/.android/cache"),
              ]),
        Entry(id: "sublime", name: "Sublime Text", category: "Editors", risk: .low,
              riskReason: "索引与缓存，启动即重建",
              processNames: ["sublime_text", "Sublime Text"],
              paths: [
                NamedPath(name: "缓存", path: "~/Library/Caches/com.sublimetext.4"),
                NamedPath(name: "索引", path: "~/Library/Application Support/Sublime Text/Index"),
                NamedPath(name: "缓存文件", path: "~/Library/Application Support/Sublime Text/Cache"),
              ]),

        // ── Languages ──────────────────────────────────────────────
        Entry(id: "cargo", name: "Cargo (Rust)", category: "Languages", risk: .medium,
              riskReason: "注册表缓存与 git 依赖，重下可达数 GB",
              processNames: ["cargo", "rustc"],
              paths: [
                NamedPath(name: "注册表缓存", path: "~/.cargo/registry/cache"),
                NamedPath(name: "注册表源码", path: "~/.cargo/registry/src"),
                NamedPath(name: "git db", path: "~/.cargo/git/db"),
                NamedPath(name: "git checkouts", path: "~/.cargo/git/checkouts"),
              ]),
        Entry(id: "go", name: "Go", category: "Languages", risk: .medium,
              riskReason: "模块缓存跨项目共享，重下拖慢构建",
              processNames: ["go"],
              paths: [
                NamedPath(name: "模块缓存", path: "~/go/pkg/mod"),
                NamedPath(name: "构建缓存", path: "~/Library/Caches/go-build"),
              ]),
        Entry(id: "gradle", name: "Gradle", category: "Languages", risk: .high,
              riskReason: "依赖缓存 10–30GB，清后首构建 10–60 分钟",
              processNames: ["gradle", "gradlew", "java"],
              paths: [
                NamedPath(name: "依赖缓存", path: "~/.gradle/caches"),
                NamedPath(name: "wrapper dists", path: "~/.gradle/wrapper/dists"),
                NamedPath(name: "临时文件", path: "~/.gradle/.tmp"),
                NamedPath(name: "daemon 日志", path: "~/.gradle/daemon"),
              ]),
        Entry(id: "maven", name: "Maven", category: "Languages", risk: .high,
              riskReason: "本地仓库是所有 Maven 项目的依赖缓存，重建 30+ 分钟",
              processNames: ["mvn", "mvnw"],
              paths: [
                NamedPath(name: "本地仓库", path: "~/.m2/repository"),
              ]),
        Entry(id: "python", name: "Python (ruff)", category: "Languages", risk: .low,
              riskReason: "Ruff 缓存，下次 lint 即时重建",
              processNames: [],
              paths: [
                NamedPath(name: "ruff 缓存", path: "~/Library/Caches/ruff"),
              ]),

        // ── Build Tools ────────────────────────────────────────────
        Entry(id: "docker", name: "Docker", category: "Build Tools", risk: .medium,
              riskReason: "buildx 缓存元数据，无层缓存下次构建更慢",
              processNames: ["docker", "dockerd", "Docker Desktop"],
              paths: [
                NamedPath(name: "buildx 缓存", path: "~/.docker/buildx"),
              ]),
        Entry(id: "turborepo", name: "Turborepo", category: "Build Tools", risk: .low,
              riskReason: "构建输出缓存，无命中 turbo 直接重建",
              processNames: ["turbo"],
              paths: [
                NamedPath(name: "全局缓存", path: "~/Library/Caches/turborepo"),
              ]),
        Entry(id: "watchman", name: "Watchman", category: "Build Tools", risk: .low,
              riskReason: "文件监听状态，重启即重建",
              processNames: ["watchman"],
              paths: [
                NamedPath(name: "状态", path: "/opt/homebrew/var/run/watchman"),
                NamedPath(name: "状态(Intel)", path: "/usr/local/var/run/watchman"),
              ]),

        // ── Cloud & DevOps ─────────────────────────────────────────
        Entry(id: "aws", name: "AWS CLI", category: "Cloud & DevOps", risk: .low,
              riskReason: "API 响应缓存，下次调用即刷新",
              processNames: ["aws"],
              paths: [
                NamedPath(name: "CLI 缓存", path: "~/.aws/cli/cache"),
              ]),
        Entry(id: "gcloud", name: "Google Cloud CLI", category: "Cloud & DevOps", risk: .low,
              riskReason: "仅命令日志，不影响功能",
              processNames: ["gcloud"],
              paths: [
                NamedPath(name: "日志", path: "~/.config/gcloud/logs"),
              ]),
        Entry(id: "kubernetes", name: "Kubernetes", category: "Cloud & DevOps", risk: .low,
              riskReason: "API 发现缓存，kubectl 自动刷新",
              processNames: ["kubectl"],
              paths: [
                NamedPath(name: "发现缓存", path: "~/.kube/cache/discovery"),
                NamedPath(name: "HTTP 缓存", path: "~/.kube/cache/http"),
              ]),
        Entry(id: "helm", name: "Helm", category: "Cloud & DevOps", risk: .low,
              riskReason: "chart 索引缓存，下次 repo 更新重下",
              processNames: ["helm"],
              paths: [
                NamedPath(name: "仓库缓存", path: "~/Library/Caches/helm/repository"),
                NamedPath(name: "缓存", path: "~/Library/Caches/helm"),
              ]),
        Entry(id: "terraform", name: "Terraform", category: "Cloud & DevOps", risk: .medium,
              riskReason: "provider 插件缓存，重下可达 500MB+",
              processNames: ["terraform"],
              paths: [
                NamedPath(name: "插件缓存", path: "~/.terraform.d/plugin-cache"),
              ]),
        Entry(id: "vagrant", name: "Vagrant", category: "Cloud & DevOps", risk: .high,
              riskReason: "VM box 镜像每个 1–5GB，重下 10–30 分钟",
              processNames: ["vagrant", "VBoxHeadless"],
              paths: [
                NamedPath(name: "临时文件", path: "~/.vagrant.d/tmp"),
                NamedPath(name: "boxes", path: "~/.vagrant.d/boxes"),
              ]),

        // ── Package Managers ───────────────────────────────────────
        Entry(id: "npm", name: "npm", category: "Package Managers", risk: .medium,
              riskReason: "包缓存加速安装，清掉下次重下",
              processNames: ["npm"],
              paths: [
                NamedPath(name: "包缓存", path: "~/.npm/_cacache"),
                NamedPath(name: "安装日志", path: "~/.npm/_logs"),
                NamedPath(name: "npx 缓存", path: "~/.npm/_npx"),
              ]),
        Entry(id: "yarn", name: "Yarn", category: "Package Managers", risk: .medium,
              riskReason: "离线镜像缓存，下次安装重下",
              processNames: ["yarn"],
              paths: [
                NamedPath(name: "v1 缓存", path: "~/Library/Caches/Yarn/v6"),
                NamedPath(name: "berry 缓存", path: "~/.yarn/berry/cache"),
              ]),
        Entry(id: "pnpm", name: "pnpm", category: "Package Managers", risk: .medium,
              riskReason: "内容寻址存储跨项目共享，重下即慢",
              processNames: ["pnpm"],
              paths: [
                NamedPath(name: "store", path: "~/Library/pnpm/store/v3"),
                NamedPath(name: "缓存", path: "~/.cache/pnpm"),
                NamedPath(name: "store(alt)", path: "~/.local/share/pnpm/store/v3"),
              ]),
        Entry(id: "pip", name: "pip", category: "Package Managers", risk: .low,
              riskReason: "wheel 与 HTTP 缓存，按需重下",
              processNames: ["pip", "pip3"],
              paths: [
                NamedPath(name: "wheel 缓存", path: "~/Library/Caches/pip/wheels"),
                NamedPath(name: "HTTP 缓存", path: "~/Library/Caches/pip/http"),
                NamedPath(name: "HTTP v2 缓存", path: "~/Library/Caches/pip/http-v2"),
                NamedPath(name: "selfcheck", path: "~/Library/Caches/pip/selfcheck"),
              ]),
        Entry(id: "conda", name: "Conda", category: "Package Managers", risk: .high,
              riskReason: "包 tarball 5–20GB 且重下极慢，使用中清理可能破坏环境",
              processNames: ["conda", "mamba"],
              paths: [
                NamedPath(name: "包 tarball", path: "~/miniconda3/pkgs"),
                NamedPath(name: "anaconda 包", path: "~/anaconda3/pkgs"),
                NamedPath(name: "miniforge 包", path: "~/miniforge3/pkgs"),
                NamedPath(name: "mambaforge 包", path: "~/mambaforge/pkgs"),
              ]),
        Entry(id: "poetry", name: "Poetry", category: "Package Managers", risk: .low,
              riskReason: "下载产物缓存，下次安装重取",
              processNames: ["poetry"],
              paths: [
                NamedPath(name: "artifacts", path: "~/Library/Caches/pypoetry/artifacts"),
                NamedPath(name: "缓存", path: "~/Library/Caches/pypoetry/cache"),
              ]),
        Entry(id: "pipenv", name: "Pipenv", category: "Package Managers", risk: .low,
              riskReason: "HTTP 缓存，下次安装重下",
              processNames: ["pipenv"],
              paths: [
                NamedPath(name: "缓存", path: "~/Library/Caches/pipenv"),
              ]),
        Entry(id: "homebrew", name: "Homebrew", category: "Package Managers", risk: .low,
              riskReason: "已下载的 bottle/cask，brew 下次安装重下",
              processNames: ["brew"],
              paths: [
                NamedPath(name: "下载", path: "~/Library/Caches/Homebrew/downloads"),
                NamedPath(name: "cask 下载", path: "~/Library/Caches/Homebrew/Cask"),
                NamedPath(name: "API 缓存", path: "~/Library/Caches/Homebrew/api"),
              ]),
        Entry(id: "cocoapods", name: "CocoaPods", category: "Package Managers", risk: .medium,
              riskReason: "pod specs 缓存，从 CDN 重新 clone 需数分钟",
              processNames: ["pod"],
              paths: [
                NamedPath(name: "缓存", path: "~/Library/Caches/CocoaPods"),
              ]),
        Entry(id: "rubygems", name: "Ruby Gems", category: "Package Managers", risk: .low,
              riskReason: "Bundler 下载缓存，从 rubygems 重取",
              processNames: ["bundle", "gem"],
              paths: [
                NamedPath(name: "bundler 缓存", path: "~/.bundle/cache"),
              ]),

        // ── System ─────────────────────────────────────────────────
        Entry(id: "chrome", name: "Google Chrome", category: "System", risk: .low,
              riskReason: "浏览器缓存，Chrome 自动重建",
              processNames: ["Google Chrome", "chrome"],
              paths: [
                NamedPath(name: "HTTP 缓存", path: "~/Library/Caches/Google/Chrome/Default/Cache"),
                NamedPath(name: "代码缓存", path: "~/Library/Caches/Google/Chrome/Default/Code Cache"),
                NamedPath(name: "GPU 缓存", path: "~/Library/Application Support/Google/Chrome/Default/GPUCache"),
                NamedPath(name: "Dawn 缓存", path: "~/Library/Application Support/Google/Chrome/Default/DawnGraphiteCache"),
                NamedPath(name: "WebGPU 缓存", path: "~/Library/Application Support/Google/Chrome/Default/DawnWebGPUCache"),
                NamedPath(name: "Blob 存储", path: "~/Library/Application Support/Google/Chrome/Default/blob_storage"),
                NamedPath(name: "Service Worker", path: "~/Library/Application Support/Google/Chrome/Default/Service Worker"),
              ]),
        Entry(id: "firefox", name: "Firefox", category: "System", risk: .low,
              riskReason: "浏览器缓存，下次浏览重建",
              processNames: ["firefox", "Firefox"],
              paths: [
                NamedPath(name: "缓存", path: "~/Library/Caches/Firefox"),
              ]),
        Entry(id: "safari", name: "Safari", category: "System", risk: .low,
              riskReason: "浏览器缓存，自动重建",
              processNames: ["Safari"],
              paths: [
                NamedPath(name: "缓存", path: "~/Library/Caches/com.apple.Safari"),
                NamedPath(name: "WebKit 缓存", path: "~/Library/Caches/com.apple.WebKit.WebContent"),
              ]),
        Entry(id: "system-logs", name: "System Logs", category: "System", risk: .medium,
              riskReason: "应用日志，调试时可能有用，建议保留近期",
              processNames: [],
              paths: [
                NamedPath(name: "用户日志", path: "~/Library/Logs"),
              ]),
    ]

    // MARK: - 扫描

    /// 展开 ~ 并判断存在；存在则算尺寸。只读、不删。返回命中条目（按占用从大到小）。
    static func scan() -> [Found] {
        let fm = FileManager.default
        var out: [Found] = []
        for e in registry {
            var hits: [(path: String, size: Int64)] = []
            for p in e.paths {
                let expanded = (p.path as NSString).expandingTildeInPath
                guard fm.fileExists(atPath: expanded) else { continue }
                let url = URL(fileURLWithPath: expanded)
                let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
                let size: Int64
                if isDir {
                    size = (try? url.directorySize()) ?? 0
                } else {
                    size = Int64((try? fm.attributesOfItem(atPath: expanded)[.size] as? UInt64 ?? 0) ?? 0)
                }
                hits.append((expanded, size))
            }
            if !hits.isEmpty {
                out.append(Found(id: e.id, entry: e, hits: hits))
            }
        }
        return out.sorted {
            $0.total != $1.total ? $0.total > $1.total : $0.entry.name < $1.entry.name
        }
    }

    // MARK: - CLI

    /// `--ai-tools`：列出检测到的 AI / 开发工具残留（仅扫描、不删除）。
    static func scanCLI() -> Int32 {
        let found = scan()
        let fmt = ByteCountFormatter()
        fmt.allowedUnits = [.useGB, .useMB, .useKB]
        fmt.countStyle = .file

        guard !found.isEmpty else {
            print("未检测到已知的 AI / 开发工具残留。")
            return 0
        }

        var total: Int64 = 0
        print("检测到的 AI / 开发工具残留（仅扫描、不删除）：")
        print("")
        for f in found {
            total += f.total
            print("\(f.entry.risk.symbol) \(f.entry.name)  [\(f.entry.category) · \(f.entry.risk.label)]  \(fmt.string(fromByteCount: f.total))")
            for h in f.hits {
                print("      \(h.path)  (\(fmt.string(fromByteCount: h.size)))")
            }
        }
        print("")
        print("合计可回收：\(fmt.string(fromByteCount: total))")
        print("删除请在图形界面「残留」页确认，或继续用 --orphans；本命令只列出。")
        return 0
    }
}
